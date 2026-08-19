#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-codeql-swift.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
TARGET="$(uname -m)-apple-macos13.0"

command -v xcrun >/dev/null || { echo 'xcrun not found' >&2; exit 69; }

# CodeQL only needs a faithful compile of every Swift source. Keep this build
# intentionally unoptimized and free of signing/install side effects so hosted
# security analysis is fast and deterministic.
xcrun swiftc -Onone -parse-as-library \
  -target "$TARGET" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework Vision \
  -o "$OUT/MacUIHelper" \
  "$ROOT/desktop-helper/MacUIHelper.swift" \
  "$ROOT/desktop-helper/DesktopAdvanced.swift"

xcrun swiftc -Onone -parse-as-library \
  -target "$TARGET" \
  -framework AppKit \
  -framework CoreGraphics \
  -o "$OUT/MacUICursorOverlay" \
  "$ROOT/desktop-helper/MacUICursorOverlay.swift"

xcrun swiftc -Onone \
  -target "$TARGET" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -o "$OUT/DarwinRelay" \
  "$ROOT/menubar/MenuBarApp.swift"

xcrun swiftc -Onone -parse-as-library \
  -target "$TARGET" \
  -framework AppKit \
  -o "$OUT/DarwinRelayDesktopFixture" \
  "$ROOT/tests/fixtures/DesktopControlFixture.swift"

printf 'CodeQL Swift build compiled all native targets.\n'
