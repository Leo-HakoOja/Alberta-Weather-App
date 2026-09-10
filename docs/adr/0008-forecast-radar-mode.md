# Radar migrates to ECCC GeoMet and gains a forecast mode

> **Status:** GeoMet observed migration is **built** (2026-09-10): `RADAR_1KM_RRAI`
> primary, RainViewer fallback, attribution shown, exact-match timestamps pinned by
> `test/radar_test.dart`. Forecast mode is **deferred to v1.1** (operator,
> 2026-09-10). See "Cold read" finding 9.

Radar becomes a two-mode surface backed by one **Weather Source**: **Observed** (what fell, last ~3 h) and **Forecast** (what is coming, next 48 h). Both come from ECCC GeoMet. RainViewer drops to the fallback role [ADR 0004](0004-radar-single-source.md) always intended for it.

## The gap this closes

[ADR 0004](0004-radar-single-source.md) decided radar uses ECCC GeoMet as the single source, with RainViewer "retained only as a tile-fetch fallback if GeoMet is unavailable." [ADR 0006](0006-v1-scope-cut.md) lists "ECCC GeoMet radar (RainViewer wired as fallback, not primary)" as v1 scope.

The shipped app does the opposite. RainViewer is the only radar source in `main.dart`, and GeoMet has never been integrated. The decision was recorded and then not built, so the record and the binary disagree. This ADR does not supersede 0004. It implements it, and extends it with the forecast half that GeoMet makes available.

## Why forecast mode is a new surface, not a longer loop

RainViewer already contributes a nowcast (~30 min, flagged `forecast: true` on `_RadarFrame`, badged FORECAST in the viewer). That is a tail on the observed loop, and it is the right shape for 30 minutes.

Forecast mode is a different thing and must not be modelled as a longer tail:

- **Different physics.** Observed radar is measured reflectivity. Forecast precipitation is model output from HRDPS. Presenting them on one continuous scrubber implies a confidence in hour 40 that the app has not earned.
- **Different cadence.** Observed runs at 6-minute steps. Forecast runs at 1-hour steps. One slider cannot serve both without either 480 phantom steps or a discontinuity mid-drag.
- **Different provenance, not different units.** With `_RT` both modes are a precipitation rate in mm/h, so the legend is shared. What differs is that one is measured and one is modelled, and only the mode split communicates that.

Two modes, one toggle, separate timelines each.

## Sources, verified 2026-09-09

Both endpoints were queried live before writing this, not taken from documentation.

### Observed: `RADAR_1KM_RRAI`

- Radar precipitation rate for rain, mm/h
- 1 km resolution, `PT6M` steps, ~3 h rolling window
- Beats RainViewer on both counts: 1 km vs coarser tiles, 6-minute vs 10-minute cadence

### Forecast: `HRDPS.CONTINENTAL_RT`, not `HRDPS.CONTINENTAL_PR`

- HRDPS 2.5 km **instantaneous precipitation rate**, kg/(m^2 s), rendered mm/h
- `PT1H` steps, 48 h ahead (observed extent `2026-09-09T13:00Z/2026-09-11T12:00Z`)
- Style `PRECIPPRTMMH`
- Refreshes with the HRDPS run cycle

**This corrects the first draft of this ADR, which specified `HRDPS.CONTINENTAL_PR`.**
That layer is *run-total accumulation*, and animating it is wrong. Measured coverage
of the Alberta frame across one run:

| Valid time | `_PR` accumulation | `_RT` rate |
|---|---|---|
| +5 h  | 1%  | 2%  |
| +11 h | 4%  | 11% |
| +14 h | 15% | 24% |
| +20 h | 41% | 23% |
| +26 h | 55% | 27% |
| +38 h | 86% | 39% |
| +48 h | 90% | 31% |

`_PR` climbs monotonically to 90% because accumulation never decreases. Played as a
loop it is a bathtub filling, and it ends with the province solid colour whether or
not it is raining at hour 48. `_RT` rises and falls as systems cross, which is what a
radar loop must do and what the user is actually asking to see. Rate also matches
observed radar's units (mm/h), which removes the unit change between modes that the
first draft had to apologise for.

Both serve `EPSG:3857` and `image/png` with a WMS `time` dimension, which is what `flutter_map`'s WMS tile support needs. No backend work required, consistent with the resource strategy in [radar-data-options.md](../radar-data-options.md).

### Style, and why the default is unusable

The default style is unusable as an overlay. Alpha comes back binary (no partial transparency at all) and only 33% of the Alberta frame is transparent, so trace accumulation paints an opaque pale wash over two thirds of the province and buries the dark basemap.

Measured across the candidate styles on the same frame:

