# DarwinRelay Agent Operations Guide

This document is for AI agents and operators using DarwinRelay at runtime. It complements `AGENTS.md`, which is for coding agents modifying the repository.

## Operating model

DarwinRelay exposes a broad local-machine tool surface. Use the narrowest reliable capability that solves the task. The preferred order is:

1. A dedicated API/MCP connector when one exists.
2. DarwinRelay `chrome_*` tools for normal web-page work.
3. Semantic native UI tools (`ui_observe`, `ui_ax_query`, `ui_action`).
4. Raw native mouse/keyboard/OCR only when semantics are unavailable.
5. Shell automation only when the task is genuinely a shell/filesystem/process task.

Normal Chrome page automation should **not** be routed through AppleScript, JXA, direct Chrome executable launches, or shell URL-opening commands. DarwinRelay intentionally forces routine browser work through the managed background Chrome workspace.

## First checks in a new session

Start with read-only diagnostics:

1. `bridge_status` — runtime/version, paths, approval mode, Chrome binding, native-helper availability and effective access model.
2. `ui_status` — Accessibility, Screen Recording, synthetic-input permission, frontmost app and display geometry.
3. `chrome_workspace_status` — whether the background extension/tab pool is ready.
4. `shell_job_list` / PTY state from `bridge_status` when resuming previous local work.

Do not assume a permission because a macOS Settings toggle looks enabled. Use the runtime status returned by the helper.

## Tool catalog

### Bridge, audit and filesystem

- `bridge_status` — inspect version, runtime paths, permissions context, approval mode, helper/browser status and host identity.
- `audit_tail` — read bounded DarwinRelay audit output. Entries from tool calls include a server-generated `correlationId`; HTTP-backed calls may also include `transportRequestId` and an opaque `sessionCorrelationId`. Use those fields to reconstruct overlapping workflows instead of relying on timestamps or JSON-RPC client ids.
- `fs_stat` — metadata for one path.
- `fs_list` — list directories, optionally recursively.
- `fs_read` — bounded file reads.
- `fs_write` — atomic create/replace/append.
- `fs_manage` — mkdir/remove/move/copy/chmod/symlink.
- `apply_patch` — apply a unified Git patch without invoking another model.

Use filesystem tools for structured file work when shell parsing would add unnecessary quoting/risk.

### Shell and background jobs

- `shell_exec` — one command expected to finish within the timeout.
- `shell_start` — detached/background command with persistent logs.
- `shell_job_list` — list stored jobs.
- `shell_job_status` — inspect state and log tail.
- `shell_job_kill` — signal an entire background job process group.

Prefer `shell_start` for services, builds or commands that may outlive one tool call. Do not start an interactive prompt with `shell_exec`; use a PTY.

### PTY sessions

- `pty_start` — start an interactive program on a real pseudo-terminal.
- `pty_read` — read terminal output by absolute cursor.
- `pty_write` — send exact terminal bytes/keystrokes; input is not audit-logged.
- `pty_resize` — change terminal rows/columns and deliver SIGWINCH.
- `pty_signal` — signal the whole PTY process group.
- `pty_close` — close and reclaim the PTY session/process group.

Use PTY for shells, REPLs, ssh/sudo passphrase prompts, TUI programs, debuggers and anything that redraws the terminal.

### Persisted Codex history

- `codex_thread_list` — enumerate stored Codex threads.
- `codex_thread_read` — read a persisted thread without resuming it or starting a model turn.
- `codex_thread_turns_list` — page full persisted turn items when one read is too large.

These tools are for history inspection only. Prefer them over launching Codex merely to recover prior context.

### Managed background Chrome

- `chrome_workspace_status` — inspect the extension-owned DR tab pool.
- `chrome_workspace_setup` — create/expand the pool while Chrome is already naturally foreground.
- `chrome_tabs` — list tabs visible to the configured extension/profile subject to approval mode.
- `chrome_open` — lease an idle DR workspace tab and navigate it.
- `chrome_navigate` — navigate an existing managed tab.
- `chrome_snapshot` — read bounded visible text and interactive elements.
- `chrome_fill` — fill inputs/select/contenteditable fields in background.
- `chrome_click` — click an element returned by `chrome_snapshot`.
- `chrome_close` — return a workspace tab to the pool or close a non-workspace tab.

