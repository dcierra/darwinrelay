#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_DIR="${DARWINRELAY_APP_INSTALL_DIR:-/Applications}"
APP="$APP_DIR/DarwinRelay.app"
ROLLBACK="$APP_DIR/.DarwinRelay.app.rollback"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
TUNNEL_PID_FILE="$DATA_DIR/cloudflared.pid"
PS_BIN="${PS_BIN:-$(command -v ps 2>/dev/null || true)}"
VERIFY_RUNTIME_PIDS="${DARWINRELAY_DEPLOY_VERIFY_RUNTIME_PIDS:-1}"
case "$VERIFY_RUNTIME_PIDS" in
  0|1) ;;
  *) printf 'DARWINRELAY_DEPLOY_VERIFY_RUNTIME_PIDS must be 0 or 1.\n' >&2; exit 64 ;;
esac

process_snapshot() {
  [[ -n "$PS_BIN" && -x "$PS_BIN" ]] || return 69
  "$PS_BIN" -axo pid=,command=
}

pid_for_process_name() {
  local name="$1" table
  # Snapshot first, then inspect it. Starting awk only after ps exits avoids both
  # SIGPIPE under pipefail and process-discovery self-matches.
  table="$(process_snapshot)"
  printf '%s\n' "$table" | awk -v name="$name" '{
    pid=$1; exe=$2; n=split(exe, part, "/")
    if (!found && part[n] == name) found=pid
  } END { if (found) print found }'
}

pid_for_command_contains() {
  local needle="$1" table
  # Do not pipe ps directly into `awk -v needle=...`: when no real runtime is
  # present, ps can observe that downstream awk process and the needle in awk's
  # own argv, producing a false PID that changes on every call.
  table="$(process_snapshot)"
  printf '%s\n' "$table" | awk -v needle="$needle" '{
    if (!found && index($0, needle)) found=$1
  } END { if (found) print found }'
}

pid_for_recorded_executable() { # pidfile, executable basename
  local pid_file="$1" expected="$2" raw comm
  [[ -f "$pid_file" ]] || return 0
  raw="$(head -1 "$pid_file" 2>/dev/null || true)"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= 2 )) || return 0
  [[ -n "$PS_BIN" && -x "$PS_BIN" ]] || return 69
  comm="$("$PS_BIN" -o comm= -p "$raw" 2>/dev/null || true)"
  comm="${comm#"${comm%%[![:space:]]*}"}"
  comm="${comm%"${comm##*[![:space:]]}"}"
  [[ "${comm##*/}" == "$expected" ]] || return 0
  printf '%s\n' "$raw"
}

check_pid_unchanged() {
  local name="$1" before="$2" after="$3"
  if [[ -n "$before" && "$before" != "$after" ]]; then
    printf 'error: %s runtime pid changed during zero-downtime deploy (%s -> %s)\n' "$name" "$before" "${after:-<stopped>}" >&2
    exit 1
  fi
}

main() {
  local before_menu="" before_http="" before_cf="" after_menu="" after_http="" after_cf="" helper_status
  if [[ "$VERIFY_RUNTIME_PIDS" == "1" ]]; then
    before_menu="$(pid_for_process_name DarwinRelay)"
    before_http="$(pid_for_command_contains "$ROOT/mcp-http.mjs")"
    before_cf="$(pid_for_recorded_executable "$TUNNEL_PID_FILE" cloudflared)"
  fi

  DARWINRELAY_INSTALL_APP=1 \
  DARWINRELAY_APP_INSTALL_DIR="$APP_DIR" \
    "$ROOT/menubar/build.sh"

  codesign --verify --deep --strict "$APP"
  helper_status="$("$APP/Contents/Helpers/MacUIHelper" status <<<'{}')"
  [[ "$helper_status" == *'"ok":true'* ]]

  if [[ "$VERIFY_RUNTIME_PIDS" == "1" ]]; then
    after_menu="$(pid_for_process_name DarwinRelay)"
    after_http="$(pid_for_command_contains "$ROOT/mcp-http.mjs")"
    after_cf="$(pid_for_recorded_executable "$TUNNEL_PID_FILE" cloudflared)"

    check_pid_unchanged menu "$before_menu" "$after_menu"
    check_pid_unchanged http "$before_http" "$after_http"
    check_pid_unchanged cloudflared "$before_cf" "$after_cf"
  fi

  printf 'Menu app update installed: %s\n' "$APP"
  [[ -d "$ROLLBACK" ]] && printf 'Rollback bundle retained: %s\n' "$ROLLBACK"
  if [[ "$VERIFY_RUNTIME_PIDS" == "1" ]]; then
    printf 'Runtime PIDs preserved: menu=%s http=%s cloudflared=%s\n' "${after_menu:-n/a}" "${after_http:-n/a}" "${after_cf:-n/a}"
  else
    printf 'Runtime PID preservation check skipped for an explicitly stopped-runtime transaction.\n'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
