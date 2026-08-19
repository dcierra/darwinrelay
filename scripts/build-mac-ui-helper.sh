#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
OUT="${MAC_DEV_BRIDGE_UI_HELPER_OUTPUT:-$ROOT/bin/MacUIHelper}"
SOURCES=("$ROOT/desktop-helper/MacUIHelper.swift" "$ROOT/desktop-helper/DesktopAdvanced.swift")
source "$HERE/codesign-runtime.sh"

command -v xcrun >/dev/null || { echo "xcrun not found; install Xcode Command Line Tools" >&2; exit 69; }
mkdir -p "$(dirname "$OUT")"

xcrun swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework Vision \
  -o "$OUT" \
  "${SOURCES[@]}"
chmod 0755 "$OUT"
mdb_sign_runtime "$OUT" "local.mac-developer-bridge.ui-helper"
codesign --verify --strict "$OUT" >/dev/null
echo "$OUT"
