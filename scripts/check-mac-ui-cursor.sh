#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
xcrun swiftc -typecheck -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework CoreGraphics \
  "$ROOT/desktop-helper/MacUICursorOverlay.swift"
