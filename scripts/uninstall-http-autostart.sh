#!/bin/bash
set -euo pipefail
LABEL="io.github.dcierra.darwinrelay.http"
DOMAIN="gui/$(id -u)"
PLIST_DIR="${DARWINRELAY_PLIST_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$PLIST_DIR/$LABEL.plist"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
if [[ -n "$LAUNCHCTL_BIN" && -x "$LAUNCHCTL_BIN" ]]; then
  "$LAUNCHCTL_BIN" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
fi
rm -f "$PLIST"
printf 'Removed HTTP/Cloudflare autostart: %s\n' "$PLIST"
