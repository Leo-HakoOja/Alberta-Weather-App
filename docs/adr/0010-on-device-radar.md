# Radar is drawn on the device, from numbers, on one continuous timeline

> **Status:** Built 2026-09-11 (build 40 follow-up). Operator approved the
> backend-served path ("get it done") after the source survey below. Radar-ready
> time on a real TestFlight run is **still to be read** from
> `GET /v1/radar/telemetry`; frame density is not to be reduced before it is.
>
> **Supersedes** the two-mode split in [ADR 0008](0008-forecast-radar-mode.md)
> ("two modes, one toggle, separate timelines each") and the RainViewer fallback of
> [ADR 0004](0004-radar-single-source.md). Keeps ADR 0008's sources:
> `RADAR_1KM_RRAI` and `HRDPS.CONTINENTAL_RT`, never `_PR`.

## What the operator asked for

1. One hero temperature, the mean of the live sources (per-source values stay in
   the API response, unrendered).
2. No observed/forecast toggle: one timeline, now - 2 h to now + 24 h, with a
   visible "now" where observed hands to forecast.
3. Stop displaying GeoMet's server-styled tiles. Prefetch the whole window at
   launch, render frames on the device as an overlay locked to the map, one colour
   ramp for observed and forecast, every real timestamp, delta disk cache.
4. Interpolate between real frames for smooth playback, in data values, never
   altering real frames; real frames only while a tornado or severe thunderstorm
   warning covers the visible area.

ADR 0008's argument against one scrubber (different physics, different cadence)
is answered, not ignored: the seam is marked "Now", the FORECAST badge and the
forecast attribution still switch on at it, and the scrubber colours the two halves
differently.

## Sources, verified live 2026-09-11

| | Forecast (HRDPS) | Observed radar |
|---|---|---|
| GeoMet WCS | **Raw floats.** kg/(m^2 s); 0.0022375 = 8.06 mm/h matched GetFeatureInfo's "5.0 - 10.0 mm/h" class | **Not enabled** on the layer; none of 6,123 WCS coverages is radar |
| MSC Datamart | (GRIB2, not needed) | Pre-coloured per-site GIFs only |
| HPFX | | Raw radar folder returns 401 |
| MSC OGC API | | No radar collection |

**Observed radar has no public raw grid.** What it does have: GeoMet honours an SLD
1.0 `ColorMap` sent in the GetMap request (`sld_body`), applied as intervals
`[q_i, q_i+1)` painted with entry i's colour. So the backend sends a style whose
interval c paints `#cc0000`: the PNG comes back holding the class code in its red
channel. Checked against GetFeatureInfo's raw values: **35 of 35** pixels, wet and
dry, fell inside their decoded class. Alpha also separates "covered and dry" (code 0)
from "outside radar range" (transparent).

Limits found the hard way:
- The style travels in the URL; GeoMet answers **414** above about 8.2 KB. 120 log
  classes (0.1 to 200 mm/h, 6.6% wide) is the most that fits (7.8 KB). POST is not
  read by GeoMet's front end; SE 1.1 `Interpolate` is silently ignored.
- If GeoMet ever ignores the style it falls back to its default palette. The
  decoder refuses any pixel with green or blue, or red above 120, rather than
  decoding a palette as codes.

## Decision

**The backend (fly.io) fetches each frame from ECCC once and serves compact grids;
the phone caches, interpolates and draws.**

- **One grid.** Web Mercator (EPSG:3857), 2 km pixels (1.3 km on the ground at the
  border, 1.0 km at 60N), -122.5 to -108.5, 48.5 to 60.3: 780 x 1139. Linear in the
  map's own projection, so the image is placed between two projected corners and
  stays on the roads at every zoom and pan. Corner round trip through flutter_map's
  `Epsg3857` is under 1 cm (`test/radar_store_test.dart`).
- **One code table** for both sources. Observed arrives as codes; HRDPS floats are
  nearest-resampled onto the grid and quantised to the same classes. 255 = no data.
- **Frames** are gzip'd uint8 codes: measured 47 KB per radar scan and 15 KB per
  model hour on 2026-09-11; a cold full window of 45 frames was 1.37 MB plus 97 KB
  of motion fields.
