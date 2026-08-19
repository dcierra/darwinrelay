#!/bin/bash
set -euo pipefail

# Builds MacDevBridge.app — a menu bar front end for the Cloudflare/HTTP
# transport. No Xcode project and no dependencies: swiftc plus a hand-assembled
# bundle, which is all a single-file AppKit agent needs.
#
# The bundle is placed IN the package directory on purpose: the app locates
# mcp-http.mjs relative to its own bundle path, so keeping them together means
# there is no path to configure.

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PACKAGE_DIR="$(cd "$HERE/.." && pwd -P)"
APP="$PACKAGE_DIR/MacDevBridge.app"
NAME="MacDevBridge"
INSTALL_APP="${MAC_DEV_BRIDGE_INSTALL_APP:-1}"
source "$PACKAGE_DIR/scripts/codesign-runtime.sh"
SIGN_ID="$(mdb_codesign_identity)"
if [[ -n "$SIGN_ID" ]]; then export MAC_DEV_BRIDGE_SIGN_IDENTITY="$SIGN_ID"; fi

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2; exit 69; }

# Build the optional native desktop-control helper into the package. The running
# production app is not involved; bridge.mjs resolves this helper from bin/.
MAC_DEV_BRIDGE_UI_HELPER_OUTPUT="$PACKAGE_DIR/bin/MacUIHelper" "$PACKAGE_DIR/scripts/build-mac-ui-helper.sh" >/dev/null
echo "  built native desktop-control helper"
MAC_DEV_BRIDGE_UI_CURSOR_OUTPUT="$PACKAGE_DIR/bin/MacUICursorOverlay" "$PACKAGE_DIR/scripts/build-mac-ui-cursor.sh" >/dev/null
echo "  built virtual AI cursor overlay"

echo "Building $NAME..."

# Quit a running instance FIRST. Deleting a live bundle leaves the old process
# running, and LaunchServices then reactivates that stale instance when you `open`
# the rebuilt app — so you test old code believing it is new, while the old process
# still supervises children from a bundle that no longer exists on disk.
if pgrep -f "$APP/Contents/MacOS/$NAME" >/dev/null 2>&1; then
  echo "  quitting the running instance first"
  osascript -e 'quit app id "local.mac-developer-bridge.menubar"' >/dev/null 2>&1 || true
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
  <key>CFBundleDisplayName</key><string>Mac Developer Bridge</string>
  <key>CFBundleIdentifier</key><string>local.mac-developer-bridge.menubar</string>
  <key>CFBundleVersion</key><string>0.5.1</string>
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
  <!-- Lets the bundle be installed to /Applications while the package stays put.
       The app prefers a package sitting next to itself and falls back to this. -->
  <key>MDBPackageDirectory</key><string>$PACKAGE_DIR</string>
</dict>
</plist>
PLIST

# Pin the deployment target so the binary matches LSMinimumSystemVersion. Without
# -target, swiftc uses the host triple (macos26 here), so the plist promised 13.0
# while the binary would dyld-error on anything older instead of showing the clean
# "requires a newer macOS" dialog.
swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -o "$APP/Contents/MacOS/$NAME" \
  "$HERE/MenuBarApp.swift"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign the outer app with the SAME identity already used for both nested helpers.
# The helpers are copied before this step so the bundle seal covers their stable
# designated requirements too.
mdb_sign_runtime "$APP" "local.mac-developer-bridge.menubar" "$SIGN_ID"
codesign --verify --deep --strict "$APP" >/dev/null

# Install a copy where the user will actually look for it. Launchpad and Spotlight
# do not surface apps living in ~/Downloads, which is where this one was stranded.
INSTALLED=""
if [[ "$INSTALL_APP" != "0" ]]; then
  for dest in /Applications "$HOME/Applications"; do
    [ -d "$dest" ] || mkdir -p "$dest" 2>/dev/null || continue
    if rm -rf "$dest/$NAME.app" 2>/dev/null && cp -R "$APP" "$dest/" 2>/dev/null; then
      # Preserve the signature created above. Re-signing the installed copy ad-hoc
      # changes its designated requirement/cdhash and invalidates TCC grants.
      codesign --verify --deep --strict "$dest/$NAME.app" >/dev/null 2>&1 || {
        echo "warning: installed app signature verification failed: $dest/$NAME.app" >&2
        continue
      }
      INSTALLED="$dest/$NAME.app"
      break
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
  ~/Library/Application Support/MacDeveloperBridge/http-token
and passes it to the front end by file, so the token stays out of ps output.

Start writes the full-access unlock file; Stop and Quit remove it, which makes
stopping fail-closed rather than only killing a process.
OUT
