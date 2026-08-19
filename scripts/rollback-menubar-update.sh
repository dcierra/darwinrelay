#!/bin/bash
set -euo pipefail

APP_DIR="${DARWINRELAY_APP_INSTALL_DIR:-/Applications}"
APP="$APP_DIR/DarwinRelay.app"
ROLLBACK="$APP_DIR/.DarwinRelay.app.rollback"
FAILED="$APP_DIR/.DarwinRelay.app.failed.$$"

[[ -d "$ROLLBACK" ]] || { printf 'No rollback bundle found at %s\n' "$ROLLBACK" >&2; exit 66; }
codesign --verify --deep --strict "$ROLLBACK"

mv "$APP" "$FAILED"
if mv "$ROLLBACK" "$APP" && codesign --verify --deep --strict "$APP"; then
  rm -rf "$FAILED"
  printf 'Rolled back DarwinRelay.app without restarting the running transport.\n'
  exit 0
fi

rm -rf "$APP"
mv "$FAILED" "$APP"
printf 'Rollback failed; restored the pre-attempt installed bundle.\n' >&2
exit 1
