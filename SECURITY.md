# Security model

### Public CI and security automation

Public CI runs on isolated GitHub-hosted macOS runners. The repository does not dispatch pull-request code to a maintainer workstation. Real mutable AppKit E2E is a local maintainer check because TCC-dependent GUI input is not a trustworthy assertion on disposable hosted sessions.

GitHub CodeQL runs independently for JavaScript/Node and Swift. JavaScript analysis runs on pull requests, every `main` push, and the weekly schedule. The heavier Swift analysis uses SwiftPM and runs after `main` pushes that change any `*.swift` source, `Package.swift`/`Package.resolved`, or the Swift CodeQL workflow itself; it also runs weekly and on manual dispatch. Metadata-only releases therefore do not spend ~20 minutes re-extracting unchanged Swift code. Dependabot monitors GitHub Actions and npm metadata.

## Reporting a vulnerability

Please do not open a public issue for vulnerabilities that could expose credentials, bypass authentication, weaken the explicit unlock, escape a containment claim, or broaden remote execution. Use this repository's private GitHub vulnerability-reporting channel so the issue can be investigated before disclosure.

Include the affected version or commit, reproduction steps, expected versus observed behavior, and any evidence showing the security impact. Do not include real credentials or unrelated personal data.

## Design and threat model

This project intentionally exposes unrestricted local capabilities. There is no path allowlist, command allowlist, sandbox, or internal approval gate after the bridge starts.

`bridge.mjs` itself communicates only over stdio and opens no network socket. The exposure therefore depends entirely on which transport carries it.

- **OpenAI Secure MCP Tunnel** (`install.sh`): `tunnel-client` makes an outbound HTTPS connection and nothing listens for inbound traffic. Nothing is publicly reachable.
- **Cloudflare Tunnel + Server URL** (`mcp-http.mjs`): a listener *is* opened. It is pinned to `127.0.0.1`, but `cloudflared` publishes it at a public hostname, so the endpoint is reachable from anywhere and a static bearer token is the only thing in front of unrestricted shell access.


## HTTP error disclosure boundary

The public HTTP/OAuth transport treats exception text as local diagnostic data. Request-body transport errors and bridge-child failures may contain process state or filesystem details, so remote responses use fixed status-specific messages while the detailed exception remains in stderr/audit-local diagnostics. Tests kill a real bridge child and assert that the transient 503 does not expose exit codes, local paths or unlock-state details.

## OAuth client-secret comparison

An optional configured OAuth `client_secret` is never persisted. DarwinRelay encodes its UTF-8 length and bytes into a fixed 4100-byte in-memory comparison buffer, then scrubs the original environment value before spawning the bridge. Presented secrets are bounded to 4096 UTF-8 bytes, encoded to the same fixed shape, and compared with one `timingSafeEqual`. This avoids both a reusable password-hash verifier and a deliberately expensive password KDF on the public `/token` endpoint, where attacker-controlled repeated requests could otherwise become a CPU denial-of-service primitive.

## Request limits

`MAX_BODY` caps one body at 8 MiB, but that alone did not bound memory: the
`requestTimeout = 0` needed so a long `shell_exec` *response* is not cut off also
disables Node's deadline for *receiving* a body, and `headersTimeout` covers only
headers. A connection could finish its headers then dribble a body staying just
under the cap forever, pinning ~8 MiB and never completing — 250 of them reached
1.75 GB, which OOM-kills the process fronting your shell, unauthenticated. Two limits now apply on every route, and both count the right thing:

- **A global byte budget** (`DARWINRELAY_MAX_BUFFERED_BYTES`, default 96 MiB).
  An earlier attempt capped concurrent *connections* instead, which was a far cheaper
  denial of service — 48 sockets sending one byte each held every slot for the full
  timeout, denying all POST routes for ~10 KB of traffic, and braking `POST /authorize`,
  the only path that can approve a connector. Counting bytes means ordinary small
  bodies cost almost nothing and can never exclude anyone.
- **An idle deadline** (`DARWINRELAY_BODY_IDLE_TIMEOUT_MS`, default 30 s), reset on
  every chunk. It bounds *stalls*, which is what the attack exploits, rather than
  transfer time — a total deadline would truncate a legitimate large `fs_write`, whose
  base64 `content` is bounded only by `MAX_BODY`.

Exceeding the budget yields a retryable 503 delivered to the client, not a bare socket
reset, and both limits are logged (rate-limited, so the log cannot be flooded by the
condition it reports). A malformed numeric override is warned about and ignored rather
than silently disabling the limit.

## OAuth 2.1 (HTTP transport)

ChatGPT's connector dialog offers only OAuth, No Auth, and Mixed, so the static
bearer cannot be configured there. `mcp-http.mjs` therefore implements an OAuth 2.1
authorization server. Properties that matter:

- Access tokens **expire** (1 h) and are **revocable** — the reason to do this rather
  than ship one immortal secret. `/revoke` takes a single token; `/revoke-all`
  requires the static bearer. Rotating the bearer revokes every OAuth session.
- PKCE S256 is required; authorization codes are single-use, short-lived, bound to
  `client_id` and `redirect_uri`, and never survive a restart.
- `redirect_uri` is validated by parsing, requiring the raw string to equal
  `https://chatgpt.com` + a `/connector/oauth/<token>` path. ChatGPT mints a new
  callback per connector, so an exact-match list cannot work — but a string prefix
  would accept `https://chatgpt.com.evil.com/…` and turn `/authorize` into an open
  redirect leaking codes.
