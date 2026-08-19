#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Background Chrome integration currently supports macOS only.\n' >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTENSION_DIR="$ROOT/chrome-extension"
EXTENSION_ID="pfhahlehpahegefejooendokpkklgmgd"
HOST_NAME="io.github.dcierra.darwinrelay"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
NATIVE_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
WRAPPER="$DATA_DIR/chrome-native-host"
INSTALLED_HOST_SCRIPT="$DATA_DIR/chrome-native-host.mjs"
MANIFEST="$NATIVE_DIR/$HOST_NAME.json"
PROFILE_BINDING="$DATA_DIR/chrome-background-profile.json"
CHROME_USER_DATA="$HOME/Library/Application Support/Google/Chrome"
CHROME_LOCAL_STATE="$CHROME_USER_DATA/Local State"
NODE_BIN="$(command -v node || true)"
OPEN_CHROME=0
PROFILE_SELECTOR=""
USE_CURRENT_PROFILE=0
DEFAULT_PROFILE_NAME="${DARWINRELAY_CHROME_PROFILE_NAME:-DarwinRelay}"
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  CHROME_RUNNING=1
else
  CHROME_RUNNING=0
fi

usage() {
  cat <<EOF
Usage: $0 [--open] [--profile NAME_OR_DIRECTORY | --use-current-profile]

Default behavior:
  Create or reuse a signed-out Chrome profile named "$DEFAULT_PROFILE_NAME" and
  bind DarwinRelay to it in dedicated-local mode.

Options:
  --profile NAME_OR_DIRECTORY  Bind an existing explicit Chrome profile.
  --use-current-profile       Bind Chrome's last-used profile; it must be signed in.
  --open                      Open chrome://extensions in the selected profile after install.
EOF
}

while (( $# )); do
  case "$1" in
    --open)
      OPEN_CHROME=1
      shift
      ;;
    --profile)
      [[ $# -ge 2 && -n "${2:-}" ]] || { printf '%s\n' '--profile requires a Chrome profile name or directory.' >&2; exit 2; }
      [[ "$USE_CURRENT_PROFILE" == "0" ]] || { printf '%s\n' '--profile and --use-current-profile are mutually exclusive.' >&2; exit 2; }
      PROFILE_SELECTOR="$2"
      shift 2
      ;;
    --use-current-profile)
      [[ -z "$PROFILE_SELECTOR" ]] || { printf '%s\n' '--profile and --use-current-profile are mutually exclusive.' >&2; exit 2; }
      USE_CURRENT_PROFILE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -x "$NODE_BIN" ]] || { printf 'node was not found in PATH. Install Node.js first.\n' >&2; exit 1; }
[[ -f "$EXTENSION_DIR/manifest.json" ]] || { printf 'Missing extension at %s\n' "$EXTENSION_DIR" >&2; exit 1; }
[[ -f "$CHROME_LOCAL_STATE" ]] || { printf 'Chrome Local State was not found at %s. Launch Chrome once, then rerun.\n' "$CHROME_LOCAL_STATE" >&2; exit 1; }

mkdir -p "$DATA_DIR" "$NATIVE_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || true

PROFILE_RESULT="$(python3 - "$CHROME_LOCAL_STATE" "$PROFILE_BINDING" "$PROFILE_SELECTOR" "$USE_CURRENT_PROFILE" "$DEFAULT_PROFILE_NAME" "$CHROME_RUNNING" <<'PYPROFILE'
import json, os, re, stat, sys
from pathlib import Path

local_state, out, selector, use_current_raw, default_name, chrome_running_raw = sys.argv[1:]
use_current = use_current_raw == "1"
chrome_running = chrome_running_raw == "1"
state_path = Path(local_state)
user_data = state_path.parent
with state_path.open(encoding="utf-8") as f:
    data = json.load(f)
profile = data.setdefault("profile", {})
info_cache = profile.setdefault("info_cache", {})
profiles_order = profile.setdefault("profiles_order", [])
created = False
mode = "explicit" if selector.strip() else ("current" if use_current else "default-dedicated")

