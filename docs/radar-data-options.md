# Radar data sources

Radar policy is set by [ADR 0004](adr/0004-radar-single-source.md) (single source)
and [ADR 0008](adr/0008-forecast-radar-mode.md) (GeoMet migration, forecast mode).

## Primary: ECCC GeoMet (implemented)

WMS at `https://geo.weather.gc.ca/geomet?`

| | Observed (shipped) | Forecast (shipped) |
|---|---|---|
| Layer | `RADAR_1KM_RRAI` | `HRDPS.CONTINENTAL_RT` |
| Quantity | Radar precipitation rate for rain, mm/h | Instantaneous precipitation rate, mm/h |
| Resolution | 1 km composite | 2.5 km model |
| Step | `PT6M` | `PT1H` |
| Window | ~3 h rolling, 31 frames | next 24 h shown (48 h published) |
| Style | `Radar-Rain_Dis-14colors` | `PRECIPPRTMMH` |

Notes that cost time to rediscover:

- **The time dimension is exact-match.** The layer advertises `nearestValue="0"`,
  so a timestamp off by a second, or carrying milliseconds, returns a
  ServiceException XML body instead of a PNG. flutter_map treats that as a failed
  tile and renders nothing, so the failure is silent. Frame times are generated
  from the advertised `start/end/period` extent, never from the device clock.
  Pinned by `test/radar_test.dart`.
- **Prefer the discrete (`_Dis`) styles.** Same coverage as the continuous ramps
  at roughly a third of the bytes (~7 KB vs ~23 KB per tile), which matters across
  a 31-frame loop on cellular.
- **No zoom cap needed.** GeoMet renders each tile on request at whatever zoom is
  asked for, unlike RainViewer.
- **Do not use `HRDPS.CONTINENTAL_PR` for animation.** It is run-total
  accumulation, so a loop of it only ever fills. See ADR 0008.
- GeoMet renders on demand rather than serving a static CDN, so tile traffic is a
  real cost. Check ECCC fair-use before raising the frame rate.

## Fallback: RainViewer

`https://api.rainviewer.com/public/weather-maps.json`

Used only when GeoMet is unreachable, per ADR 0004. Tiles stop at z7, so its layer
keeps `maxNativeZoom: 7` and upscales above that. Its ~30 min nowcast is gone: the
feed returned zero nowcast frames as of 2026-09-10, so the only predictive radar is
the HRDPS forecast mode. The radar sheet says which source is live.

## Base map: Natural Resources Canada (since 2026-09-11)

Canada Base Map (Transportation), Web Mercator, from NRCan's ArcGIS tile service
(`maps-cartes.services.geo.ca/.../BaseMaps/...`, tile order `{z}/{y}/{x}`):

- `CBMT_CBCT_GEOM_3857`: roads, water, borders, no text (JPEG). Drawn under the radar.
- `CBMT_TXT_3857`: English labels only, transparent PNG. Drawn over the radar.

Free with no key under the Open Government Licence - Canada. The licence requires the
statement "Contains information licensed under the Open Government Licence – Canada"
(shown on the radar sheet) and forbids implying government endorsement or using
government logos. Zoom 0 to 23. Covers Canada only: south of the 49th the tiles are
blank, which the dark filter renders as plain background.

The map is light, so the app darkens it with a `ColorFilter.matrix`: greyscale,
invert luminance, dim to 55% (labels: greyscale and invert, not dimmed). A plain
colour invert (flutter_map's `darkModeTileBuilder`) was tried and rejected: it turns
every lake and river orange.

**Why not the alternatives:**

- **CARTO** (the original basemap) started watermarking keyless tiles "API KEY
  REQUIRED" in late August 2026. Its key signup did not work for a Canadian
  operator (only a two-week platform trial was offered).
- **Apple Maps** has no tile feed a third-party renderer like flutter_map can use.
  Switching would mean replacing the map engine, and it would be iOS only.
- **Google Map Tiles API** works with flutter_map but is billed past 100k tiles a
  month, capped at 15k tiles a day, and needs session tokens.
- **Esri's** dark basemap loaded without a key, but Esri's current docs require one,
  so that endpoint could close the same way CARTO's did.

## Resource strategy

- One static newest frame in the hero preview, painted instantly (no fade).
- Full viewer animates by frame index only, no image processing.
- Loop capped at 40 frames; Flutter's default ImageCache holds 1000 images and a
  full-viewport loop evicts well before that.
- Reuse fetched extent metadata; do not re-request capabilities per frame.
