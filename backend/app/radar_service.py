"""Radar grids for the app's on-device renderer (ADR 0010).

The app no longer displays GeoMet's server-styled tiles. It draws radar itself,
from numbers, with one colour ramp shared by observed radar and the model
forecast. This module turns ECCC's two sources into one grid format:

* **Observed radar** (`RADAR_1KM_RRAI`). ECCC publishes no raw grid for it: WCS
  is disabled on the layer, the Datamart carries only pre-coloured per-site
  GIFs, and the raw folder on HPFX is not public (all verified 2026-09-11). But
  GeoMet honours an SLD 1.0 `ColorMap` sent with the request, as intervals. So
  the request carries a style whose every interval paints its own class number
  into the red channel, and the PNG comes back holding class codes, not
  colours. That is exact to the class (35 of 35 pixels checked against
  GetFeatureInfo's raw values), with no guessing at ECCC's palette.
* **Model forecast** (`HRDPS.CONTINENTAL_RT`). WCS serves raw floats in
  kg/(m^2 s), which is mm/s. Pinned to one model run with `DIM_REFERENCE_TIME`.

Both land on the same Web Mercator grid over Alberta, so the app can place the
image between two projected corners and it stays locked to the map at every
zoom, and both are quantised to the same code table. Frames are gzip'd uint8
codes, one byte per pixel.

Everything is fetched from ECCC on demand, once per machine, and cached in
memory. The phone holds its own delta cache, so a warm phone asks for very
little.
"""

from __future__ import annotations

import gzip
import http.client
import json
import math
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from io import BytesIO
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

import numpy as np
from PIL import Image

GEOMET_URL = "https://geo.weather.gc.ca/geomet"
RADAR_LAYER = "RADAR_1KM_RRAI"
FORECAST_LAYER = "HRDPS.CONTINENTAL_RT"
ALERTS_COLLECTION_URL = "https://api.weather.gc.ca/collections/weather-alerts/items"

USER_AGENT = "alberta-weather-api (radar grids)"


class RadarError(RuntimeError):
    """Radar data could not be produced. Carries a reason fit for a 502."""


# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------

EARTH_RADIUS_M = 6378137.0

# Alberta plus a margin: weather mostly arrives from British Columbia, so the
# west edge reaches into it.
GRID_WEST, GRID_EAST = -122.5, -108.5
GRID_SOUTH, GRID_NORTH = 48.5, 60.3

GRID_PIXEL_M = 2000.0
"""Web Mercator metres per pixel: 1.3 km on the ground at the US border, 1.0 km
at 60N. Radar's native grid is 1 km, so this is close to native across the
province without doubling the pixel count."""


def merc_x(lon: float) -> float:
    return EARTH_RADIUS_M * math.radians(lon)


def merc_y(lat: float) -> float:
    return EARTH_RADIUS_M * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))


def lon_of_x(x):
    return np.degrees(np.asarray(x, dtype=np.float64) / EARTH_RADIUS_M)


def lat_of_y(y):
    y = np.asarray(y, dtype=np.float64)
    return np.degrees(2 * np.arctan(np.exp(y / EARTH_RADIUS_M)) - math.pi / 2)


@dataclass(frozen=True)
class Grid:
    xmin: float
    ymin: float
    width: int
    height: int
    pixel_m: float

    @property
    def xmax(self) -> float:
        return self.xmin + self.width * self.pixel_m

    @property
    def ymax(self) -> float:
        return self.ymin + self.height * self.pixel_m

    def spec(self) -> dict:
        return {
            "crs": "EPSG:3857",
            "xmin": self.xmin,
            "ymin": self.ymin,
            "xmax": self.xmax,
            "ymax": self.ymax,
            "width": self.width,
            "height": self.height,
            "pixel_m": self.pixel_m,
            # Row 0 is the north edge, as in an image.
            "row_order": "north_to_south",
        }


