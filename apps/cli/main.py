#!/usr/bin/env python3
"""Terminal weather app for Myrnam, Alberta using Open-Meteo."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen


MYRNAM_LAT = 53.66686
MYRNAM_LON = -111.23504
API_BASE_URL = "https://api.open-meteo.com/v1/forecast"


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


def fetch_weather_data() -> dict:
    """Fetch current and 7-day forecast weather data for Myrnam."""
    params = {
        "latitude": MYRNAM_LAT,
        "longitude": MYRNAM_LON,
        "current": ",".join(
            [
                "temperature_2m",
                "apparent_temperature",
                "relative_humidity_2m",
                "wind_speed_10m",
                "wind_direction_10m",
                "uv_index",
            ]
        ),
        "hourly": ",".join(
            [
                "temperature_2m",
                "apparent_temperature",
                "precipitation_probability",
                "weather_code",
            ]
        ),
        "daily": ",".join(
            [
                "temperature_2m_max",
                "temperature_2m_min",
                "uv_index_max",
                "precipitation_probability_max",
                "weather_code",
            ]
        ),
        "forecast_days": 14,
        "timezone": "auto",
    }

    url = f"{API_BASE_URL}?{urlencode(params)}"

    try:
        with urlopen(url, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as err:
        raise RuntimeError(
            f"API request failed with status {err.code}: {err.reason}"
        ) from err
    except URLError as err:
        raise RuntimeError(
            f"Network error while contacting Open-Meteo: {err.reason}"
        ) from err
    except json.JSONDecodeError as err:
        raise RuntimeError(f"Failed to parse API response: {err}") from err


def wind_direction_to_compass(degrees: float | int) -> str:
    """Convert wind direction in degrees to 16-point compass direction."""
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


def weather_description(code: int | None) -> str:
    if code is None:
        return "Unknown"
    return WMO_WEATHER_CODES.get(code, f"Unknown ({code})")


def print_current_weather(data: dict) -> None:
    current = data.get("current", {})
    current_units = data.get("current_units", {})

    temp = current.get("temperature_2m")
    apparent = current.get("apparent_temperature")
    humidity = current.get("relative_humidity_2m")
    wind_speed = current.get("wind_speed_10m")
    wind_dir_deg = current.get("wind_direction_10m")
    uv_index = current.get("uv_index")
    timestamp = current.get("time")

    time_display = "N/A"
    if timestamp:
        try:
            time_display = datetime.fromisoformat(timestamp).strftime(
                "%Y-%m-%d %I:%M %p"
            )
        except ValueError:
            time_display = timestamp

    wind_compass = (
        wind_direction_to_compass(wind_dir_deg) if wind_dir_deg is not None else "N/A"
    )

    print("\n" + "=" * 60)
    print("Myrnam, Alberta - Current Weather")
    print("=" * 60)
    print(f"As of:              {time_display}")
    print(
        f"Temperature:        {temp} {current_units.get('temperature_2m', '')} "
        f"(Feels like {apparent} {current_units.get('apparent_temperature', '')})"
    )
    print(
        f"Humidity:           {humidity} {current_units.get('relative_humidity_2m', '')}"
    )
    print(
        f"Wind:               {wind_speed} {current_units.get('wind_speed_10m', '')} "
        f"from {wind_compass} ({wind_dir_deg}°)"
    )
    print(f"UV Index:           {uv_index} {current_units.get('uv_index', '')}")


def print_24_hour_forecast(data: dict) -> None:
    hourly = data.get("hourly", {})
    hourly_units = data.get("hourly_units", {})
    current = data.get("current", {})

    times = hourly.get("time", [])
    temps = hourly.get("temperature_2m", [])
    apparent_temps = hourly.get("apparent_temperature", [])
    pops = hourly.get("precipitation_probability", [])
    weather_codes = hourly.get("weather_code", [])

    start_index = 0
    current_time = current.get("time")
    if current_time and current_time in times:
        start_index = times.index(current_time)

    end_index = min(start_index + 24, len(times))

    print("\n" + "=" * 60)
    print("Hourly Forecast (Next 24 Hours)")
    print("=" * 60)
    print(f"{'Time':<18} {'Weather':<26} {'Temp':<10} {'Feels':<10} {'Rain %':<8}")
    print("-" * 80)

    temp_unit = hourly_units.get("temperature_2m", "")
    apparent_unit = hourly_units.get("apparent_temperature", "")
    pop_unit = hourly_units.get("precipitation_probability", "")

    for i in range(start_index, end_index):
        date_str = times[i]
        try:
            label = datetime.fromisoformat(date_str).strftime("%a %I:%M %p")
        except ValueError:
            label = date_str

        code = weather_codes[i] if i < len(weather_codes) else None
        desc = weather_description(code)

        temp = temps[i] if i < len(temps) else "-"
        apparent = apparent_temps[i] if i < len(apparent_temps) else "-"
        pop = pops[i] if i < len(pops) else "-"

        temp_text = f"{temp}{temp_unit}" if temp != "-" else "-"
        apparent_text = f"{apparent}{apparent_unit}" if apparent != "-" else "-"
        pop_text = f"{pop}{pop_unit}" if pop != "-" else "-"

        print(
            f"{label:<18} {desc:<26.26} {temp_text:<10} {apparent_text:<10} {pop_text:<8}"
        )


def print_7_day_forecast(data: dict) -> None:
    daily = data.get("daily", {})
    daily_units = data.get("daily_units", {})

    dates = daily.get("time", [])[:7]
    max_temps = daily.get("temperature_2m_max", [])
    min_temps = daily.get("temperature_2m_min", [])
    uv_max = daily.get("uv_index_max", [])
    pop_max = daily.get("precipitation_probability_max", [])
    weather_codes = daily.get("weather_code", [])

    print("\n" + "=" * 60)
    print("7-Day Forecast")
    print("=" * 60)
    print(f"{'Day':<12} {'Weather':<28} {'Min/Max':<14} {'UV Max':<8} {'Rain %':<8}")
    print("-" * 80)

    for i, date_str in enumerate(dates):
        try:
            day_name = datetime.fromisoformat(date_str).strftime("%a %b %d")
        except ValueError:
            day_name = date_str

        code = weather_codes[i] if i < len(weather_codes) else None
        desc = weather_description(code)

        min_temp = min_temps[i] if i < len(min_temps) else "-"
        max_temp = max_temps[i] if i < len(max_temps) else "-"
        min_max = (
            f"{min_temp}/{max_temp}{daily_units.get('temperature_2m_max', '')}"
            if min_temp != "-" and max_temp != "-"
            else "-"
        )

        uv = uv_max[i] if i < len(uv_max) else "-"
        pop = pop_max[i] if i < len(pop_max) else "-"

        print(f"{day_name:<12} {desc:<28.28} {min_max:<14} {str(uv):<8} {str(pop):<8}")


def print_14_day_forecast(data: dict) -> None:
    daily = data.get("daily", {})
    daily_units = data.get("daily_units", {})

    dates = daily.get("time", [])[7:14]
    max_temps = daily.get("temperature_2m_max", [])
    min_temps = daily.get("temperature_2m_min", [])
    weather_codes = daily.get("weather_code", [])

    print("\n" + "=" * 60)
    print("14-Day Forecast (Days 8-14)")
    print("=" * 60)
    print(f"{'Day':<12} {'Weather Prediction':<32} {'Min/Max':<14}")
    print("-" * 62)

    for offset, date_str in enumerate(dates, start=7):
        try:
            day_name = datetime.fromisoformat(date_str).strftime("%a %b %d")
        except ValueError:
            day_name = date_str

        code = weather_codes[offset] if offset < len(weather_codes) else None
        desc = weather_description(code)

        min_temp = min_temps[offset] if offset < len(min_temps) else "-"
        max_temp = max_temps[offset] if offset < len(max_temps) else "-"
        min_max = (
            f"{min_temp}/{max_temp}{daily_units.get('temperature_2m_max', '')}"
            if min_temp != "-" and max_temp != "-"
            else "-"
        )

        print(f"{day_name:<12} {desc:<32.32} {min_max:<14}")


def main() -> int:
    print("Fetching weather data from Open-Meteo...")
    try:
        data = fetch_weather_data()
    except RuntimeError as err:
        print(f"Error: {err}", file=sys.stderr)
        return 1

    print_current_weather(data)
    print_24_hour_forecast(data)
    print_7_day_forecast(data)
    print_14_day_forecast(data)
    print("=" * 60 + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
