#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-desktop-doctor-routing.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

OPEN_LOG="$TMP/open.log"
cat > "$TMP/open" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$OPEN_LOG"
SH
chmod +x "$TMP/open"
export OPEN_LOG

write_helper() {
  local ax="$1" screen="$2" post="$3"
  cat > "$TMP/helper" <<SH
#!/bin/bash
cat >/dev/null
printf '%s\n' '{"ok":true,"result":{"accessibilityTrusted":$ax,"screenRecordingGranted":$screen,"postEventsGranted":$post,"helperVersion":"test"}}'
SH
  chmod +x "$TMP/helper"
}

run_case() {
  local ax="$1" screen="$2" post="$3" expected="$4"
  : > "$OPEN_LOG"
  write_helper "$ax" "$screen" "$post"
  set +e
  DARWINRELAY_UI_HELPER="$TMP/helper" DARWINRELAY_OPEN_BIN="$TMP/open" \
    "$ROOT/scripts/desktop-doctor.sh" --open >"$TMP/out" 2>"$TMP/err"
  rc=$?
  set -e
  if [[ "$ax" == true && "$screen" == true && "$post" == true ]]; then
    [[ "$rc" -eq 0 ]] || { cat "$TMP/out"; cat "$TMP/err" >&2; exit 1; }
  else
    [[ "$rc" -eq 2 ]] || { cat "$TMP/out"; cat "$TMP/err" >&2; exit 1; }
  fi
  grep -Fq "?$expected" "$OPEN_LOG" || {
    printf 'expected %s, got:\n' "$expected" >&2
    cat "$OPEN_LOG" >&2
    exit 1
  }
}

run_case false true true Privacy_Accessibility
run_case true true false Privacy_Accessibility
run_case true false true Privacy_ScreenCapture
run_case true true true Privacy_Accessibility

printf 'desktop doctor permission routing test passed\n'
