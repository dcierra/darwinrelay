#!/bin/bash
set -euo pipefail
INSTALL_DIR="${DARWINRELAY_INSTALL_DIR:-$HOME/.local/share/darwinrelay}"
NODE_BIN="${NODE_BIN:-$(command -v node)}"
exec "$NODE_BIN" "$INSTALL_DIR/bridge.mjs"
