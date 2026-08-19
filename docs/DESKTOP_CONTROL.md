# Native Desktop Control

This private line extends Mac Developer Bridge into a native macOS computer-use runtime while preserving the existing shell/filesystem/PTY/Chrome architecture and the global unlock/kill switch.

## Architecture

```text
ChatGPT
  |
  | MCP
  v
bridge.mjs
  |-- shell / filesystem / PTY / Codex
  |-- signed-in Background Chrome workspace
  `-- native ui_* tools
        |
        | bounded JSON stdin/stdout; one helper process per call
        v
      MacUIHelper (Swift, short-lived per burst)
        |-- AppKit / NSWorkspace
        |-- Accessibility / AXObserver
        |-- ScreenCaptureKit
        |-- CoreGraphics / CGEvent
        |-- Vision OCR
        `-- NSPasteboard

bridge.mjs -- optional persistent, click-through --> MacUICursorOverlay
```

The Mac side is deterministic execution/observation infrastructure; reasoning remains in the ChatGPT-side agent. Semantic Accessibility operations are preferred over visual coordinates, with screenshots/OCR/input as fallbacks for canvas, RDP and custom-rendered surfaces.

## Observe -> act -> verify

A normal native workflow is:

```text
ui_observe
  -> choose AX ref when available
  -> ui_action(precondition=..., verify=...)
  -> ui_wait_for / ui_assert
  -> re-observe when layout changed
```

For visual-only UI:

```text
ui_screenshot / ui_ocr
  -> ui_ax_at(coordinate) when AX can identify the visual target
  -> otherwise ui_mouse / ui_drag_drop / ui_keyboard
  -> ui_wait_visual
  -> screenshot/OCR verification
```

## Observation and synchronization

- `ui_status` — Accessibility/Screen Recording/event-post state, frontmost app and canonical display geometry.
- `ui_app_list` — running application metadata.
- `ui_window_list` — CoreGraphics windows, global bounds and display routing.
- `ui_tree` — bounded Accessibility hierarchy and fingerprinted refs. Attribute reads are batched with `AXUIElementCopyMultipleAttributeValues` when supported.
- `ui_ax_query` — targeted semantic search using `AXUIElementsForSearchPredicate` when available, with a bounded tree fallback.
- `ui_ax_at` — `AXUIElementCopyElementAtPosition` hit-test that converts a visual coordinate into a stable fingerprinted ref.
- `ui_screenshot` — ScreenCaptureKit display/window/region capture as native MCP image content.
- `ui_observe` — status + AX tree + optional display/window/region screenshot.
- `ui_cursor` — independent click-through AI cursor; it is visual state only and never moves the physical system cursor.
- `ui_wait_for` — AXObserver-assisted bounded wait with polling fallback.
- `ui_assert` — immediate semantic state assertion.
- `ui_ocr` — Apple Vision OCR over a display/window/region, with text confidence and pixel bounds.
- `ui_wait_visual` — bounded pixel-change or visual-stability wait.

`ui_tree` and `ui_observe` return a short-lived `observationId`. Mutation calls may bind refs to that observation. A ref that was not part of the observation fails before the native helper is allowed to act.

## Actions

- `ui_app_launch`, `ui_app_activate`
- `ui_action` — semantic AX press/focus/set-value/menu/increment/decrement/etc.; supports a target precondition and a post-action verification clause.
- `ui_window_action` — focus/raise/move/resize/set bounds/minimize/restore/full-screen/close.
- `ui_mouse` — move/click/double/right/scroll/smooth drag in canonical Quartz coordinates.
- `ui_drag_drop` — drag between AX refs or coordinates, including display-local coordinates.
- `ui_keyboard` — Unicode typing, named virtual keys, raw key codes, modifiers, key down/up and bounded repeats.
- `ui_dialogs`, `ui_dialog_action` — semantic native sheet/dialog discovery and button actions.
- `ui_file_dialog` — deterministic open/save panel path navigation using the standard Go-to-Folder UI plus Accessibility semantics.
- `ui_clipboard_read`, `ui_clipboard_write`.
- `ui_sequence` — up to 64 bounded deterministic native primitives in one helper process; `wait_for` steps fail the burst by default when their postcondition does not match.

## Background-targeted input and focus preservation

`ui_mouse` and `ui_keyboard` have three delivery modes:

- `foreground` — the compatibility path, posting through the global HID event tap; the caller may explicitly activate the target.
- `background` — requires a target pid and posts CoreGraphics events directly to that process. The physical mouse is not warped and `preserve_focus=true` fails with `UI_FOCUS_CHANGED` if the target unexpectedly becomes frontmost. This mode never activates the target automatically.
- `auto` — uses background delivery when a pid is supplied, otherwise foreground delivery. If the caller also supplied a semantic `verify` clause and the background attempt fails that postcondition, MDB may perform **one** foreground retry (`activate_target=true`) unless `allow_foreground_fallback=false`. No `verify` means no automatic fallback.

