#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-deploy-pids.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ps" <<'PS'
#!/bin/bash
# Put the wanted rows first and then enough output to reliably trigger SIGPIPE
# in the old `awk { print; exit }` implementation under pipefail.
printf '%s\n' \
  '101 /Applications/DarwinRelay.app/Contents/MacOS/DarwinRelay --start' \
  '102 /opt/homebrew/bin/node /repo with spaces/mcp-http.mjs' \
  '103 /opt/homebrew/bin/cloudflared tunnel --config /tmp/config.yml run darwinrelay'
for i in $(seq 1 20000); do
  printf '%s filler-process-%s --arg value\n' "$((1000+i))" "$i"
done
PS
chmod +x "$TMP/ps"

PS_BIN="$TMP/ps"
# shellcheck source=../scripts/deploy-menubar-update.sh
source "$ROOT/scripts/deploy-menubar-update.sh"

[[ "$(pid_for_process_name DarwinRelay)" == "101" ]]
[[ "$(pid_for_command_contains '/repo with spaces/mcp-http.mjs')" == "102" ]]
[[ "$(pid_for_command_contains 'cloudflared tunnel')" == "103" ]]
[[ -z "$(pid_for_process_name DefinitelyMissingProcess)" ]]

echo "deploy menubar pid discovery test passed"
