#!/bin/bash
set -Eeuo pipefail

# Manual, release-to-release updater for the source-first DarwinRelay install.
# The menu app and Git checkout are one runtime transaction: bridge.mjs,
# mcp-http.mjs, scripts, and the unpacked Chrome extension remain in the checkout.

usage() {
  cat <<'USAGE'
Usage: ./scripts/update.sh [latest|vX.Y.Z] [--yes]

Update a clean DarwinRelay release checkout to another published release tag.

  latest   Update to the highest stable vMAJOR.MINOR.PATCH tag on origin (default).
  vX.Y.Z   Update to this exact release tag.
  --yes    Skip the interactive restart confirmation. Use only after explicit
           operator approval to restart DarwinRelay.

The updater refuses dirty trees, development commits, non-canonical origins,
moved tags, and downgrades. It never uses git reset --hard or git pull.
USAGE
}

is_canonical_origin() {
  case "${1:-}" in
    https://github.com/dcierra/darwinrelay|https://github.com/dcierra/darwinrelay.git|\
    git@github.com:dcierra/darwinrelay.git|git@github.com:dcierra/darwinrelay|\
    ssh://git@github.com/dcierra/darwinrelay|ssh://git@github.com/dcierra/darwinrelay.git)
      return 0 ;;
    *) return 1 ;;
  esac
}

