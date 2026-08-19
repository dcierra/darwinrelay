#!/bin/bash
set -euo pipefail

# Builds DarwinRelay.app — a menu bar front end for the Cloudflare/HTTP
# transport. No Xcode project and no dependencies: swiftc plus a hand-assembled
# bundle, which is all a single-file AppKit agent needs.
#
# The bundle is placed IN the package directory on purpose: the app locates
# mcp-http.mjs relative to its own bundle path, so keeping them together means
# there is no path to configure.

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PACKAGE_DIR="$(cd "$HERE/.." && pwd -P)"
APP="${DARWINRELAY_APP_OUTPUT:-$PACKAGE_DIR/DarwinRelay.app}"
NAME="DarwinRelay"
INSTALL_APP="${DARWINRELAY_INSTALL_APP:-1}"
INSTALL_DIR_OVERRIDE="${DARWINRELAY_APP_INSTALL_DIR:-}"
PACKAGE_VERSION="$(node -p 'require(process.argv[1]).version' "$PACKAGE_DIR/package.json")"
BUNDLE_VERSION="${PACKAGE_VERSION%%-*}"
source "$PACKAGE_DIR/scripts/codesign-runtime.sh"
SIGN_ID="$(darwinrelay_codesign_identity)"
if [[ -n "$SIGN_ID" ]]; then export DARWINRELAY_SIGN_IDENTITY="$SIGN_ID"; fi

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2; exit 69; }

# Build the optional native desktop-control helper into the package. The running
# production app is not involved; bridge.mjs resolves this helper from bin/.
DARWINRELAY_UI_HELPER_OUTPUT="$PACKAGE_DIR/bin/MacUIHelper" "$PACKAGE_DIR/scripts/build-mac-ui-helper.sh" >/dev/null
echo "  built native desktop-control helper"
DARWINRELAY_UI_CURSOR_OUTPUT="$PACKAGE_DIR/bin/MacUICursorOverlay" "$PACKAGE_DIR/scripts/build-mac-ui-cursor.sh" >/dev/null
echo "  built virtual AI cursor overlay"

echo "Building $NAME..."

# Quit a running instance FIRST. Deleting a live bundle leaves the old process
# running, and LaunchServices then reactivates that stale instance when you `open`
# the rebuilt app — so you test old code believing it is new, while the old process
# still supervises children from a bundle that no longer exists on disk.
if pgrep -f "$APP/Contents/MacOS/$NAME" >/dev/null 2>&1; then
  echo "  quitting the running instance first"
  osascript -e 'quit app id "io.github.dcierra.darwinrelay"' >/dev/null 2>&1 || true
  sleep 1
  pkill -f "$APP/Contents/MacOS/$NAME" 2>/dev/null || true
  sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp -p "$PACKAGE_DIR/bin/MacUIHelper" "$APP/Contents/Helpers/MacUIHelper"
cp -p "$PACKAGE_DIR/bin/MacUICursorOverlay" "$APP/Contents/Helpers/MacUICursorOverlay"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>DarwinRelay</string>
  <key>CFBundleIdentifier</key><string>io.github.dcierra.darwinrelay</string>
  <key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
  <!-- Lets the bundle be installed to /Applications while the package stays put.
       The app prefers a package sitting next to itself and falls back to this. -->
  <key>DarwinRelayPackageDirectory</key><string>$PACKAGE_DIR</string>
</dict>
</plist>
PLIST

# Pin the deployment target so the binary matches LSMinimumSystemVersion. Without
# -target, swiftc uses the host triple (macos26 here), so the plist promised 13.0
# while the binary would dyld-error on anything older instead of showing the clean
# "requires a newer macOS" dialog.
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -o "$APP/Contents/MacOS/$NAME" \
  "$HERE/MenuBarApp.swift" \
  "$HERE/TunnelURL.swift"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign the outer app with the SAME identity already used for both nested helpers.
# The helpers are copied before this step so the bundle seal covers their stable
# designated requirements too.
darwinrelay_sign_runtime "$APP" "io.github.dcierra.darwinrelay" "$SIGN_ID"
codesign --verify --deep --strict "$APP" >/dev/null

# Install a copy where the user will actually look for it. Installation is a
# same-filesystem rename, not rm+cp: a running /Applications instance keeps its
# existing executable alive while future helper launches resolve through the new
# bundle. One rollback bundle is retained beside the installed app.
designated_requirement() {
  codesign -dr - "$1" 2>&1 | sed -n 's/^designated => //p'
}

