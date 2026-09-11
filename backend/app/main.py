from __future__ import annotations

from typing import Optional

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import radar_service

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


# ---------------------------------------------------------------------------
# Radar grids for the on-device renderer (ADR 0010)
# ---------------------------------------------------------------------------

_FRAME_HEADERS = {
    # A frame for a given instant (and model run) never changes.
    "Cache-Control": "public, max-age=604800, immutable",
    "X-Radar-Encoding": "gzip-uint8-codes",
}


def _frame_response(blob: bytes, transport: Optional[str]) -> Response:
    headers = dict(_FRAME_HEADERS)
    if transport == "http":
        # Browsers cannot gunzip in Dart, so the web build asks for the gzip
        # to be declared as transport encoding and the browser inflates it.
        headers["Content-Encoding"] = "gzip"
    return Response(content=blob, media_type="application/octet-stream", headers=headers)


def _radar_call(fn, *args):
    try:
        return fn(*args)
    except LookupError as err:
        raise HTTPException(status_code=404, detail=str(err)) from err
    except radar_service.RadarError as err:
        raise HTTPException(status_code=502, detail=str(err)) from err


@app.get("/v1/radar/manifest")
def radar_manifest() -> dict:
    return _radar_call(radar_service.build_manifest)


@app.get("/v1/radar/observed/{frame_id}")
def radar_observed(frame_id: str, transport: Optional[str] = None) -> Response:
    instant = _radar_call(radar_service.parse_stamp, frame_id)
    return _frame_response(_radar_call(radar_service.observed_frame, instant), transport)


@app.get("/v1/radar/forecast/{run_id}/{frame_id}")
def radar_forecast(run_id: str, frame_id: str, transport: Optional[str] = None) -> Response:
    run = _radar_call(radar_service.parse_stamp, run_id)
    instant = _radar_call(radar_service.parse_stamp, frame_id)
    return _frame_response(_radar_call(radar_service.forecast_frame, run, instant), transport)


@app.get("/v1/radar/flow/{run_id}/{frame_id}")
def radar_flow(run_id: str, frame_id: str, response: Response) -> dict:
    run = _radar_call(radar_service.parse_stamp, run_id)
    instant = _radar_call(radar_service.parse_stamp, frame_id)
    response.headers["Cache-Control"] = "public, max-age=604800, immutable"
    return _radar_call(radar_service.forecast_flow, run, instant)


@app.get("/v1/radar/warnings")
def radar_warnings() -> dict:
    return _radar_call(radar_service.fetch_warnings)


class RadarTelemetry(BaseModel):
    """How long radar took to become ready on a phone. Timings, byte counts and
    frame counts only; no location, no device identifier."""

    build: Optional[str] = Field(default=None, max_length=32)
    platform: Optional[str] = Field(default=None, max_length=16)
    launch_to_manifest_ms: Optional[int] = None
    launch_to_first_frame_ms: Optional[int] = None
    launch_to_ready_ms: Optional[int] = None
    real_frames: Optional[int] = None
    frames_from_network: Optional[int] = None
    frames_from_disk: Optional[int] = None
    network_bytes: Optional[int] = None
    disk_bytes: Optional[int] = None
    flows_from_network: Optional[int] = None
    flow_bytes: Optional[int] = None
    launch_to_flows_ms: Optional[int] = None
    decode_ms: Optional[int] = None
    render_ms_avg: Optional[float] = None
    display_frames: Optional[int] = None
    error: Optional[str] = Field(default=None, max_length=300)


@app.post("/v1/radar/telemetry", status_code=204)
def radar_telemetry_post(report: RadarTelemetry) -> Response:
    radar_service.record_telemetry(report.model_dump(exclude_none=True))
    return Response(status_code=204)


@app.get("/v1/radar/telemetry")
def radar_telemetry_get() -> list[dict]:
    return radar_service.recent_telemetry()
