#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-update-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DARWINRELAY_UPDATE_LIBRARY_ONLY=1 source "$ROOT/scripts/update.sh"

is_canonical_origin https://github.com/dcierra/darwinrelay
is_canonical_origin https://github.com/dcierra/darwinrelay.git
is_canonical_origin git@github.com:dcierra/darwinrelay.git
if is_canonical_origin https://github.com/someone/darwinrelay; then exit 1; fi
if is_canonical_origin /tmp/darwinrelay; then exit 1; fi

[[ "$(semver_cmp v0.6.4 v0.6.4)" == 0 ]]
[[ "$(semver_cmp v0.6.5 v0.6.4)" == 1 ]]
[[ "$(semver_cmp v0.6.4 v0.7.0)" == -1 ]]
[[ "$(semver_cmp v1.0.0 v0.99.99)" == 1 ]]
if is_release_tag v0.6.4-beta.1; then exit 1; fi
if is_release_tag latest; then exit 1; fi

mkdir -p "$TMP/work"
git -C "$TMP/work" init -q
git -C "$TMP/work" config user.email test@example.invalid
git -C "$TMP/work" config user.name Test
printf 'x\n' > "$TMP/work/file"
git -C "$TMP/work" add file
git -C "$TMP/work" commit -qm init
for tag in v0.6.4 v0.10.0 v1.0.0 v0.9.12; do git -C "$TMP/work" tag "$tag"; done
git -C "$TMP/work" tag v2.0.0-beta.1
[[ "$(latest_stable_tag_from_origin "$TMP/work")" == v1.0.0 ]]

# Structural safety invariants: never destroy local Git work to make an update fit.
if grep -Eq '^[[:space:]]*git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-|pull([[:space:]]|$))' "$ROOT/scripts/update.sh"; then
  echo "destructive Git command found in updater" >&2
  exit 1
fi
grep -Fq 'CORE VERDICT: READY' "$ROOT/scripts/update.sh"
grep -Fq 'rollback-menubar-update.sh' "$ROOT/scripts/update.sh"
grep -Fq 'check:integrity' "$ROOT/scripts/update.sh"
grep -Fq 'Refusing to update a modified checkout' "$ROOT/scripts/update.sh"
grep -Fq 'Refusing moved tag' "$ROOT/scripts/update.sh"


# The updater must be able to use a target release's corrected kill-switch before
# changing HEAD; otherwise a bug in the currently installed disable.sh can make
# the update path impossible to repair.
# shellcheck disable=SC2016
pattern='git show "${TARGET_SHA}:scripts/disable.sh"'
grep -Fq "$pattern" "$ROOT/scripts/update.sh"
grep -Fq 'TARGET_DISABLE_EXPECTED=' "$ROOT/scripts/update.sh"
# shellcheck disable=SC2016
pattern='DARWINRELAY_INSTALL_DIR="$ROOT" "$TARGET_DISABLE_SCRIPT"'
grep -Fq "$pattern" "$ROOT/scripts/update.sh"

# LaunchAgent ownership is part of update success, not merely localhost health.
cat > "$TMP/ps" <<'SH'
#!/bin/bash
if [[ "$1" == "-axo" ]]; then
  printf '%s\n' \
    '101 /Applications/DarwinRelay.app/Contents/MacOS/DarwinRelay --start' \
    '102 /opt/homebrew/bin/node /tmp/other.mjs'
  exit 0
fi
exit 1
SH
chmod +x "$TMP/ps"
PS_BIN="$TMP/ps"
[[ "$(darwinrelay_menu_pids)" == "101" ]]

cat > "$TMP/launchctl" <<'SH'
#!/bin/bash
if [[ "$1" == "print" ]]; then
  cat <<'OUT'
gui/501/io.github.dcierra.darwinrelay.http = {
    state = running
    pid = 101
}
OUT
  exit 0
fi
exit 1
SH
chmod +x "$TMP/launchctl"
LAUNCHCTL_BIN="$TMP/launchctl"
[[ "$(launchagent_running_pid gui/501 io.github.dcierra.darwinrelay.http)" == "101" ]]

# Native desktop readiness is measured through the authenticated live MCP probe,
# never by launching MacUIHelper directly from the updater's Terminal/iTerm TCC context.
ui_status_json_ready '{"accessibilityTrusted":true,"screenRecordingGranted":true,"postEventsGranted":true}'
if ui_status_json_ready '{"accessibilityTrusted":true,"screenRecordingGranted":false,"postEventsGranted":true}'; then
  echo "ui_status readiness accepted a missing permission" >&2
  exit 1