def _make_grid() -> Grid:
    px = GRID_PIXEL_M
    x0 = math.floor(merc_x(GRID_WEST) / px) * px
    x1 = math.ceil(merc_x(GRID_EAST) / px) * px
    y0 = math.floor(merc_y(GRID_SOUTH) / px) * px
    y1 = math.ceil(merc_y(GRID_NORTH) / px) * px
    return Grid(x0, y0, int(round((x1 - x0) / px)), int(round((y1 - y0) / px)), px)


GRID = _make_grid()


# ---------------------------------------------------------------------------
# Code table
# ---------------------------------------------------------------------------

CODE_CLASSES = 120
"""Log-spaced classes from 0.1 to 200 mm/h, 6.6% wide. 120 is the most that
fits: the style travels in the GetMap URL, and GeoMet answers 414 above about
8.2 KB. POST is not read by GeoMet's front end."""

CODE_MIN_MMH = 0.1
CODE_MAX_MMH = 200.0
NODATA = 255
"""Outside radar coverage. Distinct from code 0, which is "the radar looked and
there is no precipitation"."""


def _thresholds() -> list[float]:
    ratio = math.log(CODE_MAX_MMH / CODE_MIN_MMH)
    out = []
    for c in range(1, CODE_CLASSES + 1):
        value = CODE_MIN_MMH * math.exp((c - 1) / (CODE_CLASSES - 1) * ratio)
        # Rounded to exactly what the SLD sends, so decode uses the same edges
        # GeoMet classified against.
        out.append(float(f"{value:.4g}"))
    return out


THRESHOLDS = _thresholds()
"""Lower edge, in mm/h, of code c at index c - 1."""


def code_values() -> list[float]:
    """Representative mm/h for codes 0..CODE_CLASSES: the geometric middle of
    each class. Code 0 is dry."""
    reps = [0.0]
    step = THRESHOLDS[-1] / THRESHOLDS[-2]
    for c in range(1, CODE_CLASSES + 1):
        lo = THRESHOLDS[c - 1]
        hi = THRESHOLDS[c] if c < CODE_CLASSES else lo * step
        reps.append(round(math.sqrt(lo * hi), 5))
    return reps


def encode_mmh(values: np.ndarray) -> np.ndarray:
    """mm/h to codes. NaN (outside the source's coverage) becomes NODATA."""
    values = np.asarray(values, dtype=np.float64)
    finite = np.isfinite(values)
    safe = np.where(finite, values, 0.0)
    # Number of lower edges at or below the value: 0 below 0.1 mm/h, and the
    # top class for anything at or above its edge.
    codes = np.searchsorted(np.asarray(THRESHOLDS), safe, side="right")
    codes = np.clip(codes, 0, CODE_CLASSES).astype(np.uint8)
    codes[~finite] = NODATA
    return codes


def codes_spec() -> dict:
    return {
        "classes": CODE_CLASSES,
        "nodata": NODATA,
        "units": "mm/h",
        "values": code_values(),
    }


def pack(codes: np.ndarray) -> bytes:
    """Row-major uint8, gzip'd. mtime pinned so identical frames are
    byte-identical."""
    return gzip.compress(np.ascontiguousarray(codes, dtype=np.uint8).tobytes(), 6, mtime=0)


def unpack(blob: bytes, grid: Grid = GRID) -> np.ndarray:
    raw = gzip.decompress(blob)
    return np.frombuffer(raw, dtype=np.uint8).reshape(grid.height, grid.width)


# ---------------------------------------------------------------------------
# Observed radar: GeoMet WMS with a code-painting style
# ---------------------------------------------------------------------------


