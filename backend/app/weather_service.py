from __future__ import annotations

import copy
import json
import time
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen

API_BASE_URL = "https://api.open-meteo.com/v1/forecast"
DEFAULT_FORECAST_DAYS = 14
FORECAST_CACHE_TTL_SECONDS = 300
PERSISTENT_CACHE_PATH = (
    Path(__file__).resolve().parent.parent / ".cache" / "forecast_cache.json"
)

MYRNAM = {
    "name": "Myrnam",
    "province": "Alberta",
    "country": "Canada",
    "latitude": 53.66686,
    "longitude": -111.23504,
    "timezone": "America/Edmonton",
}

WMO_WEATHER_CODES = {
    0: "Clear sky",
    1: "Mainly clear",
    2: "Partly cloudy",
    3: "Overcast",
    45: "Fog",
    48: "Depositing rime fog",
    51: "Light drizzle",
    53: "Moderate drizzle",
    55: "Dense drizzle",
    56: "Light freezing drizzle",
    57: "Dense freezing drizzle",
    61: "Slight rain",
    63: "Moderate rain",
    65: "Heavy rain",
    66: "Light freezing rain",
    67: "Heavy freezing rain",
    71: "Slight snow fall",
    73: "Moderate snow fall",
    75: "Heavy snow fall",
    77: "Snow grains",
    80: "Slight rain showers",
    81: "Moderate rain showers",
    82: "Violent rain showers",
    85: "Slight snow showers",
    86: "Heavy snow showers",
    95: "Thunderstorm",
    96: "Thunderstorm with slight hail",
    99: "Thunderstorm with heavy hail",
}


@dataclass(slots=True)
class ForecastRequest:
    latitude: float
    longitude: float
    timezone: str = "auto"
    forecast_days: int = DEFAULT_FORECAST_DAYS


class WeatherServiceError(RuntimeError):
    pass


_cache: dict[str, tuple[float, dict]] = {}


def _cache_key(request: ForecastRequest) -> str:
    return (
        f"{request.latitude:.5f}|{request.longitude:.5f}|"
        f"{request.timezone}|{request.forecast_days}"
    )


def _load_persistent_cache(path: Path = PERSISTENT_CACHE_PATH) -> dict[str, dict]:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, dict):
            return payload
    except (OSError, json.JSONDecodeError):
        return {}
    return {}


def _save_persistent_cache(
    cache_payload: dict[str, dict], path: Path = PERSISTENT_CACHE_PATH
) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(cache_payload), encoding="utf-8")
    except OSError:
        # Non-fatal: if disk cache fails we still have in-memory + network fallback.
        return


def clear_forecast_cache(clear_disk: bool = False) -> None:
    _cache.clear()
    if clear_disk:
        with suppress(OSError):
            PERSISTENT_CACHE_PATH.unlink(missing_ok=True)


def weather_description(code: int | None) -> str:
    if code is None:
        return "Unknown"
    return WMO_WEATHER_CODES.get(code, f"Unknown ({code})")


def wind_direction_to_compass(degrees: float | int | None) -> str:
    if degrees is None:
        return "N/A"
    directions = [
        "N",
        "NNE",
        "NE",
        "ENE",
        "E",
        "ESE",
        "SE",
        "SSE",
        "S",
        "SSW",
        "SW",
        "WSW",
        "W",
        "WNW",
        "NW",
        "NNW",
    ]
    index = int((float(degrees) / 22.5) + 0.5) % 16
    return directions[index]


def _is_cache_valid(cached_at_epoch: float, now_epoch: float) -> bool:
    return now_epoch - cached_at_epoch < FORECAST_CACHE_TTL_SECONDS