def labels(directory, entry):
    return {
        str(directory).strip().casefold(),
        str(entry.get("name") or "").strip().casefold(),
        str(entry.get("shortcut_name") or "").strip().casefold(),
    } - {""}

def resolve(wanted_raw):
    wanted = wanted_raw.strip().casefold()
    matches = [directory for directory, entry in info_cache.items() if wanted in labels(directory, entry)]
    if not matches:
        available = ", ".join(
            f"{directory} ({(entry.get('name') or directory)!s})"
            for directory, entry in info_cache.items()
        ) or "none"
        raise SystemExit(f"Chrome profile {wanted_raw!r} was not found. Available profiles: {available}")
    if len(matches) != 1:
        raise SystemExit(f"Chrome profile selector {wanted_raw!r} is ambiguous: {', '.join(matches)}")
    return matches[0]

def signed_in(entry):
    email = str(entry.get("user_name") or "").strip()
    gaia = str(entry.get("gaia_id") or "").strip()
    return bool(email and "@" in email and gaia.isdigit()), email, gaia

if selector.strip():
    profile_dir = resolve(selector)
elif use_current:
    profile_dir = profile.get("last_used") or "Default"
    if profile_dir not in info_cache:
        raise SystemExit(f"Chrome last-used profile {profile_dir!r} is missing from Local State")
else:
    default_matches = [directory for directory, entry in info_cache.items() if default_name.casefold() in labels(directory, entry)]
    if len(default_matches) > 1:
        raise SystemExit(f"Default DarwinRelay profile name {default_name!r} is ambiguous: {', '.join(default_matches)}")
    if default_matches:
        profile_dir = default_matches[0]
    else:
        if chrome_running:
            raise SystemExit(
                f"Chrome is running and the dedicated {default_name!r} profile does not exist yet. "
                "Quit Chrome once, rerun this installer, then use --open if you want DarwinRelay to reopen the new profile."
            )
        used = set(info_cache)
        for child in user_data.iterdir():
            if child.is_dir():
                used.add(child.name)
        n = 1
        while f"Profile {n}" in used:
            n += 1
        profile_dir = f"Profile {n}"
        entry = {
            "name": default_name,
            "shortcut_name": default_name,
            "user_name": "",
            "gaia_id": "",
            "is_using_default_name": False,
            "is_using_default_avatar": True,
            "background_apps": False,
        }
        info_cache[profile_dir] = entry
        if profile_dir not in profiles_order:
            profiles_order.append(profile_dir)

        profile_path = user_data / profile_dir
        profile_path.mkdir(mode=0o700, parents=True, exist_ok=True)
        prefs_path = profile_path / "Preferences"
        if not prefs_path.exists():
            prefs_tmp = prefs_path.with_name("Preferences.darwinrelay.tmp")
            with prefs_tmp.open("w", encoding="utf-8") as f:
                json.dump({"profile": {"name": default_name, "exit_type": "Normal", "exited_cleanly": True}}, f, indent=2)
                f.write("\n")
            os.chmod(prefs_tmp, 0o600)
            os.replace(prefs_tmp, prefs_path)

        state_tmp = state_path.with_name("Local State.darwinrelay.tmp")
        original_mode = stat.S_IMODE(state_path.stat().st_mode)
        with state_tmp.open("w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.chmod(state_tmp, original_mode or 0o600)
        os.replace(state_tmp, state_path)
        created = True

entry = info_cache.get(profile_dir) or {}
profile_name = str(entry.get("name") or entry.get("shortcut_name") or profile_dir).strip() or profile_dir
is_signed_in, email, gaia = signed_in(entry)

if mode == "current":
    if not is_signed_in:
        raise SystemExit(
            f"Chrome current profile {profile_dir!r} ({profile_name}) is signed out. "
            "Use the default dedicated DarwinRelay profile, or explicitly select a local profile with --profile."
        )
    binding = {
        "profileDirectory": profile_dir,
        "profileName": profile_name,
        "bindingMode": "signed-in",
        "expectedEmail": email,
        "expectedGaiaId": gaia,
    }
elif mode == "default-dedicated":
    if is_signed_in:
        raise SystemExit(
            f"The default DarwinRelay profile {profile_dir!r} ({profile_name}) is signed in. "
            "Sign it out to keep the default isolated, or explicitly choose another profile with --profile."
        )
    binding = {
        "profileDirectory": profile_dir,
        "profileName": profile_name,
        "bindingMode": "dedicated-local",
        "expectedSignedIn": False,
    }
else:
    if is_signed_in:
        binding = {
            "profileDirectory": profile_dir,
            "profileName": profile_name,
            "bindingMode": "signed-in",
            "expectedEmail": email,
            "expectedGaiaId": gaia,
        }
    else:
        binding = {
            "profileDirectory": profile_dir,
            "profileName": profile_name,
            "bindingMode": "dedicated-local",
            "expectedSignedIn": False,
        }

tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(binding, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, out)
print(f"profileDirectory={profile_dir}")
print(f"profileName={profile_name}")
print(f"bindingMode={binding['bindingMode']}")
print(f"created={str(created).lower()}")
PYPROFILE
)"
chmod 600 "$PROFILE_BINDING"

