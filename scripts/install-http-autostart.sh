#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LABEL="io.github.dcierra.darwinrelay.http"
DOMAIN="gui/$(id -u)"
PLIST_DIR="${DARWINRELAY_PLIST_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$PLIST_DIR/$LABEL.plist"
APP="${DARWINRELAY_APP_PATH:-/Applications/DarwinRelay.app}"
APP_EXE="$APP/Contents/MacOS/DarwinRelay"
LOG_DIR="${DARWINRELAY_LOG_DIR:-$HOME/Library/Logs/DarwinRelay}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
PLUTIL_BIN="${PLUTIL_BIN:-$(command -v plutil 2>/dev/null || true)}"
LOAD_NOW="${DARWINRELAY_HTTP_AUTOSTART_LOAD_NOW:-auto}"

[[ -x "$APP_EXE" ]] || { printf 'DarwinRelay executable not found: %s\n' "$APP_EXE" >&2; exit 69; }
[[ -n "$PLUTIL_BIN" && -x "$PLUTIL_BIN" ]] || { printf 'plutil is required.\n' >&2; exit 69; }

xml_sed_value() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" \
    | sed -e 's/[\\&|]/\\&/g'
}

mkdir -p "$PLIST_DIR" "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
APP_XML="$(xml_sed_value "$APP_EXE")"
ROOT_XML="$(xml_sed_value "$ROOT")"
HOME_XML="$(xml_sed_value "$HOME")"
STDOUT_XML="$(xml_sed_value "$LOG_DIR/autostart.stdout.log")"
STDERR_XML="$(xml_sed_value "$LOG_DIR/autostart.stderr.log")"
sed \
  -e "s|__APP_EXECUTABLE__|$APP_XML|g" \
  -e "s|__PACKAGE_DIR__|$ROOT_XML|g" \
  -e "s|__HOME__|$HOME_XML|g" \
  -e "s|__STDOUT_LOG__|$STDOUT_XML|g" \
  -e "s|__STDERR_LOG__|$STDERR_XML|g" \
  "$ROOT/launchd/$LABEL.plist.template" > "$PLIST"
"$PLUTIL_BIN" -lint "$PLIST" >/dev/null
chmod 600 "$PLIST"

app_running=0
if ps -axo command= | awk '{ exe=$1; n=split(exe, part, "/"); if (part[n] == "DarwinRelay") found=1 } END { exit(found ? 0 : 1) }'; then
  app_running=1
fi
case "$LOAD_NOW" in
  0|false|no) should_load=0 ;;
  1|true|yes) should_load=1 ;;
  auto) (( app_running == 0 )) && should_load=1 || should_load=0 ;;
  *) printf 'DARWINRELAY_HTTP_AUTOSTART_LOAD_NOW must be auto, 0, or 1.\n' >&2; exit 64 ;;
esac

if (( app_running == 1 && should_load == 1 )); then
  printf 'Refusing to load a second DarwinRelay instance while one is already running.\n' >&2
  printf 'Leave LOAD_NOW=auto/0; the LaunchAgent will take ownership on the next login.\n' >&2
  exit 73
fi

if (( should_load == 1 )); then
  [[ -n "$LAUNCHCTL_BIN" && -x "$LAUNCHCTL_BIN" ]] || { printf 'launchctl is required to load autostart now.\n' >&2; exit 69; }
  "$LAUNCHCTL_BIN" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  "$LAUNCHCTL_BIN" bootstrap "$DOMAIN" "$PLIST"
  "$LAUNCHCTL_BIN" enable "$DOMAIN/$LABEL"
  printf 'HTTP/Cloudflare autostart installed and loaded: %s\n' "$PLIST"
else
  printf 'HTTP/Cloudflare autostart installed for the next login: %s\n' "$PLIST"
  if (( app_running == 1 )); then
    printf 'The current DarwinRelay process was left untouched to avoid a duplicate instance.\n'
  fi
fi
