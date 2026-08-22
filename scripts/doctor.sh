#!/bin/bash
# DarwinRelay first-run/runtime diagnostics.
#
# Exit status describes the CORE MCP coding path only:
#   0  core ready
#   2  core action required
#  64  bad invocation
#
# Native desktop, Full Disk Access, background Chrome and Codex continuity are
# optional capability planes. Their absence is reported explicitly but does not
# turn a working shell/filesystem MCP runtime into a failed installation.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SOURCE_ROOT="$(cd "$HERE/.." && pwd -P)"
LABEL="io.github.dcierra.darwinrelay.tunnel"
HTTP_LABEL="io.github.dcierra.darwinrelay.http"
DOMAIN="gui/$(id -u)"
INSTALL_DIR="${DARWINRELAY_INSTALL_DIR:-$HOME/.local/share/darwinrelay}"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
LOG_DIR="${DARWINRELAY_LOG_DIR:-$HOME/Library/Logs/DarwinRelay}"
UNLOCK_FILE="${DARWINRELAY_UNLOCK_FILE:-$DATA_DIR/FULL_ACCESS_ENABLED}"
HTTP_TOKEN_FILE="${DARWINRELAY_HTTP_TOKEN_FILE:-$DATA_DIR/http-token}"
KEYCHAIN_SERVICE="${DARWINRELAY_KEYCHAIN_SERVICE:-OpenAI Secure MCP Tunnel Runtime}"
KEYCHAIN_ACCOUNT="${DARWINRELAY_KEYCHAIN_ACCOUNT:-$(id -un)}"
HTTP_PORT="${DARWINRELAY_HTTP_PORT:-8787}"
PROFILE="${DARWINRELAY_PROFILE:-}"
TRANSPORT="${DARWINRELAY_DOCTOR_TRANSPORT:-auto}"

NODE_BIN="${DARWINRELAY_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
CURL_BIN="${DARWINRELAY_CURL_BIN:-$(command -v curl 2>/dev/null || true)}"
CLOUDFLARED_BIN="${DARWINRELAY_CLOUDFLARED_BIN:-$(command -v cloudflared 2>/dev/null || true)}"
CODEX_BIN="${DARWINRELAY_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
TUNNEL_CLIENT_BIN="${TUNNEL_CLIENT_BIN:-$(command -v tunnel-client 2>/dev/null || true)}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
DESKTOP_DOCTOR_BIN="${DARWINRELAY_DESKTOP_DOCTOR:-$HERE/desktop-doctor.sh}"
TCC_DOCTOR_BIN="${DARWINRELAY_TCC_DOCTOR:-$HERE/tcc-doctor.sh}"
BRIDGE_PROBE_BIN="${DARWINRELAY_BRIDGE_PROBE:-$HERE/probe-bridge-status.mjs}"

usage() {
  cat <<'TXT'
Usage: scripts/doctor.sh [--transport auto|http|tunnel|stdio]

Reports a blocking Core / MCP coding-path verdict separately from optional
native-desktop, protected-filesystem, background-Chrome and Codex capabilities.

Transport modes:
  auto    infer the intended path from the installed app/runtime state (default)
  http    menu-app / HTTP+OAuth Server URL path used by the normal ChatGPT setup
  tunnel  OpenAI Secure MCP Tunnel transport
  stdio   direct local stdio MCP bridge
TXT
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transport)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      TRANSPORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

case "$TRANSPORT" in
  auto|http|tunnel|stdio) ;;
  *) printf 'doctor: invalid transport %s\n' "$TRANSPORT" >&2; exit 64 ;;
esac

if [[ -z "$PROFILE" && -f "$DATA_DIR/tunnel-profile" ]]; then
  PROFILE="$(cat "$DATA_DIR/tunnel-profile")"
fi

if [[ ${DARWINRELAY_APP_PATH+x} == x ]]; then
  APP_PATH="$DARWINRELAY_APP_PATH"
elif [[ -d /Applications/DarwinRelay.app ]]; then
  APP_PATH=/Applications/DarwinRelay.app