is_release_tag() {
  [[ "${1:-}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

semver_cmp() {
  local a="$1" b="$2"
  is_release_tag "$a" && is_release_tag "$b" || return 64
  /usr/bin/awk -v a="${a#v}" -v b="${b#v}" 'BEGIN {
    split(a,A,"."); split(b,B,".");
    for (i=1;i<=3;i++) {
      A[i]+=0; B[i]+=0;
      if (A[i]<B[i]) {print -1; exit}
      if (A[i]>B[i]) {print 1; exit}
    }
    print 0
  }'
}

latest_stable_tag_from_origin() {
  local remote="$1"
  git ls-remote --refs --tags "$remote" 'v*' 2>/dev/null \
    | /usr/bin/awk '{ sub("refs/tags/", "", $2); print $2 }' \
    | /usr/bin/grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    | /usr/bin/awk -F'[v.]' '{ printf "%012d %012d %012d %s\n", $2, $3, $4, $0 }' \
    | /usr/bin/sort \
    | /usr/bin/tail -1 \
    | /usr/bin/awk '{print $4}'
}

darwinrelay_menu_pids() {
  local ps_bin="${PS_BIN:-$(command -v ps 2>/dev/null || true)}"
  [[ -n "$ps_bin" && -x "$ps_bin" ]] || return 69
  "$ps_bin" -axo pid=,command= | /usr/bin/awk '$2 ~ /\/DarwinRelay\.app\/Contents\/MacOS\/DarwinRelay$/ {print $1}'
}

stop_all_menu_instances() {
  local pid attempts survivors
  while IFS= read -r pid; do
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || (( pid < 2 )); then
      continue
    fi
    kill -TERM "$pid" 2>/dev/null || true
  done < <(darwinrelay_menu_pids)

  attempts=50
  while (( attempts > 0 )); do
    survivors="$(darwinrelay_menu_pids)"
    [[ -z "$survivors" ]] && return 0
    sleep 0.1
    attempts=$((attempts - 1))
  done

  while IFS= read -r pid; do
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || (( pid < 2 )); then
      continue
    fi
    kill -KILL "$pid" 2>/dev/null || true
  done <<<"$survivors"

  attempts=20
  while (( attempts > 0 )); do
    survivors="$(darwinrelay_menu_pids)"
    [[ -z "$survivors" ]] && return 0
    sleep 0.1
    attempts=$((attempts - 1))
  done
  printf 'DarwinRelay menu instance(s) survived SIGKILL: %s\n' "$(echo "$survivors" | tr '\n' ' ')" >&2
  return 1
}

launchagent_running_pid() { # domain, label
  local domain="$1" label="$2" launchctl_bin out state pid
  launchctl_bin="${LAUNCHCTL_BIN:-$(command -v launchctl 2>/dev/null || true)}"
  [[ -n "$launchctl_bin" && -x "$launchctl_bin" ]] || return 69
  out="$("$launchctl_bin" print "$domain/$label" 2>/dev/null)" || return 1
  state="$(printf '%s\n' "$out" | /usr/bin/awk '$1 == "state" && $2 == "=" {print $3; exit}')"
  pid="$(printf '%s\n' "$out" | /usr/bin/awk '$1 == "pid" && $2 == "=" {print $3; exit}')"
  [[ "$state" == "running" && "$pid" =~ ^[0-9]+$ ]] || return 1
  (( pid >= 2 )) || return 1
  printf '%s\n' "$pid"
}

wait_launchagent_running() { # domain, label
  local domain="$1" label="$2" attempts=100 pid
  while (( attempts > 0 )); do
    pid="$(launchagent_running_pid "$domain" "$label" || true)"
    if [[ -n "$pid" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.2
    attempts=$((attempts - 1))
  done
  return 1
}

ui_status_json_ready() { # JSON string
  node -e '''const s=JSON.parse(process.argv[1]); process.exit(s.accessibilityTrusted===true && s.screenRecordingGranted===true && s.postEventsGranted===true ? 0 : 1)''' "$1"
}

runtime_ui_status_ready() { # probe-script, token-file, port
  local probe="$1" token_file="$2" port="$3" raw
  raw="$(node "$probe" --http-port "$port" --token-file "$token_file" --tool ui_status 2>/dev/null)" || return 2
  ui_status_json_ready "$raw"
}

wait_runtime_ui_status_ready() { # probe-script, token-file, port, attempts, interval-seconds
  local probe="$1" token_file="$2" port="$3" attempts="${4:-100}" interval="${5:-0.2}"
  while (( attempts > 0 )); do
    if runtime_ui_status_ready "$probe" "$token_file" "$port"; then
      return 0
    fi
    sleep "$interval"
    attempts=$((attempts - 1))
  done
  return 1
}

if [[ "${DARWINRELAY_UPDATE_LIBRARY_ONLY:-0}" == "1" ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

# Copy the transaction driver outside the checkout before changing Git HEAD.
if [[ "${DARWINRELAY_UPDATE_HELPER:-0}" != "1" ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
  HELPER="$(mktemp "${TMPDIR:-/tmp}/darwinrelay-update.XXXXXX")"
  cp "$0" "$HELPER"
  chmod 700 "$HELPER"
  export DARWINRELAY_UPDATE_HELPER=1
  export DARWINRELAY_UPDATE_ROOT="$ROOT"
  exec "$HELPER" "$@"
fi

ROOT="${DARWINRELAY_UPDATE_ROOT:?missing DARWINRELAY_UPDATE_ROOT}"
SELF="$0"
TARGET_DISABLE_SCRIPT=""
TARGET_PROBE_DIR=""
TARGET_PROBE_SCRIPT=""
cleanup_update_helper() {
  rm -f "$SELF" 2>/dev/null || true
  [[ -z "$TARGET_DISABLE_SCRIPT" ]] || rm -f "$TARGET_DISABLE_SCRIPT" 2>/dev/null || true
  [[ -z "$TARGET_PROBE_DIR" ]] || rm -rf "$TARGET_PROBE_DIR" 2>/dev/null || true
}
trap cleanup_update_helper EXIT

TARGET_REQUEST="latest"
TARGET_SET=0
ASSUME_YES=0
CANDIDATE_MODE=0
CANDIDATE_SHA="${DARWINRELAY_UPDATE_CANDIDATE_SHA:-}"
CANDIDATE_ACK="I_UNDERSTAND_THIS_INSTALLS_UNPUBLISHED_DARWINRELAY_CODE"
if [[ -n "$CANDIDATE_SHA" ]]; then
  [[ "${DARWINRELAY_MAINTAINER_CANDIDATE_TEST:-}" == "$CANDIDATE_ACK" ]] || {
    echo "Unpublished candidate mode is maintainer-only and requires the explicit candidate-test acknowledgement." >&2
    exit 64
  }
  CANDIDATE_MODE=1
fi
CANDIDATE_FAILPOINT="${DARWINRELAY_UPDATE_CANDIDATE_FAILPOINT:-}"
CANDIDATE_MARKER_FILE="${DARWINRELAY_UPDATE_CANDIDATE_MARKER_FILE:-}"
CANDIDATE_EXPECT_DESKTOP_READY="${DARWINRELAY_UPDATE_EXPECT_DESKTOP_READY:-0}"
if [[ -n "$CANDIDATE_MARKER_FILE" && "$CANDIDATE_MODE" != 1 ]]; then
  echo "Candidate marker files are unavailable outside maintainer candidate mode." >&2
  exit 64
fi
if [[ "$CANDIDATE_EXPECT_DESKTOP_READY" != 0 && "$CANDIDATE_EXPECT_DESKTOP_READY" != 1 ]]; then
  echo "DARWINRELAY_UPDATE_EXPECT_DESKTOP_READY must be 0 or 1." >&2
  exit 64
fi
if [[ -n "$CANDIDATE_FAILPOINT" ]]; then
  (( CANDIDATE_MODE == 1 )) || { echo "Candidate failpoints are unavailable outside maintainer candidate mode." >&2; exit 64; }
  case "$CANDIDATE_FAILPOINT" in
    after_app_install|after_validation) ;;
    *) echo "Unknown candidate failpoint: $CANDIDATE_FAILPOINT" >&2; exit 64 ;;
  esac
fi
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --yes) ASSUME_YES=1 ;;
    latest|v[0-9]*.[0-9]*.[0-9]*)
      (( TARGET_SET == 0 )) || { echo "Only one target release may be specified." >&2; exit 64; }
      TARGET_REQUEST="$arg"
      TARGET_SET=1
      ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 64 ;;
  esac
done

for tool in git node npm codesign launchctl curl plutil ps awk sed grep shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 69; }
done
[[ "$(uname -s)" == "Darwin" ]] || { echo "DarwinRelay's installed-app updater is macOS-only." >&2; exit 69; }
[[ -d "$ROOT/.git" || -f "$ROOT/.git" ]] || { echo "Not a Git checkout: $ROOT" >&2; exit 69; }

cd "$ROOT"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
is_canonical_origin "$ORIGIN_URL" || {
  echo "Refusing to update from non-canonical origin: ${ORIGIN_URL:-<missing>}" >&2
  echo "Expected https://github.com/dcierra/darwinrelay (or its GitHub SSH form)." >&2
  exit 78
}
[[ -z "$(git status --porcelain)" ]] || {
  echo "Refusing to update a modified checkout. Commit/stash/revert your work first:" >&2
  git status --short >&2
  exit 78
}

OLD_SHA="$(git rev-parse HEAD)"
OLD_TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
is_release_tag "$OLD_TAG" || {
  echo "Refusing to update a development checkout. Current HEAD is not an exact stable release tag." >&2
  echo "Keep development work in another worktree; installed runtimes should be pinned to vMAJOR.MINOR.PATCH." >&2
  exit 78
}
OLD_VERSION="${OLD_TAG#v}"

APP_DIR=""
for candidate in /Applications "$HOME/Applications"; do
  if [[ -d "$candidate/DarwinRelay.app" ]]; then APP_DIR="$candidate"; break; fi
done
[[ -n "$APP_DIR" ]] || { echo "Installed DarwinRelay.app not found in /Applications or ~/Applications." >&2; exit 69; }
APP="$APP_DIR/DarwinRelay.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$APP_VERSION" == "$OLD_VERSION" ]] || {
  echo "Refusing a split-version starting state: checkout=$OLD_VERSION app=${APP_VERSION:-unknown}." >&2
  echo "Run ./scripts/doctor.sh and repair the installation before updating." >&2
  exit 78
}

npm run check:integrity >/dev/null

if (( CANDIDATE_MODE == 1 )); then
  (( TARGET_SET == 0 )) || { echo "Do not combine maintainer candidate mode with a release tag argument." >&2; exit 64; }
  git cat-file -e "${CANDIDATE_SHA}^{commit}" 2>/dev/null || { echo "Candidate commit is not present in this repository: $CANDIDATE_SHA" >&2; exit 69; }
  TARGET_SHA="$(git rev-parse "${CANDIDATE_SHA}^{commit}")"
  TARGET_PACKAGE_VERSION="$(git show "${TARGET_SHA}:package.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).version))')"
  is_release_tag "v$TARGET_PACKAGE_VERSION" || { echo "Candidate package version must be a stable semver: $TARGET_PACKAGE_VERSION" >&2; exit 78; }
  TARGET_VERSION="$TARGET_PACKAGE_VERSION"
  TARGET_TAG="candidate:$TARGET_VERSION@${TARGET_SHA:0:12}"
  CMP="$(semver_cmp "v$TARGET_VERSION" "$OLD_TAG")"
  [[ "$CMP" == "1" ]] || { echo "Candidate version must be newer than $OLD_TAG (candidate=$TARGET_VERSION)." >&2; exit 78; }
