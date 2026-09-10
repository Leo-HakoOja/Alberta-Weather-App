"""Tests for the WeatherKit source normalisers (ADR 0009).

The failure mode that matters here is a quiet unit mismatch. WeatherKit reports
humidity and precipitation chance as 0-1 fractions while Open-Meteo and ECCC report
percentages, so an un-normalised value shows 0.6 beside 60 in the side-by-side
comparison and simply looks like one source is broken.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.app.weatherkit_service import (  # noqa: E402
    _humanize_condition,
    _normalize_current,
    _normalize_daily,
    _normalize_hourly,
    _percent,
)

# Shaped like a real WeatherKit currentWeather block, including the 0-1 humidity
# that the live verification returned.
_CURRENT = {
    "asOf": "2026-09-10T18:51:14Z",
    "temperature": 16.21,
    "temperatureApparent": 15.8,
    "humidity": 0.6,
    "windSpeed": 12.4,
    "windDirection": 270,
    "uvIndex": 3,
    "conditionCode": "Cloudy",
    "daylight": True,
}


def test_humidity_fraction_becomes_percent():
    out = _normalize_current(_CURRENT)
    assert out["humidity"] == 60.0


def test_precipitation_chance_becomes_percent():
    assert _percent(0.35) == 35.0
    assert _percent(1) == 100.0
    assert _percent(0) == 0.0


def test_percent_rejects_non_numbers():
    assert _percent(None) is None
    assert _percent("0.5") is None
    assert _percent({}) is None


def test_current_carries_the_scalar_fields():
    out = _normalize_current(_CURRENT)
    assert out["temperature"] == 16.21
    assert out["apparent_temperature"] == 15.8
    assert out["wind_speed"] == 12.4
    assert out["wind_direction_degrees"] == 270
    assert out["uv_index"] == 3
    assert out["is_daylight"] is True
    assert out["time"] == "2026-09-10T18:51:14Z"


def test_wind_direction_is_converted_to_compass():
    out = _normalize_current(_CURRENT)
    assert out["wind_direction_compass"] not in (None, "", "N/A")


def test_camelcase_conditions_read_like_the_other_sources():
    assert _humanize_condition("Cloudy") == "Cloudy"
    assert _humanize_condition("MostlyCloudy") == "Mostly cloudy"
    assert _humanize_condition("PartlyCloudy") == "Partly cloudy"
    assert _humanize_condition("ScatteredThunderstorms") == "Scattered thunderstorms"


def test_condition_falls_back_rather_than_crashing():
    assert _humanize_condition(None) == "-"
    assert _humanize_condition("") == "-"
    assert _humanize_condition(123) == "-"


def test_current_survives_an_empty_payload():
    out = _normalize_current({})
    assert out["temperature"] is None
    assert out["humidity"] is None
    assert out["weather"] == "-"


def test_current_rejects_a_non_dict():
    assert _normalize_current(None) is None
    assert _normalize_current([]) is None


def test_hourly_is_capped_at_24_and_normalised():
    hours = [
        {
            "forecastStart": f"2026-09-10T{h:02d}:00:00Z",
            "temperature": 10 + h,
            "humidity": 0.5,
            "precipitationChance": 0.25,
            "conditionCode": "PartlyCloudy",
            "windDirection": 180,
        }
        for h in range(24)
    ] * 2  # 48 entries; only 24 should survive
    out = _normalize_hourly({"forecastHourly": {"hours": hours}})
    assert len(out) == 24
    assert out[0]["humidity"] == 50.0
    assert out[0]["precipitation_probability"] == 25.0
    assert out[0]["weather"] == "Partly cloudy"


def test_hourly_skips_entries_with_no_start_time():
    out = _normalize_hourly(
        {"forecastHourly": {"hours": [{"temperature": 5}, "junk", None]}}
    )
    assert out == []


def test_hourly_handles_a_missing_block():
    assert _normalize_hourly({}) == []
    assert _normalize_hourly({"forecastHourly": {}}) == []


def test_daily_is_capped_at_7_and_dates_are_extracted():
    days = [
        {
            "forecastStart": f"2026-09-{10 + d:02d}T06:00:00Z",
            "temperatureMax": 20 + d,
            "temperatureMin": 5 + d,
            "precipitationChance": 0.1,
            "conditionCode": "Clear",
        }
        for d in range(10)
    ]
    out = _normalize_daily({"forecastDaily": {"days": days}})
    assert len(out) == 7
    assert out[0]["date"] == "2026-09-10"
    assert out[0]["temperature_max"] == 20
    assert out[0]["precipitation_probability_max"] == 10.0


def test_daily_handles_a_missing_block():
    assert _normalize_daily({}) == []


def test_missing_credentials_produce_an_error_stub_not_an_exception():
    """A machine with no WeatherKit credentials must still serve two sources."""
    import os

    from backend.app import weatherkit_service

    saved_env = {
        k: os.environ.pop(k, None)
        for k in (
            "WEATHERKIT_TEAM_ID",
            "WEATHERKIT_SERVICES_ID",
            "WEATHERKIT_KEY_ID",
            "WEATHERKIT_PRIVATE_KEY",
            "WEATHERKIT_KEY_PATH",
        )
    }
    saved_dir = weatherkit_service.CONFIG_DIR
    saved_cache = weatherkit_service._token_cache
    try:
        weatherkit_service.CONFIG_DIR = "/nonexistent/apple-weatherkit"
        weatherkit_service._token_cache = None
        out = weatherkit_service.fetch_weatherkit_source(53.6667, -111.0)
        assert out["source_id"] == "apple-weatherkit"
        assert out["error"] is not None
        assert out["current"] is None
        assert out["hourly_next_24h"] == []
    finally:
        weatherkit_service.CONFIG_DIR = saved_dir
        weatherkit_service._token_cache = saved_cache
        for key, value in saved_env.items():
            if value is not None:
                os.environ[key] = value


# ---------------------------------------------------------------------------
# Contract tests.
#
# The field-by-field tests above check what this module *intends* to emit. They
# cannot catch a field the schema requires and this module never knew about,
# which is exactly how `uv_index_max` was missed: every unit test passed while
# the real response failed validation. These validate against the actual models.
# ---------------------------------------------------------------------------

from backend.app.schemas import (  # noqa: E402
    CurrentConditions,
    DailyForecastItem,
    HourlyForecastItem,
)

_FULL_PAYLOAD = {
    "currentWeather": _CURRENT,
    "forecastHourly": {
        "hours": [
            {
                "forecastStart": "2026-09-10T19:00:00Z",
                "temperature": 16.4,
                "temperatureApparent": 16.0,
                "humidity": 0.58,
                "windSpeed": 9.1,
                "windDirection": 200,
                "uvIndex": 2,
                "precipitationChance": 0.12,
                "precipitationAmount": 0.0,
                "conditionCode": "MostlyClear",
                "daylight": True,
            }
        ]
    },
    "forecastDaily": {
        "days": [
            {
                "forecastStart": "2026-09-10T06:00:00Z",
                "temperatureMax": 21.3,
                "temperatureMin": 7.4,
                "maxUvIndex": 4,
                "precipitationChance": 0.2,
                "precipitationAmount": 0.5,
                "conditionCode": "PartlyCloudy",
                "sunrise": "2026-09-10T12:57:00Z",
                "sunset": "2026-09-11T02:11:00Z",
            }
        ]
    },
}


def test_current_validates_against_the_schema():
    CurrentConditions.model_validate(_normalize_current(_CURRENT))


def test_hourly_validates_against_the_schema():
    items = _normalize_hourly(_FULL_PAYLOAD)
    assert items
    for item in items:
        HourlyForecastItem.model_validate(item)


def test_daily_validates_against_the_schema():
    """Regression: uv_index_max is required and was originally not emitted."""
    items = _normalize_daily(_FULL_PAYLOAD)
    assert items
    for item in items:
        DailyForecastItem.model_validate(item)


def test_daily_emits_uv_index_max_even_when_apple_omits_it():
    sparse = {"forecastDaily": {"days": [{"forecastStart": "2026-09-10T06:00:00Z"}]}}
    items = _normalize_daily(sparse)
    assert "uv_index_max" in items[0]
    assert items[0]["uv_index_max"] is None
    DailyForecastItem.model_validate(items[0])


def test_daily_carries_sunrise_and_sunset_through():
    item = _normalize_daily(_FULL_PAYLOAD)[0]
    assert item["sunrise"] == "2026-09-10T12:57:00Z"
    assert item["sunset"] == "2026-09-11T02:11:00Z"
    assert item["uv_index_max"] == 4