elif [[ -d "$HOME/Applications/DarwinRelay.app" ]]; then
  APP_PATH="$HOME/Applications/DarwinRelay.app"
else
  APP_PATH=""
fi

plist_value() {
  local plist="$1" key="$2"
  [[ -f "$plist" ]] || return 1
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

package_version() {
  local package="$1/package.json"
  [[ -f "$package" ]] || return 1
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$package" | head -1
}

APP_VERSION=""
APP_RUNTIME_DIR=""
if [[ -n "$APP_PATH" && -d "$APP_PATH" ]]; then
  APP_VERSION="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
  APP_RUNTIME_DIR="$(plist_value "$APP_PATH/Contents/Info.plist" DarwinRelayPackageDirectory)"
fi

if [[ -n "${DARWINRELAY_RUNTIME_DIR:-}" ]]; then
  RUNTIME_DIR="$DARWINRELAY_RUNTIME_DIR"
elif [[ -n "$APP_RUNTIME_DIR" && -f "$APP_RUNTIME_DIR/bridge.mjs" ]]; then
  RUNTIME_DIR="$APP_RUNTIME_DIR"
elif [[ -f "$INSTALL_DIR/bridge.mjs" && -n "$PROFILE" ]]; then
  RUNTIME_DIR="$INSTALL_DIR"
else
  RUNTIME_DIR="$SOURCE_ROOT"
fi
RUNTIME_VERSION="$(package_version "$RUNTIME_DIR" 2>/dev/null || true)"

if [[ "$TRANSPORT" == auto ]]; then
  if [[ -n "$APP_PATH" || -f "$HTTP_TOKEN_FILE" ]]; then
    TRANSPORT=http
  elif [[ -n "$PROFILE" && -n "$TUNNEL_CLIENT_BIN" ]]; then
    TRANSPORT=tunnel
  else
    TRANSPORT=stdio
  fi
fi

core_failures=0
core_pass() { printf '  [PASS]            %s\n' "$1"; }
core_note() { printf '  [INFO]            %s\n' "$1"; }
core_fail() {
  printf '  [ACTION REQUIRED] %s\n' "$1"
  [[ -z "${2:-}" ]] || printf '                    Next: %s\n' "$2"
  core_failures=$((core_failures + 1))
}
optional_ready() { printf '  %-28s READY%s\n' "$1" "${2:+ — $2}"; }
optional_action() { printf '  %-28s OPTIONAL / ACTION REQUIRED%s\n' "$1" "${2:+ — $2}"; }
optional_absent() { printf '  %-28s OPTIONAL / NOT CONFIGURED%s\n' "$1" "${2:+ — $2}"; }

printf 'DarwinRelay doctor\n'
printf '==================\n'
printf 'Selected transport: %s\n' "$TRANSPORT"
printf 'Source checkout:    %s\n' "$SOURCE_ROOT"
printf 'Runtime package:    %s\n' "$RUNTIME_DIR"
printf 'Menu app:           %s\n' "${APP_PATH:-<not installed>}"

printf '\nCore / MCP coding path\n'
printf '%s\n' '----------------------'

if [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]]; then
  NODE_VERSION="$($NODE_BIN --version 2>/dev/null || true)"
  NODE_MAJOR="$(printf '%s' "$NODE_VERSION" | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "$NODE_MAJOR" && "$NODE_MAJOR" -ge 18 ]]; then
    core_pass "Node $NODE_VERSION at $NODE_BIN"
  else
    core_fail "Node 18+ is required (found ${NODE_VERSION:-unknown})." "Install/activate Node 18+ and make sure a login shell can resolve node."
  fi
else
  core_fail "Node is not available." "Install Node 18+ and make sure 'zsh -lc \"command -v node\"' returns an executable path."
fi

if [[ -f "$RUNTIME_DIR/bridge.mjs" && -f "$RUNTIME_DIR/mcp-http.mjs" && -f "$RUNTIME_DIR/package.json" ]]; then
  core_pass "Runtime package is complete${RUNTIME_VERSION:+ (v$RUNTIME_VERSION)}."
else
  core_fail "Runtime package is incomplete at $RUNTIME_DIR." "Keep the DarwinRelay source checkout in place or rebuild/reinstall from a complete public checkout."
