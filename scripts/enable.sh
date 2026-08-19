#!/bin/bash
set -euo pipefail

LABEL="io.github.dcierra.darwinrelay.tunnel"
DOMAIN="gui/$(id -u)"
PLIST_DIR="${DARWINRELAY_PLIST_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$PLIST_DIR/$LABEL.plist"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
UNLOCK_FILE="${DARWINRELAY_UNLOCK_FILE:-$DATA_DIR/FULL_ACCESS_ENABLED}"
ACK="I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"

if [[ "${DARWINRELAY_FULL_ACCESS_ACK:-}" != "$ACK" ]]; then
  printf "Refusing to enable unrestricted access. Export DARWINRELAY_FULL_ACCESS_ACK='%s' first.\n" "$ACK" >&2
  exit 64
fi
if [[ ! -f "$PLIST" ]]; then
  printf 'LaunchAgent plist not found: %s\n' "$PLIST" >&2
  exit 66
fi
if [[ -z "$LAUNCHCTL_BIN" || ! -x "$LAUNCHCTL_BIN" ]]; then
  printf 'launchctl is unavailable.\n' >&2
  exit 69
fi

mkdir -p "$(dirname "$UNLOCK_FILE")"
printf '%s\n' "$ACK" > "$UNLOCK_FILE"
chmod 600 "$UNLOCK_FILE"
if ! "$LAUNCHCTL_BIN" print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  "$LAUNCHCTL_BIN" bootstrap "$DOMAIN" "$PLIST"
fi
"$LAUNCHCTL_BIN" enable "$DOMAIN/$LABEL"
"$LAUNCHCTL_BIN" kickstart -k "$DOMAIN/$LABEL"
printf 'DarwinRelay enabled and LaunchAgent started.\n'