PID-targeted event APIs are best-effort: native applications are free to reject synthetic events without returning an actionable failure. Therefore a reported event-post success is not treated as proof that the UI changed; use semantic postconditions for consequential input. `ui_status.postEventsGranted` and the menu-bar `Input` indicator expose the separate CoreGraphics event-post permission.

Installed desktop control uses the nested `MacDevBridge.app/Contents/Helpers/MacUIHelper` executable. The app, helper, and virtual-cursor overlay are signed with the same available Apple code-signing identity and stable identifiers. `MAC_DEV_BRIDGE_UI_HELPER` / `MAC_DEV_BRIDGE_UI_CURSOR_HELPER` are set by the menu app so the MCP runtime cannot accidentally fall back to a differently signed checkout binary. The menu permission row queries this exact helper. Use `scripts/desktop-doctor.sh --request` to ask macOS for the helper permissions and `scripts/desktop-doctor.sh` to verify them without prompting.

`AXEnhancedUserInterface` is enabled best-effort on application roots to improve the exposed tree for applications that support it; unsupported applications simply retain their normal AX behavior.

## AX target safety

AX refs have the form:

```text
ax:<pid>:<child.path>:<fingerprint>
```

The 64-bit FNV-1a fingerprint covers role, subrole, identifier, title, description and rounded frame. Immediately before a semantic action the helper resolves the path again and recomputes the fingerprint. If AppKit merely re-indexed child arrays, the helper performs a bounded application-tree search for that exact fingerprint and recovers only when there is exactly one match. Changed, missing, or ambiguous targets fail as `UI_ELEMENT_STALE`.

For consequential operations, the bridge provides two additional layers:

1. `observation_id` binds a ref to a recent `ui_tree`/`ui_observe` result (60-second in-memory lifetime, bounded to 64 generations).
2. `precondition` rechecks semantic properties immediately before mutation; mismatch fails as `UI_PRECONDITION_FAILED`.

`ui_action.verify` performs a bounded postcondition wait and returns `UI_POSTCONDITION_FAILED` if the requested state never appears.

These are correctness guards, not authentication boundaries against hostile same-user code.

## Coordinate system and multiple displays

Pointer actions and region capture use **Quartz global display coordinates** in points. The primary display begins at `(0,0)`; secondary displays may have positive or negative origins. `ui_status` reports, per display:

- Quartz bounds;
- AppKit frame/visible frame;
- backing scale factor;
- pixel dimensions;
- logical-to-pixel scale.

For `ui_mouse`, `ui_drag_drop`, and region screenshots, a display id can make coordinates display-local; the helper translates them into Quartz global space. Window metadata also reports the display containing the window center.

## Screen capture and OCR

Display and desktop-independent window screenshots use ScreenCaptureKit. Region capture uses the native cross-display screenshot API on macOS 15.2+ and a fail-closed single-display fallback on older supported releases.

Screenshot content is returned as MCP `image` blocks; base64 bytes are not duplicated into structured metadata or the audit log. When the MDB virtual cursor is visible, `ui_screenshot`/`ui_observe` render that independent cursor into the returned frame by default (`show_virtual_cursor=false` disables it) without moving or capturing the operator's physical pointer. JPEG is the bounded default, PNG is available for lossless inspection.

`ui_ocr` uses `VNRecognizeTextRequest` locally. It returns recognized strings, confidence, normalized Vision bounds and top-left-origin pixel bounds in the returned image. Automatic language detection is the default and explicit recognition languages are supported.

## Visual waits

`ui_wait_visual` downsamples repeated captures to a fixed 64x64 grayscale signature and reports:

- mean normalized pixel difference;
- changed-pixel fraction.

It can wait for either a change from the baseline or a stable interval. This avoids sending a stream of screenshots through MCP just to determine whether a visual surface finished updating.

## Native dialogs and file panels

`ui_dialogs` discovers AX sheets/system dialogs and returns button refs. `ui_dialog_action` can press the default/cancel/named button.

`ui_file_dialog` deliberately drives only Apple's standard open/save panel path. It opens Go-to-Folder with bounded key-equivalent retries, resolves `PathTextField` by Accessibility identifier, assigns the absolute path through AX, and considers navigation complete only when that nested field actually disappears. `NSSavePanel` filenames are set through the stable `saveAsNameTextField` identifier before the outer Open/Save button is pressed semantically. Both NSOpenPanel and NSSavePanel are covered by the native integration fixture.

Custom application-specific file browsers remain ordinary UI and should be handled with `ui_tree`/`ui_screenshot`/`ui_action` instead.

