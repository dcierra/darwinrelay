#!/bin/bash
# Shared code-signing helpers for every executable that participates in DarwinRelay's
# native desktop runtime. Keep one identity across the menu app and its helper
# processes so macOS TCC can key grants to a stable designated requirement.

darwinrelay_codesign_identity() {
  if [[ -n "${DARWINRELAY_SIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$DARWINRELAY_SIGN_IDENTITY"
    return 0
  fi
  command -v security >/dev/null 2>&1 || return 0
  security find-identity -v -p codesigning 2>/dev/null \
    | awk '/\) [0-9A-F]{40} "/ {print $2; exit}' \
    || true
}

darwinrelay_sign_runtime() {
  local target="$1"
  local identifier="$2"
  local identity="${3:-}"
  if [[ -z "$identity" ]]; then identity="$(darwinrelay_codesign_identity)"; fi

  if [[ -n "$identity" ]] && codesign --force --options runtime --identifier "$identifier" --sign "$identity" "$target" >/dev/null 2>&1; then
    printf '  signed %s as %s with %s\n' "$target" "$identifier" "$identity" >&2
    return 0
  fi

  # CI and machines without a developer certificate still need runnable native
  # binaries. Keep an explicit identifier even in the fallback signature, but
  # warn because an ad-hoc designated requirement remains cdhash-based and TCC
  # grants can therefore be invalidated by the next rebuild.
  if codesign --force --identifier "$identifier" --sign - "$target" >/dev/null 2>&1; then
    printf 'warning: signed %s ad-hoc as %s; TCC grants may reset after rebuilds\n' "$target" "$identifier" >&2
    return 0
  fi

  printf 'error: codesign failed for %s\n' "$target" >&2
  return 1
}