fi

if [[ -n "$APP_PATH" ]]; then
  if [[ -n "$APP_VERSION" ]]; then
    core_pass "Menu app found at $APP_PATH (v$APP_VERSION)."
  else
    core_fail "Menu app Info.plist/version could not be read at $APP_PATH." "Rebuild the app with ./menubar/build.sh."
  fi
  if [[ -n "$APP_RUNTIME_DIR" && -f "$APP_RUNTIME_DIR/mcp-http.mjs" ]]; then
    core_pass "Menu app resolves runtime package $APP_RUNTIME_DIR."
  else
    core_fail "Menu app does not resolve a valid DarwinRelay source package." "Keep the checkout used to build the app, or rebuild the app from the checkout you intend to run."
  fi
  if [[ -n "$APP_VERSION" && -n "$RUNTIME_VERSION" && "$APP_VERSION" != "$RUNTIME_VERSION" ]]; then
    core_fail "App/runtime version mismatch: app v$APP_VERSION, runtime v$RUNTIME_VERSION." "Rebuild the menu app from $RUNTIME_DIR so app/package versions agree."
  fi
else
  if [[ "$TRANSPORT" == http ]]; then
    core_note "Menu app is not installed. Headless HTTP is possible, but the normal ChatGPT path uses ./menubar/build.sh."
  else
    core_note "Menu app is not required for the selected $TRANSPORT transport."
  fi
fi

unlock_granted=0
if [[ "${DARWINRELAY_FULL_ACCESS_ACK:-}" == I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS ]]; then
  unlock_granted=1
  core_pass "Full-access acknowledgement is present in the current environment."
elif [[ -f "$UNLOCK_FILE" ]] && [[ "$(tr -d '\r\n' < "$UNLOCK_FILE" 2>/dev/null || true)" == I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS ]]; then
  unlock_granted=1
  core_pass "Full-access latch is armed at $UNLOCK_FILE."
else
  core_note "Full-access latch is not armed. This is normal while the menu app is stopped."
fi

bridge_json=""
bridge_probe_error=""

run_bridge_probe() {
  local mode="$1"
  [[ -n "$NODE_BIN" && -x "$NODE_BIN" && -f "$BRIDGE_PROBE_BIN" ]] || return 1
  local error_file
  error_file="$(mktemp "${TMPDIR:-/tmp}/darwinrelay-doctor-probe.XXXXXX")" || return 1
  if [[ "$mode" == http ]]; then
    bridge_json="$($NODE_BIN "$BRIDGE_PROBE_BIN" --http-port "$HTTP_PORT" --token-file "$HTTP_TOKEN_FILE" 2>"$error_file")"
  else
    bridge_json="$($NODE_BIN "$BRIDGE_PROBE_BIN" --stdio "$RUNTIME_DIR/bridge.mjs" 2>"$error_file")"
  fi
  local rc=$?
  if [[ -f "$error_file" ]]; then
    bridge_probe_error="$(tail -5 "$error_file" 2>/dev/null || true)"
    rm -f "$error_file" 2>/dev/null || true
  fi
  return "$rc"
}

json_field() {
  local field="$1"
  [[ -n "$bridge_json" && -n "$NODE_BIN" ]] || return 1
  printf '%s' "$bridge_json" | "$NODE_BIN" -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  let v=JSON.parse(s); for (const p of process.argv[1].split(".")) v=v?.[p];
  if (v === undefined || v === null) return;
  process.stdout.write(typeof v === "object" ? JSON.stringify(v) : String(v));
});' "$field" 2>/dev/null
}

