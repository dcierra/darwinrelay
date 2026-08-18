#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
xcrun swiftc -typecheck \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$ROOT/menubar/MenuBarApp.swift"
