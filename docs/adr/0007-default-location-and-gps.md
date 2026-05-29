# Edmonton default, explicit base, and a one-shot location button

The app opens on **Edmonton** (the provincial capital) when nothing else is stored. There are no pre-seeded foreign **Saved Locations** — the previous Vancouver chip is removed. An Albertan can pin a **base** Location (the one the app opens to) by tapping a star in the location picker, and can tap a location button to switch to their current spot via device GPS.

## Why

Vancouver was a stale artifact from before the all-Alberta scope was locked ([CONTEXT.md], [ADR 0006]) — it is not a **Location** and contradicted the product's Alberta boundary. With it gone, the app needs a sensible first-run **Location**. Edmonton is the unambiguous choice: it is the capital, it is inside **Alberta**, and it requires no permission prompt on launch.

Rather than auto-prompting for location on first launch (interrupts before any value is shown) or silently following the device every launch (surprising, and the app is province-scoped), we let the Albertan decide:

- **Edmonton on first launch** — always works, no permission gate.
- **Explicit "Set as base"** — opening Location is a deliberate one-time choice the operator makes, not an implicit "last viewed." This matches how testers think about a home location and avoids the app drifting its default as they browse.
- **Location button (on tap)** — permission is requested only when the Albertan asks for it, and the result is constrained to the Alberta bounding box. Outside the province, the app declines and explains why.

## Consequences

- Two new runtime dependencies, approved per the factory install protocol: **`geolocator`** (device GPS for the location button; needs iOS `NSLocationWhenInUseUsageDescription` and Android `ACCESS_FINE/COARSE_LOCATION`) and **`shared_preferences`** (persists the base **Location** across restarts).
- The base **Location** is stored as JSON under a single prefs key and restored on launch; if absent, Edmonton stands.
- The GPS result is labelled "Current location" at the exact device coordinates rather than reverse-geocoded to a named place or county. Exact coordinates serve **Accuracy**; a friendlier nearest-place name is a later refinement, not shipped here.
- Myrnam remains a pre-saved chip (one tap away) but no longer auto-loads.