else
  if [[ "$TARGET_REQUEST" == "latest" ]]; then
    TARGET_TAG="$(latest_stable_tag_from_origin origin)"
    [[ -n "$TARGET_TAG" ]] || { echo "No stable DarwinRelay release tags found on origin." >&2; exit 69; }
  else
    TARGET_TAG="$TARGET_REQUEST"
  fi
  is_release_tag "$TARGET_TAG" || { echo "Invalid release tag: $TARGET_TAG" >&2; exit 64; }
  CMP="$(semver_cmp "$TARGET_TAG" "$OLD_TAG")"
  if [[ "$CMP" == "0" ]]; then
    echo "DarwinRelay is already on $OLD_TAG."
    exit 0
  elif [[ "$CMP" == "-1" ]]; then
    echo "Refusing downgrade $OLD_TAG -> $TARGET_TAG. Use the retained rollback path for recovery instead." >&2
    exit 78
  fi

  REMOTE_TAG_OBJECT="$(git ls-remote --refs origin "refs/tags/$TARGET_TAG" | /usr/bin/awk 'NR==1{print $1}')"
  [[ -n "$REMOTE_TAG_OBJECT" ]] || { echo "Release tag not found on canonical origin: $TARGET_TAG" >&2; exit 69; }
  if git show-ref --verify --quiet "refs/tags/$TARGET_TAG"; then
    LOCAL_TAG_OBJECT="$(git rev-parse "refs/tags/$TARGET_TAG")"
    [[ "$LOCAL_TAG_OBJECT" == "$REMOTE_TAG_OBJECT" ]] || {
      echo "Refusing moved tag $TARGET_TAG (local=$LOCAL_TAG_OBJECT remote=$REMOTE_TAG_OBJECT)." >&2
      exit 78
    }
  else
    git fetch --quiet origin "refs/tags/$TARGET_TAG:refs/tags/$TARGET_TAG"
    [[ "$(git rev-parse "refs/tags/$TARGET_TAG")" == "$REMOTE_TAG_OBJECT" ]] || {
      echo "Fetched tag object did not match origin for $TARGET_TAG." >&2
      exit 78
    }
  fi
  TARGET_SHA="$(git rev-list -n1 "$TARGET_TAG")"
  TARGET_VERSION="${TARGET_TAG#v}"
  TARGET_PACKAGE_VERSION="$(git show "${TARGET_SHA}:package.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).version))')"
  [[ "$TARGET_PACKAGE_VERSION" == "$TARGET_VERSION" ]] || {
    echo "Release metadata mismatch: $TARGET_TAG points to package version $TARGET_PACKAGE_VERSION." >&2
    exit 78
  }
