#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
OUT="${DARWINRELAY_UI_CURSOR_OUTPUT:-$ROOT/bin/MacUICursorOverlay}"
source "$HERE/codesign-runtime.sh"
command -v xcrun >/dev/null || { echo "xcrun not found; install Xcode Command Line Tools" >&2; exit 69; }
mkdir -p "$(dirname "$OUT")"
xcrun swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework CoreGraphics \
  -o "$OUT" "$ROOT/desktop-helper/MacUICursorOverlay.swift"
chmod 0755 "$OUT"
darwinrelay_sign_runtime "$OUT" "io.github.dcierra.darwinrelay.cursor-overlay"
codesign --verify --strict "$OUT" >/dev/null
echo "$OUT"
