# Radar data sources

Radar policy is set by [ADR 0004](adr/0004-radar-single-source.md) (single source)
and [ADR 0008](adr/0008-forecast-radar-mode.md) (GeoMet migration, forecast mode).

## Primary: ECCC GeoMet (implemented)

WMS at `https://geo.weather.gc.ca/geomet?`

| | Observed (shipped) | Forecast (deferred to v1.1) |
|---|---|---|
| Layer | `RADAR_1KM_RRAI` | `HRDPS.CONTINENTAL_RT` |
| Quantity | Radar precipitation rate for rain, mm/h | Instantaneous precipitation rate, mm/h |
| Resolution | 1 km composite | 2.5 km model |
| Step | `PT6M` | `PT1H` |
| Window | ~3 h rolling, 31 frames | 48 h ahead |
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
keeps `maxNativeZoom: 7` and upscales above that. Its ~30 min nowcast tail is kept
and badged FORECAST. The radar sheet says which source is live.

## Base map

CARTO dark tiles, split so labels paint above the radar:
`dark_nolabels` under, `dark_only_labels` over. The hero preview uses `dark_all`.

## Resource strategy

- One static newest frame in the hero preview, painted instantly (no fade).
- Full viewer animates by frame index only, no image processing.
- Loop capped at 40 frames; Flutter's default ImageCache holds 1000 images and a
  full-viewport loop evicts well before that.
- Reuse fetched extent metadata; do not re-request capabilities per frame.
