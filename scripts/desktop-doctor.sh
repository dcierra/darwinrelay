#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
HELPER="${MAC_DEV_BRIDGE_UI_HELPER:-$ROOT/bin/MacUIHelper}"
TEMP_HELPER=""
OPEN=0

usage() {
  cat <<'TXT'
Usage: scripts/desktop-doctor.sh [--open]

Checks the non-prompting native desktop-control permissions used by MDB:
  Accessibility, Screen Recording, and CoreGraphics event posting.

It never modifies TCC. --open opens Privacy & Security after reporting status.
Full Disk Access is a separate filesystem permission; use scripts/tcc-doctor.sh.
TXT
}

case "${1:-}" in
  "") ;;
  --open) OPEN=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'desktop-doctor: macOS only\n' >&2
  exit 69
fi

if [[ ! -x "$HELPER" ]]; then
  command -v xcrun >/dev/null 2>&1 || { printf 'MacUIHelper is not built and xcrun is unavailable. Install Xcode Command Line Tools.\n' >&2; exit 69; }
  TEMP_HELPER="$(mktemp "${TMPDIR:-/tmp}/MacUIHelper.doctor.XXXXXX")"
  trap 'rm -f "$TEMP_HELPER"' EXIT
  MAC_DEV_BRIDGE_UI_HELPER_OUTPUT="$TEMP_HELPER" "$HERE/build-mac-ui-helper.sh" >/dev/null
  HELPER="$TEMP_HELPER"
fi

RAW="$(printf '{}\n' | "$HELPER" status)"
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
console.log("Full Disk Access is separate: run scripts/tcc-doctor.sh through the real MDB runtime chain for the authoritative check.");
if (s.accessibilityTrusted !== true || s.screenRecordingGranted !== true || s.postEventsGranted !== true) process.exitCode = 2;
NODE
RC=$?
set -e

if (( OPEN )); then
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' >/dev/null 2>&1 || true
fi
exit "$RC"