def radar_sld() -> str:
    # MapServer maps SLD 1.0 ColorMap entries to intervals [q_i, q_i+1),
    # painted with entry i's colour. Code 0 is opaque black so "covered and
    # dry" survives as alpha 255; outside coverage stays transparent.
    entries = ["<ColorMapEntry color='#000000' quantity='0'/>"]
    for c in range(1, CODE_CLASSES + 1):
        entries.append(
            f"<ColorMapEntry color='#{c:02X}0000' quantity='{THRESHOLDS[c - 1]:.4g}'/>"
        )
    entries.append(f"<ColorMapEntry color='#{CODE_CLASSES:02X}0000' quantity='1e5'/>")
    return (
        "<StyledLayerDescriptor version='1.0.0'><NamedLayer>"
        f"<Name>{RADAR_LAYER}</Name><UserStyle><FeatureTypeStyle><Rule>"
        "<RasterSymbolizer><ColorMap>"
        + "".join(entries)
        + "</ColorMap></RasterSymbolizer></Rule></FeatureTypeStyle></UserStyle>"
        "</NamedLayer></StyledLayerDescriptor>"
    )


def radar_url(instant: datetime, grid: Grid = GRID) -> str:
    query = urlencode(
        {
            "service": "WMS",
            "version": "1.3.0",
            "request": "GetMap",
            "layers": RADAR_LAYER,
            "crs": "EPSG:3857",
            "bbox": f"{grid.xmin:.0f},{grid.ymin:.0f},{grid.xmax:.0f},{grid.ymax:.0f}",
            "width": grid.width,
            "height": grid.height,
            "format": "image/png",
            "transparent": "true",
            "time": iso(instant),
        }
    )
    return f"{GEOMET_URL}?{query}&sld_body={quote(radar_sld(), safe=chr(39) + '/=.')}"


def decode_radar_png(data: bytes, grid: Grid = GRID) -> np.ndarray:
    """PNG painted by radar_sld() to codes.

    Refuses anything that is not purely code-painted. If GeoMet ever ignores
    the style it falls back to its default palette, which would decode to
    confident nonsense; a colour in the green or blue channel is the tell.
    """
    if not data.startswith(b"\x89PNG"):
        raise RadarError(f"GeoMet radar returned no image: {data[:120]!r}")
    rgba = np.asarray(Image.open(BytesIO(data)).convert("RGBA"))
    if rgba.shape[:2] != (grid.height, grid.width):
        raise RadarError(f"GeoMet radar size {rgba.shape[:2]} != grid")
    covered = rgba[..., 3] > 0
    red = rgba[..., 0]
    if (
        np.any(rgba[..., 1][covered])
        or np.any(rgba[..., 2][covered])
        or np.any(red[covered] > CODE_CLASSES)
    ):
        raise RadarError("GeoMet did not apply the code style; refusing to guess")
    return np.where(covered, red, NODATA).astype(np.uint8)


# ---------------------------------------------------------------------------
# Model forecast: GeoMet WCS, raw floats
# ---------------------------------------------------------------------------

HRDPS_RESOLUTION_DEG = 0.0225


def forecast_url(run: datetime, instant: datetime) -> str:
    pad = 0.1
    params = [
        ("service", "WCS"),
        ("version", "2.0.1"),
        ("request", "GetCoverage"),
        ("coverageId", FORECAST_LAYER),
        ("subset", f"lat({GRID_SOUTH - pad},{GRID_NORTH + pad})"),
        ("subset", f"long({GRID_WEST - pad},{GRID_EAST + pad})"),
        ("format", "image/tiff"),
        ("TIME", iso(instant)),
        ("DIM_REFERENCE_TIME", iso(run)),
        ("RESOLUTION", f"long({HRDPS_RESOLUTION_DEG})"),
        ("RESOLUTION", f"lat({HRDPS_RESOLUTION_DEG})"),
    ]
    return f"{GEOMET_URL}?{urlencode(params)}"