| Style | Transparent | Opaque |
|---|---|---|
| default | 33% | 66% |
| `PRECIPMM` | 33% | 66% |
| `PRECIPMM-LINEAR` | 33% | 66% |
| **`Precip-Accum_0to40mm_Dis`** | **59%** | **40%** |

The lesson carried over to `_RT`: use the discrete banded style (`PRECIPPRTMMH`), which
clips trace values to fully transparent and renders the rest as intensity bands.
Verified visually: it produces discrete precipitation cells with real gaps, not a wash.

Alpha is binary at every style GeoMet offers, so the server will not provide partial
transparency. **Client-side opacity is not a free fix.** In flutter_map 7.0.2,
`TileDisplay.fadeIn` (which `_RadarViewerSheet` uses for its 500 ms cross-dissolve)
documents that opacity is not supported; only `TileDisplay.instantaneous` accepts it,
and it applies per tile, which shows seams. Softening the layer therefore means either
losing the cross-dissolve or wrapping the map child in an `Opacity` widget. Do not
plan on a one-line `opacity:` parameter.

## Build spec

**Mode toggle.** Segmented control in the `_RadarViewerSheet` header, Observed / Forecast, Observed default. The hero card cutout stays Observed only. It is a glanceable "what is happening now" and a forecast frame there would need a timestamp to be honest, which the cutout has no room for.

**Timeline model.** This is more work than "generalise `_RadarTimeline`" implies, and the
first draft undersold it:

- The URL is hardcoded in `_RadarFrame.tileUrlTemplate()`, not in `_RadarTimeline`. The
  frame, not the timeline, is what has to become source-aware.
- `_RadarFrame.unixTime` is `int` seconds. WMS needs an exact ISO 8601 string that
  matches the server's extent, so frames need the formatted string, not a conversion at
  call time.
- In flutter_map 7.0.2, `WMSTileLayerOptions.otherParameters` is folded into
  `_encodedBaseUrl` in the constructor. Per-frame `time` therefore requires a *new*
  options object each frame; `didUpdateWidget` diffs the encoded URL and calls
  `reloadImages`. This works, but it means the options object cannot be hoisted or
  memoised across frames.
- `_RadarViewerSheetState` hooks `widget.timelineFuture` once in `initState`, and
  `_loopFrameCount` is written in `build()` and read by the timer. Swapping a 13-frame
  timeline for a 48-frame one mid-playback races that field. The mode switch has to stop
  the timer, reset `_frameIndex`, and re-arm, not just hand over a new future.
- `_RadarFrame.forecast` stays for the RainViewer nowcast tail and does not get
  overloaded to mean "GeoMet forecast."

**Scrubber at 48 steps.** The current slider gives one division per frame, which is right at 13 frames and unusable at 48 on a phone. Forecast mode gets day-boundary tick labels and snaps to 3-hour steps on drag, with playback still stepping hourly. Play speed drops from 800 ms to ~400 ms per frame so a 48-frame loop runs ~19 s instead of 38 s.

**Timestamp is mandatory in forecast mode.** Observed mode shows a clock time. Forecast mode shows day plus hour ("Thu 14:00"), because hour 40 of a 48-hour loop is not self-evidently tomorrow.

**Caching and tile cost.** GeoMet frame lists come from `GetCapabilities`, ~14 to 21 KB of
XML per layer. Parse the `time` dimension extent (`start/end/period` ISO 8601 interval)
and expand it locally rather than requesting a frame list per open.

The XML is the cheap part. The real cost is tiles, and the first draft ignored it:

- RainViewer serves pre-rendered static CDN PNGs. GeoMet renders every `GetMap` on
  demand. These are not comparable per-request costs.
- Prefetch the loop before playing rather than fetching during playback, and hold the
  play button disabled until it is warm. Do not drop the frame interval to 400 ms as
  the first draft proposed: that doubles request rate against the slower source. Keep
  800 ms and shorten the horizon instead if the loop feels long.
- If a render overruns the frame interval the timer advances anyway, so the timestamp
  label races ahead of the pixels. Drive frame advance off image-ready, not off a bare
  `Timer.periodic`. The existing `_startPlaying` does exactly the bare-timer thing.
- Flutter's default `ImageCache` holds 1000 images. A 48-frame loop at full viewport
  will evict, so frames re-fetch on the second pass through the loop. Size the horizon
  with this in mind.
- Check ECCC fair-use before shipping. An always-on animated loop against a
  render-on-demand government service is a different traffic profile from a static CDN.

