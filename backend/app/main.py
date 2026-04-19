from __future__ import annotations

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from .schemas import WeatherResponse
from .weather_service import WeatherServiceError, get_myrnam_weather, get_weather

app = FastAPI(
    title="Weather App API",
    version="0.1.0",
    description="Backend weather API for iOS and Android clients.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/v1/weather/myrnam", response_model=WeatherResponse)
def weather_myrnam() -> WeatherResponse:
    try:
        return WeatherResponse.model_validate(get_myrnam_weather())
    except WeatherServiceError as err:
        raise HTTPException(status_code=502, detail=str(err)) from err


@app.get("/v1/weather", response_model=WeatherResponse)
def weather_by_coordinates(
    lat: float = Query(..., description="Latitude"),
    lon: float = Query(..., description="Longitude"),
    timezone: str = Query("auto", description="IANA timezone name or 'auto'"),
) -> WeatherResponse:
    try:
        return WeatherResponse.model_validate(
            get_weather(latitude=lat, longitude=lon, timezone=timezone)
        )
    except WeatherServiceError as err:
        raise HTTPException(status_code=502, detail=str(err)) from err
