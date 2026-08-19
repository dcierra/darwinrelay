#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mdb-menubar-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BUILD_APP="$TMP/build/MacDevBridge.app"
INSTALL_DIR="$TMP/Applications"
mkdir -p "$INSTALL_DIR"

MAC_DEV_BRIDGE_APP_OUTPUT="$BUILD_APP" \
MAC_DEV_BRIDGE_APP_INSTALL_DIR="$INSTALL_DIR" \
MAC_DEV_BRIDGE_INSTALL_APP=1 \
  "$ROOT/menubar/build.sh" > "$TMP/build1.out" 2> "$TMP/build1.err"
TARGET="$INSTALL_DIR/MacDevBridge.app"
[[ -d "$TARGET" ]]
codesign --verify --deep --strict "$TARGET"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")" == "0.5.2" ]]

# Hosted CI has only ad-hoc signing, so a rebuilt binary intentionally has a new
# designated requirement. The override is test-local; production deploys refuse
# such a TCC identity change by default.
MAC_DEV_BRIDGE_ALLOW_SIGNING_CHANGE=1 \
MAC_DEV_BRIDGE_APP_OUTPUT="$BUILD_APP" \
MAC_DEV_BRIDGE_APP_INSTALL_DIR="$INSTALL_DIR" \
MAC_DEV_BRIDGE_INSTALL_APP=1 \
  "$ROOT/menubar/build.sh" > "$TMP/build2.out" 2> "$TMP/build2.err"
[[ -d "$INSTALL_DIR/.MacDevBridge.app.rollback" ]]
codesign --verify --deep --strict "$TARGET"
codesign --verify --deep --strict "$INSTALL_DIR/.MacDevBridge.app.rollback"

MAC_DEV_BRIDGE_APP_INSTALL_DIR="$INSTALL_DIR" "$ROOT/scripts/rollback-menubar-update.sh" > "$TMP/rollback.out"
codesign --verify --deep --strict "$TARGET"

echo "menubar atomic install test passed"
