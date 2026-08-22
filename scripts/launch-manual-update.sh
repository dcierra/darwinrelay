#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
LOG_DIR="${DARWINRELAY_LOG_DIR:-$HOME/Library/Logs/DarwinRelay}"

if [[ "${1:-}" != "--confirmed" || $# -ne 1 ]]; then
  echo "Usage: ./scripts/launch-manual-update.sh --confirmed" >&2
  echo "This launcher is intended for the DarwinRelay menu-bar confirmation flow." >&2
  exit 64
fi

UPDATER="$ROOT/scripts/update.sh"
OPEN_BIN="/usr/bin/open"
if [[ "${DARWINRELAY_LAUNCHER_TEST_MODE:-0}" == "1" ]]; then
  UPDATER="${DARWINRELAY_MANUAL_UPDATE_BIN:-$UPDATER}"
  OPEN_BIN="${DARWINRELAY_OPEN_BIN:-$OPEN_BIN}"
fi
[[ -x "$UPDATER" ]] || { echo "DarwinRelay updater is not executable: $UPDATER" >&2; exit 69; }
[[ -x "$OPEN_BIN" ]] || { echo "macOS opener is not executable: $OPEN_BIN" >&2; exit 69; }

mkdir -p "$DATA_DIR" "$LOG_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || true
RUN_DIR="$(mktemp -d "$DATA_DIR/manual-update.XXXXXX")"
chmod 700 "$RUN_DIR"
COMMAND_FILE="$RUN_DIR/DarwinRelay Update.command"
LOG_FILE="$LOG_DIR/update.log"

printf -v Q_UPDATER '%q' "$UPDATER"
printf -v Q_LOG '%q' "$LOG_FILE"
printf -v Q_SELF '%q' "$COMMAND_FILE"
printf -v Q_RUN_DIR '%q' "$RUN_DIR"
cat > "$COMMAND_FILE" <<EOF_COMMAND
#!/bin/zsh
set -u
SELF=$Q_SELF
RUN_DIR=$Q_RUN_DIR
LOG_FILE=$Q_LOG
cleanup() {
  rm -f "\$SELF" 2>/dev/null || true
  rmdir "\$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "\${LOG_FILE:h}" 2>/dev/null || true
touch "\$LOG_FILE" 2>/dev/null || true
chmod 600 "\$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "\$LOG_FILE") 2>&1
print "DarwinRelay manual update"
print "========================="
print "The app will restart while the canonical release updater runs."
print
set +e
$Q_UPDATER latest --yes
rc=\$?
set -e
print
if (( rc == 0 )); then
  print "DarwinRelay update finished successfully."
else
  print "DarwinRelay update failed with exit code \$rc."
  print "Review: \$LOG_FILE"
fi
if [[ -t 0 ]]; then
  print -n "Press Return to close this window… "
  read -r _ || true
fi
exit \$rc
EOF_COMMAND
chmod 700 "$COMMAND_FILE"

if ! "$OPEN_BIN" "$COMMAND_FILE"; then
  rm -f "$COMMAND_FILE" 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
  echo "Could not open the DarwinRelay update terminal." >&2
  exit 69
fi
printf 'Opened DarwinRelay updater: %s\n' "$COMMAND_FILE"
