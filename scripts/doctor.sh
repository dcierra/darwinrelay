#!/bin/bash
set -u

LABEL="com.openai.mac-developer-bridge-tunnel"
HTTP_LABEL="local.mac-developer-bridge.http"
DOMAIN="gui/$(id -u)"
INSTALL_DIR="${MAC_DEV_BRIDGE_INSTALL_DIR:-$HOME/.local/share/mac-developer-bridge}"
DATA_DIR="${MAC_DEV_BRIDGE_DATA_DIR:-$HOME/Library/Application Support/MacDeveloperBridge}"
LOG_DIR="${MAC_DEV_BRIDGE_LOG_DIR:-$HOME/Library/Logs/MacDeveloperBridge}"
UNLOCK_FILE="${MAC_DEV_BRIDGE_UNLOCK_FILE:-$DATA_DIR/FULL_ACCESS_ENABLED}"
KEYCHAIN_SERVICE="${MAC_DEV_BRIDGE_KEYCHAIN_SERVICE:-OpenAI Secure MCP Tunnel Runtime}"
KEYCHAIN_ACCOUNT="${MAC_DEV_BRIDGE_KEYCHAIN_ACCOUNT:-$(id -un)}"
TUNNEL_CLIENT_BIN="${TUNNEL_CLIENT_BIN:-$(command -v tunnel-client 2>/dev/null || true)}"
PROFILE="${MAC_DEV_BRIDGE_PROFILE:-}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
HTTP_PORT="${MAC_DEV_BRIDGE_HTTP_PORT:-8787}"

if [[ -z "$PROFILE" && -f "$DATA_DIR/tunnel-profile" ]]; then
  PROFILE="$(cat "$DATA_DIR/tunnel-profile")"
fi

printf 'Mac Developer Bridge diagnostics\n'
printf '================================\n'
printf 'Install directory: %s\n' "$INSTALL_DIR"
printf 'Data directory:    %s\n' "$DATA_DIR"
printf 'Log directory:     %s\n' "$LOG_DIR"
printf 'Tunnel profile:    %s\n' "${PROFILE:-<unknown>}"
printf 'Tunnel client:     %s\n' "${TUNNEL_CLIENT_BIN:-<not found>}"
printf 'Unlock file:       %s (%s)\n' "$UNLOCK_FILE" "$([[ -f "$UNLOCK_FILE" ]] && printf present || printf missing)"
printf '\nLaunchAgents\n------------\n'
if [[ -n "$LAUNCHCTL_BIN" && -x "$LAUNCHCTL_BIN" ]]; then
  for launch_label in "$LABEL" "$HTTP_LABEL"; do
    printf -- '--- %s ---\n' "$launch_label"
    "$LAUNCHCTL_BIN" print "$DOMAIN/$launch_label" 2>&1 | head -80 || true
  done
else
  printf 'launchctl unavailable.\n'
fi

printf '\nTunnel doctor (Tunnel transport only)\n-------------------------------------\n'
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
  printf 'Not configured (expected on the Cloudflare/HTTP transport).\n'
fi

printf '\nLocal health\n------------\n'
# tunnel-client's own endpoints; only meaningful on the Tunnel transport.
if [[ -n "$TUNNEL_CLIENT_BIN" && -x "$TUNNEL_CLIENT_BIN" && -n "$PROFILE" ]]; then
  for endpoint in healthz readyz; do
    printf 'tunnel-client %-8s ' "$endpoint:"
    curl -fsS --max-time 3 "http://127.0.0.1:8080/$endpoint" 2>/dev/null || printf 'unavailable'
    printf '\n'
  done
fi
printf 'HTTP front end (:%s)  ' "$HTTP_PORT"
if curl -fsS --max-time 3 "http://127.0.0.1:$HTTP_PORT/healthz" >/dev/null 2>&1; then
  printf 'listening\n'
else
  printf 'not running\n'
fi
if [[ -n "${MAC_DEV_BRIDGE_HTTP_TOKEN_FILE:-}" ]]; then
  if [[ -f "$MAC_DEV_BRIDGE_HTTP_TOKEN_FILE" ]]; then
    token_mode="$(stat -f '%OLp' "$MAC_DEV_BRIDGE_HTTP_TOKEN_FILE" 2>/dev/null || printf '?')"
    # stat drops leading zeros, so 000 arrives as "0" and 040 as "40". Normalize
    # before judging, or mode 000 gets reported as "too open" — the opposite.
    [[ "$token_mode" =~ ^[0-7]+$ ]] && token_mode="$(printf '%03d' "$token_mode")"
    case "$token_mode" in
      600|400) token_verdict="ok" ;;
      000) token_verdict="unreadable - the front end will exit 78" ;;
      '?') token_verdict="could not stat" ;;
      # Judge the mode, don't just print it: a group/other-readable file holding
      # the only credential for a public endpoint is a finding, not a detail.
      *) token_verdict="TOO OPEN - chmod 600" ;;
    esac
    printf 'HTTP token source:    file %s (mode %s, %s)\n' \
      "$MAC_DEV_BRIDGE_HTTP_TOKEN_FILE" "$token_mode" "$token_verdict"
  else
    printf 'HTTP token source:    file %s (MISSING)\n' "$MAC_DEV_BRIDGE_HTTP_TOKEN_FILE"
  fi
elif [[ -n "${MAC_DEV_BRIDGE_HTTP_TOKEN:-}" ]]; then
  printf 'HTTP token source:    environment (visible in ps eww; a 0600 file is preferable)\n'
else
  printf 'HTTP token source:    <not in this shell>\n'
fi

printf '\nRecent transport errors\n----------------------\n'
found=0
for logfile in tunnel.stderr.log http.stderr.log; do
  if [[ -f "$LOG_DIR/$logfile" ]]; then
    printf -- '--- %s ---\n' "$logfile"
    tail -40 "$LOG_DIR/$logfile"
    found=1
  fi
done
if (( ! found )); then
  # Say which paths were checked: "no logs" must not be misread as "no errors".
  # The HTTP transport only writes here if it was started with its stderr
  # redirected (see DEPLOY.md); run in a terminal, its log lines are lost.
  printf 'No transport stderr logs found. Checked:\n'
  printf '  %s\n' "$LOG_DIR/tunnel.stderr.log" "$LOG_DIR/http.stderr.log"
  printf 'If the HTTP front end is running in a terminal, its output is not captured here.\n'
fi

printf '\nFull Disk Access\n----------------\n'
"$(dirname "$0")/tcc-doctor.sh" || true
