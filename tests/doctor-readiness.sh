#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-doctor-readiness.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
DATA_DIR="$TMP/data"
LOG_DIR="$TMP/logs"
APP="$TMP/DarwinRelay.app"
mkdir -p "$HOME_DIR" "$DATA_DIR" "$LOG_DIR" "$APP/Contents"

VERSION="$(node -p 'require(process.argv[1]).version' "$ROOT/package.json")"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>DarwinRelayPackageDirectory</key><string>$ROOT</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

TOKEN_FILE="$DATA_DIR/http-token"
UNLOCK_FILE="$DATA_DIR/FULL_ACCESS_ENABLED"
printf 'test-doctor-token-that-is-long-enough\n' > "$TOKEN_FILE"
printf 'I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n' > "$UNLOCK_FILE"
chmod 600 "$TOKEN_FILE" "$UNLOCK_FILE"

cat > "$TMP/cloudflared" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$TMP/cloudflared"

cat > "$TMP/curl-ok" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$TMP/curl-fail" <<'SH'
#!/bin/bash
exit 22
SH
chmod +x "$TMP/curl-ok" "$TMP/curl-fail"

cat > "$TMP/desktop-doctor" <<'SH'
#!/bin/bash
printf 'Accessibility : MISSING\n'
exit 2
SH
cat > "$TMP/tcc-doctor" <<'SH'
#!/bin/bash
printf 'MISSING\n'
exit 1
SH
chmod +x "$TMP/desktop-doctor" "$TMP/tcc-doctor"

cat > "$TMP/probe.mjs" <<JS
console.log(JSON.stringify({bridgeVersion:"$VERSION",backgroundChrome:{extensionReady:false}}));
JS

run_doctor() {
  local curl_bin="$1" out="$2"
  set +e
  HOME="$HOME_DIR" \
  DARWINRELAY_APP_PATH="$APP" \
  DARWINRELAY_RUNTIME_DIR="$ROOT" \
  DARWINRELAY_DATA_DIR="$DATA_DIR" \
  DARWINRELAY_LOG_DIR="$LOG_DIR" \
  DARWINRELAY_UNLOCK_FILE="$UNLOCK_FILE" \
  DARWINRELAY_HTTP_TOKEN_FILE="$TOKEN_FILE" \
  DARWINRELAY_DOCTOR_TRANSPORT=http \
  DARWINRELAY_NODE_BIN="$(command -v node)" \
  DARWINRELAY_CURL_BIN="$curl_bin" \
  DARWINRELAY_CLOUDFLARED_BIN="$TMP/cloudflared" \
  DARWINRELAY_CODEX_BIN="$TMP/no-codex" \
  DARWINRELAY_DESKTOP_DOCTOR="$TMP/desktop-doctor" \
  DARWINRELAY_TCC_DOCTOR="$TMP/tcc-doctor" \
  DARWINRELAY_BRIDGE_PROBE="$TMP/probe.mjs" \
  LAUNCHCTL_BIN="$TMP/no-launchctl" \
  TUNNEL_CLIENT_BIN="$TMP/no-tunnel-client" \
    "$ROOT/scripts/doctor.sh" > "$out" 2>&1
  rc=$?
  set -e
  return "$rc"
}

READY_OUT="$TMP/ready.out"
run_doctor "$TMP/curl-ok" "$READY_OUT"
grep -Fq 'CORE VERDICT: READY' "$READY_OUT"
grep -Fq 'Native desktop               OPTIONAL / ACTION REQUIRED' "$READY_OUT"
grep -Fq 'Protected filesystem (FDA)   OPTIONAL / ACTION REQUIRED' "$READY_OUT"
grep -Fq 'Background Chrome            OPTIONAL / NOT CONFIGURED' "$READY_OUT"
grep -Fq 'Codex continuity             OPTIONAL / NOT CONFIGURED' "$READY_OUT"
grep -Fq 'Real MCP initialize + bridge_status smoke passed' "$READY_OUT"

STOPPED_OUT="$TMP/stopped.out"
if run_doctor "$TMP/curl-fail" "$STOPPED_OUT"; then
  printf 'doctor unexpectedly reported READY with the HTTP front end stopped\n' >&2
  cat "$STOPPED_OUT" >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 2 ]]
grep -Fq 'HTTP front end is not listening' "$STOPPED_OUT"
grep -Fq 'Open DarwinRelay and choose Start' "$STOPPED_OUT"
grep -Fq 'CORE VERDICT: ACTION REQUIRED' "$STOPPED_OUT"

# App/runtime disagreement is a blocking onboarding error even if HTTP itself is up.
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.0.0' "$APP/Contents/Info.plist"
MISMATCH_OUT="$TMP/mismatch.out"
if run_doctor "$TMP/curl-ok" "$MISMATCH_OUT"; then
  printf 'doctor unexpectedly accepted app/runtime version mismatch\n' >&2
  cat "$MISMATCH_OUT" >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 2 ]]
grep -Fq "App/runtime version mismatch: app v0.0.0, runtime v$VERSION" "$MISMATCH_OUT"

echo 'doctor readiness grouping test passed'
