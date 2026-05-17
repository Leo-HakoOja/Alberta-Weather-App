# Radar uses a single source — ECCC GeoMet

[ADR 0001](0001-multi-source-side-by-side.md) commits the app to multi-source side-by-side comparison. This ADR carves out a deliberate exception: **radar uses one source (ECCC GeoMet), not several.** RainViewer is retained only as a tile-fetch fallback if GeoMet is unavailable.

## Why

Multi-source side-by-side is valuable when sources can *honestly disagree* — different models, different assumptions, different blends. Forecasts have this property: three models can produce three different tomorrow-high temperatures and the disagreement is meaningful.

Radar does not. Radar shows reflectivity from physical antennas observing actual precipitation right now. Two radar products of the same Alberta scene will look ~identical — they should, because reality is one scene. What differs between radar providers is coverage, refresh rate, and processing quality, not the underlying truth. A side-by-side radar view would show two near-identical animations, manufacturing the appearance of disagreement where there is none, and undermining the legitimacy of the same UI on the forecast surfaces.

We pick **ECCC GeoMet** as the single source because it is the authoritative Canadian radar provider with the best Alberta coverage and refresh cadence. **RainViewer** stays in the codebase as a fallback path only — used when GeoMet is unreachable, never shown alongside it.

## Consequences

- The radar surface gets a single, beautifully-presented animation — and the design language ("data-density artistry") applies fully without comparison-UI noise.
- The "multi-source" identity in marketing copy and the App Store description applies to **forecasts**, not radar. Be honest about this in screenshots and descriptions.
- Forecast sources (ECCC + Open-Meteo + Apple WeatherKit) and radar source (ECCC GeoMet) are independent decisions — changing one does not imply changing the other.
- If a future radar source genuinely differs from GeoMet in a way users would benefit from seeing (e.g., a dual-pol product, hail tracking, satellite-augmented radar), this ADR can be superseded.
