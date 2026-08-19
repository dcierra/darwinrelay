#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-menubar-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BUILD_APP="$TMP/build/DarwinRelay.app"
INSTALL_DIR="$TMP/Applications"
mkdir -p "$INSTALL_DIR"

DARWINRELAY_APP_OUTPUT="$BUILD_APP" \
DARWINRELAY_APP_INSTALL_DIR="$INSTALL_DIR" \
DARWINRELAY_INSTALL_APP=1 \
  "$ROOT/menubar/build.sh" > "$TMP/build1.out" 2> "$TMP/build1.err"
TARGET="$INSTALL_DIR/DarwinRelay.app"
[[ -d "$TARGET" ]]
codesign --verify --deep --strict "$TARGET"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")" == "0.5.2" ]]

# Hosted CI has only ad-hoc signing, so a rebuilt binary intentionally has a new
# designated requirement. The override is test-local; production deploys refuse
# such a TCC identity change by default.
DARWINRELAY_ALLOW_SIGNING_CHANGE=1 \
DARWINRELAY_APP_OUTPUT="$BUILD_APP" \
DARWINRELAY_APP_INSTALL_DIR="$INSTALL_DIR" \
DARWINRELAY_INSTALL_APP=1 \
  "$ROOT/menubar/build.sh" > "$TMP/build2.out" 2> "$TMP/build2.err"
[[ -d "$INSTALL_DIR/.DarwinRelay.app.rollback" ]]
codesign --verify --deep --strict "$TARGET"
codesign --verify --deep --strict "$INSTALL_DIR/.DarwinRelay.app.rollback"

DARWINRELAY_APP_INSTALL_DIR="$INSTALL_DIR" "$ROOT/scripts/rollback-menubar-update.sh" > "$TMP/rollback.out"
codesign --verify --deep --strict "$TARGET"

echo "menubar atomic install test passed"
