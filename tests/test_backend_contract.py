from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from backend.app import main as api_main
from backend.app.schemas import WeatherResponse
from backend.app.weather_service import (
    ForecastRequest,
    _load_persistent_cache,
    _save_persistent_cache,
    clear_forecast_cache,
    fetch_open_meteo_forecast,
    normalize_forecast_response,
)


def _sample_raw(days: int = 14) -> dict:
    daily_dates = [f"2026-04-{i:02d}" for i in range(1, days + 1)]
    hourly_times = [f"2026-04-01T{i:02d}:00" for i in range(24)]

    return {
        "timezone": "America/Edmonton",
        "current": {
            "time": "2026-04-01T02:00",
            "temperature_2m": 5.5,
            "apparent_temperature": 3.2,
            "relative_humidity_2m": 77,
            "wind_speed_10m": 16.4,
            "wind_direction_10m": 110,
            "uv_index": 1.1,
            "weather_code": 2,
        },
        "current_units": {"temperature_2m": "°C"},
        "hourly": {
            "time": hourly_times,
            "temperature_2m": [float(i) for i in range(24)],
            "apparent_temperature": [float(i) - 1 for i in range(24)],
            "precipitation_probability": [i % 100 for i in range(24)],
            "precipitation": [round((i % 4) * 0.2, 1) for i in range(24)],
            "weather_code": [0 if i < 10 else 3 for i in range(24)],
        },
        "hourly_units": {"temperature_2m": "°C"},
        "daily": {
            "time": daily_dates,
            "temperature_2m_min": [float(-10 + i) for i in range(days)],
            "temperature_2m_max": [float(0 + i) for i in range(days)],
            "uv_index_max": [float(2 + i / 10) for i in range(days)],
            "precipitation_probability_max": [20 + i for i in range(days)],
            "precipitation_sum": [round(i * 0.7, 1) for i in range(days)],
            "sunrise": [f"2026-04-{i:02d}T06:3{i % 10}" for i in range(1, days + 1)],
            "sunset": [f"2026-04-{i:02d}T20:1{i % 10}" for i in range(1, days + 1)],
            "weather_code": [1 if i % 2 == 0 else 3 for i in range(days)],
        },
        "daily_units": {"temperature_2m_min": "°C", "temperature_2m_max": "°C"},
    }


class WeatherServiceContractTests(unittest.TestCase):
    def setUp(self) -> None:
        clear_forecast_cache(clear_disk=True)

    def tearDown(self) -> None:
        clear_forecast_cache(clear_disk=True)

    def test_normalized_response_has_versioned_contract_shape(self) -> None:
        data = normalize_forecast_response(
            _sample_raw(),
            {
                "name": "Myrnam",
                "province": "Alberta",
                "country": "Canada",
                "latitude": 53.66686,
                "longitude": -111.23504,
                "timezone": "America/Edmonton",
            },
        )

        self.assertEqual(data["schema_version"], "1.1.0")
        self.assertIn("generated_at", data)
        self.assertIn("location", data)
        self.assertIn("units", data)
        self.assertIn("current", data)
        self.assertIn("hourly_next_24h", data)
        self.assertIn("daily_7d", data)
        self.assertIn("daily_14d_extended", data)
        self.assertIn("dayparts_14d", data)
        self.assertIn("sources", data)

        self.assertEqual(len(data["hourly_next_24h"]), 21)
        self.assertEqual(data["hourly_next_24h"][0]["time"], "2026-04-01T03:00")
        self.assertEqual(len(data["daily_7d"]), 7)
        self.assertEqual(len(data["daily_14d_extended"]), 7)
        self.assertEqual(len(data["dayparts_14d"]), 14)
        self.assertIsNotNone(
            data["dayparts_14d"][0]["periods"]["overnight"]["precipitation_amount_mm"]
        )
        self.assertEqual(data["current"]["wind_direction_compass"], "ESE")
        self.assertIsNotNone(data["current"]["sunrise"])
        self.assertIsNotNone(data["current"]["sunset"])

        # normalize_forecast_response always seeds the Open-Meteo source.
        self.assertEqual(len(data["sources"]), 1)
        self.assertEqual(data["sources"][0]["source_id"], "open-meteo")
        self.assertEqual(
            data["sources"][0]["current"]["temperature"],
            data["current"]["temperature"],
        )
        self.assertEqual(
            len(data["sources"][0]["hourly_next_24h"]), len(data["hourly_next_24h"])
        )

        validated = WeatherResponse.model_validate(data)
        self.assertEqual(validated.schema_version, "1.1.0")
        self.assertEqual(len(validated.sources), 1)

    def test_forecast_fetch_uses_in_memory_cache(self) -> None:
        payload = _sample_raw()

        class _DummyResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return json.dumps(payload).encode("utf-8")

        with patch(
            "backend.app.weather_service.urlopen", return_value=_DummyResponse()
        ) as mocked:
            req = ForecastRequest(
                latitude=53.66686, longitude=-111.23504, timezone="America/Edmonton"
            )
            first = fetch_open_meteo_forecast(req)
            second = fetch_open_meteo_forecast(req)

        self.assertEqual(mocked.call_count, 1)
        self.assertEqual(first["timezone"], "America/Edmonton")
        self.assertEqual(second["timezone"], "America/Edmonton")

    def test_persistent_cache_round_trip(self) -> None:
        key = "test-key"
        payload = {"timezone": "America/Edmonton"}

        with tempfile.TemporaryDirectory() as tmp_dir:
            cache_path = Path(tmp_dir) / "forecast_cache.json"
            _save_persistent_cache(
                {key: {"cached_at": 123.0, "payload": payload}},
                path=cache_path,
            )
            loaded = _load_persistent_cache(path=cache_path)

        self.assertIn(key, loaded)
        self.assertEqual(loaded[key]["payload"]["timezone"], "America/Edmonton")