def resample_to_grid(
    src: np.ndarray,
    lon0: float,
    lat0: float,
    dlon: float,
    dlat: float,
    grid: Grid = GRID,
) -> np.ndarray:
    """Nearest-neighbour from a north-up lon/lat raster onto the Mercator grid.

    (lon0, lat0) is the outer corner of the raster's top-left pixel. Nearest,
    not bilinear: every output value is a value the model produced.
    """
    xs = grid.xmin + (np.arange(grid.width) + 0.5) * grid.pixel_m
    ys = grid.ymax - (np.arange(grid.height) + 0.5) * grid.pixel_m
    cols = np.floor((lon_of_x(xs) - lon0) / dlon).astype(np.int64)
    rows = np.floor((lat0 - lat_of_y(ys)) / dlat).astype(np.int64)
    h, w = src.shape
    col_ok = (cols >= 0) & (cols < w)
    row_ok = (rows >= 0) & (rows < h)
    out = src[np.clip(rows, 0, h - 1)[:, None], np.clip(cols, 0, w - 1)[None, :]]
    out = out.astype(np.float64)
    out[~(row_ok[:, None] & col_ok[None, :])] = np.nan
    return out


def decode_forecast_tiff(data: bytes, grid: Grid = GRID) -> np.ndarray:
    """HRDPS GeoTIFF (kg m-2 s-1) to codes on the grid."""
    if not data.startswith((b"II*\x00", b"MM\x00*")):
        raise RadarError(f"GeoMet forecast returned no GeoTIFF: {data[:120]!r}")
    img = Image.open(BytesIO(data))
    src = np.asarray(img, dtype=np.float64)
    tags = img.tag_v2
    try:
        tie = tags[33922]  # ModelTiepoint: (i, j, k, lon, lat, z)
        scale = tags[33550]  # ModelPixelScale: (dlon, dlat, dz)
    except KeyError as err:
        raise RadarError("GeoTIFF has no georeferencing") from err
    mmh = resample_to_grid(src, tie[3], tie[4], scale[0], scale[1], grid) * 3600.0
    mmh = np.where(np.isfinite(mmh), np.maximum(mmh, 0.0), np.nan)
    return encode_mmh(mmh)


# ---------------------------------------------------------------------------
# Time dimensions
# ---------------------------------------------------------------------------


def iso(instant: datetime) -> str:
    return instant.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(instant: datetime) -> str:
    return instant.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_stamp(value: str) -> datetime:
    try:
        return datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError as err:
        raise RadarError(f"Bad frame stamp {value!r}") from err


_PERIOD_RE = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


def expand_extent(extent: str) -> list[datetime]:
    """GeoMet `start/end/PTnX` to every instant in it. GeoMet matches `time`
    exactly (nearestValue=0), so instants only ever come from here."""
    parts = extent.strip().split("/")
    if len(parts) != 3:
        raise RadarError(f"Unparseable extent {extent!r}")
    start = datetime.fromisoformat(parts[0].replace("Z", "+00:00"))
    end = datetime.fromisoformat(parts[1].replace("Z", "+00:00"))
    m = _PERIOD_RE.match(parts[2].strip())
    if not m or not any(m.groups()):
        raise RadarError(f"Unsupported period {parts[2]!r}")
    step = timedelta(
        hours=int(m.group(1) or 0), minutes=int(m.group(2) or 0), seconds=int(m.group(3) or 0)
    )
    if step.total_seconds() <= 0 or end < start:
        raise RadarError(f"Bad extent {extent!r}")
    out = []
    t = start
    while t <= end and len(out) < 1000:
        out.append(t)
        t += step
    return out


