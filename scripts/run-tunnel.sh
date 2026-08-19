#!/bin/bash
set -euo pipefail

PROFILE="${DARWINRELAY_PROFILE:-darwinrelay}"
TUNNEL_CLIENT_BIN="${TUNNEL_CLIENT_BIN:-$HOME/.local/bin/tunnel-client}"
KEYCHAIN_SERVICE="${DARWINRELAY_KEYCHAIN_SERVICE:-OpenAI Secure MCP Tunnel Runtime}"
KEYCHAIN_ACCOUNT="${DARWINRELAY_KEYCHAIN_ACCOUNT:-$(id -un)}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"

if [[ ! -x "$TUNNEL_CLIENT_BIN" ]]; then
  printf 'tunnel-client not found or not executable: %s\n' "$TUNNEL_CLIENT_BIN" >&2
  exit 127
fi

if [[ -z "${CONTROL_PLANE_API_KEY:-}" ]]; then
  CONTROL_PLANE_API_KEY="$("$SECURITY_BIN" find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
  export CONTROL_PLANE_API_KEY
fi

if [[ -z "${CONTROL_PLANE_API_KEY:-}" ]]; then
  printf "No CONTROL_PLANE_API_KEY in environment or macOS Keychain service '%s'.\n" "$KEYCHAIN_SERVICE" >&2
  exit 78
fi

exec "$TUNNEL_CLIENT_BIN" run --profile "$PROFILE"
