# Connect DarwinRelay to ChatGPT

This guide is the canonical ChatGPT onboarding path for the current **source-first / self-build** DarwinRelay distribution model.

The target path is:

```text
clone → self-build → start DarwinRelay → connect ChatGPT → verify → first useful task
```

Chrome automation, Codex history, and native macOS UI permissions are optional follow-up capabilities. They are not required for the first shell/filesystem coding workflow.

## Before you start: ChatGPT availability

ChatGPT controls which MCP capabilities are exposed to each account/workspace, and rollout behavior can change independently of DarwinRelay. OpenAI's published plan matrix may not perfectly match every account during rollout, so verify the actual DarwinRelay tool surface shown in your ChatGPT account and check the current [OpenAI developer-mode and MCP app documentation](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt-beta) when setting up the connection.

DarwinRelay can expose read, write, and execute tools; ChatGPT decides which of those it will surface and invoke in the current account/session.

This guide uses a normal ChatGPT conversation with a custom app. OpenAI currently documents that the separate **Agent mode** feature does not use custom apps.

## 1. Install DarwinRelay

Requirements:

- macOS 13 or newer;
- Node.js 18 or newer;
- Xcode Command Line Tools / `swiftc`;
- `cloudflared` on the login-shell `PATH` for the Server URL path described below.

### Option A — Install with a local coding agent

If you already use Codex, Claude Code, or another local coding agent with shell/filesystem access, give it this repository and let it perform the self-build:

```text
Install DarwinRelay on this Mac from:
https://github.com/dcierra/darwinrelay

Read AGENTS.md and the installation documentation first.
Install or verify required dependencies, then build and install DarwinRelay
using the documented source-first/self-build path.

Do not bypass macOS security controls. Do not use my personal Chrome profile.
Stop and ask me whenever macOS requires Accessibility, Screen Recording,
Input/Post Events, Full Disk Access, Keychain access, or another user-consent
action. Tell me exactly what I need to approve manually.

After installation, verify that DarwinRelay starts correctly and report what
remains to connect it to my MCP client.
```

The desired behavior is `agent -> documented install -> explicit user consent handoff`, not an agent inventing workarounds. Any step where a capable local agent has to guess should be treated as a DarwinRelay onboarding/script issue.

### Option B — Install manually

```bash
git clone https://github.com/dcierra/darwinrelay.git
cd darwinrelay
npm run check
./menubar/build.sh
open /Applications/DarwinRelay.app
```

If `/Applications` is not writable, the build script can install under `~/Applications` instead.

DarwinRelay does not currently ship a prebuilt `.app`/`.dmg`. The locally built app intentionally keeps using the runtime files in your source checkout, so keep that checkout in place after installation.

A paid Apple Developer Program membership is not required. When no persistent signing identity is available, the build falls back to ad-hoc signing; macOS may require native desktop permissions to be granted again after later rebuilds.

## 2. Start the MCP transport

Open the **DR** menu-bar item and choose **Start**.

Start does three important things for the menu-app/HTTP path:

1. arms DarwinRelay's explicit full-access latch;
2. starts the local `mcp-http.mjs` front end;
3. starts `cloudflared` and obtains the public HTTPS origin used by ChatGPT.

The menu should eventually show a running MCP transport and a Server URL.

If Start fails because `cloudflared` is not found, install it and ensure the executable is visible on the login-shell `PATH`, then try again.

### Quick tunnel vs named tunnel

Without a named Cloudflare tunnel configuration, the app can use a quick tunnel for a one-off setup. Quick tunnels receive a different hostname after restart, and the hostname is also the OAuth issuer; a new hostname means the ChatGPT app configuration must be recreated.

For repeated use, configure a named Cloudflare tunnel as described in [DEPLOY.md](../DEPLOY.md).

## 3. Create the DarwinRelay app in ChatGPT

Open the **DR** menu and choose **Copy ChatGPT Setup**. Keep the copied bearer token private.

OpenAI's current UI calls custom MCP integrations **Apps**. Depending on plan and workspace role, developer mode is enabled from workspace settings or from **Settings → Apps → Advanced Settings**, and a custom app is created from **Apps → Create**. Follow the current OpenAI documentation if the labels differ in your account.

> [!NOTE]
> The clipboard text in DarwinRelay v0.6.2 still starts with older `Plugins → New Plugin` wording. Use the current **Apps → Create** flow instead; the endpoint/OAuth values in the clipboard payload are still the values DarwinRelay exposes. Updating that menu copy is tracked as onboarding work.

