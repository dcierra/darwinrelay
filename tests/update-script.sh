#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/darwinrelay-update-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DARWINRELAY_UPDATE_LIBRARY_ONLY=1 source "$ROOT/scripts/update.sh"

is_canonical_origin https://github.com/dcierra/darwinrelay
is_canonical_origin https://github.com/dcierra/darwinrelay.git
is_canonical_origin git@github.com:dcierra/darwinrelay.git
if is_canonical_origin https://github.com/someone/darwinrelay; then exit 1; fi
if is_canonical_origin /tmp/darwinrelay; then exit 1; fi

[[ "$(semver_cmp v0.6.4 v0.6.4)" == 0 ]]
[[ "$(semver_cmp v0.6.5 v0.6.4)" == 1 ]]
[[ "$(semver_cmp v0.6.4 v0.7.0)" == -1 ]]
[[ "$(semver_cmp v1.0.0 v0.99.99)" == 1 ]]
if is_release_tag v0.6.4-beta.1; then exit 1; fi
if is_release_tag latest; then exit 1; fi

mkdir -p "$TMP/work"
git -C "$TMP/work" init -q
git -C "$TMP/work" config user.email test@example.invalid
git -C "$TMP/work" config user.name Test
printf 'x\n' > "$TMP/work/file"
git -C "$TMP/work" add file
git -C "$TMP/work" commit -qm init
for tag in v0.6.4 v0.10.0 v1.0.0 v0.9.12; do git -C "$TMP/work" tag "$tag"; done
git -C "$TMP/work" tag v2.0.0-beta.1
[[ "$(latest_stable_tag_from_origin "$TMP/work")" == v1.0.0 ]]

# Structural safety invariants: never destroy local Git work to make an update fit.
if grep -Eq '^[[:space:]]*git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-|pull([[:space:]]|$))' "$ROOT/scripts/update.sh"; then
  echo "destructive Git command found in updater" >&2
  exit 1
fi
grep -Fq 'CORE VERDICT: READY' "$ROOT/scripts/update.sh"
grep -Fq 'rollback-menubar-update.sh' "$ROOT/scripts/update.sh"
grep -Fq 'check:integrity' "$ROOT/scripts/update.sh"
grep -Fq 'Refusing to update a modified checkout' "$ROOT/scripts/update.sh"
grep -Fq 'Refusing moved tag' "$ROOT/scripts/update.sh"


# The updater must be able to use a target release's corrected kill-switch before
# changing HEAD; otherwise a bug in the currently installed disable.sh can make
# the update path impossible to repair.
# shellcheck disable=SC2016
pattern='git show "${TARGET_SHA}:scripts/disable.sh"'
grep -Fq "$pattern" "$ROOT/scripts/update.sh"
grep -Fq 'TARGET_DISABLE_EXPECTED=' "$ROOT/scripts/update.sh"
# shellcheck disable=SC2016
pattern='DARWINRELAY_INSTALL_DIR="$ROOT" "$TARGET_DISABLE_SCRIPT"'
grep -Fq "$pattern" "$ROOT/scripts/update.sh"

echo "manual updater test passed"
