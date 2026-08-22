#!/bin/bash
set -euo pipefail

# Maintainer-only pre-release validation. This runs the candidate commit's real
# update transaction against the installed release checkout without requiring a
# public tag. Normal users should use scripts/update.sh, which remains release-only.
CANDIDATE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="${DARWINRELAY_APP_PATH:-/Applications/DarwinRelay.app}"
ACK="I_UNDERSTAND_THIS_INSTALLS_UNPUBLISHED_DARWINRELAY_CODE"
MODE="roundtrip"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --rollback-check) MODE="rollback" ;;
    --keep-installed) MODE="apply" ;;
    --yes) ARGS+=("--yes") ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./scripts/test-update-candidate.sh [--rollback-check|--keep-installed] --yes

Maintainer-only: validate this clean worktree's exact commit against the installed
DarwinRelay release checkout before publishing a tag. By default the candidate
reaches full LaunchAgent/doctor validation and is then deliberately rolled back
to the original release. --rollback-check injects an earlier failure immediately
after the app swap. --keep-installed leaves a fully validated candidate installed.
USAGE
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 64 ;;
  esac
done
[[ " ${ARGS[*]} " == *" --yes "* ]] || { echo "Candidate testing requires --yes after explicit operator approval." >&2; exit 64; }

[[ -x "$APP/Contents/MacOS/DarwinRelay" ]] || { echo "Installed DarwinRelay.app not found: $APP" >&2; exit 69; }
PROD_ROOT="$(/usr/libexec/PlistBuddy -c 'Print :DarwinRelayPackageDirectory' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$PROD_ROOT" && -d "$PROD_ROOT" ]] || { echo "Installed app does not identify a valid production checkout." >&2; exit 69; }
CANDIDATE_ROOT="$(cd "$CANDIDATE_ROOT" && pwd -P)"
PROD_ROOT="$(cd "$PROD_ROOT" && pwd -P)"
[[ "$CANDIDATE_ROOT" != "$PROD_ROOT" ]] || { echo "Candidate testing requires a separate development worktree." >&2; exit 78; }
[[ -z "$(git -C "$CANDIDATE_ROOT" status --porcelain)" ]] || { echo "Candidate worktree must be clean and committed." >&2; exit 78; }
[[ -z "$(git -C "$PROD_ROOT" status --porcelain)" ]] || { echo "Production checkout must be clean." >&2; exit 78; }

common_dir() {
  local repo="$1" d
  d="$(git -C "$repo" rev-parse --git-common-dir)"
  if [[ "$d" != /* ]]; then d="$repo/$d"; fi
  (cd "$d" && pwd -P)
}
[[ "$(common_dir "$CANDIDATE_ROOT")" == "$(common_dir "$PROD_ROOT")" ]] || {
  echo "Candidate and installed checkout must share the same canonical Git object store." >&2
  exit 78
}

CANDIDATE_SHA="$(git -C "$CANDIDATE_ROOT" rev-parse HEAD)"
OLD_SHA="$(git -C "$PROD_ROOT" rev-parse HEAD)"
OLD_TAG="$(git -C "$PROD_ROOT" describe --tags --exact-match 2>/dev/null || true)"
OLD_VERSION="${OLD_TAG#v}"
CANDIDATE_VERSION="$(node -p 'require(process.argv[1]).version' "$CANDIDATE_ROOT/package.json")"
[[ "$OLD_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Production checkout is not an exact stable release." >&2; exit 78; }
[[ "$CANDIDATE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Candidate package version is not stable semver: $CANDIDATE_VERSION" >&2; exit 78; }
[[ "$CANDIDATE_SHA" != "$OLD_SHA" ]] || { echo "Candidate commit equals installed release commit." >&2; exit 78; }

npm --prefix "$CANDIDATE_ROOT" run check:integrity >/dev/null
HELPER="$(mktemp "${TMPDIR:-/tmp}/darwinrelay-candidate-update.XXXXXX")"
cp "$CANDIDATE_ROOT/scripts/update.sh" "$HELPER"
chmod 700 "$HELPER"

export DARWINRELAY_UPDATE_HELPER=1
export DARWINRELAY_UPDATE_ROOT="$PROD_ROOT"
export DARWINRELAY_MAINTAINER_CANDIDATE_TEST="$ACK"
export DARWINRELAY_UPDATE_CANDIDATE_SHA="$CANDIDATE_SHA"
case "$MODE" in
  rollback) export DARWINRELAY_UPDATE_CANDIDATE_FAILPOINT=after_app_install ;;
  roundtrip) export DARWINRELAY_UPDATE_CANDIDATE_FAILPOINT=after_validation ;;
esac

set +e
"$HELPER" "${ARGS[@]}"
rc=$?
set -e
rm -f "$HELPER" 2>/dev/null || true

app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true
}
launchagent_running() {
  launchctl print "gui/$(id -u)/io.github.dcierra.darwinrelay.http" 2>/dev/null \
    | awk '$1 == "state" && $2 == "=" && $3 == "running" {ok=1} $1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ {pid=$3} END {exit !(ok && pid >= 2)}'
}

if [[ "$MODE" == "rollback" || "$MODE" == "roundtrip" ]]; then
  [[ "$rc" -ne 0 ]] || { echo "Candidate test expected the injected validation failure." >&2; exit 1; }
  [[ "$(git -C "$PROD_ROOT" rev-parse HEAD)" == "$OLD_SHA" ]] || { echo "Rollback did not restore old checkout." >&2; exit 1; }
  [[ "$(app_version)" == "$OLD_VERSION" ]] || { echo "Rollback did not restore app v$OLD_VERSION." >&2; exit 1; }
  launchagent_running || { echo "Rollback did not restore LaunchAgent ownership." >&2; exit 1; }
  DOCTOR_OUT="$("$PROD_ROOT/scripts/doctor.sh" --transport http)"
  [[ "$DOCTOR_OUT" == *"CORE VERDICT: READY"* ]] || { echo "$DOCTOR_OUT" >&2; exit 1; }
  if [[ "$MODE" == "roundtrip" ]]; then
    printf 'Candidate full round-trip passed: %s reached full validation, then %s was restored.\n' "$CANDIDATE_VERSION" "$OLD_TAG"
  else
    printf 'Candidate rollback check passed: %s restored after injected app-install failure.\n' "$OLD_TAG"
  fi
  exit 0
fi

[[ "$rc" -eq 0 ]] || exit "$rc"
[[ "$(git -C "$PROD_ROOT" rev-parse HEAD)" == "$CANDIDATE_SHA" ]] || { echo "Candidate update did not land on the exact tested commit." >&2; exit 1; }
[[ "$(app_version)" == "$CANDIDATE_VERSION" ]] || { echo "Candidate app version mismatch after update." >&2; exit 1; }
launchagent_running || { echo "Candidate update is not LaunchAgent-owned." >&2; exit 1; }
printf 'Candidate apply check passed: %s (%s).\n' "$CANDIDATE_VERSION" "$CANDIDATE_SHA"