Create the app with the DarwinRelay values. When the corresponding fields are shown, the current HTTP/OAuth path uses:

| Setting | DarwinRelay value |
|---|---|
| Endpoint / Server URL | the copied `https://<hostname>/mcp` URL |
| Authentication | OAuth |
| Registration method | User-defined OAuth client |
| OAuth Client ID | the copied DarwinRelay client id |
| OAuth Client Secret | leave blank |
| Token endpoint auth method | `none` |
| Scope | `mcp` |
| OIDC | off / disabled |

Then use ChatGPT's **Scan Tools** / create flow. During OAuth authorization, DarwinRelay opens its consent page; paste the bearer token copied from the DR menu to prove that the approval came from the Mac operator.

When testing, select the DarwinRelay app from ChatGPT's tools menu or mention it in the prompt. OpenAI currently applies app selection to the message that uses it, so select/mention DarwinRelay again when a later message needs another local action.

Do not paste that bearer token into issues, logs, screenshots, chat messages, or Git. A client that can send it directly as a bearer credential can authorize the endpoint.

## 4. Verify the connection read-only

Start a new ChatGPT conversation with the DarwinRelay app enabled and ask:

```text
Use DarwinRelay.
Call bridge_status first.
Then list ~/Projects/myapp and read its top-level README/package metadata.
Do not modify files or run shell commands yet.
```

Check that `bridge_status` reports the Mac and runtime you expected. This is the point to stop if the host/path/version is surprising.

The first verification does not need:

- Accessibility;
- Screen Recording;
- Input/Post Events;
- Google Chrome;
- Codex history.

Full Disk Access is only needed when the task must read macOS-protected locations. A normal project under your home directory should not require it merely to prove the core coding path works.

## 5. Run the first real local task

If the DarwinRelay app exposes write/execute tools in your ChatGPT session, use a bounded developer task:

```text
Use DarwinRelay and work on ~/Projects/myapp.

Inspect the repository and current git status. Run the relevant tests and
reproduce the failure. Find the underlying cause, make the smallest correct fix,
rerun the affected tests, and verify the result locally.

Do not deploy, force-push, change credentials, or delete user data.
```

The desired first-use proof is not "ChatGPT can see a list of MCP tools." It is:

```text
ChatGPT inspected the real project → executed locally → changed it → verified the result
```

## 6. Add optional capabilities only when needed

### Native macOS UI

Grant Accessibility, Screen Recording, and Input/Post Events when you want DarwinRelay to operate native application UI. Run `ui_status` after granting permissions.

These permissions should not block the core shell/filesystem onboarding path.

### Full Disk Access

Grant Full Disk Access only when a task needs protected filesystem locations. The current diagnostic is:

```bash
./scripts/tcc-doctor.sh
```

The menu-app/HTTP runtime should normally be granted through the DarwinRelay app bundle as described by that script.

### Background Chrome

Set up the dedicated signed-out `DarwinRelay` Chrome profile only when you need `chrome_*` tools. See the [Background Chrome workspace](../README.md#background-chrome-workspace) section.

Do not opt into an everyday Chrome profile unless you intentionally want DarwinRelay to use it.

### Codex continuity

Codex is optional. If persisted Codex threads exist, ChatGPT can use `codex_thread_*` tools to inspect them without starting another Codex model turn.

## 7. Stop DarwinRelay

Use **Stop** in the DR menu when you are done. Stop removes the full-access unlock latch and terminates the menu-owned HTTP/tunnel pair.

For manual/emergency containment and transport-specific shutdown details, see [DEPLOY.md](../DEPLOY.md) and [SECURITY.md](../SECURITY.md).

## Troubleshooting

Run:

```bash
./scripts/doctor.sh
```

The current doctor reports transport, LaunchAgent, token-source, logs, and Full Disk Access state. It is not yet the final onboarding health gate.

The product target is a doctor that reports separate groups instead of treating every optional capability as a failed installation:

```text
Core / ChatGPT coding path    READY | ACTION REQUIRED
Native desktop               READY | OPTIONAL / ACTION REQUIRED
Background Chrome            READY | OPTIONAL / ACTION REQUIRED
Codex continuity             READY | OPTIONAL / NOT CONFIGURED
```

For each failed core check it should name the exact failing component and the next action. This requirement is tracked in [ROADMAP.md](../ROADMAP.md).
