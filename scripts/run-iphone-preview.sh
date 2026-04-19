#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8000}"
WEB_HOST="${WEB_HOST:-0.0.0.0}"
WEB_PORT="${WEB_PORT:-7357}"

LAN_IP="${LAN_IP:-$(hostname -I 2>/dev/null | awk '{print $1}') }"
LAN_IP="${LAN_IP// /}"

if [[ -z "$LAN_IP" ]]; then
  echo "[weather-app] Could not auto-detect LAN IP."
  echo "[weather-app] Re-run with: LAN_IP=192.168.x.x bash scripts/run-iphone-preview.sh"
  exit 1
fi

WEATHER_API_URL="${WEATHER_API_URL:-http://$LAN_IP:$API_PORT/v1/weather/myrnam}"

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

for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! curl -fsS "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1; then
  echo "[weather-app] Backend failed to start. See /tmp/weather-app-api.log"
  exit 1
fi

echo "[weather-app] Backend is up."
echo "[weather-app] Building Flutter web release (this can take ~10-30s) ..."

cd "$ROOT_DIR/mobile/flutter_app"
flutter build web --release --dart-define=WEATHER_API_URL="$WEATHER_API_URL"

echo
cat <<EOF
✅ iPhone preview is ready.

Open this URL on your iPhone (same Wi-Fi):
  http://$LAN_IP:$WEB_PORT

Tips:
- If Safari shows a stale page, use: http://$LAN_IP:$WEB_PORT/?v=$(date +%s)
- Keep this terminal open while previewing.
- Press Ctrl+C to stop backend + web server.
EOF

echo "[weather-app] Serving build/web at http://$WEB_HOST:$WEB_PORT ..."
cd "$ROOT_DIR/mobile/flutter_app/build/web"
python3 -m http.server "$WEB_PORT" --bind "$WEB_HOST"
