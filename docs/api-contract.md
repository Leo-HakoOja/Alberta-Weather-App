# API Contract (v1.1)

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
  "sources": [
    {
      "source_id": "open-meteo",
      "source_name": "Open-Meteo",
      "attribution_url": "https://open-meteo.com/",
      "fetched_at": "...",
      "current": {},
      "hourly_next_24h": [],
      "daily_7d": [],
      "error": null
    },
    {
      "source_id": "eccc",
      "source_name": "Environment and Climate Change Canada",
      "attribution_url": "...",
      "fetched_at": "...",
      "current": {},
      "hourly_next_24h": [],
      "daily_7d": [],
      "error": null
    }
  ],
  "schema_version": "1.1.0",
  "source": "open-meteo.com"
}
```

### Multi-source notes (`sources`)

Per [ADR 0001](adr/0001-multi-source-side-by-side.md), the backend fans out
to multiple Weather Sources and returns each source's answers under
`sources[]`. The top-level `current`, `hourly_next_24h`, and `daily_7d` remain
the Open-Meteo response and act as the default render.

- Each entry conforms to the same `CurrentConditions` / `HourlyForecastItem` /
  `DailyForecastItem` shapes used at the top level. Fields a source can't
  provide are `null` (e.g. ECCC does not provide UV index per hour).
- On fetch failure, the source's data fields are empty and `error` is set.
- ECCC is currently scoped to Alberta. For locations outside Alberta (or
  where no citypage site is within ~250 km), the ECCC entry returns with
  `error: "No ECCC citypage site near this location"`.