The default installer creates/reuses a signed-out Chrome profile named **DarwinRelay**. This profile is bound in `dedicated-local` mode so agent browser state is isolated from a normal signed-in profile. A user can explicitly opt into another profile at install time.

Routine calls do not activate Chrome. Native browser dialogs, file pickers, CAPTCHAs and trusted-user-gesture flows can still require foreground/manual interaction.

### Optional raw Browser Harness / CDP

These tools are hidden unless `DARWINRELAY_ADVANCED_BROWSER=1` was set before startup:

- `browser_cdp_status`
- `browser_cdp_call`
- `browser_cdp_session`
- `browser_cdp_events`

This is a separate, broad authority surface over an already-running Browser Harness Unix socket. DarwinRelay does not install/start Browser Harness automatically. Raw CDP fails closed under Strict approvals because arbitrary CDP methods cannot be reliably mapped to URL scopes.

### Native app/process discovery

- `ui_status` — native desktop-control readiness and permissions.
- `ui_app_list` — running applications.
- `ui_app_launch` — launch an app by path/bundle id/name.
- `ui_app_activate` — bring a running app to foreground.
- `ui_window_list` — CoreGraphics window inventory.

### Semantic native observation

- `ui_observe` — primary observation: AX tree plus optional screenshot; returns an expiring observation id.
- `ui_tree` — bounded Accessibility tree.
- `ui_ax_query` — targeted Accessibility search; preferred over dumping a large tree.
- `ui_ax_at` — hit-test a Quartz coordinate and map it back to a semantic AX ref.

Refs are fingerprinted and intentionally fail closed when stale. Do not silently apply an old ref to a newly rendered element.

### Semantic native actions and waits

- `ui_action` — press/focus/set value/etc. on a fingerprinted AX ref with optional precondition and verification.
- `ui_wait_for` — wait for semantic state using AX notifications plus bounded polling fallback.
- `ui_assert` — immediate/bounded semantic assertion.
- `ui_sequence` — execute up to 64 typed native primitives inside one helper process to reduce MCP round trips/races.

For consequential UI mutations, prefer `ui_action` plus a postcondition. `ui_sequence` is useful for deterministic bursts where separate round trips would stale a dynamic AX ref.

### Window, dialogs and file panels

- `ui_window_action` — focus/raise/move/resize/minimize/fullscreen/close a native window.
- `ui_dialogs` — inspect sheets/system dialogs and semantic buttons.
- `ui_dialog_action` — default/cancel/named button on a dialog.
- `ui_file_dialog` — navigate standard macOS Open/Save panels to an absolute path.
- `ui_drag_drop` — semantic or coordinate drag/drop.

`ui_file_dialog` targets standard Apple open/save panels. Custom in-app file browsers may need normal AX/UI handling instead.

### Raw input, clipboard and visual fallback

- `ui_mouse` — move/click/double/right/scroll/drag through CoreGraphics; supports background PID delivery and foreground fallback.
- `ui_keyboard` — Unicode text, named keys and hotkeys; text is redacted from audit.
- `ui_clipboard_read` — read general pasteboard string/types.
- `ui_clipboard_write` — replace pasteboard text; content is redacted from audit.
- `ui_screenshot` — ScreenCaptureKit display/window/region image.
- `ui_ocr` — Vision text recognition over display/window/region.
- `ui_wait_visual` — wait for pixel change/stability.
- `ui_cursor` — visual DarwinRelay AI cursor overlay; it does not move the physical mouse. Prefer transient `move` (auto-hides by default); use persistent `show` only when the user needs the overlay to remain visible, then `hide` it explicitly.

Raw input transport success is not proof the app consumed the event. Use semantic verification whenever the result matters.

## Recommended native workflow

For a normal app task:

1. `ui_app_list` or `ui_window_list` to locate the target.
2. `ui_observe` or `ui_ax_query` for semantic state.
3. `ui_action` for the intended element.
4. Supply `verify` or follow with `ui_wait_for` / `ui_assert`.
5. If semantics are missing, use screenshot/OCR.
6. Use `ui_ax_at` to bridge a visual coordinate back to a semantic ref when possible.
7. Use `ui_mouse` / `ui_keyboard` only as fallback and verify the resulting state.

