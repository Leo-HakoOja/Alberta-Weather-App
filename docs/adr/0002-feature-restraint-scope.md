# Feature scope — what we ship and what we deliberately don't

The product budget is reallocated *from* feature breadth *to* **Premium UI** polish. This ADR records the explicit lines so feature creep has somewhere to bounce off of.

## In

- Current conditions, hourly, 7-day, 14-day forecasts
- Radar (animated, full-screen, multi-source — see ADR 0001)
- Multi-source forecast comparison (see ADR 0001)
- Severe weather alerts — *non-negotiable* in Alberta; tornadoes and blizzards are life-safety
- Push notifications for severe alerts only
- Dark mode
- Per-location settings (units, default view)
- Home-screen widgets (iOS + Android) — they *are* a Premium UI showcase, not a feature add
- iOS lock-screen widgets — same logic
- Background app refresh — battery cost is the price of being a real weather app
- AQI shown as one chip in the metrics row (not as a feature surface)

## Out — deliberately

These would each be reasonable in another weather app. We are not building them, because each one costs polish budget we'd rather spend elsewhere.

- AQI / pollen / UV as standalone feature surfaces (AQI lives only as a metrics chip)
- Lifestyle indices (hike score, golf weather, garden index, runner's report, etc.)
- Social sharing / "share my forecast"
- News / articles / climate explainers
- Photo of the day / community photos
- Multiple themes — the Alberta brand *is* the theme
- In-app tipping, donations, "buy me a coffee" — the portfolio footer is the only commercial element
- Account system / cloud sync — locations stored locally only
- Localization beyond English — Albertan audience, English-Canada is sufficient
- Apple Watch complication — narrow audience, real cost; revisit post-v1

## Why a hard list

Without an explicit Out list, every feature is implicitly "maybe someday." That kills **Feature Restraint** by accretion. The Out list is the dependency that makes **Premium UI** affordable.