case "$TRANSPORT" in
  http)
    if [[ -n "$CLOUDFLARED_BIN" && -x "$CLOUDFLARED_BIN" ]]; then
      core_pass "cloudflared is available at $CLOUDFLARED_BIN."
    else
      core_fail "cloudflared is not available for the ChatGPT Server URL path." "Install cloudflared and ensure it is on the login-shell PATH."
    fi

    http_running=0
    if [[ -n "$CURL_BIN" && -x "$CURL_BIN" ]] && "$CURL_BIN" -fsS --max-time 3 "http://127.0.0.1:$HTTP_PORT/healthz" >/dev/null 2>&1; then
      http_running=1
      core_pass "HTTP front end is listening on localhost:$HTTP_PORT."
    else
      core_fail "HTTP front end is not listening on localhost:$HTTP_PORT." "Open DarwinRelay and choose Start; for headless use, start mcp-http.mjs with the documented token-file configuration."
    fi

    if [[ -f "$HTTP_TOKEN_FILE" ]]; then
      token_mode="$(stat -f '%OLp' "$HTTP_TOKEN_FILE" 2>/dev/null || printf '?')"
      [[ "$token_mode" =~ ^[0-7]+$ ]] && token_mode="$(printf '%03d' "$token_mode")"
      case "$token_mode" in
        600|400)
          core_pass "HTTP token file exists with mode $token_mode."
          ;;
        000)
          core_fail "HTTP token file is unreadable (mode 000)." "chmod 600 '$HTTP_TOKEN_FILE' or Stop/Start DarwinRelay to recreate it."
          ;;
        '?')
          core_fail "HTTP token file exists but its mode could not be checked." "Inspect $HTTP_TOKEN_FILE and ensure it is owned by you with mode 0600."
          ;;
        *)
          core_fail "HTTP token file is too open (mode $token_mode)." "chmod 600 '$HTTP_TOKEN_FILE'."
          ;;
      esac
    else
      if (( http_running )); then
        core_fail "HTTP front end is running but $HTTP_TOKEN_FILE is missing." "Stop DarwinRelay, verify the data directory, then Start so the token file is recreated."
      else
        core_note "HTTP token file is not present yet; the menu app creates it before Start."
      fi
    fi

    if (( http_running )) && (( unlock_granted == 0 )); then
      core_fail "HTTP transport is running while the full-access latch is not armed." "Use Stop then Start in the DarwinRelay menu; do not bypass the latch."
    fi

    if (( http_running )) && [[ -f "$HTTP_TOKEN_FILE" ]] && [[ -n "$NODE_BIN" ]]; then
      if run_bridge_probe http; then
        BRIDGE_VERSION="$(json_field bridgeVersion || true)"
        core_pass "Real MCP initialize + bridge_status smoke passed${BRIDGE_VERSION:+ (bridge v$BRIDGE_VERSION)}."
        if [[ -n "$RUNTIME_VERSION" && -n "$BRIDGE_VERSION" && "$RUNTIME_VERSION" != "$BRIDGE_VERSION" ]]; then
          core_fail "Running bridge version v$BRIDGE_VERSION does not match runtime package v$RUNTIME_VERSION." "Stop the old runtime and restart DarwinRelay from $RUNTIME_DIR."
        fi
      else
        core_fail "HTTP health is up, but a real bridge_status MCP call failed." "Check $LOG_DIR/http.stderr.log, verify the full-access latch, then Stop/Start DarwinRelay. ${bridge_probe_error:-}"
      fi
    fi
    ;;

  tunnel)
    if [[ -n "$TUNNEL_CLIENT_BIN" && -x "$TUNNEL_CLIENT_BIN" ]]; then
      core_pass "tunnel-client is available at $TUNNEL_CLIENT_BIN."
    else
      core_fail "tunnel-client is not available." "Install the Secure MCP Tunnel client and ensure it is executable."
    fi
    if [[ -n "$PROFILE" ]]; then
      core_pass "Tunnel profile is $PROFILE."
    else
      core_fail "Tunnel profile is not configured." "Create/configure the Secure MCP Tunnel profile, then set DARWINRELAY_PROFILE or $DATA_DIR/tunnel-profile."
    fi
    if [[ -n "$TUNNEL_CLIENT_BIN" && -x "$TUNNEL_CLIENT_BIN" && -n "$PROFILE" && -n "$CURL_BIN" ]]; then
      if "$CURL_BIN" -fsS --max-time 3 http://127.0.0.1:8080/readyz >/dev/null 2>&1; then
        core_pass "Secure MCP Tunnel readiness endpoint is healthy."
      else
        core_fail "Secure MCP Tunnel readiness endpoint is unavailable." "Run tunnel-client doctor --profile '$PROFILE' --explain and fix the reported transport issue."
      fi
    fi
    if (( unlock_granted == 0 )); then
      core_fail "Full-access acknowledgement is not armed for the stdio bridge behind the tunnel." "Use the documented unlock file or exact DARWINRELAY_FULL_ACCESS_ACK value; do not weaken the latch."
    elif [[ -n "$NODE_BIN" && -f "$RUNTIME_DIR/bridge.mjs" ]]; then
      if run_bridge_probe stdio; then
        BRIDGE_VERSION="$(json_field bridgeVersion || true)"
        core_pass "Direct bridge_status smoke passed${BRIDGE_VERSION:+ (bridge v$BRIDGE_VERSION)}."
      else
        core_fail "Direct bridge_status smoke failed." "Check the runtime package and unlock state. ${bridge_probe_error:-}"
      fi
    fi
    ;;

  stdio)
    if (( unlock_granted == 0 )); then
      core_fail "Full-access acknowledgement is not armed for direct stdio use." "Create the documented unlock file or set the exact DARWINRELAY_FULL_ACCESS_ACK value before starting bridge.mjs."
    elif [[ -n "$NODE_BIN" && -f "$RUNTIME_DIR/bridge.mjs" ]]; then
      if run_bridge_probe stdio; then
        BRIDGE_VERSION="$(json_field bridgeVersion || true)"
        core_pass "Direct initialize + bridge_status smoke passed${BRIDGE_VERSION:+ (bridge v$BRIDGE_VERSION)}."
      else
        core_fail "Direct bridge_status smoke failed." "Check $RUNTIME_DIR/bridge.mjs and the full-access acknowledgement. ${bridge_probe_error:-}"
      fi
    fi
    ;;
