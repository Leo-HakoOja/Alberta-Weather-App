"""ECCC (Environment and Climate Change Canada) weather source adapter.

Pulls citypage_weather data from the MSC GeoMet OGC API and normalizes it
into the same shape as the Open-Meteo response, so the multi-source UI can
render them side by side.

Per [ADR 0001](../../docs/adr/0001-multi-source-side-by-side.md), this is one
of several Weather Sources fanned out from the backend — not a blended winner.
"""

from __future__ import annotations

import copy
import json
import math
import time
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen

from .weather_service import (
    WeatherServiceError,
    format_iso_label,
    wind_direction_to_compass,
)

ECCC_COLLECTION_URL = (
    "https://api.weather.gc.ca/collections/citypageweather-realtime/items"
)
ECCC_CACHE_TTL_SECONDS = 600
ATTRIBUTION_URL = (
    "https://eccc-msc.github.io/open-data/msc-data/citypage-weather/"
    "readme_citypageweather_en/"
)
SOURCE_ID = "eccc"
SOURCE_NAME = "Environment and Climate Change Canada"

# Alberta saved-location → nearest ECCC citypage site. For locations not in
# this table we fall back to nearest-neighbour against the live bbox feed.
KNOWN_ALBERTA_SITES: dict[str, str] = {
    "Myrnam": "ab-26",  # Vegreville, ~80 km SW
    "Edmonton": "ab-50",
    "Calgary": "ab-52",
    "Banff": "ab-49",
    "Lethbridge": "ab-30",
    "Fort McMurray": "ab-20",
    "Red Deer": "ab-39",  # Lacombe, the nearest ECCC region
    "Cold Lake": "ab-23",
    "Canmore": "ab-3",
    "Jasper": "ab-70",
    "Medicine Hat": "ab-51",
    "Grande Prairie": "ab-57",  # Beaverlodge
}

ALBERTA_BBOX = "-120.0,49.0,-110.0,60.0"


_site_cache: dict[str, tuple[float, dict]] = {}
_alberta_sites_cache: tuple[float, list[dict]] | None = None


@dataclass(slots=True)
class _EcccSite:
    site_id: str
    name: str
    latitude: float
    longitude: float


def _en(value: object) -> object:
    """Unwrap an ECCC `{en, fr}` localised value to the English variant."""
    if isinstance(value, dict) and "en" in value:
        return value["en"]
    return value


def _as_float(value: object) -> float | None:
    value = _en(value)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        with suppress(ValueError):
            return float(value)
    return None


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    )
    return 2 * r * math.asin(math.sqrt(a))


