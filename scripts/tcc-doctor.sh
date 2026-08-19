#!/bin/bash
# Reports whether the binaries in the bridge's runtime chain actually hold
# Full Disk Access, and prints the exact paths to add in System Settings.
#
# FDA cannot be granted from a script: the TCC databases are SIP-protected, so
# they are unwritable even as root. The only ways in are a human clicking in
# System Settings, or an MDM-pushed PPPC profile. `tccutil` can only reset.
#
# Run with --open to jump straight to the right settings pane.

set -uo pipefail

NODE_BIN="$(command -v node 2>/dev/null || true)"
ZSH_BIN="${MAC_DEV_BRIDGE_SHELL:-/bin/zsh}"
# A read of the user's own TCC database requires Full Disk Access.
PROBE="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

pass=0
fail=0
absent=0

report() { # name, path, state: 0=granted, 1=missing, 2=absent
  case "$3" in
    0) printf '  GRANTED  %-8s %s\n' "$1" "$2"; pass=$((pass + 1)) ;;
    2) printf '  ABSENT   %-8s %s\n' "$1" "$2"; absent=$((absent + 1)) ;;
    *) printf '  MISSING  %-8s %s\n' "$1" "$2"; fail=$((fail + 1)) ;;
  esac
}

printf 'Full Disk Access check\n'
printf 'Probe: %s\n' "$PROBE"
# The immediate parent is always a shell, whether launched from Terminal or via
# shell_exec, so print the whole ancestry: the presence of launchd vs
# Terminal/iTerm2 in the chain is what tells you which grant is being measured.
printf 'Process ancestry: '
ancestry_pid=$PPID
ancestry=""
while [[ -n "$ancestry_pid" && "$ancestry_pid" != "0" ]]; do
  read -r ancestry_ppid ancestry_comm <<<"$(ps -o ppid=,comm= -p "$ancestry_pid" 2>/dev/null)"
  [[ -n "${ancestry_comm:-}" ]] || break
  # Separator as a prefix, so a pid vanishing mid-walk cannot leave a trailing
  # " <- " pointing at nothing (which reads as truncation of a known parent).
  [[ -n "$ancestry" ]] && ancestry="${ancestry} <- "
  ancestry="${ancestry}${ancestry_comm}"
  [[ "$ancestry_pid" == "1" ]] && break
  ancestry_pid="${ancestry_ppid:-}"
done
printf '%s\n\n' "${ancestry:-unknown}"

if [[ ! -e "$PROBE" ]]; then
  printf 'Probe file does not exist; cannot determine FDA state on this system.\n'
  exit 69
fi

# IMPORTANT: TCC evaluates the *responsible process*, which is usually the
# parent that launched this script, not the binary named below. Run from
# Terminal, these probes inherit Terminal's grant. So a GRANTED line means
# "a process launched from this session can read protected paths" -- it does
# NOT prove that the same binary spawned by launchd can. To test the real
# runtime chain, run this script through the bridge itself (shell_exec).
if [[ -n "$NODE_BIN" ]]; then
  node -e 'require("fs").readFileSync(process.argv[1]).length' "$PROBE" >/dev/null 2>&1
  rc=$?
  report node "$NODE_BIN" "$rc"
else
  report node "not on PATH" 2
fi

if [[ -x "$ZSH_BIN" ]]; then
  # Bare redirection makes the shell itself perform the open(2). `head -c 1`
  # would measure /usr/bin/head, and zsh's `read -k` reads the terminal rather
  # than the redirected fd (and does not exist in bash, a supported value of
  # MAC_DEV_BRIDGE_SHELL).
  "$ZSH_BIN" -c ': < "$1"' sh "$PROBE" >/dev/null 2>&1
  # Capture the status BEFORE any command substitution: the substitution in the
  # report call would otherwise overwrite $? with basename's status, which is
  # always 0, hard-coding this row to GRANTED.
  rc=$?
  report "$(basename "$ZSH_BIN")" "$ZSH_BIN" "$rc"
else
  report "$(basename "$ZSH_BIN")" "$ZSH_BIN not executable" 2
fi

printf '\n%d granted, %d missing, %d absent\n' "$pass" "$fail" "$absent"

if (( absent > 0 )); then
  printf '\nABSENT rows are not a permissions problem: the executable was not found.\n'
  printf 'Install node, or point MAC_DEV_BRIDGE_SHELL at a real shell, then re-run.\n'
fi

if (( fail > 0 )); then
  cat <<'TXT'

To grant it (requires your password; no scripted path exists):

  System Settings -> Privacy & Security -> Full Disk Access -> +

On the Cloudflare/HTTP transport, add the APP BUNDLE, not the binaries:

  /Applications/MacDevBridge.app

Measured on this machine: granting Full Disk Access to the bundle alone produced
GRANTED for both node and zsh, with no separate TCC entries for either, because
macOS attributes access to the responsible process and the chain is

  MacDevBridge.app -> node -> zsh

The control that makes this conclusive is that Terminal was NOT granted access, yet
the check still passed — so the grant was genuinely inherited from the app rather
than from the shell the check was typed into. Add the individual binaries only if the
app bundle alone leaves a row MISSING.

Binaries are hidden in the file picker: press Cmd-Shift-G and paste the path.

Three further things people get wrong:

  1. Granting FDA to Terminal does NOT cover a LaunchAgent-spawned process.
     The grant is per-executable, and launchd children get their own attribution.
  2. A version-managed node path changes when you switch versions. If you
     upgrade Node, re-add the new path and re-run this check.
  3. This check describes the session it ran from, because TCC attributes
     access to the responsible parent process. To test the chain that actually
     serves ChatGPT, run this script *through the bridge*:
       shell_exec -> scripts/tcc-doctor.sh

After granting, restart whichever transport supervises the bridge so the new
permission is picked up. For the Cloudflare/HTTP transport that is the HTTP
front end (mcp-http.mjs); for the OpenAI Tunnel transport it is tunnel-client:

  Tunnel transport (a LaunchAgent exists):
    launchctl kickstart -k "gui/$(id -u)/<the label you installed>"
  Cloudflare/HTTP transport (menu app or optional local.mac-developer-bridge.http LaunchAgent):
    use Stop then Start in the MacDevBridge menu bar app

Listing what is actually loaded:

  launchctl list | grep mac-developer-bridge
TXT
fi

if [[ "${1:-}" == "--open" ]]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
fi

(( fail == 0 && absent == 0 ))