fi
OLD_EXTENSION_VERSION="$(git show "${OLD_SHA}:chrome-extension/manifest.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).version))')"
TARGET_EXTENSION_VERSION="$(git show "${TARGET_SHA}:chrome-extension/manifest.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).version))')"

printf 'DarwinRelay update plan\n'
printf '  source: %s (%s)\n' "$OLD_TAG" "$OLD_SHA"
printf '  target: %s (%s)\n' "$TARGET_TAG" "$TARGET_SHA"
printf '  app:    %s\n' "$APP"
printf '\nThis restarts DarwinRelay and terminates active DarwinRelay shell/PTY/job authority.\n'
if (( ASSUME_YES == 0 )); then
  [[ -t 0 ]] || { echo "Non-interactive update requires --yes after explicit operator approval." >&2; exit 64; }
  read -r -p "Continue with $OLD_TAG -> $TARGET_TAG? [y/N] " answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Update cancelled."; exit 0 ;; esac
fi

# Use the target release's kill-switch before changing HEAD. This lets a newer
# release repair containment logic in an older installed updater. Verify the
# extracted script against the target release's integrity manifest before it is
# executed.
TARGET_DISABLE_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/darwinrelay-disable-target.XXXXXX")"
git show "${TARGET_SHA}:scripts/disable.sh" > "$TARGET_DISABLE_SCRIPT"
TARGET_DISABLE_EXPECTED="$(git show "${TARGET_SHA}:SHA256SUMS" | awk '$2 == "scripts/disable.sh" {print $1; exit}')"
TARGET_DISABLE_ACTUAL="$(shasum -a 256 "$TARGET_DISABLE_SCRIPT" | awk '{print $1}')"
[[ -n "$TARGET_DISABLE_EXPECTED" && "$TARGET_DISABLE_ACTUAL" == "$TARGET_DISABLE_EXPECTED" ]] || {
  echo "Target release kill-switch failed integrity verification." >&2
  exit 78
}
chmod 700 "$TARGET_DISABLE_SCRIPT"