## Recommended browser workflow

1. `chrome_workspace_status`.
2. `chrome_open` the target URL.
3. `chrome_snapshot`.
4. Use returned selectors with `chrome_fill` / `chrome_click`.
5. Snapshot again to verify.
6. `chrome_close` to return the tab to the pool.

Do not create arbitrary foreground Chrome tabs unless a user explicitly needs a manual/browser-security interaction.

## Approval modes

### Relaxed approvals

This is the default. The user has already chosen to give DarwinRelay broad local authority, so normal `chrome_*` page work and native app mutations do not require a second per-site/per-app terminal grant.

### Strict approvals

When enabled from the menu app:

- managed browser access is limited to active scoped URL grants;
- native/shell GUI mutations may require a one-use app-scoped approval;
- raw Browser Harness/CDP is blocked entirely.

Do not attempt to bypass Strict mode through shell, environment tricks, another browser route or stale approval files.

## Updating an installed runtime

For a source-first installation, use the repository's manual updater from an independent local shell:

```bash
cd /path/to/darwinrelay
./scripts/update.sh
```

Do not run a self-update as a long mutation chain owned only by the DarwinRelay MCP connection being restarted. `scripts/update.sh` verifies a canonical clean release checkout, moves source and app together, refreshes the HTTP LaunchAgent, stops fail-closed, waits for `/healthz`, runs the authenticated doctor, and rolls back on failure. Use `--yes` only when the operator has already explicitly approved the restart.

After reconnect, call `bridge_status` and confirm the installed app/runtime versions match. If the release changes the unpacked background-Chrome extension, reload **DarwinRelay Background Browser** only in the dedicated DarwinRelay Chrome profile and verify `backgroundChrome.extension.version` plus a background tab smoke test.

## Common failure states

### `UI_ELEMENT_STALE`

The AX element changed after observation. Query/observe again and act on a fresh ref. Prefer `ui_sequence` when the target is known to rerender between round trips.

### Accessibility / Screen / Input missing

Run `ui_status`. The user must grant macOS TCC permissions to the actual signed DarwinRelay helper/app identity. DarwinRelay does not edit the TCC database itself.

### Chrome extension offline

Check `bridge_status` and `chrome_workspace_status`:

- confirm the Native Messaging host is installed;
- confirm the unpacked extension is loaded in the configured profile only;
- confirm the extension id matches the public manifest key;
- if using dedicated-local mode, keep the DarwinRelay profile signed out;
- if the DR group is missing, naturally focus Chrome once and run `chrome_workspace_setup`.

### No idle Chrome tab

Release a leased tab with `chrome_close` or expand the pool with `chrome_workspace_setup` while Chrome is already foreground.

### PTY write refused near 1 KiB line size

Canonical terminal input discards overly long lines. Send shorter submitted lines; chunking one unsubmitted line does not bypass the terminal line discipline.

### Transport disconnect during app restart

The menu app/HTTP child can briefly drop the MCP connection during supervised restart. Do not assume data loss. Recheck `bridge_status` after reconnection before repeating a mutating operation.

## Safety rules for agents

- Never claim DarwinRelay is sandboxed.
- Never expose or echo bearer/OAuth/tunnel credentials in chat or logs.
- Never delete a user's dedicated Chrome profile as part of uninstall/cleanup.
- Never weaken code-signing/TCC identity checks merely to make installation easier.
- Do not use direct Chrome shell automation for normal web work.
- Do not interpret a successful low-level input post as proof of application state.
- Prefer read-only discovery before mutation when joining an unfamiliar session.
- Respect explicit user boundaries on production projects and destructive operations.

## Repository documentation for deeper reasoning

- Product/user overview: `README.md`
- Coding-agent rules: `AGENTS.md`
- Architecture/trust/data flow: `docs/ARCHITECTURE.md`
- Native desktop model: `docs/DESKTOP_CONTROL.md`
- Security contract: `SECURITY.md`
- Deployment transports: `DEPLOY.md`
- Development/public-private workflow: `docs/DEVELOPMENT_MODEL.md`
- Upstream lineage: `UPSTREAM.md`
