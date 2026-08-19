#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Background Chrome integration currently supports macOS only.\n' >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTENSION_DIR="$ROOT/chrome-extension"
EXTENSION_ID="pcebfblnmcappinbenkmddjdapaoajgm"
HOST_NAME="io.github.alexanderradahl.mac_developer_bridge"
DATA_DIR="${MAC_DEV_BRIDGE_DATA_DIR:-$HOME/Library/Application Support/MacDeveloperBridge}"
NATIVE_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
WRAPPER="$DATA_DIR/chrome-native-host"
INSTALLED_HOST_SCRIPT="$DATA_DIR/chrome-native-host.mjs"
MANIFEST="$NATIVE_DIR/$HOST_NAME.json"
PROFILE_BINDING="$DATA_DIR/chrome-background-profile.json"
CHROME_LOCAL_STATE="$HOME/Library/Application Support/Google/Chrome/Local State"
NODE_BIN="$(command -v node || true)"
OPEN_CHROME=0
PROFILE_SELECTOR=""

while (( $# )); do
  case "$1" in
    --open)
      OPEN_CHROME=1
      shift
      ;;
    --profile)
      [[ $# -ge 2 && -n "${2:-}" ]] || { printf '%s\n' '--profile requires a Chrome profile name or directory.' >&2; exit 2; }
      PROFILE_SELECTOR="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s [--open] [--profile NAME_OR_DIRECTORY]\n' "$0"
      exit 0
      ;;
    *)
      printf 'Usage: %s [--open] [--profile NAME_OR_DIRECTORY]\n' "$0" >&2
      exit 2
      ;;
  esac
done

[[ -x "$NODE_BIN" ]] || { printf 'node was not found in PATH. Install Node.js first.\n' >&2; exit 1; }
[[ -f "$EXTENSION_DIR/manifest.json" ]] || { printf 'Missing extension at %s\n' "$EXTENSION_DIR" >&2; exit 1; }
[[ -f "$CHROME_LOCAL_STATE" ]] || { printf 'Chrome Local State was not found at %s\n' "$CHROME_LOCAL_STATE" >&2; exit 1; }

mkdir -p "$DATA_DIR" "$NATIVE_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || true

python3 - "$CHROME_LOCAL_STATE" "$PROFILE_BINDING" "$PROFILE_SELECTOR" <<'PYPROFILE'
import json, os, sys
local_state, out, selector = sys.argv[1:]
data = json.load(open(local_state, encoding="utf-8"))
profile = data.get("profile") or {}
info_cache = profile.get("info_cache") or {}
explicit = bool(selector.strip())

if explicit:
    wanted = selector.strip().casefold()
    matches = []
    for directory, entry in info_cache.items():
        labels = {
            str(directory).strip().casefold(),
            str(entry.get("name") or "").strip().casefold(),
            str(entry.get("shortcut_name") or "").strip().casefold(),
        }
        labels.discard("")
        if wanted in labels:
            matches.append(directory)
    if not matches:
        available = ", ".join(
            f"{directory} ({(entry.get('name') or directory)!s})"
            for directory, entry in info_cache.items()
        ) or "none"
        raise SystemExit(f"Chrome profile {selector!r} was not found. Available profiles: {available}")
    if len(matches) != 1:
        raise SystemExit(f"Chrome profile selector {selector!r} is ambiguous: {', '.join(matches)}")
    profile_dir = matches[0]
else:
    profile_dir = profile.get("last_used") or "Default"

entry = info_cache.get(profile_dir) or {}
profile_name = str(entry.get("name") or entry.get("shortcut_name") or profile_dir).strip() or profile_dir
email = str(entry.get("user_name") or "").strip()
gaia = str(entry.get("gaia_id") or "").strip()
signed_in = bool(email and "@" in email and gaia.isdigit())

if signed_in:
    binding = {
        "profileDirectory": profile_dir,
        "profileName": profile_name,
        "bindingMode": "signed-in",
        "expectedEmail": email,
        "expectedGaiaId": gaia,
    }
elif explicit:
    # A deliberately selected local-only profile is useful for isolating MDB from
    # the operator's normal signed-in Chrome. Chrome's extension APIs do not expose
    # the profile directory/name to an extension, so this mode is enforced by
    # loading the unpacked extension only in the selected profile and requiring it
    # to remain signed out. If that profile is later signed in, re-run this script.
    binding = {
        "profileDirectory": profile_dir,
        "profileName": profile_name,
        "bindingMode": "dedicated-local",
        "expectedSignedIn": False,
    }
else:
    raise SystemExit(
        f"Chrome profile {profile_dir!r} is not signed in with a primary Google account. "
        "Select an intentional isolated local profile with --profile NAME_OR_DIRECTORY."
    )

tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(binding, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, out)
print(f"Bound background Chrome to profile {profile_dir} ({profile_name}), mode={binding['bindingMode']}")
PYPROFILE
chmod 600 "$PROFILE_BINDING"

umask 077
# Chrome is the responsible process for TCC when it starts a native messaging
# host. Executing the host source directly from a checkout under ~/Documents can
# therefore block on macOS privacy access before the host creates its Unix socket.
# Install the self-contained host runtime into Application Support instead.
HOST_TMP="$INSTALLED_HOST_SCRIPT.tmp.$$"
cp "$ROOT/scripts/chrome-native-host.mjs" "$HOST_TMP"
chmod 600 "$HOST_TMP"
mv -f "$HOST_TMP" "$INSTALLED_HOST_SCRIPT"

cat > "$WRAPPER" <<EOF2
#!/bin/sh
exec "$NODE_BIN" "$INSTALLED_HOST_SCRIPT"
EOF2
chmod 700 "$WRAPPER"

python3 - "$MANIFEST" "$HOST_NAME" "$WRAPPER" "$EXTENSION_ID" <<'PY'
import json, os, sys
out, name, path, extension_id = sys.argv[1:]
data = {
    "name": name,
    "description": "Mac Developer Bridge background Chrome native host",
    "path": path,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{extension_id}/"],
}
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, out)
PY
chmod 600 "$MANIFEST"

cat <<EOF2
Background Chrome native host installed.

One-time Chrome step:
  1. Open chrome://extensions
  2. Enable Developer mode
  3. Click "Load unpacked"
  4. Choose: $EXTENSION_DIR

Expected extension id: $EXTENSION_ID
Native host manifest: $MANIFEST
Installed native host runtime: $INSTALLED_HOST_SCRIPT
Profile binding: $PROFILE_BINDING

Load the unpacked extension ONLY in the Chrome profile selected by this installer.
For a dedicated-local (signed-out) profile, keep that profile signed out; re-run
this installer if its sign-in state changes.

Relaxed browser access is the default: once the extension is loaded and the
configured profile binding matches, MDB can use normal HTTP/HTTPS sites without
per-site terminal approvals. If you want scoped URL/app approval gates, turn on
"Strict approvals" in the Mac Developer Bridge menu-bar app. Strict mode then uses
scripts/approve-personal-browser.sh and scripts/approve-foreground-gui.sh.

Routine chrome_* tools then use background tabs (active:false) and do not activate
Chrome. Native dialogs, CAPTCHAs, file pickers, and trusted-user-gesture flows still
require foreground/manual interaction.
EOF2

if (( OPEN_CHROME )); then
  open -g -a "Google Chrome" "chrome://extensions" || true
fi
