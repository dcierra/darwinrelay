#!/bin/bash
set -euo pipefail

LABEL="io.github.dcierra.darwinrelay.tunnel"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
INSTALL_DIR="${DARWINRELAY_INSTALL_DIR:-$HOME/.local/share/darwinrelay}"
BIN_DIR="${DARWINRELAY_BIN_DIR:-$HOME/.local/bin}"
PLIST_DIR="${DARWINRELAY_PLIST_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${DARWINRELAY_LOG_DIR:-$HOME/Library/Logs/DarwinRelay}"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
UNLOCK_FILE="${DARWINRELAY_UNLOCK_FILE:-$DATA_DIR/FULL_ACCESS_ENABLED}"
AUDIT_MODE="${DARWINRELAY_AUDIT_MODE:-metadata}"
BRIDGE_SHELL="${DARWINRELAY_SHELL:-/bin/zsh}"
KEYCHAIN_SERVICE="${DARWINRELAY_KEYCHAIN_SERVICE:-OpenAI Secure MCP Tunnel Runtime}"
KEYCHAIN_ACCOUNT="${DARWINRELAY_KEYCHAIN_ACCOUNT:-$(id -un)}"
FULL_ACCESS_ACK_EXPECTED="I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS"
TUNNEL_CLIENT_BIN="${TUNNEL_CLIENT_BIN:-$(command -v tunnel-client 2>/dev/null || true)}"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"
NODE_BIN="$(command -v node 2>/dev/null || true)"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
PLUTIL_BIN="${PLUTIL_BIN:-$(command -v plutil 2>/dev/null || true)}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
UNAME_BIN="${UNAME_BIN:-$(command -v uname 2>/dev/null || true)}"

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

