#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-deploy-pids.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
DATA="$TMP/data"
mkdir -p "$DATA"
printf '103\n' > "$DATA/cloudflared.pid"

cat > "$TMP/ps" <<'PS'
#!/bin/bash
if [[ "$1" == "-o" && "$2" == "comm=" && "$3" == "-p" ]]; then
  case "$4" in
    103) printf '/opt/homebrew/bin/cloudflared\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
# Put an unrelated cloudflared before the DarwinRelay-owned row. Ownership must
# come from the pidfile, not from whichever command-line match appears first.
printf '%s\n' \
  '101 /Applications/DarwinRelay.app/Contents/MacOS/DarwinRelay --start' \
  '102 /opt/homebrew/bin/node /repo with spaces/mcp-http.mjs' \
  '104 /opt/homebrew/bin/cloudflared tunnel --config /tmp/other.yml run other-service' \
  '103 /opt/homebrew/bin/cloudflared tunnel --config /tmp/config.yml run darwinrelay'
for i in $(seq 1 20000); do
  printf '%s filler-process-%s --arg value\n' "$((1000+i))" "$i"
done
PS
chmod +x "$TMP/ps"

PS_BIN="$TMP/ps"
DARWINRELAY_DATA_DIR="$DATA"
export PS_BIN DARWINRELAY_DATA_DIR
# shellcheck source=../scripts/deploy-menubar-update.sh
# shellcheck disable=SC1091
source "$ROOT/scripts/deploy-menubar-update.sh"

[[ "$(pid_for_process_name DarwinRelay)" == "101" ]]
[[ "$(pid_for_command_contains '/repo with spaces/mcp-http.mjs')" == "102" ]]
[[ "$(pid_for_command_contains 'cloudflared tunnel')" == "104" ]]
[[ "$(pid_for_recorded_executable "$DATA/cloudflared.pid" cloudflared)" == "103" ]]
[[ -z "$(pid_for_process_name DefinitelyMissingProcess)" ]]

echo "deploy menubar pid discovery test passed"
