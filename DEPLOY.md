# Deployment checklist

This checklist gets the bridge from the downloaded archive to a callable ChatGPT toolset.
Option A exposes no inbound port. Option B publishes an HTTPS endpoint through
Cloudflare Tunnel; read `SECURITY.md` before choosing it.

Pick a transport first. **Option A** requires the Tunnel connection type, which
personal ChatGPT accounts cannot select. If the Tunnel toggle in ChatGPT's
plugin dialog is greyed out, skip to Option B.

## Option B — Cloudflare Tunnel + Server URL (personal accounts)

```bash
cd ~/Downloads/darwinrelay

# 1. Unlock and generate the bearer token.
mkdir -p "$HOME/Library/Application Support/DarwinRelay"
printf 'I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n' \
  > "$HOME/Library/Application Support/DarwinRelay/FULL_ACCESS_ENABLED"
chmod 600 "$HOME/Library/Application Support/DarwinRelay/FULL_ACCESS_ENABLED"
export DARWINRELAY_HTTP_TOKEN="$(openssl rand -hex 32)"
printf 'token: %s\n' "$DARWINRELAY_HTTP_TOKEN"

# 2. Start the HTTP front end, capturing logs where doctor.sh looks for them.
#    Without the redirect its 401s, respawns, and errors are lost on scroll.
LOG_DIR="$HOME/Library/Logs/DarwinRelay"
mkdir -p "$LOG_DIR"
node mcp-http.mjs >>"$LOG_DIR/http.stdout.log" 2>>"$LOG_DIR/http.stderr.log" &

# 3. Confirm it is up before publishing it. Retry: node needs a moment to bind,
#    and this is the only gate before step 4 exposes the machine.
for _ in $(seq 20); do curl -fsS http://127.0.0.1:8787/healthz && break; sleep 0.25; done

# 4. Publish it.
cloudflared tunnel --url http://127.0.0.1:8787
```

Then connect ChatGPT with **OAuth** — its dialog has no API-key field, so the bearer
token is the *consent* credential rather than the transport credential:

| Field | Value |
|---|---|
| Connection | Server URL |
| Server URL | `https://<hostname>/mcp` |
| Authentication | OAuth |
| Registration method | User-Defined OAuth Client |
| OAuth Client ID | the `client_id` logged at startup |
| OAuth Client Secret | leave blank |
| Token endpoint auth method | `none` |
| Default scopes | `mcp` |
| OIDC enabled | **untick** |

ChatGPT opens a consent page served by your own machine; paste the bridge token to
approve. Prefer a **named** tunnel over the quick tunnel in step 4 — see the note
under §7 for why a rotating hostname breaks the connector.

`cloudflared tunnel --url` runs in the foreground and prints the assigned
`https://...trycloudflare.com` hostname to stderr; that is the `<hostname>` above.

Note `/healthz` answers before `bridge.mjs` is ever spawned, so a green step 3
does not prove the unlock file is correct. Confirm with a real call after
connecting the plugin.

Verify with `scripts/doctor.sh`, which reports the HTTP front end's state and the
Full Disk Access check. For persistence, build/install the menu app and install
its per-user LaunchAgent:

```bash
./menubar/build.sh
./scripts/install-http-autostart.sh
```

If the menu app is already running, the installer writes the LaunchAgent for the
next login without loading a duplicate instance. Once launchd owns it, it starts
at login and restarts after abnormal exits; normal Quit is not immediately
respawned. The menu app continues to supervise `mcp-http.mjs` and `cloudflared` as
a pair.

To stop everything, from this directory:

```bash
pkill -f 'cloudflared tunnel'   # first: disable.sh flags a live cloudflared
./scripts/disable.sh            # read the output; non-zero means NOT contained
```

Stop `cloudflared` **first**. `disable.sh` treats any running `cloudflared` as
not-contained, so running it before the `pkill` reports "NOT contained" and exits 1
every time on a perfectly contained host — which teaches you to ignore the one signal
you are told to read.

## Option A — OpenAI Secure MCP Tunnel (workspace accounts)

### 1. Create the OpenAI tunnel resources

In OpenAI Platform:

1. Create or select a tunnel that includes the ChatGPT workspace where the app will be used.
2. Ensure the operator and runtime-key principal have Tunnels Read + Use.
3. Create a restricted runtime API key for the long-lived tunnel client. Do not use an admin key.
4. Download the supported `tunnel-client` binary for the Mac.