def fetch_open_meteo_forecast(request: ForecastRequest) -> dict:
    key = _cache_key(request)
    now_epoch = time.time()

    memory_entry = _cache.get(key)
    if memory_entry and _is_cache_valid(memory_entry[0], now_epoch):
        return copy.deepcopy(memory_entry[1])

    persistent_cache = _load_persistent_cache()
    disk_entry = persistent_cache.get(key)
    if isinstance(disk_entry, dict):
        cached_at = disk_entry.get("cached_at")
        payload = disk_entry.get("payload")
        if (
            isinstance(cached_at, (int, float))
            and isinstance(payload, dict)
            and _is_cache_valid(float(cached_at), now_epoch)
        ):
            _cache[key] = (float(cached_at), payload)
            return copy.deepcopy(payload)

    params = {
        "latitude": request.latitude,
        "longitude": request.longitude,
        "current": ",".join(
            [
                "temperature_2m",
                "apparent_temperature",
                "relative_humidity_2m",
                "wind_speed_10m",
                "wind_direction_10m",
                "uv_index",
                "weather_code",
            ]
        ),
        "hourly": ",".join(
            [
                "temperature_2m",
                "apparent_temperature",
                "precipitation_probability",
                "precipitation",
                "weather_code",
            ]
        ),
        "daily": ",".join(
            [
                "temperature_2m_max",
                "temperature_2m_min",
                "uv_index_max",
                "precipitation_probability_max",
                "precipitation_sum",
                "sunrise",
                "sunset",
                "weather_code",
            ]
        ),
        "forecast_days": request.forecast_days,
        "timezone": request.timezone,
    }

    url = f"{API_BASE_URL}?{urlencode(params)}"

    try:
        with urlopen(url, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
            _cache[key] = (now_epoch, payload)
            persistent_cache[key] = {"cached_at": now_epoch, "payload": payload}
            _save_persistent_cache(persistent_cache)
            return copy.deepcopy(payload)
    except HTTPError as err:
        raise WeatherServiceError(
            f"Open-Meteo request failed with status {err.code}: {err.reason}"
        ) from err
    except URLError as err:
        raise WeatherServiceError(
            f"Network error while contacting Open-Meteo: {err.reason}"
        ) from err
    except json.JSONDecodeError as err:
        raise WeatherServiceError(
            f"Failed to parse Open-Meteo response: {err}"
        ) from err


def format_iso_label(iso_value: str, fmt: str) -> str:
    try:
        return datetime.fromisoformat(iso_value).strftime(fmt)
    except ValueError:
        return iso_value


def _day_period_from_hour(hour: int | None) -> str:
    if hour is None:
        return "overnight"
    if 0 <= hour < 6:
        return "overnight"
    if 6 <= hour < 12:
        return "morning"
    if 12 <= hour < 18:
        return "afternoon"
    return "evening"


def _parse_iso_datetime(value: object) -> datetime | None:
    if isinstance(value, str):
        with suppress(ValueError):
            return datetime.fromisoformat(value)
    return None


def _is_daylight_at(
    when_iso: object, sunrise_iso: object, sunset_iso: object
) -> bool | None:
    when_dt = _parse_iso_datetime(when_iso)
    sunrise_dt = _parse_iso_datetime(sunrise_iso)
    sunset_dt = _parse_iso_datetime(sunset_iso)
    if when_dt is None or sunrise_dt is None or sunset_dt is None:
        return None
    return sunrise_dt <= when_dt < sunset_dt


def _hourly_start_index(times: list[object], current_time: object) -> int:
    current_dt = _parse_iso_datetime(current_time)
    if current_dt is not None:
        for idx, value in enumerate(times):
            time_dt = _parse_iso_datetime(value)
            if time_dt is not None and time_dt > current_dt:
                return idx

    if isinstance(current_time, str) and current_time in times:
        return times.index(current_time) + 1

    return 0


def _build_dayparts(
    dates: list[str],
    hourly: dict,
    sunrise_by_date: dict[str, object],
    sunset_by_date: dict[str, object],
) -> list[dict]:
    times = hourly.get("time", [])
    temps = hourly.get("temperature_2m", [])
    pops = hourly.get("precipitation_probability", [])
    precipitation_mm = hourly.get("precipitation", [])
    codes = hourly.get("weather_code", [])

    period_order = ["overnight", "morning", "afternoon", "evening"]
    period_midpoint_hour = {
        "overnight": 2,
        "morning": 9,
        "afternoon": 15,
        "evening": 21,
    }
    date_set = set(dates)
    buckets: dict[str, dict[str, list[int]]] = {
        date: {period: [] for period in period_order} for date in dates
    }

    for idx, iso in enumerate(times):
        if not isinstance(iso, str) or "T" not in iso:
            continue
        date_part = iso.split("T", 1)[0]
        if date_part not in date_set:
            continue

        hour = None
        with suppress(TypeError, ValueError):
            hour = int(iso.split("T", 1)[1].split(":", 1)[0])

        period = _day_period_from_hour(hour)
        buckets[date_part][period].append(idx)

    def _as_float(value: object) -> float | None:
        if isinstance(value, (int, float)):
            return float(value)
        return None

    def _period_summary(indices: list[int], period: str, date: str) -> dict | None:
        if not indices:
            return None

        temp_values = [_as_float(temps[i]) for i in indices if i < len(temps)]
        temp_values = [v for v in temp_values if v is not None]
        pop_values = [_as_float(pops[i]) for i in indices if i < len(pops)]
        pop_values = [v for v in pop_values if v is not None]
        precipitation_values = [
            _as_float(precipitation_mm[i]) for i in indices if i < len(precipitation_mm)
        ]
        precipitation_values = [v for v in precipitation_values if v is not None]

        code_counts: dict[int, int] = {}
        for i in indices:
            if i >= len(codes):
                continue
            code = codes[i]
            if isinstance(code, int):
                code_counts[code] = code_counts.get(code, 0) + 1

        weather_code = (
            max(code_counts, key=lambda key: code_counts[key]) if code_counts else None
        )
        representative_iso = f"{date}T{period_midpoint_hour.get(period, 12):02d}:00"

        return {
            "period": period,
            "weather_code": weather_code,
            "weather": weather_description(weather_code),
            "temperature_min": min(temp_values) if temp_values else None,
            "temperature_max": max(temp_values) if temp_values else None,
            "precipitation_probability_max": max(pop_values) if pop_values else None,
            "precipitation_amount_mm": round(sum(precipitation_values), 2)
            if precipitation_values
            else None,
            "is_daylight": _is_daylight_at(
                representative_iso,
                sunrise_by_date.get(date),
                sunset_by_date.get(date),
            ),
        }

    return [
        {
            "date": date,
            "label": format_iso_label(date, "%a %b %d"),
            "periods": {
                period: _period_summary(buckets[date][period], period, date)
                for period in period_order
            },
        }
        for date in dates
    ]


def normalize_forecast_response(data: dict, location: dict) -> dict:
    current = data.get("current", {})
    current_units = data.get("current_units", {})

    hourly = data.get("hourly", {})
    hourly_units = data.get("hourly_units", {})

    daily = data.get("daily", {})
    daily_units = data.get("daily_units", {})

    times = hourly.get("time", [])
    dates = daily.get("time", [])
    sunrise_values = daily.get("sunrise", [None] * len(dates))
    sunset_values = daily.get("sunset", [None] * len(dates))
    sunrise_by_date = {
        date: sunrise_values[i]
        for i, date in enumerate(dates)
        if i < len(sunrise_values)
    }
    sunset_by_date = {
        date: sunset_values[i] for i, date in enumerate(dates) if i < len(sunset_values)
    }

    current_time = current.get("time")
    start_index = _hourly_start_index(times, current_time)
    end_index = min(start_index + 24, len(times))

    hourly_items = []
    for i in range(start_index, end_index):
        code = hourly.get("weather_code", [None] * len(times))[i]
        time_iso = times[i]
        date_str = time_iso.split("T", 1)[0] if isinstance(time_iso, str) else ""
        hourly_items.append(
            {
                "time": time_iso,
                "label": format_iso_label(time_iso, "%a %I:%M %p"),
                "weather_code": code,
                "weather": weather_description(code),
                "temperature": hourly.get("temperature_2m", [None] * len(times))[i],
                "apparent_temperature": hourly.get(
                    "apparent_temperature", [None] * len(times)
                )[i],
                "precipitation_probability": hourly.get(
                    "precipitation_probability", [None] * len(times)
                )[i],
                "is_daylight": _is_daylight_at(
                    time_iso,
                    sunrise_by_date.get(date_str),
                    sunset_by_date.get(date_str),
                ),
            }
        )

    dayparts_14d = _build_dayparts(
        dates=dates[:14],
        hourly=hourly,
        sunrise_by_date=sunrise_by_date,
        sunset_by_date=sunset_by_date,
    )

    daily_items = []
    for i, date_str in enumerate(dates):
        code = daily.get("weather_code", [None] * len(dates))[i]
        daily_items.append(
            {
                "date": date_str,
                "label": format_iso_label(date_str, "%a %b %d"),
                "weather_code": code,
                "weather": weather_description(code),
                "temperature_min": daily.get("temperature_2m_min", [None] * len(dates))[
                    i
                ],
                "temperature_max": daily.get("temperature_2m_max", [None] * len(dates))[
                    i
                ],
                "uv_index_max": daily.get("uv_index_max", [None] * len(dates))[i],
                "precipitation_probability_max": daily.get(
                    "precipitation_probability_max", [None] * len(dates)
                )[i],
                "precipitation_amount_mm": daily.get(
                    "precipitation_sum", [None] * len(dates)
                )[i],
                "sunrise": sunrise_by_date.get(date_str),
                "sunset": sunset_by_date.get(date_str),
            }
        )

    current_code = current.get("weather_code")
    current_date = (
        current_time.split("T", 1)[0]
        if isinstance(current_time, str) and "T" in current_time
        else None
    )
    today_index = dates.index(current_date) if current_date in dates else 0
    sunrise = sunrise_values[today_index] if today_index < len(sunrise_values) else None
    sunset = sunset_values[today_index] if today_index < len(sunset_values) else None

    return {
        "location": location,
        "units": {
            "current": current_units,
            "hourly": hourly_units,
            "daily": daily_units,
        },
        "current": {
            "time": current_time,
            "temperature": current.get("temperature_2m"),
            "apparent_temperature": current.get("apparent_temperature"),
            "humidity": current.get("relative_humidity_2m"),
            "wind_speed": current.get("wind_speed_10m"),
            "wind_direction_degrees": current.get("wind_direction_10m"),
            "wind_direction_compass": wind_direction_to_compass(
                current.get("wind_direction_10m")
            ),
            "uv_index": current.get("uv_index"),
            "weather_code": current_code,
            "weather": weather_description(current_code),
            "sunrise": sunrise,
            "sunset": sunset,
            "is_daylight": _is_daylight_at(current_time, sunrise, sunset),
        },
        "hourly_next_24h": hourly_items,
        "daily_7d": daily_items[:7],
        "daily_14d_extended": daily_items[7:14],
        "dayparts_14d": dayparts_14d,
        "schema_version": "1.0.0",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": "open-meteo.com",
    }


def get_weather(latitude: float, longitude: float, timezone: str = "auto") -> dict:
    request = ForecastRequest(latitude=latitude, longitude=longitude, timezone=timezone)
    raw = fetch_open_meteo_forecast(request)
    return normalize_forecast_response(
        raw,
        {
            "latitude": latitude,
            "longitude": longitude,
            "timezone": raw.get("timezone", timezone),
        },
    )


def get_myrnam_weather() -> dict:
    request = ForecastRequest(
        latitude=MYRNAM["latitude"],
        longitude=MYRNAM["longitude"],
        timezone=MYRNAM["timezone"],
    )
    raw = fetch_open_meteo_forecast(request)
    return normalize_forecast_response(raw, MYRNAM)