def _http_get_json(url: str, timeout: float = 15.0) -> dict:
    try:
        with urlopen(url, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as err:
        raise WeatherServiceError(
            f"ECCC request failed with status {err.code}: {err.reason}"
        ) from err
    except URLError as err:
        raise WeatherServiceError(
            f"Network error contacting ECCC: {err.reason}"
        ) from err
    except json.JSONDecodeError as err:
        raise WeatherServiceError(f"Failed to parse ECCC response: {err}") from err


def _fetch_alberta_sites() -> list[_EcccSite]:
    global _alberta_sites_cache
    now = time.time()
    if _alberta_sites_cache and now - _alberta_sites_cache[0] < 24 * 3600:
        return [_EcccSite(**raw) for raw in _alberta_sites_cache[1]]

    url = f"{ECCC_COLLECTION_URL}?{urlencode({'bbox': ALBERTA_BBOX, 'f': 'json', 'limit': 200})}"
    payload = _http_get_json(url)
    sites: list[_EcccSite] = []
    for feature in payload.get("features", []):
        site_id = feature.get("id")
        if not isinstance(site_id, str) or not site_id.startswith("ab-"):
            continue
        coords = (feature.get("geometry") or {}).get("coordinates") or []
        if len(coords) < 2:
            continue
        name_dict = (feature.get("properties") or {}).get("name") or {}
        sites.append(
            _EcccSite(
                site_id=site_id,
                name=_en(name_dict) if isinstance(name_dict, dict) else str(name_dict),
                latitude=float(coords[1]),
                longitude=float(coords[0]),
            )
        )
    _alberta_sites_cache = (now, [site.__dict__ for site in sites])
    return sites


def resolve_site_code(location_name: str | None, latitude: float, longitude: float) -> str | None:
    """Return the best ECCC site code for a location, or None if outside Alberta."""
    if location_name and location_name in KNOWN_ALBERTA_SITES:
        return KNOWN_ALBERTA_SITES[location_name]

    try:
        sites = _fetch_alberta_sites()
    except WeatherServiceError:
        return None

    if not sites:
        return None

    nearest = min(
        sites,
        key=lambda site: _haversine_km(latitude, longitude, site.latitude, site.longitude),
    )
    # ~250 km is well past any sensible "nearest city" — outside Alberta.
    if _haversine_km(latitude, longitude, nearest.latitude, nearest.longitude) > 250:
        return None
    return nearest.site_id


def _fetch_site_payload(site_code: str) -> dict:
    now = time.time()
    cached = _site_cache.get(site_code)
    if cached and now - cached[0] < ECCC_CACHE_TTL_SECONDS:
        return copy.deepcopy(cached[1])

    url = f"{ECCC_COLLECTION_URL}/{site_code}?f=json"
    payload = _http_get_json(url)
    _site_cache[site_code] = (now, payload)
    return copy.deepcopy(payload)


def _normalize_current(cc: dict) -> dict | None:
    if not isinstance(cc, dict):
        return None

    timestamp = _en(cc.get("timestamp"))
    temperature = _as_float((cc.get("temperature") or {}).get("value"))
    apparent = None
    for feels_key in ("windChill", "humidex"):
        candidate = _as_float((cc.get(feels_key) or {}).get("value"))
        if candidate is not None:
            apparent = candidate
            break
    if apparent is None:
        apparent = temperature

    humidity = _as_float((cc.get("relativeHumidity") or {}).get("value"))
    wind = cc.get("wind") or {}
    wind_speed = _as_float((wind.get("speed") or {}).get("value"))
    wind_bearing = _as_float((wind.get("bearing") or {}).get("value"))
    wind_compass = _en((wind.get("direction") or {}).get("value")) or wind_direction_to_compass(
        wind_bearing
    )

    condition = _en(cc.get("condition")) or ""
    icon_code = _as_float((cc.get("iconCode") or {}).get("value"))

    return {
        "time": timestamp if isinstance(timestamp, str) else None,
        "temperature": temperature,
        "apparent_temperature": apparent,
        "humidity": humidity,
        "wind_speed": wind_speed,
        "wind_direction_degrees": wind_bearing,
        "wind_direction_compass": str(wind_compass) if wind_compass else "N/A",
        "uv_index": None,
        "weather_code": int(icon_code) if icon_code is not None else None,
        "weather": str(condition) if condition else "—",
        "sunrise": None,
        "sunset": None,
        "is_daylight": None,
    }


def _normalize_hourly(hfg: dict) -> list[dict]:
    if not isinstance(hfg, dict):
        return []
    hourly = hfg.get("hourlyForecasts") or []
    items: list[dict] = []
    for entry in hourly[:24]:
        if not isinstance(entry, dict):
            continue
        timestamp = entry.get("timestamp")
        if not isinstance(timestamp, str):
            continue

        wind = entry.get("wind") or {}
        wind_bearing = _as_float((wind.get("bearing") or {}).get("value"))
        wind_compass = _en((wind.get("direction") or {}).get("value")) or wind_direction_to_compass(
            wind_bearing
        )
        icon_code = _as_float((entry.get("iconCode") or {}).get("value"))
        lop_value = _as_float((entry.get("lop") or {}).get("value"))

        items.append(
            {
                "time": timestamp,
                "label": format_iso_label(timestamp, "%a %I:%M %p"),
                "weather_code": int(icon_code) if icon_code is not None else None,
                "weather": str(_en(entry.get("condition")) or "—"),
                "temperature": _as_float((entry.get("temperature") or {}).get("value")),
                "apparent_temperature": None,
                "humidity": None,
                "wind_speed": _as_float((wind.get("speed") or {}).get("value")),
                "wind_direction_degrees": wind_bearing,
                "wind_direction_compass": str(wind_compass) if wind_compass else "N/A",
                "uv_index": None,
                "precipitation_probability": lop_value,
                "precipitation_amount_mm": None,
                "is_daylight": None,
            }
        )
    return items


def _normalize_daily(forecast_group: dict) -> list[dict]:
    """Collapse ECCC's day+night pairs into single daily summaries."""
    if not isinstance(forecast_group, dict):
        return []
    forecasts = forecast_group.get("forecasts") or []
    if not isinstance(forecasts, list):
        return []

    by_date: dict[str, dict] = {}
    today_iso = datetime.now(timezone.utc).date().isoformat()
    day_offset = 0
    seen_period_names: set[str] = set()
    current_date = today_iso

    for forecast in forecasts:
        if not isinstance(forecast, dict):
            continue
        period = forecast.get("period") or {}
        period_name = str(_en(period.get("textForecastName")) or "").strip()
        if not period_name:
            continue

        # ECCC alternates "<Day>" then "<Day> night". Day rollover happens
        # when we see a new daytime period after at least one night.
        if period_name not in seen_period_names and "night" not in period_name.lower():
            if seen_period_names:
                day_offset += 1
                current_date = (
                    datetime.fromisoformat(today_iso) .toordinal() + day_offset
                )
                current_date = datetime.fromordinal(current_date).date().isoformat()
            seen_period_names.add(period_name)
        else:
            seen_period_names.add(period_name)

        temps = (forecast.get("temperatures") or {}).get("temperature") or []
        for entry in temps:
            if not isinstance(entry, dict):
                continue
            value = _as_float(entry.get("value"))
            klass = _en(entry.get("class")) or ""
            bucket = by_date.setdefault(
                current_date,
                {
                    "date": current_date,
                    "label": format_iso_label(current_date, "%a %b %d"),
                    "weather_code": None,
                    "weather": "—",
                    "temperature_min": None,
                    "temperature_max": None,
                    "uv_index_max": None,
                    "precipitation_probability_max": None,
                    "precipitation_amount_mm": None,
                    "sunrise": None,
                    "sunset": None,
                },
            )
            if str(klass).lower() == "high":
                bucket["temperature_max"] = value
            elif str(klass).lower() == "low":
                bucket["temperature_min"] = value

        # First textSummary we see for a date wins as the headline.
        summary = _en((forecast.get("temperatures") or {}).get("textSummary"))
        if summary and by_date.get(current_date, {}).get("weather") == "—":
            by_date[current_date]["weather"] = str(summary)

    ordered = sorted(by_date.values(), key=lambda item: item["date"])
    return ordered[:7]


def fetch_eccc_source(
    location_name: str | None, latitude: float, longitude: float
) -> dict:
    """Build a `SourceForecast`-shaped dict for ECCC, or an error stub."""
    fetched_at = datetime.now(timezone.utc).isoformat()
    base: dict = {
        "source_id": SOURCE_ID,
        "source_name": SOURCE_NAME,
        "attribution_url": ATTRIBUTION_URL,
        "fetched_at": fetched_at,
        "current": None,
        "hourly_next_24h": [],
        "daily_7d": [],
        "error": None,
    }

    site_code = resolve_site_code(location_name, latitude, longitude)
    if not site_code:
        base["error"] = "No ECCC citypage site near this location"
        return base

    try:
        payload = _fetch_site_payload(site_code)
    except WeatherServiceError as err:
        base["error"] = str(err)
        return base

    props = payload.get("properties") or {}
    base["current"] = _normalize_current(props.get("currentConditions") or {})
    base["hourly_next_24h"] = _normalize_hourly(props.get("hourlyForecastGroup") or {})
    base["daily_7d"] = _normalize_daily(props.get("forecastGroup") or {})
    return base