class ApiEndpointTests(unittest.TestCase):
    def test_health_endpoint(self) -> None:
        self.assertEqual(api_main.health(), {"status": "ok"})

    def test_weather_endpoint_passes_coordinates_and_timezone(self) -> None:
        valid_payload = normalize_forecast_response(
            _sample_raw(),
            {
                "latitude": 53.66686,
                "longitude": -111.23504,
                "timezone": "America/Edmonton",
            },
        )

        with patch(
            "backend.app.main.get_weather", return_value=valid_payload
        ) as mocked:
            response = api_main.weather_by_coordinates(
                lat=53.66686,
                lon=-111.23504,
                timezone="America/Edmonton",
            )

        self.assertIsInstance(response, WeatherResponse)
        self.assertEqual(response.location.timezone, "America/Edmonton")
        mocked.assert_called_once_with(
            latitude=53.66686,
            longitude=-111.23504,
            timezone="America/Edmonton",
        )


class EcccSourceTests(unittest.TestCase):
    """ECCC adapter tests — uses mocked HTTP, never hits the network."""

    def _sample_eccc_payload(self) -> dict:
        return {
            "properties": {
                "currentConditions": {
                    "timestamp": {"en": "2026-05-18T01:00:00Z"},
                    "temperature": {"value": {"en": 11.5}},
                    "windChill": {"value": {"en": -4}},
                    "relativeHumidity": {"value": {"en": 40}},
                    "wind": {
                        "speed": {"value": {"en": 2}},
                        "direction": {"value": {"en": "N"}},
                        "bearing": {"value": {"en": 350.7}},
                    },
                    "condition": {"en": "Mostly cloudy"},
                    "iconCode": {"value": 6},
                },
                "forecastGroup": {
                    "forecasts": [
                        {
                            "period": {"textForecastName": {"en": "Tonight"}},
                            "temperatures": {
                                "temperature": [
                                    {"class": {"en": "low"}, "value": {"en": 0}}
                                ],
                                "textSummary": {"en": "Low zero with patchy frost."},
                            },
                        },
                        {
                            "period": {"textForecastName": {"en": "Monday"}},
                            "temperatures": {
                                "temperature": [
                                    {"class": {"en": "high"}, "value": {"en": 15}}
                                ],
                                "textSummary": {"en": "High 15."},
                            },
                        },
                        {
                            "period": {"textForecastName": {"en": "Monday night"}},
                            "temperatures": {
                                "temperature": [
                                    {"class": {"en": "low"}, "value": {"en": 3}}
                                ],
                                "textSummary": {"en": "Low plus 3."},
                            },
                        },
                    ],
                },
                "hourlyForecastGroup": {
                    "hourlyForecasts": [
                        {
                            "timestamp": "2026-05-18T02:00:00Z",
                            "condition": {"en": "Chance of showers"},
                            "temperature": {"value": {"en": 10}},
                            "iconCode": {"value": 6},
                            "lop": {"value": {"en": 30}},
                            "wind": {
                                "speed": {"value": {"en": 10}},
                                "direction": {"value": {"en": "NE"}},
                                "bearing": {"value": {"en": 45}},
                            },
                        }
                    ],
                },
            }
        }

    def test_eccc_normalization_shape(self) -> None:
        from backend.app import eccc_service
        from backend.app.schemas import SourceForecast

        eccc_service._site_cache.clear()
        sample = self._sample_eccc_payload()

        with patch(
            "backend.app.eccc_service._http_get_json", return_value=sample
        ):
            result = eccc_service.fetch_eccc_source("Myrnam", 53.66686, -111.23504)

        self.assertEqual(result["source_id"], "eccc")
        self.assertIsNone(result["error"])
        self.assertEqual(result["current"]["temperature"], 11.5)
        self.assertEqual(result["current"]["apparent_temperature"], -4)
        self.assertEqual(result["current"]["wind_direction_compass"], "N")
        self.assertEqual(len(result["hourly_next_24h"]), 1)
        self.assertEqual(
            result["hourly_next_24h"][0]["precipitation_probability"], 30
        )
        # Daily collapse: "Tonight" + "Monday day" + "Monday night" = 2 dated buckets.
        self.assertGreaterEqual(len(result["daily_7d"]), 2)
        monday = result["daily_7d"][1]
        self.assertEqual(monday["temperature_max"], 15)
        self.assertEqual(monday["temperature_min"], 3)

        SourceForecast.model_validate(result)

    def test_eccc_returns_error_stub_outside_alberta(self) -> None:
        from backend.app import eccc_service

        eccc_service._site_cache.clear()
        eccc_service._alberta_sites_cache = None

        # Mock the bbox fetch to return an empty list so resolve_site_code falls
        # through to "None" without hitting the network.
        with patch(
            "backend.app.eccc_service._http_get_json",
            return_value={"features": []},
        ):
            result = eccc_service.fetch_eccc_source("Phoenix", 33.45, -112.07)

        self.assertEqual(result["source_id"], "eccc")
        self.assertIsNotNone(result["error"])
        self.assertIsNone(result["current"])

    def test_eccc_known_location_skips_bbox_lookup(self) -> None:
        from backend.app import eccc_service

        site_code = eccc_service.resolve_site_code(
            "Edmonton", 53.54, -113.49
        )
        self.assertEqual(site_code, "ab-50")


if __name__ == "__main__":
    unittest.main()
