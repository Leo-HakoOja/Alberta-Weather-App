#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-8000}"
WEB_DEVICE="${WEB_DEVICE:-chrome}"
WEB_PORT="${WEB_PORT:-7357}"
WEATHER_API_URL="${WEATHER_API_URL:-http://$API_HOST:$API_PORT/v1/weather/myrnam}"

if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
else
  PYTHON_BIN="python3"
fi

echo "[weather-app] Starting backend at http://$API_HOST:$API_PORT ..."
cd "$ROOT_DIR"
"$PYTHON_BIN" -m uvicorn backend.app.main:app --host "$API_HOST" --port "$API_PORT" --reload > /tmp/weather-app-api.log 2>&1 &
API_PID=$!

cleanup() {
  if kill -0 "$API_PID" >/dev/null 2>&1; then
    echo
    echo "[weather-app] Stopping backend (pid $API_PID)..."
    kill "$API_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

for _ in {1..30}; do
  if curl -fsS "http://$API_HOST:$API_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.3
done

if ! curl -fsS "http://$API_HOST:$API_PORT/health" >/dev/null 2>&1; then
  echo "[weather-app] Backend failed to start. See /tmp/weather-app-api.log"
  exit 1
fi

echo "[weather-app] Backend is up."
echo "[weather-app] Launching Flutter web preview on $WEB_DEVICE ..."
echo
cat <<EOF
Phone preview tips in Chrome:
  1) Press Ctrl+Shift+I (DevTools)
  2) Toggle device toolbar (Ctrl+Shift+M)
  3) Pick iPhone 14 Pro or Pixel 7

URL: http://127.0.0.1:$WEB_PORT
EOF

cd "$ROOT_DIR/mobile/flutter_app"
DEVICES="$(flutter devices 2>/dev/null || true)"
TARGET_DEVICE="$WEB_DEVICE"

if ! grep -q "• $WEB_DEVICE •" <<<"$DEVICES"; then
  echo "[weather-app] Device '$WEB_DEVICE' not available on this machine."
  if grep -q "• linux •" <<<"$DEVICES"; then
    TARGET_DEVICE="linux"
    echo "[weather-app] Falling back to Linux desktop preview."
    echo "[weather-app] Install Chrome/Chromium for phone-sized browser preview mode."
  else
    echo "[weather-app] No compatible Flutter device found."
    exit 1
  fi
fi

if [[ "$TARGET_DEVICE" == "linux" ]]; then
  flutter run -d "$TARGET_DEVICE" --dart-define=WEATHER_API_URL="$WEATHER_API_URL"
else
  flutter run \
    -d "$TARGET_DEVICE" \
    --web-hostname 127.0.0.1 \
    --web-port "$WEB_PORT" \
    --dart-define=WEATHER_API_URL="$WEATHER_API_URL"
fi
