# Transport setup

DarwinRelay's canonical installation model is **source-first / self-build**. Build the menu app first as described in [README.md](README.md). For the normal ChatGPT onboarding path, follow [docs/CHATGPT.md](docs/CHATGPT.md).

This document is the advanced transport reference. It deliberately separates **install/build** from **how an MCP client reaches the runtime**:

- **Option B — HTTPS Server URL through Cloudflare Tunnel**: publishes the loopback HTTP/OAuth front end at a public HTTPS origin.
- **Option A — OpenAI Secure MCP Tunnel**: uses the OpenAI tunnel client for supported workspaces without publishing an inbound public endpoint.

ChatGPT account/workspace availability and rollout behavior are controlled by OpenAI and can change. Check the actual tool/connection surface in your account plus the current OpenAI MCP/developer-mode documentation before choosing a path. `install.sh` is **Option A-specific**; it is not DarwinRelay's universal installer.

Read [SECURITY.md](SECURITY.md) before exposing either transport. A credential accepted by the transport ultimately gates local execution with the authority of the macOS user running DarwinRelay.

## Option B — Cloudflare Tunnel + HTTPS Server URL

The menu app owns this path for normal use. The commands below are the manual equivalent and are useful for diagnosis or headless testing.

Run them from the DarwinRelay source checkout:

```bash
cd /path/to/darwinrelay

# 1. Unlock and create a mode-0600 bearer-token file.
DATA_DIR="$HOME/Library/Application Support/DarwinRelay"
mkdir -p "$DATA_DIR"
printf 'I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n' > "$DATA_DIR/FULL_ACCESS_ENABLED"
chmod 600 "$DATA_DIR/FULL_ACCESS_ENABLED"
export DARWINRELAY_HTTP_TOKEN_FILE="$DATA_DIR/http-token"
if [[ ! -s "$DARWINRELAY_HTTP_TOKEN_FILE" ]]; then
  openssl rand -hex 32 > "$DARWINRELAY_HTTP_TOKEN_FILE"
fi
chmod 600 "$DARWINRELAY_HTTP_TOKEN_FILE"

# 2. Start the HTTP front end, capturing logs where doctor.sh looks for them.
LOG_DIR="$HOME/Library/Logs/DarwinRelay"
mkdir -p "$LOG_DIR"
node mcp-http.mjs >>"$LOG_DIR/http.stdout.log" 2>>"$LOG_DIR/http.stderr.log" &

# 3. Confirm it is up before publishing it.
for _ in $(seq 20); do curl -fsS http://127.0.0.1:8787/healthz && break; sleep 0.25; done

# 4. Publish it.
cloudflared tunnel --url http://127.0.0.1:8787
```

Then create the DarwinRelay custom MCP app in ChatGPT using the current **Apps** / developer-mode flow. See [docs/CHATGPT.md](docs/CHATGPT.md) for current plan/UI caveats.

When the corresponding OAuth fields are present, the HTTP transport uses:

| Setting | Value |
|---|---|
| Endpoint / Server URL | `https://<hostname>/mcp` |
| Authentication | OAuth |
| Registration method | User-defined OAuth client |
| OAuth Client ID | the `client_id` logged at startup |
| OAuth Client Secret | leave blank |
| Token endpoint auth method | `none` |
| Scope | `mcp` |
| OIDC | off / disabled |

ChatGPT opens a consent page served by your own machine; paste the token stored in `~/Library/Application Support/DarwinRelay/http-token` to approve. The token is the operator-consent credential and must remain private.

`cloudflared tunnel --url` runs in the foreground and prints the assigned `https://...trycloudflare.com` hostname to stderr; that is the `<hostname>` above.

`/healthz` answers before `bridge.mjs` is ever spawned, so a green HTTP health check does not prove the full-access latch or bridge process is correct. Confirm with a real `bridge_status` call after connecting the client.

Verify local state with:

```bash
./scripts/doctor.sh
```