fi
cat > "$TMP/ui-probe.mjs" <<'JS'
const f = process.env.DR_TEST_COUNT_FILE;
const fs = await import('node:fs');
let n = 0;
try { n = Number(fs.readFileSync(f, 'utf8')) || 0; } catch {}
n += 1;
fs.writeFileSync(f, String(n));
const ready = n >= 3;
process.stdout.write(JSON.stringify({accessibilityTrusted:ready,screenRecordingGranted:ready,postEventsGranted:ready})+'\n');
JS
: > "$TMP/token"
DR_TEST_COUNT_FILE="$TMP/ui-count" wait_runtime_ui_status_ready "$TMP/ui-probe.mjs" "$TMP/token" 8787 5 0.01
[[ "$(cat "$TMP/ui-count")" == 3 ]]
grep -Fq 'Native desktop baseline: READY via live MCP runtime.' "$ROOT/scripts/update.sh"
grep -Fq 'Native desktop permissions preserved after update via live MCP runtime.' "$ROOT/scripts/update.sh"
grep -Fq -- '--tool ui_status' "$ROOT/scripts/update.sh"
grep -Fq 'record_candidate_failpoint after_validation' "$ROOT/scripts/update.sh"
grep -Fq 'DARWINRELAY_UPDATE_CANDIDATE_MARKER_FILE' "$ROOT/scripts/update.sh"
grep -Fq 'Candidate updater failed before the expected' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'EXPECTED_MARKER="$EXPECTED_POINT $CANDIDATE_SHA"' "$ROOT/scripts/test-update-candidate.sh"

grep -Fq 'Re-establish a contained baseline immediately' "$ROOT/scripts/update.sh"
grep -Fq 'LAUNCHAGENT_PID="$(wait_launchagent_running "$DOMAIN" "$SERVICE_LABEL")"' "$ROOT/scripts/update.sh"
grep -Fq 'HTTP LaunchAgent owns the live menu runtime' "$ROOT/scripts/update.sh"

# Update deployment runs only after authority is stopped, so it must not apply
# the separate zero-downtime PID-preservation contract. Rollback must inspect
# real app versions rather than rely on a flag set after deploy returns success.
grep -Fq 'DARWINRELAY_DEPLOY_VERIFY_RUNTIME_PIDS=0' "$ROOT/scripts/update.sh"
grep -Fq 'restore_old_app' "$ROOT/scripts/update.sh"
if grep -Fq 'APP_SWAPPED' "$ROOT/scripts/update.sh"; then
  echo "updater still relies on post-success APP_SWAPPED state" >&2
  exit 1
fi

python3 - "$ROOT/scripts/update.sh" <<'PY2'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
anchor=s.index('Re-establish a contained baseline immediately')
second_disable=s.index('DARWINRELAY_INSTALL_DIR="$ROOT" "$TARGET_DISABLE_SCRIPT"', anchor)
stop=s.index('stop_all_menu_instances', second_disable)
bootstrap=s.index('launchctl bootstrap "$DOMAIN" "$SERVICE_PLIST"', stop)
owned=s.index('LAUNCHAGENT_PID="$(wait_launchagent_running', bootstrap)
assert second_disable < stop < bootstrap < owned
rollback=s.index('rollback_update()')
old_checkout=s.index('git checkout --detach "$OLD_SHA"', rollback)
restore=s.index('restore_old_app', old_checkout)
assert old_checkout < restore
assert 'DARWINRELAY_DEPLOY_VERIFY_RUNTIME_PIDS=0' in s
assert 'APP_SWAPPED' not in s
PY2


# Public updater stays release-only. Unpublished SHA testing is reachable only
# through the explicit maintainer acknowledgement and separate harness.
grep -Fq 'DARWINRELAY_UPDATE_CANDIDATE_SHA' "$ROOT/scripts/update.sh"
grep -Fq 'I_UNDERSTAND_THIS_INSTALLS_UNPUBLISHED_DARWINRELAY_CODE' "$ROOT/scripts/update.sh"
grep -Fq 'after_app_install|after_validation' "$ROOT/scripts/update.sh"
grep -Fq 'scripts/test-update-candidate.sh' "$ROOT/AGENTS.md"
if grep -Fq -- '--candidate' "$ROOT/scripts/update.sh"; then
  echo "public updater unexpectedly exposes arbitrary candidate CLI" >&2
  exit 1
fi
grep -Fq 'Candidate worktree must be clean and committed.' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'Candidate and installed checkout must share the same canonical Git object store.' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'Candidate full round-trip passed' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'Candidate rollback check passed' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'competing DarwinRelay launchd labels exist' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'menu ownership does not match the canonical LaunchAgent' "$ROOT/scripts/test-update-candidate.sh"
grep -Fq 'Candidate environment preflight passed' "$ROOT/scripts/test-update-candidate.sh"

echo "manual updater test passed"