- Approval requires the **bridge token** on a consent page served by your own
  machine. That page names the exact callback it will redirect to; read it before
  approving, because anyone who creates their own ChatGPT connector can send you an
  `/authorize` link pointing at their callback.
- Only digests are persisted, in `oauth-state.json` at mode 0600.

## Bearer token boundary (HTTP transport only)

For the HTTP transport, `DARWINRELAY_HTTP_TOKEN` is the entire authorization boundary for any client that can send an `Authorization: Bearer` header.

Note ChatGPT currently cannot: its plugin dialog offers only OAuth, No Auth, or Mixed. So this token protects the endpoint against arbitrary internet traffic, but it is not yet the mechanism by which ChatGPT authenticates. Properties to be aware of:

- It is read once at startup and cannot be rotated without restarting the process.
- `mcp-http.mjs` refuses to start without it, below 24 bytes, or with non-ASCII bytes. Generate it with `openssl rand -hex 32`; a human-chosen passphrase is not appropriate for a credential that is the sole barrier.
- It is deleted from the bridge child's environment, so `shell_exec` and background jobs do not inherit it. This mirrors the `CONTROL_PLANE_API_KEY` handling below.
- That scrubbing covers descendants' environments only. If the token is passed as `DARWINRELAY_HTTP_TOKEN`, it stays visible in `ps eww` output for the process lifetime, because that reads the kernel's exec-time snapshot and is unaffected by deleting the key at runtime. The same limitation applies to `CONTROL_PLANE_API_KEY`. Pass `DARWINRELAY_HTTP_TOKEN_FILE` pointing at a mode-0600 file to keep the plaintext out of the environment entirely.
- Comparison is constant-time over SHA-256 digests, so the endpoint does not leak the token by timing.
- `GET /healthz` is unauthenticated and returns only `{"ok":true}`. It confirms the endpoint exists to anyone who finds the hostname.

Because the hostname is guessable-once-known and the token never rotates, put Cloudflare Access in front of the hostname if you want a second factor. Loopback pinning limits nothing on its own — the exposure is whatever `cloudflared` publishes.

## Explicit unlock

The bridge refuses to start unless either:

- the configured `FULL_ACCESS_ENABLED` file contains exactly `I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS`, or
- the process has `DARWINRELAY_FULL_ACCESS_ACK=I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS`.

`install.sh` requires that acknowledgement and creates a mode-0600 unlock file. `bridge.mjs` re-reads it before every tool call, so `scripts/disable.sh` removing it stops a running bridge at its next call, not just future starts.

This is a revocation latch, not a sandbox or authorization boundary: it gates whether tools may be invoked, and does nothing about what an already-executing command or a detached background job is doing. Note the environment form (`DARWINRELAY_FULL_ACCESS_ACK`) is deliberately *not* revocable this way — it lives in the process's own environment, so a bridge started with it set is not stoppable by deleting a file. Prefer the unlock file for anything you may need to revoke.

## Poisoned repository test harness

`tests/adversarial.mjs` generates a disposable repository with synthetic
adversarial instructions in repository guidance, source comments, logs,
package output, filenames, Git metadata, and credential-shaped files. It proves
the current boundary rather than simulating a defense: while the latch is
armed, model-visible content is returned verbatim and the registered shell and
filesystem authority remains available. Removing the latch makes the next call
fail closed and exits 78.

The harness never executes the embedded instructions, uses no real credential,
and contacts no network endpoint. It does not run a model or claim prompt-
injection resistance. See
[`tests/fixtures/poisoned-repository.md`](tests/fixtures/poisoned-repository.md)
for the test matrix and explicit limitations.

## OAuth redirect policy (HTTP transport)

An authorization endpoint that redirects to an attacker-chosen URL leaks authorization
codes, so `redirect_uri` is validated by parsing, never by prefix or substring:

- Two built-in exact-match values, plus anything in `DARWINRELAY_OAUTH_REDIRECT_URIS`, match exactly. The built-in is `https://chatgpt.com/connector_platform_oauth_redirect`.
- ChatGPT's callbacks match by shape, because it allocates a new path per connector.
  The supplied string must already equal `https://chatgpt.com` plus a path of
  `/connector/oauth/<token>` where the token is `[A-Za-z0-9_-]{1,128}`. Comparing
  against that reassembled form rejects a trailing space (`new URL` silently trims
  one), an explicit `:443`, embedded userinfo, an appended query or fragment, a
  host-case change, a scheme downgrade, and dot-segments the parser collapses.
- A rejected value produces a 400 HTML page with no `Location` header, and the page
  does not reflect the rejected string.

Because any token under that path is a valid ChatGPT connector, this server cannot
distinguish your connector from one an attacker created. Two controls cover that: the
consent page displays the exact callback it will redirect to, and approval requires the
bridge token. **Read the "Will redirect to" line before approving** — that is the point
at which a code would be sent somewhere you did not intend.

## Runtime credential handling

The tunnel runtime API key is stored in the macOS login Keychain. The LaunchAgent contains the Keychain service/account names but no key. `run-tunnel.sh` retrieves the key only for `tunnel-client` startup.

Because `tunnel-client` launches the stdio MCP process as a child, the key would normally be inherited. `bridge.mjs` deletes `CONTROL_PLANE_API_KEY` from its environment before accepting requests, so later `shell_exec` and background jobs do not inherit it automatically.

This is credential hygiene, not isolation. An unrestricted shell can still attempt to read Keychain items, credential files, environment files, browser data, SSH material, or other secrets available to the macOS user.

