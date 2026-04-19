# Mobile App (Flutter) — Scaffold

Target platforms:
- iOS
- Android

## Status
- ✅ Backend API ready for consumption (`/v1/weather/myrnam`)
- ✅ Flutter SDK installed locally (`~/tools/flutter`)
- ✅ Real Flutter project created at `mobile/flutter_app/`
- ✅ App shell wired to backend endpoint
- ✅ Home UI implemented (hero + highlights + hourly + daily)
- ✅ Saved-location chips wired (Myrnam, Edmonton, Calgary, Vancouver)
- ✅ `flutter analyze` and `flutter test` passing

## Planned structure

- `mobile/flutter_app/` — Flutter app source
- `mobile/design/` — UI kit, wireframes, and design decisions
- `mobile/contracts/` — API response samples and client mapping notes

## Run app (development)

```bash
cd ~/weather-app/mobile/flutter_app
flutter pub get
flutter run --dart-define=WEATHER_API_URL=http://localhost:8000/v1/weather/myrnam
```

For Android emulator use:

```bash
flutter run --dart-define=WEATHER_API_URL=http://10.0.2.2:8000/v1/weather/myrnam
```

## One-command phone preview on desktop

From project root:

```bash
bash scripts/run-weather.sh preview
```

Then in Chrome DevTools, toggle device toolbar and pick iPhone/Pixel dimensions.

## API to connect

- Local dev: `http://localhost:8000/v1/weather/myrnam`

> For Android emulator, use `http://10.0.2.2:8000/...` instead of localhost.
