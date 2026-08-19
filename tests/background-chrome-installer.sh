#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-background-chrome-installer.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export DARWINRELAY_DATA_DIR="$TMP/data"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/pgrep" <<'SH'
#!/bin/sh
[[ "${DARWINRELAY_TEST_CHROME_RUNNING:-0}" == "1" ]] && exit 0
exit 1
SH
chmod +x "$FAKE_BIN/pgrep"
export PATH="$FAKE_BIN:$PATH"
export DARWINRELAY_TEST_CHROME_RUNNING=0
LOCAL_STATE="$HOME/Library/Application Support/Google/Chrome/Local State"
mkdir -p "$(dirname "$LOCAL_STATE")"
cat > "$LOCAL_STATE" <<'JSON'
{
  "profile": {
    "last_used": "Profile 2",
    "profiles_order": ["Default", "Profile 1", "Profile 2"],
    "info_cache": {
      "Default": {
        "name": "Primary",
        "shortcut_name": "Primary",
        "user_name": "primary@example.test",
        "gaia_id": "123456789012345678901"
      },
      "Profile 1": {
        "name": "Test",
        "shortcut_name": "Test",
        "user_name": "",
        "gaia_id": ""
      },
      "Profile 2": {
        "name": "Legacy Local",
        "shortcut_name": "Legacy Local",
        "user_name": "",
        "gaia_id": ""
      }
    }
  }
}
JSON

# First-time profile creation refuses to rewrite Chrome Local State while Chrome
# is running. Existing profiles can still be rebound while Chrome is open.
export DARWINRELAY_TEST_CHROME_RUNNING=1
if "$ROOT/scripts/install-background-chrome.sh" >"$TMP/running.out" 2>"$TMP/running.err"; then
  echo "installer unexpectedly created a profile while Chrome was running" >&2
  exit 1
fi
grep -Fq 'Quit Chrome once' "$TMP/running.err"
! grep -Fq '"Profile 3"' "$LOCAL_STATE"
export DARWINRELAY_TEST_CHROME_RUNNING=0

# Default behavior creates a dedicated signed-out DarwinRelay profile instead of
# silently inheriting the operator's last-used or signed-in browser identity.
"$ROOT/scripts/install-background-chrome.sh" >"$TMP/default.out"
python3 - "$DARWINRELAY_DATA_DIR/chrome-background-profile.json" "$LOCAL_STATE" <<'PY'
import json, pathlib, sys
binding = json.load(open(sys.argv[1], encoding="utf-8"))
assert binding == {
    "profileDirectory": "Profile 3",
    "profileName": "DarwinRelay",
    "bindingMode": "dedicated-local",
    "expectedSignedIn": False,
}, binding
state = json.load(open(sys.argv[2], encoding="utf-8"))
entry = state["profile"]["info_cache"]["Profile 3"]
assert entry["name"] == "DarwinRelay", entry
assert entry["user_name"] == "", entry
assert state["profile"]["profiles_order"][-1] == "Profile 3", state["profile"]["profiles_order"]
prefs = pathlib.Path(sys.argv[2]).parent / "Profile 3" / "Preferences"
assert prefs.is_file(), prefs
assert json.load(open(prefs, encoding="utf-8"))["profile"]["name"] == "DarwinRelay"
PY
grep -Fq 'created by DarwinRelay' "$TMP/default.out"

# Re-running the default installer reuses the same dedicated profile and does not
# create an unbounded sequence of Profile N directories.
"$ROOT/scripts/install-background-chrome.sh" >"$TMP/default-again.out"
python3 - "$LOCAL_STATE" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert "Profile 4" not in state["profile"]["info_cache"], state["profile"]["info_cache"]
PY
! grep -Fq 'created by DarwinRelay' "$TMP/default-again.out"

# --use-current-profile is an explicit opt-in to the last-used browser identity
# and refuses a signed-out current profile instead of silently changing semantics.
if "$ROOT/scripts/install-background-chrome.sh" --use-current-profile >"$TMP/current.out" 2>"$TMP/current.err"; then
  echo "installer unexpectedly accepted a signed-out current profile" >&2
  exit 1
fi
grep -Fq 'is signed out' "$TMP/current.err"

# Explicitly selected signed-out profiles remain supported as dedicated-local.
"$ROOT/scripts/install-background-chrome.sh" --profile 'Legacy Local' >"$TMP/local.out"
python3 - "$DARWINRELAY_DATA_DIR/chrome-background-profile.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1], encoding="utf-8"))
assert binding == {
    "profileDirectory": "Profile 2",
    "profileName": "Legacy Local",
    "bindingMode": "dedicated-local",
    "expectedSignedIn": False,
}, binding
PY

# Explicit signed-in profile selection remains available.
"$ROOT/scripts/install-background-chrome.sh" --profile Default >"$TMP/signed.out"
python3 - "$DARWINRELAY_DATA_DIR/chrome-background-profile.json" <<'PY'
import json, sys
binding = json.load(open(sys.argv[1], encoding="utf-8"))
assert binding["profileDirectory"] == "Default", binding
assert binding["profileName"] == "Primary", binding
assert binding["bindingMode"] == "signed-in", binding
assert binding["expectedEmail"] == "primary@example.test", binding
assert binding["expectedGaiaId"] == "123456789012345678901", binding
PY

# The current-profile opt-in succeeds once the last-used profile is signed in.
python3 - "$LOCAL_STATE" <<'PY'
import json, os, sys
p=sys.argv[1]
data=json.load(open(p, encoding='utf-8'))
data['profile']['last_used']='Default'
t=p+'.tmp'
with open(t,'w',encoding='utf-8') as f:
    json.dump(data,f,indent=2); f.write('\n')
os.replace(t,p)
PY
"$ROOT/scripts/install-background-chrome.sh" --use-current-profile >"$TMP/current-signed.out"
python3 - "$DARWINRELAY_DATA_DIR/chrome-background-profile.json" <<'PY'
import json, sys
binding=json.load(open(sys.argv[1], encoding='utf-8'))
assert binding['profileDirectory']=='Default', binding
assert binding['bindingMode']=='signed-in', binding
PY

grep -Fq "$DARWINRELAY_DATA_DIR/chrome-native-host.mjs" "$DARWINRELAY_DATA_DIR/chrome-native-host"
! grep -Fq "$ROOT/scripts/chrome-native-host.mjs" "$DARWINRELAY_DATA_DIR/chrome-native-host"
cmp -s "$ROOT/scripts/chrome-native-host.mjs" "$DARWINRELAY_DATA_DIR/chrome-native-host.mjs"

MANIFEST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.dcierra.darwinrelay.json"
python3 - "$MANIFEST" "$DARWINRELAY_DATA_DIR/chrome-native-host" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["path"] == sys.argv[2], manifest
assert manifest["allowed_origins"] == ["chrome-extension://pfhahlehpahegefejooendokpkklgmgd/"], manifest
PY

"$ROOT/scripts/uninstall-background-chrome.sh" >"$TMP/uninstall.out"
[[ ! -e "$MANIFEST" ]]
[[ ! -e "$DARWINRELAY_DATA_DIR/chrome-native-host" ]]
[[ ! -e "$DARWINRELAY_DATA_DIR/chrome-native-host.mjs" ]]
[[ ! -e "$DARWINRELAY_DATA_DIR/chrome-background-profile.json" ]]
# Uninstalling the bridge integration deliberately preserves the Chrome profile and
# any browsing data inside it; deleting user profile data is not an uninstall side effect.
[[ -d "$HOME/Library/Application Support/Google/Chrome/Profile 3" ]]

echo "background Chrome installer test passed"