## Interactive pty sessions

`pty_start` puts a program on a **real terminal** allocated by `lib/ptyhelper.pl`. This is a larger surface than `shell_exec`, not an equivalent one: a session is long-lived, accepts input after it starts, and is a process *session* with a controlling terminal rather than a single command.

What is enforced:

- **Revocation reaches live sessions.** Removing the unlock file terminates them by the same four paths federated children use: the per-call check, an idle re-check interval that is **always armed**, not gated on a live-session count (`DARWINRELAY_UNLOCK_RECHECK_MS`, default 3 s — so a silent client does not extend a session past the latch), `SIGTERM`/`SIGINT`/transport-close teardown, and `disable.sh` from `$DATA_DIR/jobs/*.json`.
- **Helper death is detected.** The session program does not inherit the helper's control descriptor, so when the helper dies the bridge sees it, reclaims the leader's process group, and stops reporting the session as live. Without that, a shell running `trap '' HUP TERM INT` survived, was reparented to pid 1, and was reported `exited:false` for up to the idle timeout.
- **The session cap is taken, not merely checked.** `DARWINRELAY_PTY_MAX_SESSIONS` is reserved synchronously, before any `await`, so concurrent `pty_start` calls cannot all pass one stale check. `kern.tty.ptmx_max` is 511 **system-wide**: exhausting it takes Terminal.app, iTerm and `ssh` away from the operator, which is the operator's own route to `disable.sh`.
- **Bounded retention and lifetime.** Output is a fixed per-session ring (never a growing chunk list — `yes` in a session out-produces any reader), the table is capped including exited sessions, and both an idle timeout and a hard lifetime ceiling reclaim a forgotten session.
- **Keystrokes are never audited.** `pty_write` data is redacted on both the success and the failure path, so a passphrase typed at a no-echo prompt does not land in the log. Byte counts and cursors are recorded; the transcript is not.

Containment, stated precisely:

`pty_close` and every reclaim path kill the leader's **process group**, then SIGKILL anything else still holding the session's **controlling terminal**. The second step is not optional: interactive job control puts every background job — a plain `cmd &`, no `disown`, no `setsid` — in its own process group, so a group kill alone leaves it running and reparented to pid 1. Terminal members are recorded with their process start time while the helper still owns the device, and re-verified against it before anything is signalled, so a recycled pid is reported and **not** killed.

That record is a **sample, not an enumeration**, and the sampling rate is the limit worth knowing. `pty_write` always rescans, because a write is the only thing that can create a terminal member. `pty_read` rescans at most every 150 ms, and the sweeper every 5 seconds.

So a background job started by a write is recorded before that write returns. What still escapes is a job created without any `pty_write` at all — by a program already running in the session — whose whole life fits inside the 150 ms read window and which is gone before the sweeper fires. Such a job is not in the record, so it survives every reclaim path and does **not** appear in `uncontainedPids` either.

This was worse: at a 1-second interval with writes deferring their scan to "the next call", `nohup sleep 995 & disown; exit` escaped outright — measured surviving at gaps of 0 ms and 300 ms and reclaimed only at 1100 ms. This is separate from the `setsid()` gap below; no `setsid` and no detach are needed.

The result fields are separate on purpose: `leaderGroupGone` is the group check alone, `ttyProcessesKilled` lists the background jobs reclaimed individually, `ttyRecycledSkipped` lists pids deliberately left alone, and `containmentVerified` is true **only** when the group is gone and nothing that shared the terminal survived. It can legitimately be false, and `uncontainedPids` says which. **A descendant that both calls `setsid()` and detaches from the terminal escapes both kills** — the same limit `shell_start` has. No stronger claim is made.

**Input limit worth knowing:** in canonical mode the line discipline discards an input line of 1024 bytes or more entirely. `pty_write` refuses such a write instead of reporting bytes the program will never receive; see README.

## Child MCP servers (federation gateway)

`bridge.mjs` can start other MCP servers as child processes and expose their tools under a per-provider prefix (`chrome__navigate_page`). Nothing is federated until an operator configures it: with `DARWINRELAY_MCP_SERVERS` (a path to JSON) and `DARWINRELAY_MCP_SERVERS_JSON` (inline) both unset, the gateway starts no children and advertises no extra tools.

`command` and `args` are always operator-supplied and must be absolute paths to a **pinned** version. Do not point them at `npx -y ...@latest`: that downloads and executes the newest npm publish onto a publicly reachable host, and it also makes the gateway's public tool surface change with no edit here — the exposed set varies with `--slim`, `--no-category-*` and `--categoryExtensions`.

Each child receives an environment built from `{}` — an **allowlist**, because a denylist leaks every secret added to the operator's shell after it was written. Forwarded: `PATH`, `HOME`, `TMPDIR`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TERM`, plus keys named explicitly in the provider's config. Refused even if named in config: the `DARWINRELAY_*` family (including `DARWINRELAY_AUDIT_LOG` — a child that can write the audit log can forge or truncate the record of its own use), `CONTROL_PLANE_API_KEY`, common cloud and AI credentials, `npm_config_*`, and anything matching `/(_TOKEN|_SECRET|_KEY|PASSWORD)$/`. `bridge_status` reports the live allowlist and every refusal.

As with the tunnel key, **this is credential hygiene, not isolation.** Node genuinely needs `PATH` and `HOME`, and with `HOME` set the child can read `~/.ssh`, `~/.aws` and `~/Library/Application Support` anyway.

