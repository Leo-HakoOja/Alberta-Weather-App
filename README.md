# Weather App

Cross-platform weather product (iPhone + Android) with a clean, ad-free UI.

## Project Structure

- `apps/cli/` – terminal weather app (Phase 1)
- `backend/` – API service for mobile clients
- `mobile/` – mobile app code (Flutter initialized)
- `scripts/` – helper launch scripts
- `docs/` – planning, architecture, milestones
- `tests/` – automated tests
- `docs/ios-release-checklist.md` – iOS/TestFlight/App Store launch checklist

## Current Status

- ✅ Phase 1 terminal app is implemented in `apps/cli/main.py`
- ✅ Desktop launcher is available as `~/Desktop/Myrnam-Weather.desktop`
- ✅ Backend API scaffold is implemented in `backend/app/`
- ✅ Backend in-memory + disk caching added
- ✅ Backend versioned + strictly validated response schema added
- ✅ Backend API contract tests added in `tests/test_backend_contract.py`
- ✅ Flutter app initialized in `mobile/flutter_app/` and connected to API
- 🔜 Next: full UI design system + feature-complete screens

## Run Weather App (Single Entry Command)

Use one command with a mode:

```bash
bash ~/weather-app/scripts/run-weather.sh [mode]
```

Modes:

- `full` (default): backend + Flutter desktop app
- `preview`: backend + Flutter web preview (best for iPhone/Android-sized simulation)
- `iphone`: one-command iPhone preview (backend + release web build + LAN web server)
- `cli`: terminal weather app only
- `api`: backend API only

## iOS Release

- Checklist: `docs/ios-release-checklist.md`
- Build helper (run on macOS): `scripts/build-ios-release.sh`

Examples:

```bash
bash ~/weather-app/scripts/run-weather.sh
bash ~/weather-app/scripts/run-weather.sh preview
bash ~/weather-app/scripts/run-weather.sh iphone
bash ~/weather-app/scripts/run-weather.sh cli
bash ~/weather-app/scripts/run-weather.sh api
```

If running API mode for the first time:

```bash
cd ~/weather-app
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
```

Then open:

- API docs: `http://localhost:8000/docs`
- Myrnam endpoint: `http://localhost:8000/v1/weather/myrnam`