**Run rollover.** HRDPS runs 4x daily at 00/06/12/18Z, so caching the extent for "1 h"
is wrong. When a run rolls, early frames of the cached extent stop existing server-side
and flutter_map renders error tiles with no error surfaced to the user, who just sees
blanks. Re-read the extent on mode entry and on app resume, and invalidate on rollover
rather than on a fixed timer. Also specify GeoMet failing *mid-loop* while already in
forecast mode, which the first draft left undefined.

**Fallback.** If GeoMet fails, Observed falls back to the existing RainViewer path, matching ADR 0004. Forecast mode has no fallback and is hidden when GeoMet is unreachable, since RainViewer's 30-minute nowcast is not a substitute for 48 hours.

**Attribution.** ECCC requires attribution on GeoMet data. It goes in the radar sheet, not the portfolio footer, which is a separate commercial element under **Ad-Free**.

## Consequences

- The "ECCC GeoMet radar" claim in [ADR 0006](0006-v1-scope-cut.md)'s v1 list becomes true rather than aspirational.
- Radar gains a genuinely forward-looking surface. This is new capability, not feature sprawl: radar is already In under [ADR 0002](0002-feature-restraint-scope.md), and forecast radar is not on the Out list.
- Observed radar improves as a side effect (1 km / 6 min vs RainViewer).
- RainViewer stays in the codebase. It does not get deleted, it gets demoted.
- The 48-hour horizon is a model, and the app must not let its presentation imply observed-radar confidence. The mode split is what carries that honesty.

## Cold read, 2026-09-09

A session that did not write this spec reviewed it per root CLAUDE.md section 7. Findings
and disposition:

**ACCEPTED, and the spec above is corrected.**

1. *`HRDPS.CONTINENTAL_PR` is run-total accumulation and animating it is a bathtub
   filling.* Correct and fatal. Verified empirically (coverage 1% to 90% monotonic).
   Layer changed to `HRDPS.CONTINENTAL_RT`. This finding alone justified the cold read.
2. *Client-side opacity conflicts with the existing `TileDisplay.fadeIn` cross-dissolve.*
   Correct. Verified in flutter_map 7.0.2 source: `fadeIn`'s own doc comment says opacity
   is not supported. Style section corrected.
3. *Tile cost is unbudgeted, and 400 ms doubles request rate against a render-on-demand
   source.* Correct. The 800 ms interval is retained and prefetch is now specified.
4. *Bare `Timer.periodic` lets the label race the pixels.* Correct, and it is a live
   flaw in `_startPlaying` today, not only in the new work.
5. *Run rollover at 00/06/12/18Z invalidates the "cache for 1 h" rule and fails silently.*
   Correct. Rollover handling now specified.
6. *"Generalise `_RadarTimeline`" understates the work; the URL lives on `_RadarFrame`,
   `unixTime` is the wrong type for WMS, and the mode swap races `_loopFrameCount`.*
   Correct on every point. Timeline section rewritten.
7. *`otherParameters` folds into `_encodedBaseUrl` at construction.* Verified. Noted as a
   constraint rather than a blocker: per-frame `time` does work.

**REJECTED.**

8. *Cut the 48 h horizon question as moot.* Rejected. It is not moot, it is now the main
   sizing lever. `ImageCache`'s 1000-image ceiling and prefetch cost both scale with the
   horizon, so choosing 24 h vs 48 h is a real decision, not a cosmetic one.

**OPERATOR'S CALL, not resolved here.**

9. *Cut forecast mode from v1 entirely; ship the GeoMet observed migration alone.* This
   is the review's headline recommendation and it is well argued: [ADR 0006](0006-v1-scope-cut.md)
   anchors the pre-launch roadmap, the v1 list still owes 8 hero states and WeatherKit
   and alerts, and [ADR 0002](0002-feature-restraint-scope.md)'s real test is "would this
   reduce the polish budget for features we already have," which this spec answered with
   "not on the Out list" instead. That was the weaker argument and the reviewer was right
   to name it.

   The split it proposes is clean, and worth stating plainly: the **GeoMet observed
   migration is unambiguously v1** (0006 already lists it, and it closes a
   record-vs-binary gap while improving observed radar to 1 km / 6 min). The **forecast
   mode is the contested half.**

   **Decided by the operator 2026-09-10: finish v1 first.** Since [ADR 0006](0006-v1-scope-cut.md)
   does not list forecast mode, it is out of v1 and moves to v1.1. The GeoMet observed
   migration proceeds as v1 work. The forecast half of this ADR is therefore **specified
   but not scheduled**: keep it here so the layer research and the `_RT` correction are not
   re-derived later, and build it after launch.

## Still open

1. 24 h vs 48 h horizon, if forecast mode is approved (see finding 8).
2. Does the hero card cutout stay Observed-only? The spec says yes; unchallenged by the
   review, so it stands unless the operator disagrees.