Flags relied on as security controls are verified by behaviour, not by exit code. A provider may declare `flagCheck`, and every listed flag must literally appear in the child's own help output or the provider is refused at startup. This is not theoretical: `chrome-devtools-mcp` uses yargs non-strictly, so a misspelled or nonexistent flag starts normally and the intended restriction is simply absent, with no error anywhere.

Children are spawned in their own process group and recorded in `$DATA_DIR/jobs/*.json` with `kind: "mcp-child"`, so `disable.sh` reclaims them. Removing the unlock file terminates them by four independent paths: the per-call check, an idle re-check interval that is **always armed**, `SIGTERM`/`SIGINT`/transport-close teardown, and `disable.sh`.

That interval used to be armed only while a child was alive, and it was a real hole: a provider that crashes on its first start is still `restarting` when the count is read, so the interval was never armed and the restarted child ran with the kill switch completely inert — removing the unlock file produced no revocation at all. It is now armed unconditionally.

Limits worth knowing:

- **A browser launched by a child MCP server re-parents itself out of that group.** Killing the provider can leave a browser running. No group-kill containment is claimed for federated browsers; check for stray browser processes separately.
- Without `--experimentalPageIdRouting`, page-scoped tools act on shared selected-page state, so two authorized sessions on one child interfere: one session's `navigate_page` silently changes what another's `click` operates on. This is documented, not load-tested.
- Tool annotations from a child are **untrusted** and pass through as descriptive metadata only. The gateway's own classification comes from operator config keyed on the prefixed name, so an updated or compromised child cannot downgrade its own risk classification.
- A child that dies is restarted with backoff, at most 5 times in 10 minutes, then permanently `failed`. Nothing is replayed: browser element handles are invalidated by a restart, so an auto-replayed click could act on the wrong element. Calls during that window return a typed error immediately rather than hanging. **A personal-mode provider is never restarted automatically** — see below. Neither is a start that failed for a reason retrying cannot improve (a refused grant, an unportable tool name, a version the parent cannot speak).
- An oversized reply is a **payload-size event, not a crash**. A single stdout line over the framing cap is discarded and the framer resynchronises on the next newline; the child is left running and the restart budget is untouched. The cap sits above the largest `maxResultBytes` a provider may be configured for, so a result at the configured ceiling comes back as `RESULT_TOO_LARGE` rather than reaching that path. Previously the cap was below the configurable ceiling and killed the child, so six ordinary requests for a full-page screenshot failed the provider for the life of the bridge.

Known gaps in this release, stated rather than implied:

- **A child's result is not marked as coming from a child.** `content`, `structuredContent`, `isError` and `_meta` pass through unmodified, so a compromised provider can return text shaped exactly like one of the bridge's own error envelopes, and can set keys inside the `io.modelcontextprotocol/*` namespace of a result the bridge appears to have authored.
- **Child-derived text is copied verbatim into operator-facing output** — unparseable stdout lines into the bridge's stderr, and `stderrTail` into `bridge_status`. It may contain ANSI escapes, carriage returns, and lines forged to look like the gateway's own log format.
- **The provider count is uncapped.** Startup is now concurrent and each provider is bounded by `DARWINRELAY_MCP_START_DEADLINE_MS`, so N slow providers cost N concurrent children rather than N times the budget — but nothing limits N.
- **`killNow()` (the kill-switch path) does not remove the child's job-metadata file.** A stale entry naming a dead process group is left in `$DATA_DIR/jobs`, and `disable.sh`'s ownership check accepts a recycled pgid.
- There are **no per-conversation capability leases, and none are achievable** without a protocol change. `mcp-http.mjs` re-keys every request onto one shared `bridge.mjs` child, so nothing on the stdio line distinguishes one OAuth session or conversation from another. What is enforceable is process-global: which providers may start at all, the env allowlist, and isolated-by-default browsing. Do not read the controls above as a per-caller authorization boundary — **every credential that reaches `/mcp` already has unrestricted shell.**

## Background Chrome extension

The optional `chrome_*` tools are designed specifically for the UX problem created by GUI/CDP browser automation on macOS: routine work should not activate Chrome, select a page, or pull the operator out of another app. The integration uses an unpacked Manifest V3 extension plus a Chrome native-messaging host. The extension runs inside one explicitly selected Chrome profile. That profile may be the operator's normal signed-in profile, in which case its tabs carry the same cookies and logged-in sessions, or an intentionally separate signed-out `dedicated-local` profile.

In signed-in mode, the native host is bound at install time to the selected Chrome profile's account identity. The extension reports the signed-in profile through Chrome's identity API; the host refuses a signed-out profile or an email/Gaia-id mismatch.

`dedicated-local` mode is intentionally different: the installer requires an explicit `--profile NAME_OR_DIRECTORY`, records that profile's Chrome directory/display name, and the host requires the extension to report **no signed-in primary account**. Chrome's extension APIs do not expose the profile directory/name to the extension, so the remaining isolation invariant is operational: load the unpacked DarwinRelay extension only in that selected local profile. Loading the same extension into another signed-out profile would be indistinguishable to the native host. If the dedicated profile is later signed in, the host fails closed until the binding is reinstalled. Neither mode is a credential boundary against same-user code that can modify the extension, binding file, installed host, or repository.

That convenience is an authority grant, not a sandbox. An approved background click can submit a form, send a message, change a cloud setting, publish content, or delete data with whatever authority the logged-in website session has. Losing focus theft does not reduce the consequence of a bad action.

