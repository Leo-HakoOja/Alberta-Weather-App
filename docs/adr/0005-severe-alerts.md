# Severe weather alerts — posture, delivery, and entitlement

Alberta Weather treats severe-weather alerts as a life-safety feature, not a polish feature. This ADR records the three load-bearing choices.

## Authority posture: passive

The app displays ECCC severe-weather alerts **verbatim** — wording, severity, expiry, geographic polygon — without paraphrasing or condensing the substantive text. We control layout, typography, severity color, and surface placement; we do not edit ECCC's content. The moment we paraphrase a tornado warning we take on interpretive liability for a life-safety message, and the aesthetic upside of rewording it is small relative to that cost.

## Push delivery: saved locations

Severe-alert pushes fire for **any Saved Location** the user has pinned, not just their current GPS location. The "is mom OK?" use case is a defining Alberta weather scenario — most Albertans have at least one location they care about besides their own (parents in a small town, cabin near Slave Lake, kids at the cousin's farm). Apple Weather's current-location-only model fails this case; we make it a first-class feature. This is also where the descriptive "Alberta Weather" name (see [ADR 0003](0003-product-name-alberta-weather.md)) earns its keep — multi-location severe alerts for Albertans is genuinely better than what's bundled.

## iOS Critical Alerts entitlement: apply for it

We apply for Apple's **Critical Alerts** entitlement, which allows pushes to override Do Not Disturb / Focus modes. ECCC's WeatherCAN has it, Apple Weather has it; without it, a 3 AM tornado push gets silently suppressed and creates false reassurance — the exact failure mode the feature exists to prevent. The bar is high; Apple may decline. If they do, ship without the entitlement and document that fact honestly in the App Store description rather than hiding the limitation.

## Consequences

- The backend must poll ECCC's alert feeds reliably and tag alerts to Saved Locations using ECCC's polygon geometry. This is real engineering — not "ship a string."
- Push delivery latency from ECCC issuance to user device is now a measurable correctness criterion, not a UX detail.
- If Apple grants Critical Alerts, our justification commits us to using it *only* for severe-weather pushes — not for promotional or non-safety messages. Apple revokes the entitlement for misuse.
- "Passive" posture means we can't gracefully shorten very long ECCC alert texts. The layout has to handle them.