# Use the target's authenticated MCP probe for capability snapshots. The updater
# is normally launched from Terminal/iTerm, whose TCC context is not the same as
# the running DarwinRelay.app. Measuring ui_status through the live local MCP
# runtime exercises the real responsible-process chain instead.
TARGET_PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-probe-target.XXXXXX")"
TARGET_PROBE_SCRIPT="$TARGET_PROBE_DIR/probe-bridge-status.mjs"
git show "${TARGET_SHA}:scripts/probe-bridge-status.mjs" > "$TARGET_PROBE_SCRIPT"
TARGET_PROBE_EXPECTED="$(git show "${TARGET_SHA}:SHA256SUMS" | awk '$2 == "scripts/probe-bridge-status.mjs" {print $1; exit}')"
TARGET_PROBE_ACTUAL="$(shasum -a 256 "$TARGET_PROBE_SCRIPT" | awk '{print $1}')"
[[ -n "$TARGET_PROBE_EXPECTED" && "$TARGET_PROBE_ACTUAL" == "$TARGET_PROBE_EXPECTED" ]] || {
  echo "Target runtime-status probe failed integrity verification." >&2
  exit 78
}
chmod 700 "$TARGET_PROBE_SCRIPT"

HTTP_PORT="${DARWINRELAY_HTTP_PORT:-8787}"
HTTP_TOKEN_FILE="${DARWINRELAY_HTTP_TOKEN_FILE:-$HOME/Library/Application Support/DarwinRelay/http-token}"
OLD_DESKTOP_READY=0
set +e
runtime_ui_status_ready "$TARGET_PROBE_SCRIPT" "$HTTP_TOKEN_FILE" "$HTTP_PORT"
OLD_DESKTOP_RC=$?
set -e
case "$OLD_DESKTOP_RC" in
  0) OLD_DESKTOP_READY=1; echo "Native desktop baseline: READY via live MCP runtime." ;;
  1) echo "Native desktop baseline: not fully granted via live MCP runtime." ;;
  *) echo "Native desktop baseline: unavailable; preservation postcondition will not be asserted." ;;
esac
if (( CANDIDATE_MODE == 1 )) && [[ "$CANDIDATE_EXPECT_DESKTOP_READY" == 1 && "$OLD_DESKTOP_READY" != 1 ]]; then
  echo "Candidate harness observed native desktop READY before the transaction, but updater could not reproduce that live MCP baseline." >&2
  exit 78
fi

record_candidate_failpoint() { # failpoint name
  local point="$1"
  if [[ -n "$CANDIDATE_MARKER_FILE" ]]; then
    umask 077
    printf '%s %s\n' "$point" "$TARGET_SHA" > "$CANDIDATE_MARKER_FILE"
  fi
}

