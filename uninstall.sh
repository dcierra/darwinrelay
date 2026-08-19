#!/bin/bash
set -euo pipefail

LABEL="com.openai.mac-developer-bridge-tunnel"
HTTP_LABEL="local.mac-developer-bridge.http"
DOMAIN="gui/$(id -u)"
PLIST_DIR="${MAC_DEV_BRIDGE_PLIST_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$PLIST_DIR/$LABEL.plist"
HTTP_PLIST="$PLIST_DIR/$HTTP_LABEL.plist"
INSTALL_DIR="${MAC_DEV_BRIDGE_INSTALL_DIR:-$HOME/.local/share/mac-developer-bridge}"
BIN_DIR="${MAC_DEV_BRIDGE_BIN_DIR:-$HOME/.local/bin}"
KEYCHAIN_SERVICE="${MAC_DEV_BRIDGE_KEYCHAIN_SERVICE:-OpenAI Secure MCP Tunnel Runtime}"
KEYCHAIN_ACCOUNT="${MAC_DEV_BRIDGE_KEYCHAIN_ACCOUNT:-$(id -un)}"
DATA_DIR="${MAC_DEV_BRIDGE_DATA_DIR:-$HOME/Library/Application Support/MacDeveloperBridge}"
UNLOCK_FILE="${MAC_DEV_BRIDGE_UNLOCK_FILE:-$DATA_DIR/FULL_ACCESS_ENABLED}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"

if [[ -n "$LAUNCHCTL_BIN" && -x "$LAUNCHCTL_BIN" ]]; then
  "$LAUNCHCTL_BIN" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  "$LAUNCHCTL_BIN" bootout "$DOMAIN/$HTTP_LABEL" >/dev/null 2>&1 || true
fi
rm -f "$PLIST" "$HTTP_PLIST" "$BIN_DIR/mac-developer-bridge"
rm -rf "$INSTALL_DIR"
rm -f "$UNLOCK_FILE"
"$SECURITY_BIN" delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
printf '%s\n' "Removed the bridge, LaunchAgent, symlink, full-access unlock, and Keychain runtime key. Audit/job logs and tunnel-client profile files were retained for auditability."
