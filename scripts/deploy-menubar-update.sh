#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_DIR="${MAC_DEV_BRIDGE_APP_INSTALL_DIR:-/Applications}"
APP="$APP_DIR/MacDevBridge.app"
ROLLBACK="$APP_DIR/.MacDevBridge.app.rollback"

pid_for() {
  pgrep -f "$1" | head -1 || true
}

before_menu="$(pid_for "^$APP/Contents/MacOS/MacDevBridge$")"
before_http="$(pid_for "$ROOT/mcp-http.mjs$")"
before_cf="$(pid_for 'cloudflared tunnel .*run')"

MAC_DEV_BRIDGE_INSTALL_APP=1 \
MAC_DEV_BRIDGE_APP_INSTALL_DIR="$APP_DIR" \
  "$ROOT/menubar/build.sh"

codesign --verify --deep --strict "$APP"
helper_status="$($APP/Contents/Helpers/MacUIHelper status <<<'{}')"
printf '%s\n' "$helper_status" | grep -q '"ok":true'

after_menu="$(pid_for "^$APP/Contents/MacOS/MacDevBridge$")"
after_http="$(pid_for "$ROOT/mcp-http.mjs$")"
after_cf="$(pid_for 'cloudflared tunnel .*run')"

check_pid_unchanged() {
  local name="$1" before="$2" after="$3"
  if [[ -n "$before" && "$before" != "$after" ]]; then
    printf 'error: %s runtime pid changed during zero-downtime deploy (%s -> %s)\n' "$name" "$before" "${after:-<stopped>}" >&2
    exit 1
  fi
}
check_pid_unchanged menu "$before_menu" "$after_menu"
check_pid_unchanged http "$before_http" "$after_http"
check_pid_unchanged cloudflared "$before_cf" "$after_cf"

printf 'Zero-downtime menu app update installed: %s\n' "$APP"
[[ -d "$ROLLBACK" ]] && printf 'Rollback bundle retained: %s\n' "$ROLLBACK"
printf 'Runtime PIDs preserved: menu=%s http=%s cloudflared=%s\n' "${after_menu:-n/a}" "${after_http:-n/a}" "${after_cf:-n/a}"