same_runtime_identity() {
  local current="$1" candidate="$2" label="$3"
  [[ -e "$current" && -e "$candidate" ]] || return 0
  local current_req candidate_req
  current_req="$(designated_requirement "$current")"
  candidate_req="$(designated_requirement "$candidate")"
  if [[ -n "$current_req" && "$current_req" == "$candidate_req" ]]; then return 0; fi
  if [[ "${DARWINRELAY_ALLOW_SIGNING_CHANGE:-0}" == "1" ]]; then
    echo "warning: allowing signing-identity change for $label" >&2
    return 0
  fi
  echo "error: refusing to replace $label because its designated code requirement changed" >&2
  echo "  current:   ${current_req:-<none>}" >&2
  echo "  candidate: ${candidate_req:-<none>}" >&2
  echo "Set DARWINRELAY_ALLOW_SIGNING_CHANGE=1 only when you intentionally want new TCC identities." >&2
  return 1
}

install_atomically() {
  local dest="$1"
  local target="$dest/$NAME.app"
  local staged="$dest/.${NAME}.app.new.$$"
  local rollback="$dest/.${NAME}.app.rollback"
  mkdir -p "$dest" 2>/dev/null || return 1
  rm -rf "$staged"
  cp -R "$APP" "$staged" 2>/dev/null || return 1
  codesign --verify --deep --strict "$staged" >/dev/null 2>&1 || {
    echo "warning: staged app signature verification failed: $staged" >&2
    rm -rf "$staged"
    return 1
  }

  if [[ -d "$target" ]]; then
    same_runtime_identity "$target" "$staged" "menu app" || { rm -rf "$staged"; return 1; }
    same_runtime_identity "$target/Contents/Helpers/MacUIHelper" "$staged/Contents/Helpers/MacUIHelper" "MacUIHelper" || { rm -rf "$staged"; return 1; }
    same_runtime_identity "$target/Contents/Helpers/MacUICursorOverlay" "$staged/Contents/Helpers/MacUICursorOverlay" "MacUICursorOverlay" || { rm -rf "$staged"; return 1; }
    if [[ -d "$rollback" ]]; then
      for live_file in "$rollback/Contents/MacOS/DarwinRelay" "$rollback/Contents/Helpers/MacUICursorOverlay"; do
        if [[ -e "$live_file" ]] && /usr/sbin/lsof -t "$live_file" 2>/dev/null | grep -q .; then
          echo "error: refusing another hot swap while a process is still executing from $rollback" >&2
          echo "Restart DarwinRelay normally before replacing the retained rollback bundle." >&2
          rm -rf "$staged"
          return 1
        fi
      done
      rm -rf "$rollback"
    fi
    mv "$target" "$rollback" || { rm -rf "$staged"; return 1; }
  fi

  if ! mv "$staged" "$target"; then
    [[ -d "$rollback" && ! -e "$target" ]] && mv "$rollback" "$target" || true
    return 1
  fi
  if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
    echo "warning: installed app failed signature verification; rolling back" >&2
    rm -rf "$target"
    [[ -d "$rollback" ]] && mv "$rollback" "$target"
    return 1
  fi
  printf '%s\n' "$target"
}

INSTALLED=""
if [[ "$INSTALL_APP" != "0" ]]; then
  if [[ -n "$INSTALL_DIR_OVERRIDE" ]]; then
    install_dirs=("$INSTALL_DIR_OVERRIDE")
  else
    install_dirs=(/Applications "$HOME/Applications")
  fi
  for dest in "${install_dirs[@]}"; do
    target_exists=0
    [[ -d "$dest/$NAME.app" ]] && target_exists=1
    if INSTALLED="$(install_atomically "$dest")"; then
      break
    elif (( target_exists == 1 )); then
      echo "error: existing installation at $dest/$NAME.app was left unchanged; refusing fallback to another Applications directory" >&2
      exit 1
    fi
  done
fi

cat <<OUT

Built: $APP${INSTALLED:+
Installed: $INSTALLED}

Open it with:
  open "${INSTALLED:-$APP}"

For unattended recovery/cutover, launch once with:
  open -n "${INSTALLED:-$APP}" --args --start

It will appear in the menu bar. Use Start, then "Copy ChatGPT Setup".

The app reads mcp-http.mjs from $PACKAGE_DIR (its own parent directory), keeps
the bearer token in a mode-0600 file at
  ~/Library/Application Support/DarwinRelay/http-token
and passes it to the front end by file, so the token stays out of ps output.

Start writes the full-access unlock file; Stop and Quit remove it, which makes
stopping fail-closed rather than only killing a process.
OUT
