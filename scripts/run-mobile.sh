#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

API_URL="${WEATHER_API_URL:-http://localhost:8000/v1/weather/myrnam}"
FLUTTER_DEVICE="${FLUTTER_DEVICE:-linux}"

cd "$ROOT_DIR/mobile/flutter_app"
flutter run -d "$FLUTTER_DEVICE" --dart-define=WEATHER_API_URL="$API_URL"
