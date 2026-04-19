# API Contract (v0.1)

## Base URL
- Local dev: `http://localhost:8000`

## Endpoints

### `GET /health`
Returns service health.

### `GET /v1/weather/myrnam`
Returns weather payload for Myrnam, Alberta.

### `GET /v1/weather?lat={lat}&lon={lon}&timezone={tz}`
Returns weather payload for any coordinates.

Query params:
- `lat` (required)
- `lon` (required)
- `timezone` (optional, default `auto`)

## Response shape (summary)

```json
{
  "location": {
    "latitude": 53.66,
    "longitude": -111.23,
    "timezone": "America/Edmonton"
  },
  "units": {
    "current": {},
    "hourly": {},
    "daily": {}
  },
  "current": {},
  "hourly_next_24h": [],
  "daily_7d": [],
  "daily_14d_extended": [],
  "source": "open-meteo.com"
}
```
