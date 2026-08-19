#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mdb-http-autostart.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/MacDevBridge.app"
mkdir -p "$APP/Contents/MacOS" "$TMP/home/Library/LaunchAgents" "$TMP/logs"
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/MacDevBridge"
chmod +x "$APP/Contents/MacOS/MacDevBridge"

HOME="$TMP/home" \
MAC_DEV_BRIDGE_APP_PATH="$APP" \
MAC_DEV_BRIDGE_PLIST_DIR="$TMP/home/Library/LaunchAgents" \
MAC_DEV_BRIDGE_LOG_DIR="$TMP/logs" \
MAC_DEV_BRIDGE_HTTP_AUTOSTART_LOAD_NOW=0 \
  "$ROOT/scripts/install-http-autostart.sh" > "$TMP/install.out"

PLIST="$TMP/home/Library/LaunchAgents/local.mac-developer-bridge.http.plist"
[[ -f "$PLIST" ]]
plutil -lint "$PLIST" >/dev/null
grep -Fq "$APP/Contents/MacOS/MacDevBridge" "$PLIST"
grep -Fq "$ROOT" "$PLIST"
grep -Fq '<key>SuccessfulExit</key><false/>' "$PLIST"
[[ "$(stat -f '%Lp' "$PLIST")" == "600" ]]

HOME="$TMP/home" MAC_DEV_BRIDGE_PLIST_DIR="$TMP/home/Library/LaunchAgents" LAUNCHCTL_BIN=/nonexistent \
  "$ROOT/scripts/uninstall-http-autostart.sh" > "$TMP/uninstall.out"
[[ ! -e "$PLIST" ]]

echo "http autostart test passed"
