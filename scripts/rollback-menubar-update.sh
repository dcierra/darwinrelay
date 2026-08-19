#!/bin/bash
set -euo pipefail

APP_DIR="${MAC_DEV_BRIDGE_APP_INSTALL_DIR:-/Applications}"
APP="$APP_DIR/MacDevBridge.app"
ROLLBACK="$APP_DIR/.MacDevBridge.app.rollback"
FAILED="$APP_DIR/.MacDevBridge.app.failed.$$"

[[ -d "$ROLLBACK" ]] || { printf 'No rollback bundle found at %s\n' "$ROLLBACK" >&2; exit 66; }
codesign --verify --deep --strict "$ROLLBACK"

mv "$APP" "$FAILED"
if mv "$ROLLBACK" "$APP" && codesign --verify --deep --strict "$APP"; then
  rm -rf "$FAILED"
  printf 'Rolled back MacDevBridge.app without restarting the running transport.\n'
  exit 0
fi

rm -rf "$APP"
mv "$FAILED" "$APP"
printf 'Rollback failed; restored the pre-attempt installed bundle.\n' >&2
exit 1