def layer_dimensions(capabilities_xml: str, layer: str) -> dict:
    """The layer's own time extent and default reference_time.

    A filtered GetCapabilities still lists parent group layers first, each with
    its own dimensions, so the search starts at the layer's `<Name>`.
    """
    at = capabilities_xml.find(f"<Name>{layer}</Name>")
    if at < 0:
        raise RadarError(f"{layer} missing from capabilities")
    tail = capabilities_xml[at:]
    time_m = re.search(r'<Dimension name="time"[^>]*>([^<]+)</Dimension>', tail)
    if not time_m:
        raise RadarError(f"{layer} has no time dimension")
    ref_m = re.search(r'<Dimension name="reference_time"[^>]*default="([^"]+)"', tail)
    ref_extent_m = re.search(
        r'<Dimension name="reference_time"[^>]*>([^<]+)</Dimension>', tail
    )
    return {
        "time": time_m.group(1).strip(),
        "reference_time": ref_m.group(1).strip() if ref_m else None,
        "reference_extent": ref_extent_m.group(1).strip() if ref_extent_m else None,
    }


# ---------------------------------------------------------------------------
# Motion between forecast hours
# ---------------------------------------------------------------------------

FLOW_BLOCK = 32
"""Full-resolution pixels per motion cell: 64 km."""

_FLOW_DOWN = 4
_FLOW_SEARCH = 14
"""Downsampled pixels each way: 56 grid pixels, 112 km in the hour."""

_FLOW_PENALTY = 3.0
"""Cost per downsampled pixel of motion, so a featureless window, where every
shift costs the same, resolves to no motion rather than to a corner."""


