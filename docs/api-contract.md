# API Contract (v1.2)

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
    },
    {
      "source_id": "apple-weatherkit",
      "source_name": "Apple Weather",
      "attribution_url": "https://weatherkit.apple.com/attribution/en-CA",
      "fetched_at": "...",
      "current": {},
      "hourly_next_24h": [],
      "daily_7d": [],
      "error": null
    }
  ],
  "alerts": [],
  "schema_version": "1.2.0",
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
- The ECCC entry can also report that error on a cold start: the Alberta site
  lookup has a 15 s timeout, and a request that wakes a stopped fly.io machine
  can exceed it. Warm requests resolve normally.
- WeatherKit (ADR 0009) reports humidity and precipitation chance as 0 to 1
  fractions upstream; the backend converts them to percent so all three sources
  compare directly.

### Daily headline (`daily_7d`, `daily_14d_extended`)

`weather_code` / `weather` on each day is the day's representative condition:
the most common condition during daylight hours, with precipitation taking the
headline once it covers 3 or more daylight hours. It is **not** Open-Meteo's
daily `weather_code`, which is documented as the single most severe hour of all
24 and made clear days read as Overcast. That upstream value is still returned
as `weather_code_most_severe`.

### Alerts (`alerts`, since 1.2.0)

Active ECCC severe-weather alerts whose polygon contains the requested point,
warnings first. Passive posture per [ADR 0005](adr/0005-severe-alerts.md): `name`,
`text`, `risk_colour`, `region` and the timestamps are ECCC's own values, never
reworded or truncated. An empty list is the normal case. A failed alert fetch
also yields an empty list rather than failing the whole response.
