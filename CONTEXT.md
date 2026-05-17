# Alberta Weather

A free, ad-free weather app whose product goals are:
1. **Most accurate** weather and radar for Alberta — source-agnostic, multi-source.
2. **Premium UI** that exceeds expectations for a free weather app — achieved by *not* shipping the usual feature sprawl and reinvesting the saved budget in polish.

The canonical name is **Alberta Weather** (App Store and Google Play). The repository directory remains `weather-app` and is not renamed. Tagline candidate: *"a certain beauty in Alberta weather."*

Distributed on the Apple App Store and Google Play.

## Language

**Albertan**:
A person living in Alberta. The intended user of this app.
_Avoid_: "Canadian user," "Alberta-native," "local"

**Alberta**:
The geographic boundary of supported weather locations. The app only shows weather for places inside the Alberta provincial border.
_Avoid_: "Canada," "Western Canada," "the region"

**Location**:
A place inside **Alberta** that the app can show weather for.
_Avoid_: "city," "place," "spot"

**Saved Location**:
A **Location** the user has pinned as a chip in the top bar for quick switching.

**Weather Source**:
A forecast or radar data provider — ECCC, Open-Meteo, RainViewer, Apple Weather, etc. Sources are selected on accuracy and coverage for Alberta, not on provenance. The app uses multiple **Weather Sources** simultaneously.
_Avoid_: "weather API," "the provider" (when meaning the forecast feed)

**Accuracy** (as a product goal):
The app's north-star quality. Every product decision is judged against "does this make the forecast or radar more accurate, or more clearly accurate, for an Albertan?" *How* accuracy is delivered (single best source vs. ensemble vs. side-by-side comparison) is an open question — see ADRs.
_Avoid_: "best" (vague), "premium" (implies tier)

**Ad-Free**:
No third-party advertising AND no paywall on weather content. A single attribution footer linking to the developer's portfolio site is permitted and is the app's only commercial element.
_Avoid_: "free tier" (there is no other tier)

**Premium UI**:
The level of visual and motion craft expected of a paid flagship app, deliberately delivered in a free one. The product budget is reallocated *from* feature breadth *to* polish — motion, imagery, typography, transitions. "Premium" here describes **craft, not pricing**.
_Avoid_: "premium tier," "pro features" — there are no tiers and no pro features.

**Feature Restraint**:
The constraint that funds **Premium UI**. Every candidate feature is judged against the question: "would shipping this reduce the polish budget available for the features we already have?" If yes, it doesn't ship.
_Avoid_: "minimalism" (too aesthetic; this is a budget rule, not a style)

## Relationships

- A **Saved Location** is always a **Location**, therefore always inside **Alberta**.
- Every forecast or radar tile shown comes from a **Weather Source**. The app may use several simultaneously.
- **Accuracy** is the rule for choosing between **Weather Sources**.
- **Ad-Free** and **Premium UI** are product-level invariants, not settings — there is no non-ad-free mode and no "lite" mode.
- **Feature Restraint** is the trade-off that makes **Premium UI** affordable on a solo-dev budget.

## Example dialogue

> **Dev:** "A user in Phoenix opens the app — what happens?"
> **Domain expert:** "They can install it, but every **Saved Location** they pick has to be inside **Alberta**. We're not a global weather app — we're an Alberta weather app that anyone is welcome to install."

> **Dev:** "If ECCC and Open-Meteo disagree on tomorrow's high by 4°C, which one do we show?"
> **Domain expert:** "That's the **Accuracy** question — and we haven't decided yet whether the app picks one, averages them, or shows both. That's an ADR-level call, not a glossary call."

## Flagged ambiguities

*(none currently open)*

## Resolved

- **Vancouver as a saved chip** — resolved: the chip is a stale code artifact from before the all-Alberta scope was locked. To be removed from the Flutter app. Vancouver is not a **Location**.
- **How Accuracy is delivered** — resolved by [ADR 0001](docs/adr/0001-multi-source-side-by-side.md): multi-source side-by-side for forecasts, single-source (ECCC GeoMet) for radar per [ADR 0004](docs/adr/0004-radar-single-source.md).