absolute_executable() {
  local candidate="$1"
  local directory
  if [[ "$candidate" != /* ]]; then
    candidate="$(command -v "$candidate" 2>/dev/null || true)"
  fi
  [[ -n "$candidate" ]] || return 1
  directory="$(cd "$(dirname "$candidate")" && pwd -P)"
  printf '%s/%s\n' "$directory" "$(basename "$candidate")"
}

xml_sed_value() {
  # XML-escape a string, then escape sed replacement metacharacters.
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" \
    | sed -e 's/[\\&|]/\\&/g'
}

say "Installing DarwinRelay..."

if [[ "${DARWINRELAY_FULL_ACCESS_ACK:-}" != "$FULL_ACCESS_ACK_EXPECTED" ]]; then
  warn "This bridge grants unrestricted shell and filesystem access as your macOS user."
  warn "To acknowledge that explicitly, rerun with:"
  warn "  export DARWINRELAY_FULL_ACCESS_ACK='$FULL_ACCESS_ACK_EXPECTED'"
  exit 64
fi

if [[ -z "$UNAME_BIN" || "$($UNAME_BIN -s)" != "Darwin" ]]; then
  warn "install.sh targets macOS because it installs a per-user LaunchAgent and stores the tunnel key in Keychain."
  warn "The MCP server itself is portable and can be started directly with: node bridge.mjs"
  exit 69
fi

for required_bin in "$SECURITY_BIN" "$PLUTIL_BIN" "$LAUNCHCTL_BIN"; do
  if [[ -z "$required_bin" || ! -x "$required_bin" ]]; then
    warn "Required macOS system executable is unavailable: ${required_bin:-<empty>}"
    exit 69
  fi
done

if [[ -z "$NODE_BIN" ]]; then
  warn "Node.js 18 or newer is required. Install Node, Homebrew, or use an existing Node managed by nvm/Volta."
  exit 69
fi
NODE_BIN="$(absolute_executable "$NODE_BIN")"
NODE_MAJOR="$($NODE_BIN -p 'Number(process.versions.node.split(".")[0])')"
if (( NODE_MAJOR < 18 )); then
  warn "Node.js 18 or newer is required; found $($NODE_BIN --version)."
  exit 69
fi

if [[ -z "$TUNNEL_CLIENT_BIN" || ! -x "$TUNNEL_CLIENT_BIN" ]]; then
  if [[ -x "$BIN_DIR/tunnel-client" ]]; then
    TUNNEL_CLIENT_BIN="$BIN_DIR/tunnel-client"
  else
    warn "tunnel-client is required. Download the supported macOS binary from OpenAI Platform Tunnels, place it at $BIN_DIR/tunnel-client, chmod +x it, then rerun."
    warn "Platform page: https://platform.openai.com/settings/organization/tunnels"
    exit 69
  fi
fi
TUNNEL_CLIENT_BIN="$(absolute_executable "$TUNNEL_CLIENT_BIN")"

if [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]]; then
  CODEX_BIN="$(absolute_executable "$CODEX_BIN")"
else
  CODEX_BIN="codex"
  warn "Note: codex CLI was not found on PATH. Shell/filesystem tools will work, but Codex thread-history tools require CODEX_BIN to point to a working Codex CLI."
fi

if [[ -z "${CONTROL_PLANE_TUNNEL_ID:-}" && -t 0 ]]; then
  read -r -p "OpenAI tunnel ID (tunnel_...): " CONTROL_PLANE_TUNNEL_ID
fi
if [[ -z "${CONTROL_PLANE_TUNNEL_ID:-}" ]]; then
  warn "Set CONTROL_PLANE_TUNNEL_ID to the tunnel_... value from Platform Tunnels and rerun."
  exit 64
fi
if [[ ! "$CONTROL_PLANE_TUNNEL_ID" =~ ^tunnel_[0-9a-f]{32}$ ]]; then
  warn "CONTROL_PLANE_TUNNEL_ID must be tunnel_ followed by exactly 32 lowercase hexadecimal characters."
  exit 64
fi

if [[ -z "${CONTROL_PLANE_API_KEY:-}" && -t 0 ]]; then
  read -r -s -p "Tunnel runtime API key (input hidden): " CONTROL_PLANE_API_KEY
  printf '\n'
fi
if [[ -z "${CONTROL_PLANE_API_KEY:-}" ]]; then
  warn "Set CONTROL_PLANE_API_KEY to a runtime key with Tunnels Read + Use and rerun. The installer stores it in macOS Keychain."
  exit 64
fi

case "$AUDIT_MODE" in
  off|metadata|full) ;;
  *) warn "DARWINRELAY_AUDIT_MODE must be off, metadata, or full."; exit 64 ;;
esac
if [[ ! -x "$BRIDGE_SHELL" ]]; then
  warn "Configured shell is not executable: $BRIDGE_SHELL"
  exit 69
fi

if [[ -z "${DARWINRELAY_PROFILE:-}" ]]; then
  PROFILE="darwinrelay-$(date -u +%Y%m%d%H%M%S)-${CONTROL_PLANE_TUNNEL_ID: -8}"
else
  PROFILE="$DARWINRELAY_PROFILE"
fi
if [[ ! "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  warn "DARWINRELAY_PROFILE may contain only letters, numbers, periods, underscores, and hyphens."
  exit 64
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$PLIST_DIR" "$LOG_DIR" "$DATA_DIR"
chmod 700 "$LOG_DIR" "$DATA_DIR"
printf '%s\n' "$FULL_ACCESS_ACK_EXPECTED" > "$UNLOCK_FILE"
chmod 600 "$UNLOCK_FILE"
printf '%s\n' "$PROFILE" > "$DATA_DIR/tunnel-profile"
printf '%s\n' "$CONTROL_PLANE_TUNNEL_ID" > "$DATA_DIR/tunnel-id"
chmod 600 "$DATA_DIR/tunnel-profile" "$DATA_DIR/tunnel-id"

if [[ "$SCRIPT_DIR" != "$INSTALL_DIR" ]]; then
  rsync -a --delete --exclude '.DS_Store' "$SCRIPT_DIR/" "$INSTALL_DIR/"
fi
chmod +x "$INSTALL_DIR/bridge.mjs" "$INSTALL_DIR/mcp-http.mjs" "$INSTALL_DIR/install.sh" "$INSTALL_DIR/uninstall.sh" "$INSTALL_DIR/scripts/"*.sh
ln -sfn "$INSTALL_DIR/bridge.mjs" "$BIN_DIR/darwinrelay"

# Native desktop control is optional for the portable bridge, but on macOS with
# Swift tooling available we build it automatically. Failure does not weaken the
# existing terminal/filesystem bridge; ui_* tools simply stay unadvertised.
if command -v xcrun >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
  if DARWINRELAY_UI_HELPER_OUTPUT="$INSTALL_DIR/bin/MacUIHelper" "$INSTALL_DIR/scripts/build-mac-ui-helper.sh" >/dev/null; then
    say "Built native desktop-control helper."
  else
    warn "Note: native desktop-control helper failed to build; terminal/filesystem tools remain available."
  fi
  if DARWINRELAY_UI_CURSOR_OUTPUT="$INSTALL_DIR/bin/MacUICursorOverlay" "$INSTALL_DIR/scripts/build-mac-ui-cursor.sh" >/dev/null; then
    say "Built virtual AI cursor overlay."
  else
    warn "Note: virtual AI cursor overlay failed to build; desktop control remains available without it."
  fi
else
  warn "Note: Swift/Xcode Command Line Tools are unavailable; native ui_* tools will not be advertised."
fi

say "Validating bridge protocol and host operations..."
"$NODE_BIN" --check "$INSTALL_DIR/bridge.mjs"
"$NODE_BIN" --check "$INSTALL_DIR/mcp-http.mjs"
"$NODE_BIN" "$INSTALL_DIR/tests/smoke.mjs"
if command -v git >/dev/null 2>&1; then
  "$NODE_BIN" "$INSTALL_DIR/tests/integration.mjs"
else
  warn "Note: git is not installed, so the apply_patch integration test was skipped."
fi

say "Saving the tunnel runtime key in macOS Keychain..."
"$SECURITY_BIN" add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w "$CONTROL_PLANE_API_KEY" >/dev/null

say "Creating tunnel-client profile '$PROFILE'..."
export CONTROL_PLANE_API_KEY
"$TUNNEL_CLIENT_BIN" init \
  --sample sample_mcp_stdio_local \
  --profile "$PROFILE" \
  --tunnel-id "$CONTROL_PLANE_TUNNEL_ID" \
  --mcp-command "$BIN_DIR/darwinrelay"

say "Running tunnel diagnostics..."
"$TUNNEL_CLIENT_BIN" doctor --profile "$PROFILE" --explain
unset CONTROL_PLANE_API_KEY

PLIST_PATH="$PLIST_DIR/$LABEL.plist"
PATH_VALUE="$(dirname "$NODE_BIN"):$(dirname "$TUNNEL_CLIENT_BIN"):$BIN_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ "$CODEX_BIN" == /* ]]; then
  PATH_VALUE="$(dirname "$CODEX_BIN"):$PATH_VALUE"
fi

HOME_XML="$(xml_sed_value "$HOME")"
PATH_XML="$(xml_sed_value "$PATH_VALUE")"
INSTALL_XML="$(xml_sed_value "$INSTALL_DIR")"
TUNNEL_BIN_XML="$(xml_sed_value "$TUNNEL_CLIENT_BIN")"
CODEX_BIN_XML="$(xml_sed_value "$CODEX_BIN")"
PROFILE_XML="$(xml_sed_value "$PROFILE")"
DATA_XML="$(xml_sed_value "$DATA_DIR")"
LOG_XML="$(xml_sed_value "$LOG_DIR")"
UNLOCK_XML="$(xml_sed_value "$UNLOCK_FILE")"
AUDIT_XML="$(xml_sed_value "$AUDIT_MODE")"
SHELL_XML="$(xml_sed_value "$BRIDGE_SHELL")"
KEYCHAIN_SERVICE_XML="$(xml_sed_value "$KEYCHAIN_SERVICE")"
KEYCHAIN_ACCOUNT_XML="$(xml_sed_value "$KEYCHAIN_ACCOUNT")"

sed \
  -e "s|__HOME__|$HOME_XML|g" \
  -e "s|__PATH__|$PATH_XML|g" \
  -e "s|__INSTALL_DIR__|$INSTALL_XML|g" \
  -e "s|__TUNNEL_CLIENT_BIN__|$TUNNEL_BIN_XML|g" \
  -e "s|__CODEX_BIN__|$CODEX_BIN_XML|g" \
  -e "s|__PROFILE__|$PROFILE_XML|g" \
  -e "s|__DATA_DIR__|$DATA_XML|g" \
  -e "s|__LOG_DIR__|$LOG_XML|g" \
  -e "s|__UNLOCK_FILE__|$UNLOCK_XML|g" \
  -e "s|__AUDIT_MODE__|$AUDIT_XML|g" \
  -e "s|__BRIDGE_SHELL__|$SHELL_XML|g" \
  -e "s|__KEYCHAIN_SERVICE__|$KEYCHAIN_SERVICE_XML|g" \
  -e "s|__KEYCHAIN_ACCOUNT__|$KEYCHAIN_ACCOUNT_XML|g" \
  "$INSTALL_DIR/launchd/$LABEL.plist.template" > "$PLIST_PATH"

"$PLUTIL_BIN" -lint "$PLIST_PATH"
chmod 600 "$PLIST_PATH"

DOMAIN="gui/$(id -u)"
"$LAUNCHCTL_BIN" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
"$LAUNCHCTL_BIN" bootstrap "$DOMAIN" "$PLIST_PATH"
"$LAUNCHCTL_BIN" enable "$DOMAIN/$LABEL"
"$LAUNCHCTL_BIN" kickstart -k "$DOMAIN/$LABEL"

sleep 2
say "LaunchAgent status:"
"$LAUNCHCTL_BIN" print "$DOMAIN/$LABEL" | head -80 || true

cat <<OUT

Installed successfully.

Bridge command:       $BIN_DIR/darwinrelay
Tunnel profile:       $PROFILE
Tunnel ID:            $CONTROL_PLANE_TUNNEL_ID
LaunchAgent:          $PLIST_PATH
Full-access unlock:   $UNLOCK_FILE
Bridge audit log:     $LOG_DIR/audit.jsonl
Tunnel stdout log:    $LOG_DIR/tunnel.stdout.log
Tunnel stderr log:    $LOG_DIR/tunnel.stderr.log

Next:
1. Open ChatGPT Settings -> Security and login and enable Developer mode.
2. Open ChatGPT Plugins, press +, choose Tunnel, and select/paste $CONTROL_PLANE_TUNNEL_ID.
3. Review and enable the discovered tools. ChatGPT-level confirmation policy remains separate from this unrestricted local bridge.
4. Start a new Chat conversation, select the app, and call bridge_status.
5. If you use Codex history, call codex_thread_list and then codex_thread_read for one of your own persisted threads.

Run diagnostics at any time:
  $INSTALL_DIR/scripts/doctor.sh

The tunnel-client health UI normally appears at http://127.0.0.1:8080/ui while the service is running.
OUT
