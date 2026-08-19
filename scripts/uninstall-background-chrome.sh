#!/bin/bash
set -euo pipefail
HOST_NAME="io.github.dcierra.darwinrelay"
DATA_DIR="${DARWINRELAY_DATA_DIR:-$HOME/Library/Application Support/DarwinRelay}"
MANIFEST="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$HOST_NAME.json"
rm -f \
  "$MANIFEST" \
  "$DATA_DIR/chrome-native-host" \
  "$DATA_DIR/chrome-native-host.mjs" \
  "$DATA_DIR/chrome-background-profile.json" \
  "$DATA_DIR/chrome-background.sock" \
  "$DATA_DIR/chrome-native-host.pid"
printf 'Removed the DarwinRelay background Chrome native host.\n'
printf 'Remove the unpacked extension separately from chrome://extensions if desired.\n'
