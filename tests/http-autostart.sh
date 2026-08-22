#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-http-autostart.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/DarwinRelay.app"
mkdir -p "$APP/Contents/MacOS" "$TMP/home/Library/LaunchAgents" "$TMP/logs"
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/DarwinRelay"
chmod +x "$APP/Contents/MacOS/DarwinRelay"

HOME="$TMP/home" \
DARWINRELAY_APP_PATH="$APP" \
DARWINRELAY_PLIST_DIR="$TMP/home/Library/LaunchAgents" \
DARWINRELAY_LOG_DIR="$TMP/logs" \
DARWINRELAY_HTTP_AUTOSTART_LOAD_NOW=0 \
  "$ROOT/scripts/install-http-autostart.sh" > "$TMP/install.out"

PLIST="$TMP/home/Library/LaunchAgents/io.github.dcierra.darwinrelay.http.plist"
[[ -f "$PLIST" ]]
plutil -lint "$PLIST" >/dev/null
grep -Fq "$APP/Contents/MacOS/DarwinRelay" "$PLIST"
grep -Fq "$ROOT" "$PLIST"
grep -Fq '<key>SuccessfulExit</key><false/>' "$PLIST"
if grep -Fq '<key>WorkingDirectory</key>' "$PLIST"; then
  echo "HTTP LaunchAgent must not chdir into the source checkout; launchd may lack TCC access to ~/Documents before the signed app starts" >&2
  exit 1
fi
[[ "$(stat -f '%Lp' "$PLIST")" == "600" ]]

# Auto mode must recognise an already-running DarwinRelay by process basename
# and leave launchctl alone. This guards the production failure where a second
# menu instance reclaimed the first instance's shared pidfiles/unlock state.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ps" <<'PS'
#!/bin/sh
printf '%s\n' '/Applications/DarwinRelay.app/Contents/MacOS/DarwinRelay'
PS
chmod +x "$TMP/bin/ps"
PATH="$TMP/bin:$PATH" \
HOME="$TMP/home" \
DARWINRELAY_APP_PATH="$APP" \
DARWINRELAY_PLIST_DIR="$TMP/home/Library/LaunchAgents" \
DARWINRELAY_LOG_DIR="$TMP/logs" \
DARWINRELAY_HTTP_AUTOSTART_LOAD_NOW=auto \
LAUNCHCTL_BIN=/nonexistent \
  "$ROOT/scripts/install-http-autostart.sh" > "$TMP/install-auto.out"
grep -Fq 'next login' "$TMP/install-auto.out"
grep -Fq 'current DarwinRelay process was left untouched' "$TMP/install-auto.out"

HOME="$TMP/home" DARWINRELAY_PLIST_DIR="$TMP/home/Library/LaunchAgents" LAUNCHCTL_BIN=/nonexistent \
  "$ROOT/scripts/uninstall-http-autostart.sh" > "$TMP/uninstall.out"
[[ ! -e "$PLIST" ]]

echo "http autostart test passed"
