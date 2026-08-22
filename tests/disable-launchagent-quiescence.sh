#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-disable-launchagent.XXXXXX")"
DATA="$TMP/data"
mkdir -p "$DATA/jobs"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/launchctl" <<'SH2'
#!/bin/bash
set -euo pipefail
STATE_DIR="${MOCK_LAUNCHCTL_STATE_DIR:?}"
LOG="$STATE_DIR/calls.log"
printf '%s\n' "$*" >> "$LOG"
cmd="${1:-}"; target="${2:-}"
case "$cmd" in
  print)
    case "$target" in
      */io.github.dcierra.darwinrelay.tunnel)
        printf 'Could not find service\n' >&2
        exit 3
        ;;
      */io.github.dcierra.darwinrelay.http)
        mode="$(cat "$STATE_DIR/http.state" 2>/dev/null || echo absent)"
        case "$mode" in
          loaded|stuck)
            printf 'state = running\npid = 12345\n'
            exit 0
            ;;
          pending:*)
            n="${mode#pending:}"
            if (( n > 0 )); then
              printf 'pending:%s\n' "$((n - 1))" > "$STATE_DIR/http.state"
              printf 'state = running\npid = 12345\n'
              exit 0
            fi
            rm -f "$STATE_DIR/http.state"
            printf 'Could not find service\n' >&2
            exit 3
            ;;
          *)
            printf 'Could not find service\n' >&2
            exit 3
            ;;
        esac
        ;;
    esac
    printf 'Could not find service\n' >&2
    exit 3
    ;;
  disable)
    printf 'disabled\n' > "$STATE_DIR/disabled"
    exit 0
    ;;
  bootout)
    [[ -f "$STATE_DIR/disabled" ]] || { echo 'bootout before disable' >&2; exit 9; }
    mode="$(cat "$STATE_DIR/http.state" 2>/dev/null || echo absent)"
    if [[ "$mode" == "stuck" ]]; then
      exit 0
    fi
    printf 'pending:3\n' > "$STATE_DIR/http.state"
    exit 0
    ;;
  *)
    echo "unexpected launchctl command: $*" >&2
    exit 9
    ;;
esac
SH2
chmod +x "$TMP/launchctl"

run_disable() {
  DARWINRELAY_DATA_DIR="$DATA" \
  DARWINRELAY_UNLOCK_FILE="$DATA/FULL_ACCESS_ENABLED" \
  DARWINRELAY_PERSONAL_APPROVAL_FILE="$DATA/PERSONAL_BROWSER_APPROVED" \
  DARWINRELAY_FOREGROUND_GUI_APPROVAL_FILE="$DATA/FOREGROUND_GUI_APPROVED" \
  DARWINRELAY_HTTP_PORT=47879 \
  DARWINRELAY_INSTALL_DIR="$ROOT" \
  DARWINRELAY_LAUNCHAGENT_STOP_ATTEMPTS="${1:-10}" \
  MOCK_LAUNCHCTL_STATE_DIR="$TMP" \
  LAUNCHCTL_BIN="$TMP/launchctl" \
    "$ROOT/scripts/disable.sh"
}

# bootout may return before launchd has removed the service. The kill switch must
# disable first and wait until print proves the label absent.
: > "$TMP/calls.log"
printf 'loaded\n' > "$TMP/http.state"
OUT="$TMP/async.out"
run_disable 10 >"$OUT" 2>&1
grep -Fq 'Stopped and disabled LaunchAgent: io.github.dcierra.darwinrelay.http' "$OUT"
grep -Fq 'Disabled. Re-checked after SIGKILL' "$OUT"
python3 - "$TMP/calls.log" <<'PY'
from pathlib import Path
import sys
calls=Path(sys.argv[1]).read_text().splitlines()
disable=next(i for i,x in enumerate(calls) if x.startswith('disable ') and x.endswith('io.github.dcierra.darwinrelay.http'))
bootout=next(i for i,x in enumerate(calls) if x.startswith('bootout ') and x.endswith('io.github.dcierra.darwinrelay.http'))
post=[i for i,x in enumerate(calls) if i>bootout and x.startswith('print ') and x.endswith('io.github.dcierra.darwinrelay.http')]
assert disable < bootout
assert len(post) >= 4, calls
PY

# If the service never disappears, a successful bootout return is not enough.
# Fail closed instead of killing children while launchd can respawn them.
: > "$TMP/calls.log"
rm -f "$TMP/disabled"
printf 'stuck\n' > "$TMP/http.state"
OUT2="$TMP/stuck.out"
set +e
run_disable 3 >"$OUT2" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]
grep -Fq 'STILL loaded after bootout; refusing to claim containment' "$OUT2"
grep -Fq 'PARTIALLY disabled' "$OUT2"

echo 'disable LaunchAgent quiescence test passed'