DOMAIN="gui/$(id -u)"
SERVICE_LABEL="io.github.dcierra.darwinrelay.http"
SERVICE_PLIST="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"
OLD_MENU_PID="$(darwinrelay_menu_pids | /usr/bin/awk 'NR==1{print; exit}')"
ROLLING_BACK=0

wait_health() {
  local attempts=100
  while (( attempts > 0 )); do
    curl -fsS --max-time 1 "http://127.0.0.1:${HTTP_PORT}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.2
    attempts=$((attempts - 1))
  done
  return 1
}

app_bundle_version() { # app bundle path
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true
}

restore_old_app() {
  local current rollback
  current="$(app_bundle_version "$APP")"
  [[ "$current" == "$OLD_VERSION" ]] && return 0

  rollback="$(app_bundle_version "$APP_DIR/.DarwinRelay.app.rollback")"
  if [[ "$rollback" == "$OLD_VERSION" ]]; then
    printf 'Restoring rollback app v%s.\n' "$OLD_VERSION" >&2
    DARWINRELAY_APP_INSTALL_DIR="$APP_DIR" "$ROOT/scripts/rollback-menubar-update.sh" || return 1
  else
    printf 'No matching rollback app; rebuilding v%s from restored source.\n' "$OLD_VERSION" >&2
    DARWINRELAY_INSTALL_APP=1 DARWINRELAY_APP_INSTALL_DIR="$APP_DIR" "$ROOT/menubar/build.sh" >/dev/null || return 1
  fi

  [[ "$(app_bundle_version "$APP")" == "$OLD_VERSION" ]]
  codesign --verify --deep --strict "$APP" >/dev/null 2>&1
}

rollback_update() {
  local original_rc="${1:-1}"
  (( ROLLING_BACK == 0 )) || exit "$original_rc"
  ROLLING_BACK=1
  trap - ERR INT TERM
  set +e
  echo
  echo "Update failed; rolling back to $OLD_TAG..." >&2

  DARWINRELAY_INSTALL_DIR="$ROOT" "$TARGET_DISABLE_SCRIPT" >/dev/null 2>&1 || true
  launchctl bootout "$DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1 || true
  stop_all_menu_instances || true

  # Restore source first, then restore/rebuild the matching app. Do not depend on
  # a flag set after deploy success: a deploy can install the new bundle and fail
  # in a later verification step.
  git checkout --detach "$OLD_SHA" >/dev/null 2>&1 || true
  restore_old_app || true

  if [[ -x "$ROOT/scripts/install-http-autostart.sh" && -x "$APP/Contents/MacOS/DarwinRelay" ]]; then
    DARWINRELAY_APP_PATH="$APP" DARWINRELAY_HTTP_AUTOSTART_LOAD_NOW=0 "$ROOT/scripts/install-http-autostart.sh" >/dev/null 2>&1 || true
    launchctl bootout "$DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1 || true
    launchctl enable "$DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "$DOMAIN" "$SERVICE_PLIST" >/dev/null 2>&1 || true
    wait_launchagent_running "$DOMAIN" "$SERVICE_LABEL" >/dev/null 2>&1 || true
    wait_health || true
  fi
  echo "Rollback attempt complete. Run ./scripts/doctor.sh before retrying the update." >&2
  exit "$original_rc"
}
trap 'rollback_update $?' ERR
trap 'rollback_update 130' INT TERM

# Stop before replacing source files. This is deliberately fail-closed: no MCP
# mutation authority remains live while the checkout is between release states.
DARWINRELAY_INSTALL_DIR="$ROOT" "$TARGET_DISABLE_SCRIPT"
if [[ -n "$OLD_MENU_PID" ]] || [[ -n "$(darwinrelay_menu_pids)" ]]; then
  stop_all_menu_instances
fi

