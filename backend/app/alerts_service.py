"""ECCC severe weather alerts.

Implements the passive posture from ADR 0005: ECCC's alert text, severity
colour, expiry and region name are carried through **verbatim**. Nothing here
paraphrases, truncates, or re-ranks an alert. The moment we reword a tornado
warning we take on interpretive liability for a life-safety message.

Source: the `weather-alerts` collection of ECCC's OGC API, the same service the
city-page forecasts already come from.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen

from .weather_service import WeatherServiceError

ALERTS_COLLECTION_URL = "https://api.weather.gc.ca/collections/weather-alerts/items"
ALERTS_ATTRIBUTION_URL = (
    "https://eccc-msc.github.io/open-data/msc-data/alerts/readme_alerts_en/"
)
ALERTS_CACHE_TTL_SECONDS = 120
"""Short by design. An alert that has been cancelled must stop showing quickly,
and the feed is small."""

ALERTS_REQUEST_LIMIT = 50

# Degrees of padding around the query point. ECCC alert polygons are region
# sized, so the bbox only has to be wide enough to catch a polygon whose
# centroid is far from the point; the precise test is point-in-polygon below.
_BBOX_PAD_DEGREES = 2.5

_alerts_cache: dict[str, tuple[float, list[dict]]] = {}


@dataclass
class _Ring:
    """One closed ring of a polygon, as (lon, lat) pairs."""

    points: list[tuple[float, float]] = field(default_factory=list)


def _http_get_json(url: str, timeout: float = 15.0) -> dict:
    try:
        with urlopen(url, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as err:
        raise WeatherServiceError(
            f"ECCC alerts request failed with status {err.code}: {err.reason}"
        ) from err
    except URLError as err:
        raise WeatherServiceError(
            f"Network error contacting ECCC alerts: {err.reason}"
        ) from err
    except json.JSONDecodeError as err:
        raise WeatherServiceError(
            f"Failed to parse ECCC alerts response: {err}"
        ) from err


def _point_in_ring(lon: float, lat: float, ring: list) -> bool:
    """Ray casting, counting crossings of the ring by a ray heading east.

    GeoJSON positions are (longitude, latitude), which is the opposite order
    from how the rest of this codebase passes coordinates around. Getting that
    backwards silently tags every alert to the wrong place, so the unpacking is
    explicit here.
    """
    inside = False
    count = len(ring)
    if count < 3:
        return False

    j = count - 1
    for i in range(count):
        try:
            xi, yi = float(ring[i][0]), float(ring[i][1])
            xj, yj = float(ring[j][0]), float(ring[j][1])
        except (TypeError, ValueError, IndexError):
            j = i
            continue

        # Does the edge straddle the ray's latitude?
        if (yi > lat) != (yj > lat):
            if yj != yi:
                x_at_lat = xi + (lat - yi) * (xj - xi) / (yj - yi)
                if lon < x_at_lat:
                    inside = not inside
        j = i

    return inside


def _point_in_polygon(lon: float, lat: float, rings: list) -> bool:
    """A point is inside a polygon when it is in the exterior ring and in none
    of the holes."""
    if not rings:
        return False
    if not _point_in_ring(lon, lat, rings[0]):
        return False
    for hole in rings[1:]:
        if _point_in_ring(lon, lat, hole):
            return False
    return True


def _geometry_contains(geometry: dict | None, lon: float, lat: float) -> bool:
    if not isinstance(geometry, dict):
        return False
    geom_type = geometry.get("type")
    coords = geometry.get("coordinates")
    if not isinstance(coords, list):
        return False

    if geom_type == "Polygon":
        return _point_in_polygon(lon, lat, coords)
    if geom_type == "MultiPolygon":
        return any(
            _point_in_polygon(lon, lat, polygon)
            for polygon in coords
            if isinstance(polygon, list)
        )
    return False


def _parse_dt(value: object) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _is_active(properties: dict, now: datetime) -> bool:
    """Drop alerts that have expired or that ECCC has marked ended.

    Expiry is enforced locally as well as trusting the feed: a stale cached
    response must not keep a cancelled warning on screen.
    """
    status = str(properties.get("status_en") or "").strip().lower()
    if status in {"ended", "cancelled", "canceled"}:
        return False

    expires = _parse_dt(properties.get("expiration_datetime"))
    if expires is not None and expires <= now:
        return False
    return True


def _severity_rank(properties: dict) -> int:
    """Ordering only. This does not restate or reinterpret ECCC's severity, it
    just decides which alert is drawn first when several are active."""
    alert_type = str(properties.get("alert_type") or "").strip().lower()
    order = {"warning": 0, "watch": 1, "advisory": 2, "statement": 3}
    return order.get(alert_type, 4)


def _normalize(feature: dict) -> dict | None:
    properties = feature.get("properties")
    if not isinstance(properties, dict):
        return None

    text = properties.get("alert_text_en")
    name = properties.get("alert_name_en")
    if not isinstance(name, str) or not name.strip():
        return None

    return {
        # Verbatim ECCC fields. Do not reword, shorten, or title-case these.
        "id": str(properties.get("feature_id") or "").strip() or None,
        "alert_code": properties.get("alert_code"),
        "alert_type": properties.get("alert_type"),
        "name": name,
        "short_name": properties.get("alert_short_name_en"),
        "text": text if isinstance(text, str) else None,
        "risk_colour": properties.get("risk_colour_en"),
        "confidence": properties.get("confidence_en"),
        "impact": properties.get("impact_en"),
        "region": properties.get("feature_name_en"),
        "province": properties.get("province"),
        "status": properties.get("status_en"),
        "published_at": properties.get("publication_datetime"),
        "expires_at": properties.get("expiration_datetime"),
        "effective_at": properties.get("validity_datetime"),
        "event_ends_at": properties.get("event_end_datetime"),
    }


def fetch_alerts(latitude: float, longitude: float) -> list[dict]:
    """Active ECCC alerts whose polygon contains the given point.

    Returns an empty list when there are none, which is the normal case. Raises
    WeatherServiceError only when the feed itself could not be read; the caller
    decides whether that is fatal.
    """
    cache_key = f"{latitude:.3f},{longitude:.3f}"
    now_ts = time.time()
    cached = _alerts_cache.get(cache_key)
    if cached and now_ts - cached[0] < ALERTS_CACHE_TTL_SECONDS:
        return cached[1]

    bbox = (
        f"{longitude - _BBOX_PAD_DEGREES},{latitude - _BBOX_PAD_DEGREES},"
        f"{longitude + _BBOX_PAD_DEGREES},{latitude + _BBOX_PAD_DEGREES}"
    )
    query = urlencode({"bbox": bbox, "f": "json", "limit": ALERTS_REQUEST_LIMIT})
    payload = _http_get_json(f"{ALERTS_COLLECTION_URL}?{query}")

    features = payload.get("features")
    if not isinstance(features, list):
        features = []

    now = datetime.now(timezone.utc)
    matched: list[tuple[int, dict]] = []
    for feature in features:
        if not isinstance(feature, dict):
            continue
        properties = feature.get("properties")
        if not isinstance(properties, dict):
            continue
        if not _is_active(properties, now):
            continue
        # The bbox is a coarse filter. An alert is only shown for a location if
        # the location is genuinely inside the alert's polygon.
        if not _geometry_contains(feature.get("geometry"), longitude, latitude):
            continue
        normalized = _normalize(feature)
        if normalized is not None:
            matched.append((_severity_rank(properties), normalized))

    matched.sort(key=lambda item: item[0])
    alerts = [item[1] for item in matched]

    _alerts_cache[cache_key] = (now_ts, alerts)
    return alerts


def fetch_alerts_safe(latitude: float, longitude: float) -> list[dict]:
    """fetch_alerts, but never raises.

    A forecast that renders without its alert strip is bad. A forecast that
    fails to render at all because the alert feed hiccupped is worse, so the
    weather response degrades rather than failing.
    """
    try:
        return fetch_alerts(latitude, longitude)
    except WeatherServiceError:
        return []
    except Exception:  # noqa: BLE001 - alerts must never break the forecast
        return []
