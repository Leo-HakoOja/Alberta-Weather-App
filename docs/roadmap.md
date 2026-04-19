# Weather App Roadmap

## Phase 1 (Done)
- Terminal weather output for Myrnam, Alberta
- Current + next 24 hours + 7-day + days 8-14 forecast

## Phase 2 (In Progress)
- ✅ Backend API scaffold in `backend/app/`
- ✅ Endpoints: `/health`, `/v1/weather/myrnam`, `/v1/weather?lat=...&lon=...`
- ✅ Added in-memory + persistent disk caching for forecast responses (5-minute TTL)
- ✅ Added stable response metadata (`schema_version`, `generated_at`)
- ✅ Added strict response validation with Pydantic `WeatherResponse`
- ✅ Added backend contract tests in `tests/test_backend_contract.py`

## Phase 3 (In Progress)
- ✅ Mobile scaffold + API contract files in `mobile/`
- ✅ Real Flutter app initialized in `mobile/flutter_app/`
- ✅ Backend-connected app shell implemented
- ✅ Reusable weather UI components implemented (hero, metrics, hourly, daily rows)
- ✅ Saved location chips added (Myrnam, Edmonton, Calgary, Vancouver)
- 🔜 iOS + Android UI polish + interactions using clean design system

## UI Design Timing
- UI design starts now (wireframes + design tokens before heavy feature build)
- Implement core reusable components first, then polish animations/themes

## Build Constraints
- iOS final build/signing must happen on macOS/Xcode
- Android builds can happen on Linux/macOS/CI