# Only after authority is stopped do source and installed app move to the target.
git checkout --detach "$TARGET_SHA"
npm run check:integrity >/dev/null
DARWINRELAY_DEPLOY_VERIFY_RUNTIME_PIDS=0 DARWINRELAY_APP_INSTALL_DIR="$APP_DIR" ./scripts/deploy-menubar-update.sh
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$TARGET_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/.DarwinRelay.app.rollback/Contents/Info.plist")" == "$OLD_VERSION" ]]
if (( CANDIDATE_MODE == 1 )) && [[ "$CANDIDATE_FAILPOINT" == "after_app_install" ]]; then
  record_candidate_failpoint after_app_install
  echo "Maintainer candidate failpoint: after_app_install" >&2
  false
fi

# Installing/replacing an app bundle can race with a pre-existing LaunchServices or
# manually launched menu instance. Re-establish a contained baseline immediately
# before launchd ownership: stop any runtime that appeared during the build/install
# window, then prove every standalone DarwinRelay menu instance is gone.
DARWINRELAY_INSTALL_DIR="$ROOT" "$TARGET_DISABLE_SCRIPT"
stop_all_menu_instances

DARWINRELAY_APP_PATH="$APP" DARWINRELAY_HTTP_AUTOSTART_LOAD_NOW=0 ./scripts/install-http-autostart.sh >/dev/null
plutil -lint "$SERVICE_PLIST" >/dev/null
if grep -Fq '<key>WorkingDirectory</key>' "$SERVICE_PLIST"; then
  echo "Refusing generated autostart plist with source-checkout WorkingDirectory." >&2
  false
fi

launchctl bootout "$DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1 || true
launchctl enable "$DOMAIN/$SERVICE_LABEL"
launchctl bootstrap "$DOMAIN" "$SERVICE_PLIST"
LAUNCHAGENT_PID="$(wait_launchagent_running "$DOMAIN" "$SERVICE_LABEL")"
[[ "$(darwinrelay_menu_pids | /usr/bin/awk -v pid="$LAUNCHAGENT_PID" '$1 == pid {print $1; exit}')" == "$LAUNCHAGENT_PID" ]]
wait_health

if (( OLD_DESKTOP_READY == 1 )); then
  if ! wait_runtime_ui_status_ready "$TARGET_PROBE_SCRIPT" "$HTTP_TOKEN_FILE" "$HTTP_PORT" 100 0.2; then
    echo "Native desktop was READY before update but the live MCP runtime did not recover Accessibility/Screen/Input after the app replacement; rolling back." >&2
    false
  fi
  echo "Native desktop permissions preserved after update via live MCP runtime."
fi

DOCTOR_OUT="$(./scripts/doctor.sh --transport http)"
printf '%s\n' "$DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"CORE VERDICT: READY"* ]]
[[ "$(git rev-parse HEAD)" == "$TARGET_SHA" ]]
if (( CANDIDATE_MODE == 0 )); then
  [[ "$(git describe --tags --exact-match)" == "$TARGET_TAG" ]]
else
  [[ "$(node -p 'require("./package.json").version')" == "$TARGET_VERSION" ]]
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$TARGET_VERSION" ]]
if (( CANDIDATE_MODE == 1 )) && [[ "$CANDIDATE_FAILPOINT" == "after_validation" ]]; then
  record_candidate_failpoint after_validation
  echo "Maintainer candidate failpoint: after_validation" >&2
  false
fi

trap - ERR INT TERM
printf '\nDarwinRelay update complete: %s -> %s\n' "$OLD_TAG" "$TARGET_TAG"
printf 'Checkout and app are aligned at %s; rollback app retained at %s/.DarwinRelay.app.rollback\n' "$TARGET_VERSION" "$APP_DIR"
printf 'HTTP LaunchAgent owns the live menu runtime (pid %s).\n' "$LAUNCHAGENT_PID"
if [[ "$OLD_EXTENSION_VERSION" != "$TARGET_EXTENSION_VERSION" ]]; then
  printf '\nBackground Chrome extension files changed (%s -> %s).\n' "$OLD_EXTENSION_VERSION" "$TARGET_EXTENSION_VERSION"
  printf 'Reload "DarwinRelay Background Browser" from the Extensions page in the dedicated DarwinRelay Chrome profile, then rerun ./scripts/doctor.sh.\n'
fi
