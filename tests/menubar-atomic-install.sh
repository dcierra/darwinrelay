#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-menubar-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BUILD_APP="$TMP/build/DarwinRelay.app"
INSTALL_DIR="$TMP/Applications"
mkdir -p "$INSTALL_DIR"
EXPECTED_VERSION="$(node -p 'require(process.argv[1]).version' "$ROOT/package.json")"
EXPECTED_VERSION="${EXPECTED_VERSION%%-*}"

# --build-only must never install, even when an install directory is supplied.
BUILD_ONLY_APP="$TMP/build-only/DarwinRelay.app"
BUILD_ONLY_INSTALL="$TMP/build-only-install"
mkdir -p "$BUILD_ONLY_INSTALL"
DARWINRELAY_APP_OUTPUT="$BUILD_ONLY_APP" \
DARWINRELAY_APP_INSTALL_DIR="$BUILD_ONLY_INSTALL" \
  "$ROOT/menubar/build.sh" --build-only > "$TMP/build-only.out" 2> "$TMP/build-only.err"
[[ -d "$BUILD_ONLY_APP" ]] || { echo "build-only did not create the requested app bundle" >&2; exit 1; }
[[ ! -e "$BUILD_ONLY_INSTALL/DarwinRelay.app" ]] || { echo "build-only unexpectedly installed DarwinRelay.app" >&2; exit 1; }
if grep -q '^Installed:' "$TMP/build-only.out"; then
  echo "build-only output falsely claimed installation" >&2
  exit 1
fi

DARWINRELAY_APP_OUTPUT="$BUILD_APP" \
DARWINRELAY_APP_INSTALL_DIR="$INSTALL_DIR" \
DARWINRELAY_INSTALL_APP=1 \
  "$ROOT/menubar/build.sh" > "$TMP/build1.out" 2> "$TMP/build1.err"
TARGET="$INSTALL_DIR/DarwinRelay.app"
[[ -d "$TARGET" ]]
codesign --verify --deep --strict "$TARGET"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "installed app version mismatch: expected $EXPECTED_VERSION, got $ACTUAL_VERSION" >&2
  exit 1
fi
ACTUAL_PACKAGE_DIR="$(/usr/libexec/PlistBuddy -c 'Print :DarwinRelayPackageDirectory' "$TARGET/Contents/Info.plist")"
if [[ "$ACTUAL_PACKAGE_DIR" != "$ROOT" ]]; then
  echo "installed app source-package mismatch: expected $ROOT, got $ACTUAL_PACKAGE_DIR" >&2
  exit 1
fi

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
