#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
MENU_SWIFT="$ROOT/menubar/MenuBarApp.swift"
xcrun swiftc -typecheck -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$MENU_SWIFT" \
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

# Presentation contract: the menu must identify the product/version, expose one
# concise health summary, keep transport/desktop/safety visible, and demote
# credentials/maintenance into submenus. These string assertions complement the
# Swift typecheck without requiring an interactive menu-bar session in CI.
grep -Fq 'DarwinRelay · v\(displayVersion)' "$MENU_SWIFT"
grep -Fq 'All systems operational' "$MENU_SWIFT"
grep -Fq 'Ready · bridge is stopped' "$MENU_SWIFT"
grep -Fq 'MCP transport: Running · localhost:' "$MENU_SWIFT"
grep -Fq 'Safety: Standard' "$MENU_SWIFT"
grep -Fq 'title: "Connection"' "$MENU_SWIFT"
grep -Fq 'title: "Diagnostics & Settings"' "$MENU_SWIFT"
grep -Fq 'menu.autoenablesItems = false' "$MENU_SWIFT"
grep -Fq 'connectionMenu.autoenablesItems = false' "$MENU_SWIFT"