For persistence, build/install the menu app and install its per-user LaunchAgent:

```bash
./menubar/build.sh
./scripts/install-http-autostart.sh
```

If the menu app is already running, the installer writes the LaunchAgent for the next login without loading a duplicate instance. Once launchd owns it, it starts at login and restarts after abnormal exits; normal Quit is not immediately respawned. The menu app continues to supervise `mcp-http.mjs` and `cloudflared` as a pair.

To stop everything, from the source checkout:

```bash
pkill -f 'cloudflared tunnel'   # first: disable.sh flags a live cloudflared
./scripts/disable.sh            # non-zero means containment was not proven
```

Stop `cloudflared` **first**. `disable.sh` treats any running `cloudflared` as not-contained, so running it before the `pkill` reports a failure even when the DarwinRelay-owned processes were otherwise reclaimed.

### Use a named tunnel for repeated use

A quick tunnel mints a new random hostname per run, and that hostname is also the OAuth issuer. A restart therefore changes the identity ChatGPT recorded and requires recreating the custom app.

Use a **named** tunnel for anything beyond a one-off:

```bash
cloudflared tunnel create <name>
cloudflared tunnel route dns <name> <hostname>
```

Then configure an ingress in `~/.cloudflared/config.yml` pointing at `http://localhost:8787`. The menu app reads that file and prefers the named tunnel automatically.

## Option A — OpenAI Secure MCP Tunnel

Use this path only when the target OpenAI workspace supports Secure MCP Tunnel and you intentionally want that transport. `install.sh` belongs to this path.

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

### 2. Install the Tunnel transport runtime

Run from your DarwinRelay source checkout:

```bash
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
```

Do not continue until the Tunnel transport's readiness check is healthy. If the tunnel is newly created, allow for control-plane propagation and rerun diagnostics.

### 4. Connect ChatGPT

Use the current ChatGPT **Apps** / developer-mode creation flow documented by OpenAI. Select Secure MCP Tunnel when that connection type is available for the workspace, select or paste the tunnel ID, scan the tools, and create the app.

Availability and permission UI can vary by plan, workspace role, rollout, and policy. The local bridge cannot override a missing Developer mode or Tunnel option.

### 5. Test without mutating anything

Ask ChatGPT:

```text
Use DarwinRelay. Call bridge_status first.
Then list the target repository and read its top-level README/package metadata.
Do not modify files or run shell commands yet.
```

Confirm the expected Mac, runtime version, home directory, Node path, shell, audit mode, and `fullAccessUnlocked: true`.

### 6. Optional: recover a persisted Codex session

Codex continuity is not required for DarwinRelay. If you want it:

```text
Use only DarwinRelay.
Read one of your own persisted Codex thread IDs without resuming it.
If the complete history does not fit, page codex_thread_turns_list oldest-first
with items_view full until nextCursor is null.
Summarize the objective, repository, branch, decisions, changed files, commands,
current errors, and exact next step.
Then inspect the live repository state and continue from the unfinished step.
Do not invoke a Codex model or OpenAI API from shell.
```

## Emergency disable

```bash
# Secure Tunnel transport (install.sh has run):
"$HOME/.local/share/darwinrelay/scripts/disable.sh"

# HTTP transport — run from the source package; this also boots out HTTP autostart if loaded:
./scripts/disable.sh
```

Also disable/remove the DarwinRelay app in the remote MCP client when you want the remote side disconnected.

**Removing the unlock file is fail-closed.** `bridge.mjs` re-reads it before every tool call and exits 78 when it is gone, so removing it refuses the next call. In-flight `shell_exec` work is killed rather than left running, while detached `shell_start` jobs are reclaimed by `disable.sh`.

`disable.sh` boots out DarwinRelay LaunchAgents, stops the front end, bridge processes, and detached job process groups, escalates when necessary, and re-verifies containment. It exits non-zero when containment cannot be proven. It does not kill an unrelated `cloudflared`; if it warns that one is still running, stop that process separately.
