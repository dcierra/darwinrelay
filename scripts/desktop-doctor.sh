#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
if [[ -n "${DARWINRELAY_UI_HELPER:-}" ]]; then
  HELPER="$DARWINRELAY_UI_HELPER"
elif [[ -x "/Applications/DarwinRelay.app/Contents/Helpers/MacUIHelper" ]]; then
  HELPER="/Applications/DarwinRelay.app/Contents/Helpers/MacUIHelper"
else
  HELPER="$ROOT/bin/MacUIHelper"
fi
TEMP_HELPER=""
OPEN=0
REQUEST=0

usage() {
  cat <<'TXT'
Usage: scripts/desktop-doctor.sh [--request] [--open]

Checks the permissions of the SAME MacUIHelper binary used by the installed DarwinRelay:
  Accessibility, Screen Recording, and CoreGraphics event posting.

--request asks macOS to present any supported permission prompts for MacUIHelper.
--open opens Privacy & Security after reporting status. Neither option edits TCC.
Full Disk Access is a separate filesystem permission; use scripts/tcc-doctor.sh.
TXT
}

for arg in "$@"; do
  case "$arg" in
    --open) OPEN=1 ;;
    --request) REQUEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'desktop-doctor: macOS only\n' >&2
  exit 69
fi

if [[ ! -x "$HELPER" ]]; then
  command -v xcrun >/dev/null 2>&1 || { printf 'MacUIHelper is not built and xcrun is unavailable. Install Xcode Command Line Tools.\n' >&2; exit 69; }
  TEMP_HELPER="$(mktemp "${TMPDIR:-/tmp}/MacUIHelper.doctor.XXXXXX")"
  trap 'rm -f "$TEMP_HELPER"' EXIT
  DARWINRELAY_UI_HELPER_OUTPUT="$TEMP_HELPER" "$HERE/build-mac-ui-helper.sh" >/dev/null
  HELPER="$TEMP_HELPER"
fi

if (( REQUEST )); then
  RAW="$(printf '{"request":true}\n' | "$HELPER" permissions)"
else
  RAW="$(printf '{}\n' | "$HELPER" status)"
fi
set +e
node - "$RAW" <<'NODE'
const raw = JSON.parse(process.argv[2]);
if (!raw.ok) {
  console.error(`desktop-doctor: ${raw.error?.code || "ERROR"}: ${raw.error?.message || "helper failed"}`);
  process.exit(1);
}
const s = raw.result || {};
const mark = (v) => v === true ? "GRANTED" : v === false ? "MISSING" : "UNKNOWN";
console.log(`Accessibility : ${mark(s.accessibilityTrusted)}`);
console.log(`Screen       : ${mark(s.screenRecordingGranted)}`);
console.log(`Post Events  : ${mark(s.postEventsGranted)}`);
console.log(`Helper       : ${s.helperVersion || "unknown"}`);
console.log("");
console.log("Full Disk Access is separate: run scripts/tcc-doctor.sh through the real DarwinRelay runtime chain for the authoritative check.");
if (s.accessibilityTrusted !== true || s.screenRecordingGranted !== true || s.postEventsGranted !== true) process.exitCode = 2;
NODE
RC=$?
set -e

if (( OPEN )); then
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' >/dev/null 2>&1 || true
fi
exit "$RC"
