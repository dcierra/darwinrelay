#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set +e
"$ROOT/scripts/launch-manual-update.sh" >/tmp/dr-launcher-no-confirm.out 2>/tmp/dr-launcher-no-confirm.err
RC=$?
set -e
[[ "$RC" == 64 ]]
grep -Fq -- '--confirmed' /tmp/dr-launcher-no-confirm.err

cat > "$TMP/fake-updater" <<'UPDATER'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" > "$DR_TEST_UPDATER_ARGS"
exit "${DR_TEST_UPDATER_RC:-0}"
UPDATER
chmod 755 "$TMP/fake-updater"

cat > "$TMP/fake-open" <<'OPEN'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$1" > "$DR_TEST_OPEN_PATH"
cp "$1" "$DR_TEST_COMMAND_COPY"
OPEN
chmod 755 "$TMP/fake-open"

export DARWINRELAY_LAUNCHER_TEST_MODE=1
export DARWINRELAY_MANUAL_UPDATE_BIN="$TMP/fake-updater"
export DARWINRELAY_OPEN_BIN="$TMP/fake-open"
export DARWINRELAY_DATA_DIR="$TMP/data"
export DARWINRELAY_LOG_DIR="$TMP/logs"
export DR_TEST_OPEN_PATH="$TMP/open-path"
export DR_TEST_COMMAND_COPY="$TMP/update.command.copy"
export DR_TEST_UPDATER_ARGS="$TMP/updater-args"

"$ROOT/scripts/launch-manual-update.sh" --confirmed > "$TMP/launcher.out"
COMMAND_FILE="$(cat "$TMP/open-path")"
[[ -f "$COMMAND_FILE" ]]
[[ "$(stat -f '%Lp' "$COMMAND_FILE")" == 700 ]]
grep -Fq "$TMP/fake-updater" "$COMMAND_FILE"
grep -Fq 'latest --yes' "$COMMAND_FILE"
grep -Fq 'trap cleanup EXIT HUP INT TERM' "$COMMAND_FILE"
grep -Fq 'DarwinRelay manual update' "$COMMAND_FILE"

/bin/zsh "$COMMAND_FILE" </dev/null > "$TMP/command.out" 2>&1
[[ "$(cat "$TMP/updater-args")" == 'latest --yes' ]]
[[ ! -e "$COMMAND_FILE" ]]
[[ ! -d "$(dirname "$COMMAND_FILE")" ]]
grep -Fq 'DarwinRelay update finished successfully.' "$TMP/command.out"
grep -Fq 'DarwinRelay update finished successfully.' "$TMP/logs/update.log"

# A failed updater remains visible in the terminal/log and still self-cleans.
rm -f "$TMP/open-path" "$TMP/update.command.copy" "$TMP/updater-args"
export DR_TEST_UPDATER_RC=78
"$ROOT/scripts/launch-manual-update.sh" --confirmed > "$TMP/launcher-fail.out"
FAILED_COMMAND="$(cat "$TMP/open-path")"
set +e
/bin/zsh "$FAILED_COMMAND" </dev/null > "$TMP/command-fail.out" 2>&1
FAILED_RC=$?
set -e
[[ "$FAILED_RC" == 78 ]]
[[ ! -e "$FAILED_COMMAND" ]]
grep -Fq 'DarwinRelay update failed with exit code 78.' "$TMP/command-fail.out"
grep -Fq 'DarwinRelay update failed with exit code 78.' "$TMP/logs/update.log"

echo 'manual update launcher test passed'
