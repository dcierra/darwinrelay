#!/bin/bash
set -euo pipefail

LABEL="io.github.dcierra.darwinrelay.tunnel"
DOMAIN="gui/$(id -u)"
KEYCHAIN_SERVICE="${DARWINRELAY_KEYCHAIN_SERVICE:-OpenAI Secure MCP Tunnel Runtime}"
KEYCHAIN_ACCOUNT="${DARWINRELAY_KEYCHAIN_ACCOUNT:-$(id -un)}"
NEW_KEY="${CONTROL_PLANE_API_KEY:-}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"

if [[ -z "$NEW_KEY" && -t 0 ]]; then
  read -r -s -p "New tunnel runtime API key (input hidden): " NEW_KEY
  printf '\n'
fi
if [[ -z "$NEW_KEY" ]]; then
  printf 'Set CONTROL_PLANE_API_KEY or run interactively.\n' >&2
  exit 64
fi

"$SECURITY_BIN" add-generic-password -U -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w "$NEW_KEY" >/dev/null
unset NEW_KEY CONTROL_PLANE_API_KEY
if [[ -n "$LAUNCHCTL_BIN" && -x "$LAUNCHCTL_BIN" ]]; then
  "$LAUNCHCTL_BIN" kickstart -k "$DOMAIN/$LABEL"
fi
printf 'Tunnel runtime key replaced in Keychain and the bridge service restarted.\n'
