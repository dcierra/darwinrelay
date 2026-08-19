#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
xcrun swiftc -typecheck -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$ROOT/menubar/MenuBarApp.swift" \
  "$ROOT/menubar/TunnelURL.swift"

for script in \
  "$ROOT/menubar/build.sh" \
  "$ROOT/scripts/deploy-menubar-update.sh" \
  "$ROOT/scripts/rollback-menubar-update.sh" \
  "$ROOT/scripts/install-http-autostart.sh" \
  "$ROOT/scripts/uninstall-http-autostart.sh"; do
  bash -n "$script"
done
plutil -lint "$ROOT/launchd/io.github.dcierra.darwinrelay.http.plist.template" >/dev/null