- **Endpoints:** `/v1/radar/manifest`, `/observed/{id}`, `/forecast/{run}/{id}`,
  `/flow/{run}/{id}`, `/warnings`, `POST|GET /telemetry`. Frame ids are validated
  against GeoMet's advertised extents before anything is fetched upstream.
- **Delta cache (phone).** Files keyed `obs_<id>` and `fc_<run>_<id>`. Observed
  scans are final once published. Forecast hours are keyed by model run, so a new
  run misses the cache for every hour and the whole forecast is refetched (a newer
  run is a better forecast of the same hours; "only fetch newer timestamps" would
  keep showing a superseded run). Anything outside the window is pruned. A grid or
  code-table change wipes the cache. iOS path is `Library/Caches/radar-v1`, found
  from `Directory.systemTemp` without adding `path_provider`.
- **Launch prefetch.** `RadarStore.start()` runs from the home screen's initState;
  the sheet opens onto frames already held and refreshes (delta) if older than 3 min.
- **Colour.** ECCC's 14 radar colours at their class edges, blended in log mm/h (the
  look of GeoMet's continuous `Radar-Rain_14colors`, build 40's test style). One
  ramp; nothing changes at the seam.
- **Interpolation, in values.** Real frames are drawn from their codes through the
  ramp and nothing else. Between radar scans (6 min): straight value blend at 1 min
  steps. Across the seam: straight blend at 10 min steps. Between model hours:
  motion-compensated at 10 min steps, `s*A(x - t*u) + t*B(x + s*u)`, with `u` from
  block matching on the backend (64 km cells, +-112 km/h, 0.33 s per pair).
  Reconstructing a held-out real model hour from the hours either side, motion beat
  the plain blend on all three pairs tried (MAE 0.245 vs 0.279, 0.276 vs 0.314,
  0.208 vs 0.237 mm/h). Gaps longer than 18 min (radar) or 1 h (model) are left as
  jumps, never filled. A model hour whose motion field has not arrived is left
  unfilled rather than blended.
- **Warning gate.** Active ECCC warnings whose name contains "tornado" or "severe
  thunderstorm", outer rings only (a hole can only shrink coverage; erring toward
  "covers" is the safe side). Any overlap with the visible map bounds, not
  containment, switches playback to real frames only. If warning status is unknown
  (fetch failed and nothing under 10 min old) the viewer also shows real frames
  only.
- **Rendering** runs in a worker isolate on the phone (a motion frame is about a
  million pixels); the web build renders inline. Playback paces itself to the
  renderer: 100 ms per frame, 600 ms per real frame when real-only.

## Alternatives rejected

- **Phone fetches HRDPS WCS directly:** 907 KB to 1.06 MB uncompressed float32 per
  hour, no compression offered, **21.8 MB per model run** on cellular.
- **Phone decodes GeoMet's `-LINEAR` colour ramp:** workable (strictly monotonic
  ramp) but an inferred palette, 2.3 MB per window, and it would leave the forecast
  reconstructed even though raw values exist.
- **Keep server tiles:** the request.

## Consequences

- The backend is now on the radar path. Cold machine (scale to zero): measured
  20.7 s for the whole cold burst locally; warm: 0.03 s. `min_machines_running = 1`
  would remove the cold path; it is a cost decision, left to the operator once the
  TestFlight number is in.
- Peak backend memory during a phone's cold burst: **166 MB** of the machine's
  256 MB (measured locally, 74 requests at the phone's concurrency).
- New backend dependencies: **numpy** (BSD-3) and **Pillow** (HPND/MIT-CMU), both
  mainstream and actively maintained. No new app dependencies.
- **RainViewer is removed.** It served only server-styled tiles, which item 3 rules
  out. If ECCC is down the sheet says radar is unavailable.
- **Telemetry.** The app posts one radar-readiness report per launch (and render
  timings when the sheet closes) to the backend: timings, byte and frame counts,
  build number, platform. No location, no device identifier. Long-press the radar
  sheet's title to see the same numbers on the phone.
- GeoMet transient failures are real (an IncompleteRead mid-GeoTIFF and a 5xx that
  succeeded seconds later were both seen during the build). The backend retries with
  backoff; the phone retries failed frames once per launch.