esac

printf '\nOptional capabilities\n'
printf '%s\n' '---------------------'

$DESKTOP_DOCTOR_BIN >/dev/null 2>&1
DESKTOP_RC=$?
case "$DESKTOP_RC" in
  0) optional_ready "Native desktop" "Accessibility, Screen Recording and Input/Post Events granted" ;;
  2) optional_action "Native desktop" "run scripts/desktop-doctor.sh --request --open" ;;
  *) optional_absent "Native desktop" "helper/permission status unavailable; run scripts/desktop-doctor.sh" ;;
esac

$TCC_DOCTOR_BIN >/dev/null 2>&1
FDA_RC=$?
case "$FDA_RC" in
  0) optional_ready "Protected filesystem (FDA)" ;;
  1) optional_action "Protected filesystem (FDA)" "run scripts/tcc-doctor.sh --open when a task needs protected paths" ;;
  *) optional_absent "Protected filesystem (FDA)" "status unavailable; run scripts/tcc-doctor.sh" ;;
esac

CHROME_BINDING="$DATA_DIR/chrome-background-profile.json"
CHROME_READY="$(json_field backgroundChrome.extensionReady || true)"
CHROME_EXTENSION_VERSION="$(json_field backgroundChrome.extension.version || true)"
if [[ "$CHROME_READY" == true ]]; then
  CHROME_PROFILE="$(json_field backgroundChrome.profileBinding.profileName || true)"
  if [[ -n "$RUNTIME_VERSION" && -n "$CHROME_EXTENSION_VERSION" && "$RUNTIME_VERSION" != "$CHROME_EXTENSION_VERSION" ]]; then
    optional_action "Background Chrome" "extension v$CHROME_EXTENSION_VERSION is connected but runtime is v$RUNTIME_VERSION; reload DarwinRelay Background Browser in the dedicated ${CHROME_PROFILE:-DarwinRelay} profile"
  else
    optional_ready "Background Chrome" "${CHROME_PROFILE:-DarwinRelay profile} connected${CHROME_EXTENSION_VERSION:+ (v$CHROME_EXTENSION_VERSION)}"
  fi
elif [[ -f "$CHROME_BINDING" ]]; then
  optional_action "Background Chrome" "binding exists but extension is not confirmed ready; run scripts/install-background-chrome.sh and load the extension in the dedicated profile"
