# UI Plan (Start Now)

Goal: rival premium weather apps with a clean, ad-free UI and a distinct Alberta identity.

## Design principle
- Data-dense but calm
- Zero clutter
- Fast-to-read hierarchy
- Consistent cards, spacing, and typography
- Alberta-inspired colors, motifs, and copy tone throughout

## Initial screen map

1. Home (Current conditions)
   - Big current temp + feels-like
   - Condition summary
   - Wind, humidity, UV quick metrics

2. Hourly (24h)
   - Horizontal/vertical timeline card
   - Temp + precipitation chance + icon

3. Daily
   - 7-day detailed rows
   - 14-day extended compact rows

4. Saved locations
   - Location list + reorder + default city

## Component system (v1)
- `WeatherMetricCard`
- `ForecastRow`
- `HourlyTile`
- `SectionHeader`
- `TemperatureRangeBar`

## Design milestones

### Milestone A (this week)
- Low-fidelity wireframes for Home, Hourly, Daily
- Color + typography tokens
- Basic icon strategy

### Milestone B
- High-fidelity mockups
- Dark mode parity
- Accessibility pass (contrast, dynamic text)

### Milestone C
- Implement UI in Flutter with reusable components
