#!/usr/bin/env bash
set -euo pipefail

# Run this on macOS with Xcode + Flutter configured.
# Example:
#   IOS_BUNDLE_ID=com.yourcompany.albertaweather \
#   WEATHER_API_URL=https://api.example.com/v1/weather/myrnam \
#   BUILD_NAME=1.0.0 BUILD_NUMBER=1 \
#   bash ~/weather-app/scripts/build-ios-release.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/mobile/flutter_app"

BUILD_NAME="${BUILD_NAME:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
API_URL="${WEATHER_API_URL:-}"

if [[ -z "$API_URL" ]]; then
	echo "ERROR: Set WEATHER_API_URL to your production endpoint." >&2
	echo "Example: WEATHER_API_URL=https://api.example.com/v1/weather/myrnam" >&2
	exit 1
fi

if [[ "$API_URL" == *"localhost"* || "$API_URL" == *"127.0.0.1"* ]]; then
	echo "ERROR: WEATHER_API_URL points to localhost. Use a public/production URL." >&2
	exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "ERROR: iOS IPA build must run on macOS." >&2
	exit 1
fi

cd "$APP_DIR"

echo "==> Flutter clean"
flutter clean

echo "==> Flutter pub get"
flutter pub get

echo "==> Building IPA (name=$BUILD_NAME, number=$BUILD_NUMBER)"
flutter build ipa --release \
	--dart-define=WEATHER_API_URL="$API_URL" \
	--build-name="$BUILD_NAME" \
	--build-number="$BUILD_NUMBER"

echo "\nDone. Next: upload via Xcode Organizer or Transporter."
