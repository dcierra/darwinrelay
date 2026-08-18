#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
APP="${MDB_DESKTOP_FIXTURE_APP:-/tmp/MDBDesktopFixture.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -o "$APP/Contents/MacOS/MDBDesktopFixture" \
  "$ROOT/tests/fixtures/DesktopControlFixture.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MDBDesktopFixture</string>
<key>CFBundleIdentifier</key><string>dev.dcierra.mdb.desktop-fixture</string>
<key>CFBundleName</key><string>MDB Desktop Fixture</string>
<key>CFBundleDisplayName</key><string>MDB Desktop Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf '%s\n' "$APP"
