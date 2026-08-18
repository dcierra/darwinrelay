#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
SOURCES=("$ROOT/desktop-helper/MacUIHelper.swift" "$ROOT/desktop-helper/DesktopAdvanced.swift")
xcrun swiftc -typecheck -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework ScreenCaptureKit \
  -framework Carbon \
  -framework Vision \
  "${SOURCES[@]}"
