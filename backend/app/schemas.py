from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict


class Location(BaseModel):
    model_config = ConfigDict(extra="allow")

    latitude: float
    longitude: float
    timezone: str
    name: str | None = None
    province: str | None = None
    country: str | None = None


class CurrentConditions(BaseModel):
    time: str | None
    temperature: float | None
    apparent_temperature: float | None
    humidity: float | int | None
    wind_speed: float | None
    wind_direction_degrees: float | int | None
    wind_direction_compass: str
    uv_index: float | None
    weather_code: int | None
    weather: str
    sunrise: str | None = None
    sunset: str | None = None
    is_daylight: bool | None = None


class HourlyForecastItem(BaseModel):
    time: str
    label: str
    weather_code: int | None
    weather: str
    temperature: float | None
    apparent_temperature: float | None
    precipitation_probability: float | int | None
    is_daylight: bool | None = None


class DailyForecastItem(BaseModel):
    date: str
    label: str
    weather_code: int | None
    weather: str
    temperature_min: float | None
    temperature_max: float | None
    uv_index_max: float | None
    precipitation_probability_max: float | int | None
    precipitation_amount_mm: float | None = None
    sunrise: str | None = None
    sunset: str | None = None


class UnitsBySection(BaseModel):
    model_config = ConfigDict(extra="allow")

    current: dict[str, Any]
    hourly: dict[str, Any]
    daily: dict[str, Any]


class DaypartSummary(BaseModel):
    period: str
    weather_code: int | None
    weather: str
    temperature_min: float | None
    temperature_max: float | None
    precipitation_probability_max: float | int | None
    precipitation_amount_mm: float | None = None
    is_daylight: bool | None = None


class DaypartsForecastItem(BaseModel):
    date: str
    label: str
    periods: dict[str, DaypartSummary | None]


class WeatherResponse(BaseModel):
    location: Location
    units: UnitsBySection
    current: CurrentConditions
    hourly_next_24h: list[HourlyForecastItem]
    daily_7d: list[DailyForecastItem]
    daily_14d_extended: list[DailyForecastItem]
    dayparts_14d: list[DaypartsForecastItem]
    schema_version: str
    generated_at: str
    source: str