else
  optional_absent "Background Chrome" "set up the dedicated signed-out DarwinRelay profile only when needed"
fi

if [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]]; then
  if [[ -d "$HOME/.codex" ]]; then
    optional_ready "Codex continuity" "$CODEX_BIN"
  else
    optional_absent "Codex continuity" "Codex CLI exists but no ~/.codex history was found"
  fi
elif [[ -d "$HOME/.codex" ]]; then
  optional_action "Codex continuity" "persisted history exists, but the Codex CLI is not executable on this PATH; install/restore Codex to use codex_thread_*"
else
  optional_absent "Codex continuity" "install/use Codex only if persisted-history tools are useful"
fi

printf '\nCore verdict\n'
printf '%s\n' '------------'
if (( core_failures == 0 )); then
  printf 'CORE VERDICT: READY\n'
else
  printf 'CORE VERDICT: ACTION REQUIRED (%d blocking check%s)\n' "$core_failures" "$([[ "$core_failures" -eq 1 ]] && printf '' || printf 's')"
fi

printf '\nOperational details\n'
printf '%s\n' '-------------------'
printf 'Data directory:    %s\n' "$DATA_DIR"
printf 'Log directory:     %s\n' "$LOG_DIR"
printf 'Unlock file:       %s (%s)\n' "$UNLOCK_FILE" "$([[ -f "$UNLOCK_FILE" ]] && printf present || printf missing)"
printf 'Tunnel profile:    %s\n' "${PROFILE:-<not configured>}"

printf '\nLifecycle\n'
printf '%s\n' '---------'
if [[ -n "$LAUNCHCTL_BIN" && -x "$LAUNCHCTL_BIN" ]]; then
  for launch_label in "$HTTP_LABEL" "$LABEL"; do
    if "$LAUNCHCTL_BIN" print "$DOMAIN/$launch_label" >/dev/null 2>&1; then
      printf '  %-39s LOADED\n' "$launch_label"
    else
      printf '  %-39s not loaded\n' "$launch_label"
    fi
  done
  if [[ "$TRANSPORT" == http ]]; then
    printf '  Note: the menu app may own a healthy HTTP runtime directly even when the HTTP LaunchAgent is not loaded.\n'
  fi
else
  printf '  launchctl unavailable.\n'
fi

printf '\nTunnel doctor (Secure Tunnel only)\n'
printf '%s\n' '---------------------------------'
if [[ -n "$TUNNEL_CLIENT_BIN" && -x "$TUNNEL_CLIENT_BIN" && -n "$PROFILE" ]]; then
  CONTROL_PLANE_API_KEY="$("$SECURITY_BIN" find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
  if [[ -n "$CONTROL_PLANE_API_KEY" ]]; then
    export CONTROL_PLANE_API_KEY
    "$TUNNEL_CLIENT_BIN" doctor --profile "$PROFILE" --explain || true
    unset CONTROL_PLANE_API_KEY
  else
    printf 'Runtime key not found in Keychain service %s.\n' "$KEYCHAIN_SERVICE"
  fi
else
  printf 'Not configured for this runtime.\n'
fi

printf '\nTransport logs\n'
printf '%s\n' '--------------'
if (( core_failures == 0 )); then
  printf 'Core is ready; historical stderr tails are not printed by default.\n'
  printf 'Inspect when needed:\n  %s\n  %s\n' "$LOG_DIR/tunnel.stderr.log" "$LOG_DIR/http.stderr.log"
else
  found=0
  for logfile in tunnel.stderr.log http.stderr.log; do
    if [[ -f "$LOG_DIR/$logfile" ]]; then
      printf -- '--- %s (last 40 lines) ---\n' "$logfile"
      tail -40 "$LOG_DIR/$logfile"
      found=1
    fi
  done
  if (( ! found )); then
    printf 'No transport stderr logs found. Checked:\n'
    printf '  %s\n' "$LOG_DIR/tunnel.stderr.log" "$LOG_DIR/http.stderr.log"
  fi
fi

if (( core_failures == 0 )); then
  exit 0
fi
exit 2