Install the binary:

```bash
mkdir -p "$HOME/.local/bin"
mv ~/Downloads/tunnel-client "$HOME/.local/bin/tunnel-client"
chmod 700 "$HOME/.local/bin/tunnel-client"
"$HOME/.local/bin/tunnel-client" help quickstart
```

Use the actual downloaded filename if the release archive names it differently.

### 2. Install the bridge

```bash
cd ~/Downloads/darwinrelay

export DARWINRELAY_FULL_ACCESS_ACK='I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS'
export CONTROL_PLANE_TUNNEL_ID='tunnel_0123456789abcdef0123456789abcdef'
read -r -s -p 'Tunnel runtime API key: ' CONTROL_PLANE_API_KEY; printf '\n'
export CONTROL_PLANE_API_KEY

./install.sh

unset CONTROL_PLANE_API_KEY DARWINRELAY_FULL_ACCESS_ACK
```

The installer must finish with successful bridge tests, successful `tunnel-client doctor`, and a loaded LaunchAgent.

### 3. Verify the local runtime

```bash
"$HOME/.local/share/darwinrelay/scripts/doctor.sh"
open http://127.0.0.1:8080/ui
```

Do not continue until `/readyz` is healthy. If the tunnel is newly created, allow for control-plane propagation and rerun diagnostics.

### 4. Connect ChatGPT

1. Open ChatGPT Settings → Security and login and enable Developer mode.
2. Open Plugins and create a developer-mode app.
3. Select Connection: Tunnel.
4. Select or paste the tunnel ID.
5. Save the app and add it to a new Chat conversation.

Availability and permission UI can vary by account rollout and workspace policy. The local bridge cannot override a missing Developer mode or Tunnel option.

### 5. Test without mutating anything

Ask ChatGPT:

```text
Use DarwinRelay. Call bridge_status, then fs_stat for ~/.codex. Do not call any write tool or shell command yet.
```

Confirm the expected Mac username, home directory, Node path, shell, audit mode, and `fullAccessUnlocked: true`.

### 6. Recover the target Codex session

```text
Use only DarwinRelay.
Read one of your own persisted Codex thread IDs without resuming it.
If the complete history does not fit, page codex_thread_turns_list oldest-first with items_view full until nextCursor is null.
Summarize the objective, repository, branch, decisions, changed files, commands, current errors, and exact next step.
Then inspect the live repository state and continue from the unfinished step.
Do not invoke a Codex model or OpenAI API from shell.
```

### 7. Emergency disable

```bash
# Tunnel transport (install.sh has run):
"$HOME/.local/share/darwinrelay/scripts/disable.sh"

# HTTP transport — run from the package; this also boots out HTTP autostart if loaded:
./scripts/disable.sh
```

Also disable or remove the developer-mode app in ChatGPT when you want the remote side disconnected.

**A rotating hostname breaks the connector.** `cloudflared tunnel --url` mints a new
random hostname per run, and that hostname *is* the OAuth issuer — so a restart
between discovery and callback makes the issuer stop matching what ChatGPT recorded,
and a strict client drops the callback silently. Use a **named** tunnel for anything
beyond a one-off: `cloudflared tunnel create <name>`, `cloudflared tunnel route dns
<name> <hostname>`, then an ingress in `~/.cloudflared/config.yml` pointing at
`http://localhost:8787`. The menu bar app reads that file and prefers the named
tunnel automatically.

**Removing the unlock file is fail-closed.** `bridge.mjs` re-reads it before every
tool call and exits 78 when it is gone, so `rm` alone refuses the next call. An
in-flight `shell_exec` is killed rather than left running, and detached
`shell_start` jobs still outlive the bridge until `disable.sh` reclaims them.

`disable.sh` first boots out either DarwinRelay LaunchAgent (Secure Tunnel or
HTTP/Cloudflare autostart), then stops the front end (by pidfile), any `bridge.mjs`
processes, and detached job process groups. It escalates to `SIGKILL`, re-verifies
the same targets, and exits non-zero if any survive — or if the unlock file could
not be removed, or `launchctl` could not be queried. It does not kill an unrelated
or already-detached `cloudflared`; if it warns that one is still running, the
hostname may still resolve:

```bash
pkill -f 'cloudflared tunnel'
```

The most reliable remote cutoff is deleting the plugin in ChatGPT, which revokes
the connection regardless of local state.
