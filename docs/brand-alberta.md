# Alberta-First Brand Direction

## Brand Promise
A weather app that feels unmistakably Albertan: practical, resilient, and visually rooted in the province.

## Identity Goals
- Feel local at first glance (not generic global weather UI)
- Keep a calm, premium, ad-free experience
- Balance data density with visual warmth

## Visual Language

### Core palette (crest/flag inspired)
- Alberta Blue: `#0B3A82`
- Prairie Sky: `#2F6FB2`
- Alberta Gold accent: `#F2C94C`
- Prairie Cream surface: `#FFF9EC`
- Snow/Cloud neutral: `#F5F8FF`

### Motif system (subtle, layered)
Use these as low-opacity background motifs in hero/cards/transitions:
- Foothill horizon lines
- Wheat-stem or grain arcs
- River contour paths
- Northern-light wave curves

### Motion language
- Calm, slow, ambient motion only
- Condition-driven accents: snow drift, rain shimmer, cloud glide
- No aggressive animation loops

## Copy Tone
- Clear, practical, confident
- Friendly and local (e.g., “Built for Alberta days”)
- Avoid alarmist language unless severe warning context exists

## Feature Personality
- Alberta cities/regions are first-class locations
- Timezone and seasonality optimized for Alberta by default
- Weather summaries should prioritize immediate local planning utility

## Legal / Trademark Guardrail
- Use **Alberta-inspired** design and color language
- Do not embed official crest assets unless usage rights are confirmed

## Implementation Priority
1. Tokenized Alberta palette in Flutter theme
2. Alberta-inspired hero styles + headline copy
3. Reusable motif/background assets (SVG/PNG)
4. Optional city-specific visual signatures

## Design Language

The app is a **warm place to inhabit**, not a system tool. Apple-grade craft (motion physics, typography care, pixel-level attention) is the floor; Apple's cool, neutral aesthetic is explicitly rejected.

### Primary mode: cinematic
- Full-bleed atmospheric backgrounds shift with condition × time-of-day (clear morning, overcast afternoon, snowy dusk, chinook evening, aurora night, etc.) — a generative system, not artisanal per-screen artwork
- Ambient motion only — drifting clouds, falling snow, aurora curves, rain shimmer, light gradient shifts as the sun moves
- No system chrome where avoidable — let the sky be the chrome
- Warmth over precision in color grading: prairie cream and Alberta gold dominate the warm surfaces; Alberta blue carries the cool counterpoint

### Secondary mode: data-density artistry
- Reserved for the multi-source comparison surfaces (see [ADR 0001](adr/0001-multi-source-side-by-side.md))
- Beautifully restrained data visualization in the Tufte tradition — sparklines, agreement bands, gentle disagreement highlights
- This mode is *quieter* than the cinematic hero — the hero is the place, the comparison view is the instrument panel

### What we don't do
- **No Apple-Store sterility.** Generous whitespace is fine; sterile grids and cool neutrals are not.
- **No custom illustration-per-condition.** Generative motion + photographic atmosphere covers the surface area without an illustrator on retainer.
- **No aggressive animation.** Ambient only — nothing that pulses, blinks, or competes for attention.
- **No skin-deep polish.** Premium is invisible craft (motion, type, spacing) plus atmospheric expression — not decoration on top of a sloppy app.

### Test for "is this premium enough"
Open the app at 7:00 AM on a January morning. Does it *feel* like a January Alberta morning — not just *say* it's -22°C? If yes, the design language is working. If no, the cinematic layer hasn't earned its place.
