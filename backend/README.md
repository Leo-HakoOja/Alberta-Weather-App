# Backend

FastAPI service providing weather data for mobile clients.

## Setup

```bash
cd ~/weather-app
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
```

## Run (dev)

```bash
bash ~/weather-app/scripts/run-api.sh
```

API will be available at `http://localhost:8000`.

## Endpoints

- `GET /health`
- `GET /v1/weather/myrnam`
- `GET /v1/weather?lat=53.66686&lon=-111.23504`

All weather endpoints return a validated `WeatherResponse` schema.

## Caching

- In-memory cache (fast repeat requests)
- Persistent disk cache at `backend/.cache/forecast_cache.json`
- Cache TTL: 5 minutes

Interactive docs:
- `http://localhost:8000/docs`
