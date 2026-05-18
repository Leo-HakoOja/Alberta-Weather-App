# Radar data options (free / low-cost)

## Chosen for implementation now

### RainViewer (current app integration)

- URL: `https://api.rainviewer.com/public/weather-maps.json`
- Use: fetch frame list, then render radar tiles on map.
- Why: no backend processing required, very fast to ship, light on app resources.

### OpenStreetMap tiles (base map)

- URL template: `https://tile.openstreetmap.org/{z}/{x}/{y}.png`
- Use: simple geographic context under radar layer.

## Next source to add

### Environment and Climate Change Canada GeoMet

- Use: official Canadian radar layers, especially valuable for Alberta coverage.
- Suggested approach: add as selectable layer/source in radar viewer.
- Note: verify endpoint/rate/attribution details before production rollout.

## Resource strategy

- Keep one active radar frame in mini-preview.
- In full viewer, animate using frame index only (no custom image processing).
- Reuse fetched frame metadata and avoid frequent refresh.
- Default zoom to local region to reduce tile churn.