PROFILE_DIRECTORY="$(printf '%s\n' "$PROFILE_RESULT" | sed -n 's/^profileDirectory=//p')"
PROFILE_NAME="$(printf '%s\n' "$PROFILE_RESULT" | sed -n 's/^profileName=//p')"
BINDING_MODE="$(printf '%s\n' "$PROFILE_RESULT" | sed -n 's/^bindingMode=//p')"
PROFILE_CREATED="$(printf '%s\n' "$PROFILE_RESULT" | sed -n 's/^created=//p')"

[[ -n "$PROFILE_DIRECTORY" && -n "$PROFILE_NAME" && -n "$BINDING_MODE" ]] || {
  printf 'Failed to resolve Chrome profile binding.\n' >&2
  exit 1
}
printf 'Bound background Chrome to profile %s (%s), mode=%s%s\n' \
  "$PROFILE_DIRECTORY" "$PROFILE_NAME" "$BINDING_MODE" \
  "$([[ "$PROFILE_CREATED" == "true" ]] && printf ', created by DarwinRelay' || true)"

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
    "description": "DarwinRelay background Chrome native host",
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

Selected Chrome profile:
  $PROFILE_NAME ($PROFILE_DIRECTORY), mode=$BINDING_MODE

One-time Chrome step:
  1. Open that Chrome profile
  2. Visit chrome://extensions
  3. Enable Developer mode
  4. Click "Load unpacked"
  5. Choose: $EXTENSION_DIR

Expected extension id: $EXTENSION_ID
Native host manifest: $MANIFEST
Installed native host runtime: $INSTALLED_HOST_SCRIPT
Profile binding: $PROFILE_BINDING

By default DarwinRelay creates/reuses a dedicated signed-out profile named
"$DEFAULT_PROFILE_NAME". This keeps agent browser state separate from an everyday
Google account. Use --use-current-profile only when you intentionally want the
last-used signed-in Chrome profile, or --profile NAME_OR_DIRECTORY for an explicit
existing profile.

Load the unpacked extension ONLY in the selected profile. For dedicated-local mode,
keep that profile signed out; re-run this installer if its sign-in state changes.

Relaxed browser access is the default: once the extension is loaded and the
configured profile binding matches, DarwinRelay can use normal HTTP/HTTPS sites without
per-site terminal approvals. If you want scoped URL/app approval gates, turn on
"Strict approvals" in the DarwinRelay menu-bar app.

Routine chrome_* tools use background tabs and do not activate Chrome. Native dialogs,
CAPTCHAs, file pickers, and trusted-user-gesture flows can still require foreground or
manual interaction.
EOF2

if (( OPEN_CHROME )); then
  open -a "Google Chrome" --args --profile-directory="$PROFILE_DIRECTORY" "chrome://extensions" || true
fi