The built-in background surface is intentionally narrower than the federated Chrome-DevTools personal mode described below:

- no arbitrary `evaluate_script` tool;
- no network-request/header capture;
- no file-upload tool or native file picker;
- password input values are returned as `<redacted>` by `chrome_snapshot`;
- authenticated web actions are tab list/open/navigate/snapshot/click/fill/close;
- `chrome_workspace_status` and `chrome_workspace_setup` manage only extension-owned local workspace state and do not consume a website grant;
- routine `chrome_open` **does not create a Chrome tab**. It leases one of the pre-created extension-owned tabs from the `DarwinRelay` group;
- `chrome_close` releases an `DarwinRelay` tab back to its idle extension page instead of destroying the pool tab.

The `DarwinRelay` group is a Chrome-native tab group backed by `chrome.storage.local`. The default pool size is four (maximum eight). The group is collapsed when idle and expands while tabs are leased. State is reconciled after extension/service-worker restarts, and the extension can rediscover its own group by title/color plus the presence of an extension-owned workspace page. It deliberately does not adopt an arbitrary user group that merely happens to have the same title. Older/internal `tabs.open` requests are normalized to `workspace.open` in the JS client, native host, and extension so there is no supported loose-tab creation path.

Pool creation remains a foreground-only boundary. On the measured Chrome/macOS combination, even `chrome.tabs.create({active:false})` can foreground Chrome. `chrome_workspace_setup` therefore refuses to create or expand the pool unless a normal Chrome window is **already focused**, and routine browser work fails closed rather than creating a loose fallback tab. If the pool disappears after a Chrome/extension restart, the extension automatically recreates the default pool the next time Chrome becomes naturally focused; it never activates Chrome on the operator's behalf. Once the pool exists, routine open/navigate/read/click/fill/release operations reuse those tabs and avoid creation-time focus theft.

By default, background Chrome runs in **relaxed** approval mode: once the extension/profile binding is installed, normal HTTP/HTTPS URLs do not require per-site grant files. This matches the project's intentional unrestricted-shell trust model and removes approval ceremony from ordinary execution. The operator can enable **Strict approvals** in the menu-bar app at any time; the bridge re-reads `$DATA_DIR/settings.json` on each relevant action, so the change is live. In Strict mode, background-Chrome grants are additive mode-0600 files under `$DATA_DIR/chrome-background-grants/`, each with its own nonce, URL patterns, and expiry capped at 15 minutes. The bridge unions all unexpired patterns and Chrome remains the final URL authority.


Approval mode and browser routing are separate controls. `shell_exec` and `shell_start` always reject direct Chrome AppleScript/JXA, direct Chrome executable launches, and shell `open` calls for HTTP/HTTPS URLs (including background `open -g`) with `CHROME_BACKGROUND_REQUIRED`, even in relaxed mode. The reason is UX, not a claim of containment: DarwinRelay already has a profile-bound background browser path, and allowing a parallel shell-driven Chrome path reintroduced the exact focus theft the extension exists to prevent. Native browser security UI that cannot work through the background surface remains a manual/user-foreground boundary rather than an automatic shell fallback.

The shared-pool behavior is intentionally process-global because `mcp-http.mjs` multiplexes every conversation into one bridge child and does not carry a per-conversation identity on the stdio line. This is a UX/authorization-lifetime improvement, not a per-chat security boundary: once the operator approves a site for background Chrome, every conversation that already has unrestricted access to this bridge can use that site until the grant expires. The same-user/unrestricted-shell caveat still applies.

The local transport between `bridge.mjs` and Chrome is a Unix-domain socket at `$DATA_DIR/chrome-background.sock`, mode 0600 inside the mode-0700 data directory. Installation copies the self-contained native-host runtime to `$DATA_DIR/chrome-native-host.mjs`; Chrome starts that installed copy through its registered Native Messaging wrapper/manifest. Keeping the executable runtime out of protected source folders such as `~/Documents` avoids a macOS TCC stall where Chrome, as the responsible process, can block before the host creates its socket. The host records its pid in `$DATA_DIR/chrome-native-host.pid`. `scripts/disable.sh` treats that host as part of the kill-switch surface, stops it independently of the bridge processes, verifies the process is gone, and removes stale socket/pid artifacts after SIGKILL if cleanup handlers could not run.

The extension requests `tabs`, `tabGroups`, `storage`, `scripting`, `nativeMessaging`, `identity`, `identity.email`, and `<all_urls>` because the actual per-use URL scope is dynamic and signed-in profile verification uses Chrome identity data. Treat the unpacked extension directory, its native-host manifest/wrapper, the installed `$DATA_DIR/chrome-native-host.mjs`, and the profile-binding file as security-sensitive local code. If another same-user process can modify those files, it can modify what the extension does. Likewise, the same honest limit as every personal-browser grant still applies: **`shell_exec` can forge the approval file or talk to same-user local resources.** The grant is an operator-drift gate and an audit boundary, not containment against an already-hostile unrestricted shell.

Some browser actions cannot be made reliable in the background without defeating Chrome's security model. CAPTCHAs, passkeys, native permission prompts, downloads requiring trusted user gestures, file pickers, and similar browser/OS UI may require the human to foreground Chrome. The background tools report that boundary instead of silently activating the browser.

## Optional raw CDP backend

