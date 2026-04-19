#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="${1:-full}"

usage() {
  cat <<'EOF'
Usage: bash scripts/run-weather.sh [mode]

Modes:
  full    Start backend + Flutter desktop app (default)
  preview Start backend + Flutter web preview (phone-sized via browser DevTools)
  iphone  One-command iPhone preview (backend + release web build + LAN web server)
  cli     Run terminal weather app only
  api     Run backend API only

Examples:
  bash scripts/run-weather.sh
  bash scripts/run-weather.sh preview
  bash scripts/run-weather.sh iphone
  bash scripts/run-weather.sh cli
  bash scripts/run-weather.sh api
EOF
}

case "$MODE" in
  full|dev|mobile)
    exec bash "$SCRIPT_DIR/run-dev.sh"
    ;;
  preview|phone|web)
    exec bash "$SCRIPT_DIR/run-phone-preview.sh"
    ;;
  iphone|ios|release-web)
    exec bash "$SCRIPT_DIR/run-iphone-preview.sh"
    ;;
  api|backend)
    exec bash "$SCRIPT_DIR/run-api.sh"
    ;;
  cli)
    exec python3 "$ROOT_DIR/apps/cli/main.py"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "[weather-app] Unknown mode: $MODE" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac
