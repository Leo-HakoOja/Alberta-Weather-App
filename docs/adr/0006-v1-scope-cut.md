# v1 scope cut

The first public App Store / Google Play release of Alberta Weather ships **the central differentiators and the safety baseline**, but explicitly defers widgets, Apple Watch, and the Critical Alerts entitlement to v1.1. The goal is a defensible launch quality bar, not a sprawling first release.

## In v1

- Side-by-side multi-source forecast: ECCC + Open-Meteo + Apple WeatherKit ([ADR 0001](0001-multi-source-side-by-side.md))
- ECCC GeoMet radar (RainViewer wired as fallback, not primary) ([ADR 0004](0004-radar-single-source.md))
- Cinematic UI baseline — minimum 8 hero states (clear / cloudy / rainy / snowy × day / night)
- Saved Alberta **Locations** with place-name search restricted to Alberta
- Severe weather alerts from ECCC, passive posture ([ADR 0005](0005-severe-alerts.md))
- Push notifications for Saved Locations on severe alerts (standard push only — Critical Alerts entitlement filed in parallel but not blocking v1)
- Dark mode
- Per-location settings (units, default view)
- Portfolio attribution footer

## In v1.1 (weeks after launch)

- iOS home-screen widgets + iOS lock-screen widgets
- Android home-screen widgets
- Critical Alerts entitlement integration *if/when Apple approves the application*
- Subtitle / tagline lock-in once the App Store listing has been observed live for a couple of weeks

## Deferred to v2 (someday, defended explicitly)

- Apple Watch complication (still bounded by [ADR 0002](0002-feature-restraint-scope.md)'s OUT list — revisit explicitly, not by accretion)
- Anything from the OUT list that real users repeatedly request. Feature Restraint is *defended at v2*, not *prevented forever*.

## Why this cut

1. **The two non-negotiables ship in v1.** Multi-source forecast (the brand differentiator) and severe alerts (the safety floor) are the only reasons this app earns its name. Cutting either is cutting the product.
2. **Critical Alerts entitlement runs in parallel with v1.** Apple takes weeks. The application doesn't block ship — it arrives sometime after, and gets wired in v1.1.
3. **Widgets are deferred deliberately.** Real engineering, easy to do badly, not on the critical path for "is this a weather app worth opening." Cutting them protects the launch quality bar.
4. **8 hero states is the minimum cinematic surface that *feels* generative.** Below that, the design language collapses into "two backgrounds on rails."
5. **The other v1 cuts considered** — minimum-public-release (no multi-source, abandons differentiation), safety-first-only (no premium UI, doesn't earn the name), everything-at-once (perpetual pre-launch) — each fails differently. (b)+alerts is the only one that ships something worth launching without sliding indefinitely.

## Consequences

- The pre-launch roadmap is anchored. Anything not on the v1 list is on hold by default.
- Premium UI craft applies *within* the v1 surface — not by adding new surfaces. The 8 hero states must each clear the bar.
- The codemagic.yaml pipeline must support iOS submission via the Codemagic-managed Mac runners; Linux-developer-without-Mac is otherwise a hard blocker. ([build-ios-release.sh](../../scripts/build-ios-release.sh) and the iOS checklist already anticipate this.)
- "What ships next?" has a clear answer for every PR conversation between now and launch: "is it on the v1 list?"