`DARWINRELAY_ADVANCED_BROWSER=1` is an explicit second browser authority surface. When enabled, DarwinRelay can talk directly to an already-running Browser Harness daemon over its same-user Unix socket and issue arbitrary Chrome DevTools Protocol `Domain.method` requests. The adapter does **not** start/install Browser Harness, execute its arbitrary Python surface, or replace the managed `chrome_*` extension workspace. Socket ownership is checked against the current uid before use.

Raw CDP is intentionally hidden when the opt-in is absent and **fails closed whenever Strict approvals is enabled**. Unlike the managed extension API, an arbitrary CDP method can enumerate targets, inspect network events, evaluate JavaScript, alter cookies/storage, upload files or navigate outside a predeclared site; there is no sound generic mapping from `Domain.method + params` to DarwinRelay's URL-pattern grant. Pretending otherwise would make Strict mode misleading. Use the narrower `chrome_*` tools when scoped URL approvals are required.

The raw-CDP adapter preserves the Browser Harness one-JSON-line Unix-socket protocol and bounds response bytes/time. Treat enabling it as equivalent to granting broad control of whatever browser targets that daemon can reach.

## Native desktop-control helper

The native desktop-control runtime adds `MacUIHelper`, a Swift executable used by the built-in `ui_*` tools. It deliberately does **not** run as a daemon: `bridge.mjs` starts one detached helper process for a tool call, bounds its output/time, tracks it in the same in-flight process set as foreground shell commands, and reclaims its process group on bridge revocation or teardown.

The helper receives only a small environment allowlist (`PATH`, `HOME`, temporary-directory/user/locale/terminal variables). Bridge, tunnel, cloud, and other ambient credentials are not intentionally inherited by the helper.

The authority is large:

- Accessibility (`AXUIElement`) can inspect visible/control metadata and perform supported UI actions.
- ScreenCaptureKit can expose anything visible on a captured display/window/region, including sensitive data not present in the Accessibility tree.
- Vision OCR turns captured pixels into model-readable text and bounds; it does not reduce the sensitivity of the underlying screenshot.
- CoreGraphics input can synthesize mouse, keyboard, and drag events into the logged-in desktop session across displays. Foreground delivery uses the global event tap; PID-targeted background delivery is best-effort and may be silently rejected by an application.
- The optional `MacUICursorOverlay` is visual-only: it is click-through, does not warp the physical cursor, and is reclaimed with bridge teardown.
- Window/dialog/file-panel tools can move/resize/minimize/close windows and confirm native Open/Save dialogs.
- Clipboard tools can read or replace general-pasteboard text.
- Application launch/activation can change foreground focus.

macOS TCC remains outside the bridge's control. Accessibility, Screen Recording and CoreGraphics event-post permissions must be granted by the operator to the responsible application/process chain. The helper reports each state and fails closed when a required permission is absent; it does not edit TCC databases.

AX values whose role/subrole indicates a secure field are redacted from `ui_tree`. This is not a complete secret boundary: screenshots, clipboard reads, application titles, non-secure text fields, and other UI-visible state can still contain sensitive data.

Input text is treated specially by the local audit layer. `ui_keyboard.text`, `ui_clipboard_write.text`, `ui_action` values for `set_value`, and the equivalent nested `ui_sequence` fields are replaced with byte-count/SHA-256 correlation markers before any audit serialization, including `DARWINRELAY_AUDIT_MODE=full`. Raw `browser_cdp_call.params` is likewise replaced wholesale with a JSON byte-count/hash marker because CDP parameters can contain cookies, headers, form values or script source.

AX references are ephemeral and include a 64-bit fingerprint: `ax:<pid>:<child.path>:<fingerprint>`. Before semantic mutation, the helper re-resolves the path and recomputes identity from role, subrole, identifier, title, description, and frame. If only the AX child indices changed, it performs a bounded search for the exact fingerprint and accepts recovery only when there is exactly one match. Changed, missing, or ambiguous identities fail with `UI_ELEMENT_STALE`. `ui_tree`/`ui_observe` additionally issue an in-memory 60-second observation id (bounded to 64 generations); mutation calls can require the ref to have existed in that observation. `ui_action.precondition` rechecks semantic properties immediately before mutation and `ui_action.verify` performs a bounded postcondition wait. These are correctness controls, not cryptographic/security boundaries against same-user code.

Strict approvals covers all dedicated native mutation tools as well as detected shell/AppleScript foreground actions. `ui_sequence` resolves the union of applications referenced by every mutation step and consumes one grant for that complete burst. When Strict mode is enabled, application activation/launch, semantic actions, pointer/keyboard/drag input, window actions, dialog actions, and file-panel actions consume the existing one-use app-scoped foreground grant. Relaxed mode permits them directly. As elsewhere in this project, this is an operator-drift control rather than a sandbox against an already-authorized unrestricted shell.

PID-targeted input is a UX optimization, not a stronger correctness primitive. `CGEventPostToPid` can report no transport error while a native application ignores the event. In `auto` mode DarwinRelay can retry once through the foreground compatibility path only after an explicit semantic `verify` clause fails; explicit `background` mode never activates the target. Consequential raw input should therefore carry a postcondition.

Display/window/region coordinates use Quartz global display space. Explicit display-local routing is translated by the helper. This is a correctness convention, not isolation: a coordinate action can affect whichever UI occupies that location when it is emitted, so semantic refs plus re-observation are preferred whenever Accessibility exposes the target.

`ui_file_dialog` is intentionally scoped to Apple's standard NSSavePanel/NSOpenPanel behavior. It does not bypass file permissions, sandbox/TCC checks, or application-specific authorization UI; it only navigates and confirms the same panel visible in the logged-in session.

