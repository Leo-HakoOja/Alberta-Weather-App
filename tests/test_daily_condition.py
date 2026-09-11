"""The daily card headline must describe the day, not its worst hour.

Open-Meteo's daily `weather_code` is "the most severe weather condition on a given
day" across all 24 hours. Live data for Myrnam on 2026-09-17 had a daily code of
Overcast while all twelve daylight hours were Clear, so the 7-day and 14-day cards
showed a gloomy day that the tap-through then contradicted.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.app.schemas import DailyForecastItem  # noqa: E402
from backend.app.weather_service import (  # noqa: E402
    PRECIP_HEADLINE_MIN_HOURS,
    _representative_daily_code,
    normalize_forecast_response,
)

CLEAR, MAINLY_CLEAR, PARTLY, OVERCAST = 0, 1, 2, 3
DRIZZLE, RAIN, SNOW, THUNDER = 51, 61, 71, 95


def test_twelve_clear_daylight_hours_read_as_clear_not_overcast():
    """The live 2026-09-17 case: daily code Overcast, daylight all Clear."""
    assert _representative_daily_code([CLEAR] * 12, fallback=OVERCAST) == CLEAR


def test_clear_group_beats_a_few_overcast_hours():
    """2026-09-13: Clear 7, Mainly clear 3, Overcast 3."""
    hours = [CLEAR] * 7 + [MAINLY_CLEAR] * 3 + [OVERCAST] * 3
    assert _representative_daily_code(hours, fallback=OVERCAST) == CLEAR


def test_a_passing_shower_does_not_take_the_headline():
    hours = [CLEAR] * 9 + [DRIZZLE] * (PRECIP_HEADLINE_MIN_HOURS - 1)
    assert _representative_daily_code(hours, fallback=DRIZZLE) == CLEAR


def test_a_genuinely_wet_day_still_reads_as_wet():
    hours = [OVERCAST] * 6 + [RAIN] * PRECIP_HEADLINE_MIN_HOURS
    assert _representative_daily_code(hours, fallback=RAIN) == RAIN


def test_precipitation_ties_go_to_the_more_severe_type():
    """2026-09-15: Drizzle 3, Rain 3 among overcast hours."""
    hours = [OVERCAST] * 6 + [DRIZZLE] * 3 + [RAIN] * 3
    assert _representative_daily_code(hours, fallback=RAIN) == RAIN


def test_snow_and_thunder_are_recognised_as_precipitation():
    assert _representative_daily_code([CLEAR] * 4 + [SNOW] * 5, None) == SNOW
    assert _representative_daily_code([PARTLY] * 4 + [THUNDER] * 4, None) == THUNDER


def test_dry_group_ties_go_to_the_more_severe_group():
    hours = [MAINLY_CLEAR] * 4 + [OVERCAST] * 4
    assert _representative_daily_code(hours, fallback=None) == OVERCAST


def test_no_hourly_data_falls_back_to_open_meteo():
    assert _representative_daily_code([], fallback=OVERCAST) == OVERCAST


def test_garbage_codes_are_ignored():
    hours = [None, "3", True, 12345, CLEAR, CLEAR]
    assert _representative_daily_code(hours, fallback=OVERCAST) == CLEAR


def _payload(daily_code, hourly_codes):
    """A minimal Open-Meteo response for one day with sunrise 07:00, sunset 19:00."""
    date = "2026-09-17"
    return {
        "current": {"time": f"{date}T10:00", "weather_code": CLEAR},
        "hourly": {
            "time": [f"{date}T{h:02d}:00" for h in range(24)],
            "weather_code": hourly_codes,
        },
        "daily": {
            "time": [date],
            "weather_code": [daily_code],
            "sunrise": [f"{date}T07:00"],
            "sunset": [f"{date}T19:00"],
            "temperature_2m_max": [18.0],
            "temperature_2m_min": [4.0],
            "uv_index_max": [4.0],
            "precipitation_probability_max": [2],
            "precipitation_sum": [0.0],
        },
    }


def test_normalized_daily_item_uses_daylight_headline_and_keeps_worst_hour():
    # Overcast overnight, clear through every daylight hour.
    codes = [OVERCAST] * 7 + [CLEAR] * 12 + [OVERCAST] * 5
    response = normalize_forecast_response(
        _payload(OVERCAST, codes), {"latitude": 53.67, "longitude": -111.0}
    )
    day = response["daily_7d"][0]
    assert day["weather_code"] == CLEAR
    assert day["weather"] == "Clear sky"
    assert day["weather_code_most_severe"] == OVERCAST
    DailyForecastItem.model_validate(day)


def test_overnight_rain_alone_does_not_make_a_dry_day_wet():
    codes = [RAIN] * 6 + [PARTLY] * 13 + [RAIN] * 5
    response = normalize_forecast_response(
        _payload(RAIN, codes), {"latitude": 53.67, "longitude": -111.0}
    )
    assert response["daily_7d"][0]["weather_code"] == PARTLY
