# Multi-source forecasts shown side-by-side

The app shows forecasts from multiple **Weather Sources** simultaneously rather than blending them into a single number or picking one curated winner. When sources agree, the user gains confidence; when they disagree, the user sees the uncertainty.

## Why

The product goal is **Accuracy**, and the user's intuition is "the more sources, the more accurate." There are three honest ways to honour that:

- **Curated single-source per variable** — developer picks the best provider per data point. User sees one number. Easy to ship, but the accuracy claim is unverifiable and indistinguishable from existing apps.
- **Measured ensemble** — backend stores historical forecasts, fetches station observations, learns source weights, serves a blended number. Statistically defensible but a multi-year solo research project, not a weather app for friends.
- **Side-by-side / consensus UI** — user sees N sources at once and judges agreement themselves. Shippable solo. Honest — never claims accuracy it can't prove. Turns the **Premium UI** budget into a real product surface (showing multi-source data well is genuine design work). Preserves a path to measured ensemble later once historical data has accrued.

We pick side-by-side because it's the only option that is *both* honest about uncertainty *and* affordable for a solo dev shipping to a few hundred users. It also makes the **Feature Restraint** trade-off coherent: we're not shipping AQI/pollen/lifestyle-indices, we're shipping the *one* hard UI problem — multi-source comparison — done well.

## Consequences

- Backend fans out to multiple providers and returns all of their answers, not a blended winner.
- Cache and rate-limit budgets are N× single-source.
- The hero UI must work cleanly with both agreement (collapse to one number) and disagreement (show all). This is the central design challenge.
- "Most accurate" in marketing copy means "most honestly informed" — not "lowest error against observations." If we ever want to make the harder claim, we'll need to migrate to a measured ensemble (option b) and supersede this ADR.