Chrome's background extension remains the preferred path for ordinary web-page work. The native `ui_*` surface is intentionally capable of operating a **foreground** Chrome window when OS/browser UI or another visual surface cannot be handled through the background extension. Consequently the stronger upstream statement that Chrome GUI automation is structurally background-only applies to `shell_exec`/`shell_start` routing, not to the new full-desktop input surface.

## Background-first desktop GUI policy

Native macOS Accessibility/AppleScript/JXA automation is different from the Chrome extension path. Driving Slack, Finder, System Settings, or another desktop app can inherently require that app to become frontmost. DarwinRelay cannot generically make such UI scripting invisible without changing what operation is being performed.

`DARWINRELAY_GUI_FOCUS_POLICY=background-first` remains the routing preference: use background browser/API paths first. In relaxed approval mode, native GUI control is allowed without an additional approval file when execution genuinely requires it. Direct Chrome automation through `shell_exec`/`shell_start` remains forced through the background extension; the `ui_*` desktop surface is a separate foreground-capable fallback. If the operator turns on **Strict approvals**, detected shell GUI actions and dedicated native mutation tools consume a single-use, app-scoped, maximum-five-minute grant from `scripts/approve-foreground-gui.sh`. A model-supplied environment variable does not disable Strict mode.

Prefer an API/MCP connector first, then the service's web UI through the selected-profile `DarwinRelay` Chrome group, before native GUI scripting. For example, Slack Web can be automated through the background Chrome path while native Slack Accessibility scripting cannot reliably stay in the background.

Strict approvals is an operator-UX/drift control, **not containment**. The bridge still exposes unrestricted shell under the macOS user. Same-user code can forge approval state, invoke lower-level OS mechanisms, modify bridge code, or otherwise bypass a policy implemented by that same unrestricted process. In relaxed mode foreground GUI execution is allowed when needed; in Strict mode the documented foreground path requires an explicit short-lived operator action.

## Personal-profile browser mode

This section describes **federated child-MCP browser providers** such as Chrome DevTools MCP. The built-in background extension above shares the approval-file mechanism but has a different, narrower tool surface and lifecycle.

Isolated browsing (a fresh temporary profile, auto-cleaned) is the default for a federated browser provider and needs no approval.

Attaching a federated provider to the **live** Chrome profile is a *larger* grant than shell access, so it is not a config flag:

- `evaluate_script` against a live profile is arbitrary JavaScript in the origin of every authenticated session on the machine — mail, banking, cloud consoles.
- `list_network_requests` returns `Authorization` and `Cookie` headers, because `--redactNetworkHeaders` defaults to **false**.
- `upload_file` can read an arbitrary local file into a web page, which is an exfiltration path.

It therefore requires a per-use, out-of-band, single-use, expiring grant at `$DATA_DIR/PERSONAL_BROWSER_APPROVED` (mode 0600), created **only** by the operator via `scripts/approve-personal-browser.sh`. `bridge.mjs` never creates it. The grant names one provider, carries a nonce and a non-empty `allowedUrlPatterns`, and is refused if it is absent, malformed, expired, for the wrong provider, or has a TTL over 15 minutes. It is **unlinked on use**, so a second personal session needs a fresh operator action, and its expiry is re-checked on every call. The nonce appears in the audit record for every call it authorises.

URL restriction is enforced **inside Chrome** via `--allowedUrlPattern` (Chrome 149+), not by string matching in the gateway. Prefer `--autoConnect`, which requires the user to enable `chrome://inspect/#remote-debugging` and shows a native Chrome permission dialog. A manual `--remote-debugging-port=9222` plus `--browserUrl` has **no consent dialog and no authentication** — any application on the machine can then control the browser — and is a strictly larger grant, not an equivalent one.

The grant is a **deadline, not a precondition checked on use**. A timer armed when the grant is consumed shuts the child down at `expiresAt` with no tool call involved, and `bridge_status` reports the grant's `expired` flag and `remainingMs` rather than presenting a lapsed grant as current. This matters because federated children are pinged to keep them healthy and have no idle timeout: without the timer, a browser holding every logged-in session on the machine kept running past the 15-minute ceiling for as long as the model stayed quiet.

A personal-mode provider whose child dies is **not** respawned. Each start consumes a grant, so an automatic restart spends the operator's *next* approval: with the provider retrying, a grant written for a future, deliberate session was consumed seconds later and relaunched the personal-profile browser with no user action. A crashed personal session therefore goes to `failed` and requires a fresh, deliberate grant.

**The honest limit: `shell_exec` can forge this file.** The gate stops an unattended model from drifting into personal mode and creates an audit record naming the operator action; it does **not** contain a model that has already decided to escalate. Nothing here should be read as a stronger claim than that.

Two further gaps in this release:

- **`allowedUrlPatterns` are passed as two argv tokens (`--allowedUrlPattern <pattern>`) and are not validated against a leading `-`.** Under yargs a pattern beginning with `-` is parsed as a flag in its own right, so the URL allowlist evaporates and the following token becomes another flag — while the audit record and `bridge_status` still name the patterns as if they were in force. An operator typo reaches the same state.
- **The grant is unlinked before the provider's own preconditions are checked.** A personal provider misconfigured without a `flagCheck` consumes and destroys the approval, then refuses to launch, and the refusal does not mention that the grant is gone.

## Consequences

