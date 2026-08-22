#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-disable-cf.XXXXXX")"
DATA="$TMP/data"
mkdir -p "$DATA/jobs"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/launchctl" <<'SH'
#!/bin/bash
printf 'Could not find service\n' >&2
exit 3
SH
chmod +x "$TMP/launchctl"

cat > "$TMP/cloudflared.c" <<'C'
#include <unistd.h>
int main(void) { sleep(120); return 0; }
C
/usr/bin/clang "$TMP/cloudflared.c" -o "$TMP/cloudflared"

run_disable() {
  DARWINRELAY_DATA_DIR="$DATA" \
  DARWINRELAY_UNLOCK_FILE="$DATA/FULL_ACCESS_ENABLED" \
  DARWINRELAY_PERSONAL_APPROVAL_FILE="$DATA/PERSONAL_BROWSER_APPROVED" \
  DARWINRELAY_FOREGROUND_GUI_APPROVAL_FILE="$DATA/FOREGROUND_GUI_APPROVED" \
  DARWINRELAY_HTTP_PORT=47877 \
  DARWINRELAY_INSTALL_DIR="$ROOT" \
  LAUNCHCTL_BIN="$TMP/launchctl" \
    "$ROOT/scripts/disable.sh"
}

# An unrelated cloudflared with no DarwinRelay pidfile is outside our ownership
# boundary. The old global `pgrep -x cloudflared` implementation failed here.
"$TMP/cloudflared" & unrelated=$!
PIDS+=("$unrelated")
sleep 0.1
kill -0 "$unrelated"
OUT1="$TMP/unrelated.out"
run_disable >"$OUT1" 2>&1
kill -0 "$unrelated"
grep -Fq 'Nothing was running and no unlock file was present.' "$OUT1"

# A pid recorded by DarwinRelay and still naming cloudflared is owned and must
# be reclaimed. Other cloudflared peers must remain untouched.
"$TMP/cloudflared" & owned=$!
PIDS+=("$owned")
printf '%s\n' "$owned" > "$DATA/cloudflared.pid"
OUT2="$TMP/owned.out"
run_disable >"$OUT2" 2>&1
if kill -0 "$owned" 2>/dev/null; then
  printf 'recorded DarwinRelay cloudflared survived disable\n' >&2
  exit 1
fi
kill -0 "$unrelated"
[[ ! -e "$DATA/cloudflared.pid" ]]
grep -Fq "Stopping DarwinRelay cloudflared tunnel (pid $owned)" "$OUT2"
grep -Fq 'Disabled. Re-checked after SIGKILL: no recorded DarwinRelay tunnel' "$OUT2"

# A recycled/stale pidfile naming a non-cloudflared process must not be signalled.
/bin/sleep 120 & stale=$!
PIDS+=("$stale")
printf '%s\n' "$stale" > "$DATA/cloudflared.pid"
OUT3="$TMP/stale.out"
run_disable >"$OUT3" 2>&1
kill -0 "$stale"
[[ ! -e "$DATA/cloudflared.pid" ]]
grep -Fq "Ignoring stale pidfile: pid $stale is not cloudflared" "$OUT3"

printf 'disable cloudflared ownership test passed\n'
