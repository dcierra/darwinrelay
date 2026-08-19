#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mdb-background-chrome-installer.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export MAC_DEV_BRIDGE_DATA_DIR="$TMP/data"
LOCAL_STATE="$HOME/Library/Application Support/Google/Chrome/Local State"
mkdir -p "$(dirname "$LOCAL_STATE")"
cat > "$LOCAL_STATE" <<'JSON'
{
  "profile": {
    "last_used": "Profile 2",
    "profiles_order": ["Default", "Profile 1", "Profile 2"],
    "info_cache": {
      "Default": {
        "name": "Sergey",
        "shortcut_name": "Sergey",
        "user_name": "sergey@example.test",
        "gaia_id": "123456789012345678901"
      },
      "Profile 1": {
        "name": "test",
        "shortcut_name": "test",
        "user_name": "",
        "gaia_id": ""
      },
      "Profile 2": {
        "name": "ChatGPT_1",
        "shortcut_name": "ChatGPT_1",
        "user_name": "",
        "gaia_id": ""
      }
    }
  }
}
JSON

# A signed-out last-used profile is not silently redirected to another signed-in
# profile. The operator must explicitly select a dedicated local profile.
if "$ROOT/scripts/install-background-chrome.sh" >"$TMP/default.out" 2>"$TMP/default.err"; then
  echo "installer unexpectedly accepted a signed-out last-used profile" >&2
  exit 1
fi
grep -q -- '--profile NAME_OR_DIRECTORY' "$TMP/default.err"

"$ROOT/scripts/install-background-chrome.sh" --profile ChatGPT_1 >"$TMP/local.out"
python3 - "$MAC_DEV_BRIDGE_DATA_DIR/chrome-background-profile.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1], encoding="utf-8"))
assert binding == {
    "profileDirectory": "Profile 2",
    "profileName": "ChatGPT_1",
    "bindingMode": "dedicated-local",
    "expectedSignedIn": False,
}, binding
PY

grep -Fq "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host.mjs" "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host"
! grep -Fq "$ROOT/scripts/chrome-native-host.mjs" "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host"
cmp -s "$ROOT/scripts/chrome-native-host.mjs" "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host.mjs"

"$ROOT/scripts/install-background-chrome.sh" --profile Default >"$TMP/signed.out"
python3 - "$MAC_DEV_BRIDGE_DATA_DIR/chrome-background-profile.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1], encoding="utf-8"))
assert binding["profileDirectory"] == "Default", binding
assert binding["profileName"] == "Sergey", binding
assert binding["bindingMode"] == "signed-in", binding
assert binding["expectedEmail"] == "sergey@example.test", binding
assert binding["expectedGaiaId"] == "123456789012345678901", binding
PY

MANIFEST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.alexanderradahl.mac_developer_bridge.json"
python3 - "$MANIFEST" "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["path"] == sys.argv[2], manifest
assert manifest["allowed_origins"] == ["chrome-extension://pcebfblnmcappinbenkmddjdapaoajgm/"], manifest
PY

"$ROOT/scripts/uninstall-background-chrome.sh" >"$TMP/uninstall.out"
[[ ! -e "$MANIFEST" ]]
[[ ! -e "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host" ]]
[[ ! -e "$MAC_DEV_BRIDGE_DATA_DIR/chrome-native-host.mjs" ]]
[[ ! -e "$MAC_DEV_BRIDGE_DATA_DIR/chrome-background-profile.json" ]]

echo "background Chrome installer test passed"