- A successful tool call can read credentials, alter source code, delete data, deploy production changes, contact external systems, or invoke any installed program with the host user’s authority.
- Prompt injection in repository files, web content, logs, emails, package output, or any other material read by the model can try to steer it into using these tools.
- Remembering approval for write tools removes an important human checkpoint for that conversation.
- Tool annotations are honest. Write-capable tools are not disguised as read-only.
- macOS TCC, Full Disk Access, SIP, ACLs, Keychain controls, and `sudo` remain in force.
- Non-interactive shell execution has no interactive TTY for password prompts.
- The metadata audit log can show that a tool was called, but monitoring does not prevent the action.
- On the HTTP transport, a disclosed bearer token yields unrestricted shell as the desktop user from anywhere on the internet, with no second factor and no rotation short of a restart.
- A disclosed OAuth **refresh** token does the same for up to 30 days, and unlike the access token it survives a restart because it is persisted in `oauth-state.json`. Rotating the bearer invalidates it, because that changes the epoch every stored token is bound to.

## Recommended operational controls

Even when unrestricted access is intentional:

1. Keep the developer-mode app private to the intended workspace/user.
2. Use a restricted tunnel runtime key with only Tunnels Read + Use (Tunnel transport), or put Cloudflare Access in front of the published hostname (HTTP transport).
3. Keep the runtime key separate from admin keys, and the bearer token out of shell history and any committed file.
4. Retain ChatGPT confirmations for production deploys, credential changes, force pushes, database destruction, and user-data deletion.
5. Keep the default metadata audit mode unless full argument logging is explicitly required.
6. Disable the bridge when not in use.
7. Treat instructions found inside files or external content as untrusted data, not authority to invoke tools.
8. Review Keychain and Full Disk Access grants periodically.

## Kill switch

```bash
# From the extracted package directory:
./scripts/disable.sh

# Or, if you ran install.sh (Tunnel transport):
~/.local/share/darwinrelay/scripts/disable.sh
```

**Removing the unlock file is now fail-closed.** `bridge.mjs` re-reads it before every tool call and exits 78 when it is gone, so `rm` alone refuses the next call rather than letting an in-flight bridge keep answering `200`. A `shell_exec` already in flight is **killed** on revocation: the bridge SIGKILLs each in-flight command's process group before exiting, so a command cannot outlive the latch. Its caller still gets no result for that call. Detached `shell_start` jobs are a separate case — they outlive the bridge by design, and `disable.sh` reclaims them from the recorded process groups.

`disable.sh` therefore stops three separate things and re-verifies each after escalating to `SIGKILL`:

1. The HTTP front end, identified by `$DATA_DIR/mcp-http.pid` (cross-checked against the process's actual command line, because the pidfile is not removed on `SIGKILL` or reboot).
2. Any `bridge.mjs` processes, including one owned by `tunnel-client`.
3. **Detached `shell_start` background jobs.** These spawn with their own process groups and outlive `bridge.mjs` entirely. They are signalled by the process-group ids recorded in `$DATA_DIR/jobs/*.json`, and verified using those same targets — killing by group while verifying by leader pid previously let a job running `sleep 300 &` pass verification while still alive.
4. **Interactive pty sessions** (`kind: "pty"`, process group = the `setsid`'d session leader) and **child MCP servers** (`kind: "mcp-child"`), recorded in the same jobs directory and reclaimed by the same field-driven path.

It exits non-zero and warns if any of those survive, if the unlock file could not be removed, if `launchctl bootout` failed or the LaunchAgent domain could not be queried, or if `cloudflared` is still publishing the hostname. **A non-zero exit means not contained.**

Limits worth knowing:

- The port probe only covers `DARWINRELAY_HTTP_PORT` as seen by *your* shell.
- A job whose metadata file was deleted cannot be found at all. Job metadata is also never pruned, so an old entry whose pid has been recycled can be reported as a live job. Run `shell_job_list` before disabling if this matters.
- A job process that left its group (`setsid`, a double-forking daemon) is in neither the signal list nor the verification, and the script says so on stdout.
- `disable.sh` reads `DARWINRELAY_DATA_DIR`, `DARWINRELAY_INSTALL_DIR`, `DARWINRELAY_UNLOCK_FILE`, `DARWINRELAY_HTTP_PORT` and `LAUNCHCTL_BIN` from *your* shell, not from the running process. If the deployment set any of them, the responding shell must set the same values. `DARWINRELAY_UNLOCK_FILE` is the one that bites: with the wrong path `disable.sh` reports `Unlock file already absent` — a reassuring line — and can still exit 0 while the real latch is armed.

Removing the unlock file **is** an incident-response control: `bridge.mjs` re-reads it before every tool call, so the next call is refused and the process exits 78. What it does not do is reach across the two gaps named above — an already-executing command, and detached `shell_start` jobs. `disable.sh` covers those.

One exception, and it is the important one: a bridge started with `DARWINRELAY_FULL_ACCESS_ACK` set in its environment **never reads the file**, so deleting it changes nothing for that process — not for its tool calls, and not for its live pty sessions or child MCP servers either. Prefer the unlock file for anything you may need to revoke.

That exception no longer propagates. `bridge.mjs` captures the variable at startup and deletes it from its own environment, so no `shell_exec` or `shell_start` child inherits it. Previously every child did, which meant a single tool call could re-launch the bridge with the acknowledgement pre-set and produce a process the kill switch could not stop — a route around the latch, opened by the tool the latch exists to gate.

For defense in depth, also delete the ChatGPT developer-mode app or plugin — that revokes the remote side regardless of local state — and revoke the tunnel runtime key or rotate the bearer token.
