#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-tunnel-url.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

xcrun swiftc -Onone \
  -target "$(uname -m)-apple-macos13.0" \
  -framework Foundation \
  -o "$TMP/TunnelURLTest" \
  "$ROOT/menubar/TunnelURL.swift" \
  "$ROOT/tests/swift/TunnelURLTest.swift"

"$TMP/TunnelURLTest"