## Helper lifecycle and performance

The helper remains short-lived rather than becoming a resident daemon. On the development M4 host, 20 `status` launches measured a **50.46 ms median** and **55.75 ms p95 excluding the one cold 313.78 ms outlier**. That startup cost is small relative to ScreenCaptureKit, Vision and model/tool round trips, while one-process-per-call gives simpler revocation and failure isolation.

Every `MacUIHelper` process is detached into its own reclaimable group, tracked in the bridge's in-flight set, given a minimal environment allowlist and killed on bridge revocation/teardown. A resident privileged helper is therefore intentionally not part of this release. The optional `MacUICursorOverlay` is different: it is an unprivileged, click-through visual process kept alive only to animate the independent AI cursor; bridge teardown/kill-switch paths reclaim it, and it never posts input events.

## Permissions

The helper observes but never modifies TCC:

- Accessibility is required for AX observation/actions.
- Screen Recording is required for ScreenCaptureKit pixels/OCR/visual waits.
- CoreGraphics event-post permission is checked separately before synthetic mouse/keyboard input.
- Full Disk Access affects protected filesystem authority and is displayed separately in the menu-bar app.

The menu-bar app shows `AX`, `Screen`, `Input` and `FDA` status and links to macOS Privacy & Security. `scripts/desktop-doctor.sh` performs the same three native preflight checks without prompting or editing TCC; `--open` only opens Privacy & Security. Full Disk Access remains a separate `scripts/tcc-doctor.sh` check because TCC attribution depends on the responsible runtime process chain. Login/lock screens, Secure Input, passkeys, authorization dialogs and other security-sensitive OS surfaces remain subject to macOS restrictions.

## Approval and audit model

Relaxed mode is the default unrestricted-operator mode. Strict mode requires the existing single-use, app-scoped foreground grant for native mutation tools, including window/dialog/file-picker/drag operations. Semantic cross-application drag resolves every referenced pid and requires all involved applications in the same grant; a file-picker `path` is treated only as a file path, never as an application identity.

Sensitive input is always replaced before audit serialization, including full audit mode:

- `pty_write.data`
- `ui_keyboard.text`
- `ui_clipboard_write.text`
- `ui_action.value` for `set_value`
- the corresponding nested sensitive fields inside `ui_sequence`
- raw `browser_cdp_call.params` (the whole parameter object)

Observation itself is privileged: screenshots, OCR, clipboard reads and ordinary AX values can contain sensitive user-visible data.

## Browser relationship

Normal web work should still use the signed-in `chrome_*` MDB workspace because it can operate without routine focus theft. Direct Chrome AppleScript/JXA/executable/shell-web-open paths remain rejected by `shell_exec`/`shell_start`.

The native `ui_*` surface is deliberately capable of foreground browser/OS interaction when a background extension cannot own the surface, such as native panels or visual-only controls.

An optional Browser Harness-compatible raw-CDP adapter is available only when `MAC_DEV_BRIDGE_ADVANCED_BROWSER=1` was set before bridge startup. It talks to an already-running same-user Browser Harness daemon over its Unix socket and exposes raw CDP/session/events as `browser_cdp_*`; it neither installs Browser Harness nor executes arbitrary Python. This backend is independent of the managed `chrome_*` workspace and is blocked entirely while Strict approvals is enabled because arbitrary CDP cannot be reliably reduced to URL-pattern grants.

## Validation

The desktop layer has two test tiers:

1. deterministic protocol tests with a fake helper — tool advertisement, image passthrough, AX hit/query refs, observation binding, background-input verification/fallback, virtual-cursor state, `ui_sequence`, Strict approvals and audit redaction;
2. a raw-CDP IPC fixture — Browser Harness-compatible socket framing, raw calls/session/events and fail-closed Strict-mode blocking;
3. a real AppKit fixture — semantic set/press + postconditions, targeted AX query/hit-test, sequence bursts, ScreenCaptureKit window capture with virtual cursor metadata, Vision OCR, window geometry changes, native dialogs, visual-change waits, PID-targeted input mode, drag/drop, NSOpenPanel and NSSavePanel.

The native fixture test builds everywhere on macOS. GitHub-hosted macOS is deliberately treated as a compile-only environment for the mutable native fixture because runner images can report Accessibility/Screen Recording while still failing `AXPress`/`CGEvent` delivery nondeterministically. The deterministic `desktop-control.mjs` suite exercises the complete MCP desktop surface in hosted CI; the real mutable AppKit E2E runs on an interactive Mac, or on self-hosted CI when `MDB_RUN_NATIVE_DESKTOP_E2E=1` is explicitly set. If an interactive run lacks Accessibility/Screen Recording, it reports that permission boundary and skips after the successful build.
