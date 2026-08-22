#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_DIR="${DARWINRELAY_APP_INSTALL_DIR:-/Applications}"
APP="$APP_DIR/DarwinRelay.app"
ROLLBACK="$APP_DIR/.DarwinRelay.app.rollback"
PS_BIN="${PS_BIN:-$(command -v ps 2>/dev/null || true)}"

pid_for_process_name() {
  local name="$1"
  [[ -n "$PS_BIN" && -x "$PS_BIN" ]] || return 69
  # Read the complete process stream. Under `set -o pipefail`, an early `awk exit`
  # can SIGPIPE `ps` and turn successful discovery into exit 141 on a busy host.
  "$PS_BIN" -axo pid=,command= | awk -v name="$name" '{
    pid=$1; exe=$2; n=split(exe, part, "/")
    if (!found && part[n] == name) found=pid
  } END { if (found) print found }'
}

pid_for_command_contains() {
  local needle="$1"
  [[ -n "$PS_BIN" && -x "$PS_BIN" ]] || return 69
  "$PS_BIN" -axo pid=,command= | awk -v needle="$needle" '{
    if (!found && index($0, needle)) found=$1
  } END { if (found) print found }'
}

check_pid_unchanged() {
  local name="$1" before="$2" after="$3"
  if [[ -n "$before" && "$before" != "$after" ]]; then
    printf 'error: %s runtime pid changed during zero-downtime deploy (%s -> %s)\n' "$name" "$before" "${after:-<stopped>}" >&2
    exit 1
  fi
}

main() {
  local before_menu before_http before_cf after_menu after_http after_cf helper_status
  before_menu="$(pid_for_process_name DarwinRelay)"
  before_http="$(pid_for_command_contains "$ROOT/mcp-http.mjs")"
  before_cf="$(pid_for_command_contains "cloudflared tunnel")"

  DARWINRELAY_INSTALL_APP=1 \
  DARWINRELAY_APP_INSTALL_DIR="$APP_DIR" \
    "$ROOT/menubar/build.sh"

  codesign --verify --deep --strict "$APP"
  helper_status="$($APP/Contents/Helpers/MacUIHelper status <<<'{}')"
  [[ "$helper_status" == *'"ok":true'* ]]

  after_menu="$(pid_for_process_name DarwinRelay)"
  after_http="$(pid_for_command_contains "$ROOT/mcp-http.mjs")"
  after_cf="$(pid_for_command_contains "cloudflared tunnel")"

  check_pid_unchanged menu "$before_menu" "$after_menu"
  check_pid_unchanged http "$before_http" "$after_http"
  check_pid_unchanged cloudflared "$before_cf" "$after_cf"

  printf 'Zero-downtime menu app update installed: %s\n' "$APP"
  [[ -d "$ROLLBACK" ]] && printf 'Rollback bundle retained: %s\n' "$ROLLBACK"
  printf 'Runtime PIDs preserved: menu=%s http=%s cloudflared=%s\n' "${after_menu:-n/a}" "${after_http:-n/a}" "${after_cf:-n/a}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