def _downsample(codes: np.ndarray) -> np.ndarray:
    v = np.where(codes == NODATA, 0, codes).astype(np.float32)
    h = (v.shape[0] // _FLOW_DOWN) * _FLOW_DOWN
    w = (v.shape[1] // _FLOW_DOWN) * _FLOW_DOWN
    v = v[:h, :w]
    return v.reshape(h // _FLOW_DOWN, _FLOW_DOWN, w // _FLOW_DOWN, _FLOW_DOWN).mean(axis=(1, 3))


def _window_sums(field: np.ndarray, rows: int, cols: int, block: int) -> np.ndarray:
    """Sum of `field` over a 2x2-block window centred on each block."""
    h, w = field.shape
    ii = np.zeros((h + 1, w + 1), dtype=np.float64)
    ii[1:, 1:] = field.cumsum(0).cumsum(1)
    centres_r = (np.arange(rows) + 0.5) * block
    centres_c = (np.arange(cols) + 0.5) * block
    r0 = np.clip(np.floor(centres_r - block), 0, h).astype(int)
    r1 = np.clip(np.floor(centres_r + block), 0, h).astype(int)
    c0 = np.clip(np.floor(centres_c - block), 0, w).astype(int)
    c1 = np.clip(np.floor(centres_c + block), 0, w).astype(int)
    return (
        ii[r1[:, None], c1[None, :]]
        - ii[r0[:, None], c1[None, :]]
        - ii[r1[:, None], c0[None, :]]
        + ii[r0[:, None], c0[None, :]]
    )


def estimate_flow(a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Per-cell motion (dx, dy) in grid pixels, carrying frame a onto frame b.

    Block matching on log-scaled codes, which weights a light shield and a
    heavy core by shape rather than letting the core dominate. Cells with no
    precipitation near them in either frame take the median motion of the
    cells that had some, then a 3x3 median smooths the field so neighbouring
    cells cannot tear the interpolated frame apart.
    """
    A = _downsample(a)
    B = _downsample(b)
    h, w = A.shape
    block = FLOW_BLOCK // _FLOW_DOWN
    rows = math.ceil(a.shape[0] / FLOW_BLOCK)
    cols = math.ceil(a.shape[1] / FLOW_BLOCK)
    s = _FLOW_SEARCH
    padded = np.pad(A, s)

    best = np.full((rows, cols), np.inf)
    best_dx = np.zeros((rows, cols))
    best_dy = np.zeros((rows, cols))
    for dy in range(-s, s + 1):
        for dx in range(-s, s + 1):
            shifted = padded[s - dy : s - dy + h, s - dx : s - dx + w]
            cost = _window_sums(np.abs(shifted - B), rows, cols, block)
            cost += _FLOW_PENALTY * math.hypot(dx, dy)
            better = cost < best
            best = np.where(better, cost, best)
            best_dx = np.where(better, dx, best_dx)
            best_dy = np.where(better, dy, best_dy)

    activity = _window_sums(A + B, rows, cols, block)
    active = activity > 0
    if active.sum() >= 3:
        fill_dx = float(np.median(best_dx[active]))
        fill_dy = float(np.median(best_dy[active]))
    else:
        fill_dx = fill_dy = 0.0
    best_dx = np.where(active, best_dx, fill_dx)
    best_dy = np.where(active, best_dy, fill_dy)

    def median3(f: np.ndarray) -> np.ndarray:
        p = np.pad(f, 1, mode="edge")
        stack = [p[i : i + rows, j : j + cols] for i in range(3) for j in range(3)]
        return np.median(np.stack(stack), axis=0)

    dx = np.clip(np.round(median3(best_dx) * _FLOW_DOWN), -127, 127).astype(np.int8)
    dy = np.clip(np.round(median3(best_dy) * _FLOW_DOWN), -127, 127).astype(np.int8)
    return dx, dy


# ---------------------------------------------------------------------------
# Fetching and caching
# ---------------------------------------------------------------------------

_UPSTREAM = threading.BoundedSemaphore(4)
"""At most four requests to GeoMet at once from this machine. It renders on
demand, so this is ECCC's CPU as much as ours."""

_CAPS_TTL_SECONDS = 60
_WARNINGS_TTL_SECONDS = 60
_MAX_FRAMES = 160

_frames: dict[str, bytes] = {}
_flows: dict[str, dict] = {}
_caps: dict[str, tuple[float, dict]] = {}
_warnings_cache: tuple[float, dict] | None = None
_key_locks: dict[str, threading.Lock] = {}
_guard = threading.Lock()


def _http_get(url: str, timeout: float = 40.0, attempts: int = 3) -> bytes:
    """GET from ECCC. Transport failures and 5xx are retried with backoff:
    GeoMet has been seen to cut a chunked GeoTIFF off mid-body (IncompleteRead)
    and to 5xx one request in a burst that succeeds seconds later."""
    last: Exception | None = None
    for attempt in range(attempts):
        with _UPSTREAM:
            try:
                request = Request(url, headers={"User-Agent": USER_AGENT})
                with urlopen(request, timeout=timeout) as resp:
                    return resp.read()
            except HTTPError as err:
                # A 4xx is an answer, not a hiccup; retrying will not change it.
                if err.code < 500:
                    raise RadarError(f"ECCC returned {err.code}: {err.reason}") from err
                last = err
            except (URLError, TimeoutError, http.client.HTTPException, OSError) as err:
                last = err
        if attempt + 1 < attempts:
            time.sleep(0.5 * 3**attempt)
    raise RadarError(f"ECCC unreachable after {attempts} attempts: {last}") from last


def _single_flight(key: str, cache: dict, produce):
    """One producer per key; concurrent callers wait and share the result."""
    if key in cache:
        return cache[key]
    with _guard:
        lock = _key_locks.setdefault(key, threading.Lock())
    with lock:
        if key in cache:
            return cache[key]
        value = produce()
        cache[key] = value
    with _guard:
        _key_locks.pop(key, None)
        if len(cache) > _MAX_FRAMES:
            # Dicts keep insertion order, so the front is the longest held.
            for old in list(cache)[: len(cache) - _MAX_FRAMES]:
                cache.pop(old, None)
    return value


def dimensions(layer: str) -> dict:
    now = time.monotonic()
    cached = _caps.get(layer)
    if cached and now - cached[0] < _CAPS_TTL_SECONDS:
        return cached[1]
    url = (
        f"{GEOMET_URL}?service=WMS&version=1.3.0&request=GetCapabilities"
        f"&layer={layer}"
    )
    dims = layer_dimensions(_http_get(url, timeout=20).decode("utf-8", "replace"), layer)
    _caps[layer] = (now, dims)
    return dims


def observed_frame(instant: datetime) -> bytes:
    times = expand_extent(dimensions(RADAR_LAYER)["time"])
    if instant not in times:
        raise LookupError(f"No observed radar at {iso(instant)}")
    key = f"obs/{stamp(instant)}"
    return _single_flight(
        key, _frames, lambda: pack(decode_radar_png(_http_get(radar_url(instant))))
    )


def _check_run(run: datetime) -> None:
    ref_extent = dimensions(FORECAST_LAYER).get("reference_extent")
    if ref_extent and run not in expand_extent(ref_extent):
        raise LookupError(f"No model run {iso(run)}")


def forecast_frame(run: datetime, instant: datetime) -> bytes:
    _check_run(run)
    lead = instant - run
    if not (timedelta(hours=1) <= lead <= timedelta(hours=48)) or instant.minute or instant.second:
        raise LookupError(f"No forecast hour {iso(instant)} in run {iso(run)}")
    key = f"fc/{stamp(run)}/{stamp(instant)}"
    return _single_flight(
        key, _frames, lambda: pack(decode_forecast_tiff(_http_get(forecast_url(run, instant))))
    )


def forecast_flow(run: datetime, instant: datetime) -> dict:
    """Motion from the forecast hour `instant` to the next hour, same run."""
    nxt = instant + timedelta(hours=1)
    key = f"flow/{stamp(run)}/{stamp(instant)}"

    def produce() -> dict:
        a = unpack(forecast_frame(run, instant))
        b = unpack(forecast_frame(run, nxt))
        dx, dy = estimate_flow(a, b)
        return {
            "run": iso(run),
            "from": iso(instant),
            "to": iso(nxt),
            "block": FLOW_BLOCK,
            "rows": int(dx.shape[0]),
            "cols": int(dx.shape[1]),
            "dx": dx.ravel().tolist(),
            "dy": dy.ravel().tolist(),
        }

    return _single_flight(key, _flows, produce)


OBSERVED_WINDOW = timedelta(hours=2, minutes=12)
"""A little over the app's two hours, so a phone whose clock runs a few
minutes fast still finds its oldest frame listed."""

FORECAST_AHEAD = timedelta(hours=25)


def build_manifest(now: datetime | None = None) -> dict:
    """What exists right now: the grid, the code table, and every real frame
    in the window. The app decides which it already holds."""
    now = now or datetime.now(timezone.utc)
    errors: dict[str, str] = {}

    observed: list[datetime] = []
    try:
        all_obs = expand_extent(dimensions(RADAR_LAYER)["time"])
        if all_obs:
            observed = [t for t in all_obs if t >= all_obs[-1] - OBSERVED_WINDOW]
    except RadarError as err:
        errors["observed"] = str(err)

    forecast = None
    try:
        dims = dimensions(FORECAST_LAYER)
        run_text = dims.get("reference_time")
        if not run_text:
            raise RadarError("HRDPS advertises no default model run")
        run = datetime.fromisoformat(run_text.replace("Z", "+00:00"))
        seam = observed[-1] if observed else now
        frames = [
            t
            for t in expand_extent(dims["time"])
            if seam - timedelta(hours=1) < t <= now + FORECAST_AHEAD
        ]
        forecast = {
            "run": iso(run),
            "run_id": stamp(run),
            "frames": [{"time": iso(t), "id": stamp(t)} for t in frames],
        }
    except RadarError as err:
        errors["forecast"] = str(err)

    if not observed and forecast is None:
        raise RadarError("; ".join(errors.values()) or "No radar data")

    return {
        "schema": 1,
        "grid": GRID.spec(),
        "codes": codes_spec(),
        "flow": {"block": FLOW_BLOCK},
        "observed": [{"time": iso(t), "id": stamp(t)} for t in observed],
        "forecast": forecast,
        "errors": errors,
        "generated_at": iso(now),
    }


# ---------------------------------------------------------------------------
# Warnings that switch interpolation off
# ---------------------------------------------------------------------------

_WARNING_NAMES = ("tornado", "severe thunderstorm")
_MAX_RING_POINTS = 400


def _decimate(ring: list, limit: int = _MAX_RING_POINTS) -> list[list[float]]:
    points = [[round(float(p[0]), 4), round(float(p[1]), 4)] for p in ring if len(p) >= 2]
    if len(points) <= limit:
        return points
    step = math.ceil(len(points) / limit)
    kept = points[::step]
    if kept[-1] != points[-1]:
        kept.append(points[-1])
    return kept


def warning_features(features: list, now: datetime) -> list[dict]:
    """Active tornado and severe thunderstorm warnings, with outer rings.

    Holes are dropped on purpose: a hole can only make a warning cover less,
    and this list exists to turn interpolation off, so erring toward "covers"
    is the safe direction.
    """
    from .alerts_service import _is_active  # same activeness rule as the alert strip

    out = []
    for feature in features:
        if not isinstance(feature, dict):
            continue
        props = feature.get("properties") or {}
        if str(props.get("alert_type") or "").strip().lower() != "warning":
            continue
        name = str(props.get("alert_name_en") or "").strip().lower()
        if not any(key in name for key in _WARNING_NAMES):
            continue
        if not _is_active(props, now):
            continue
        geometry = feature.get("geometry") or {}
        coords = geometry.get("coordinates")
        if geometry.get("type") == "Polygon":
            polygons = [coords]
        elif geometry.get("type") == "MultiPolygon":
            polygons = coords
        else:
            continue
        rings = [_decimate(p[0]) for p in polygons if isinstance(p, list) and p]
        rings = [r for r in rings if len(r) >= 3]
        if not rings:
            continue
        lons = [p[0] for r in rings for p in r]
        lats = [p[1] for r in rings for p in r]
        out.append(
            {
                "name": props.get("alert_name_en"),
                "alert_code": props.get("alert_code"),
                "region": props.get("feature_name_en"),
                "expires_at": props.get("expiration_datetime"),
                "bbox": [min(lons), min(lats), max(lons), max(lats)],
                "rings": rings,
            }
        )
    return out


def fetch_warnings() -> dict:
    global _warnings_cache
    now_mono = time.monotonic()
    if _warnings_cache and now_mono - _warnings_cache[0] < _WARNINGS_TTL_SECONDS:
        return _warnings_cache[1]
    query = urlencode(
        {
            "bbox": f"{GRID_WEST},{GRID_SOUTH},{GRID_EAST},{GRID_NORTH}",
            "f": "json",
            "limit": 500,
        }
    )
    raw = _http_get(f"{ALERTS_COLLECTION_URL}?{query}", timeout=20)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as err:
        raise RadarError(f"Unparseable ECCC alerts: {err}") from err
    now = datetime.now(timezone.utc)
    result = {
        "warnings": warning_features(payload.get("features") or [], now),
        "fetched_at": iso(now),
    }
    _warnings_cache = (now_mono, result)
    return result


# ---------------------------------------------------------------------------
# Readiness reports from the app
# ---------------------------------------------------------------------------

_telemetry: list[dict] = []
_TELEMETRY_KEEP = 200


def record_telemetry(report: dict) -> None:
    """Keep the app's radar-ready timings. Timings, byte counts and frame
    counts only: the app sends no location and no device identifier."""
    entry = {"received_at": iso(datetime.now(timezone.utc)), **report}
    print("RADAR_TELEMETRY " + json.dumps(entry, sort_keys=True), flush=True)
    _telemetry.append(entry)
    del _telemetry[:-_TELEMETRY_KEEP]


def recent_telemetry() -> list[dict]:
    return list(reversed(_telemetry))
