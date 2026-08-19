#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-single-instance.XXXXXX")"
FIRST=""
cleanup() {
  if [[ -n "$FIRST" ]]; then
    kill "$FIRST" >/dev/null 2>&1 || true
    sleep 0.1
    kill -9 "$FIRST" >/dev/null 2>&1 || true
    wait "$FIRST" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

BIN="$TMP/DarwinRelay"
DATA="$TMP/data"
LOGS="$TMP/logs"
mkdir -p "$DATA" "$LOGS"
xcrun swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -o "$BIN" \
  "$ROOT/menubar/MenuBarApp.swift"

DARWINRELAY_DATA_DIR="$DATA" DARWINRELAY_LOG_DIR="$LOGS" DARWINRELAY_HOME="$ROOT" \
  "$BIN" >"$TMP/first.out" 2>"$TMP/first.err" &
FIRST=$!
for _ in $(seq 1 50); do [[ -f "$DATA/menubar.lock" ]] && break; sleep 0.1; done
[[ -f "$DATA/menubar.lock" ]] || { cat "$TMP/first.err" >&2; echo "first menu instance did not acquire lock" >&2; exit 1; }
[[ "$(tr -d '[:space:]' < "$DATA/menubar.lock")" == "$FIRST" ]]
[[ "$(stat -f '%Lp' "$DATA/menubar.lock")" == "600" ]]
kill -0 "$FIRST"
# Lock acquisition happens before the first instance's own reclaimOrphans(). Wait
# for that synchronous startup baseline to finish before creating state whose
# preservation is attributed specifically to the duplicate instance.
sleep 1
kill -0 "$FIRST"

# This state belongs to the first instance. The duplicate must not run
# reclaimOrphans() or applicationWillTerminate cleanup against it.
printf 'owned-by-first\n' > "$DATA/FULL_ACCESS_ENABLED"
printf '987654\n' > "$DATA/mcp-http.pid"
printf '987655\n' > "$DATA/cloudflared.pid"
BEFORE_UNLOCK="$(shasum -a 256 "$DATA/FULL_ACCESS_ENABLED" | awk '{print $1}')"
BEFORE_HTTP="$(cat "$DATA/mcp-http.pid")"
BEFORE_CF="$(cat "$DATA/cloudflared.pid")"

set +e
DARWINRELAY_DATA_DIR="$DATA" DARWINRELAY_LOG_DIR="$LOGS" DARWINRELAY_HOME="$ROOT" \
  "$BIN" >"$TMP/second.out" 2>"$TMP/second.err"
SECOND_RC=$?
set -e
[[ "$SECOND_RC" == 0 ]]
kill -0 "$FIRST"
[[ "$(tr -d '[:space:]' < "$DATA/menubar.lock")" == "$FIRST" ]]
[[ "$(shasum -a 256 "$DATA/FULL_ACCESS_ENABLED" | awk '{print $1}')" == "$BEFORE_UNLOCK" ]]
[[ "$(cat "$DATA/mcp-http.pid")" == "$BEFORE_HTTP" ]]
[[ "$(cat "$DATA/cloudflared.pid")" == "$BEFORE_CF" ]]

echo "menubar single-instance test passed"
