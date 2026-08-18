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
      MacUIHelper (Swift)
        |-- AppKit / NSWorkspace
        |-- Accessibility / AXObserver
        |-- ScreenCaptureKit
        |-- CoreGraphics / CGEvent
        |-- Vision OCR
        `-- NSPasteboard
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
  -> ui_mouse / ui_drag_drop / ui_keyboard
  -> ui_wait_visual
  -> screenshot/OCR verification
```

## Observation and synchronization

- `ui_status` — Accessibility/Screen Recording state, frontmost app and canonical display geometry.
- `ui_app_list` — running application metadata.
- `ui_window_list` — CoreGraphics windows, global bounds and display routing.
- `ui_tree` — bounded Accessibility hierarchy and fingerprinted refs.
- `ui_screenshot` — ScreenCaptureKit display/window/region capture as native MCP image content.
- `ui_observe` — status + AX tree + optional display/window/region screenshot.
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

Screenshot content is returned as MCP `image` blocks; base64 bytes are not duplicated into structured metadata or the audit log. JPEG is the bounded default, PNG is available for lossless inspection.

`ui_ocr` uses `VNRecognizeTextRequest` locally. It returns recognized strings, confidence, normalized Vision bounds and top-left-origin pixel bounds in the returned image. Automatic language detection is the default and explicit recognition languages are supported.

## Visual waits

`ui_wait_visual` downsamples repeated captures to a fixed 64x64 grayscale signature and reports:

- mean normalized pixel difference;
- changed-pixel fraction.

It can wait for either a change from the baseline or a stable interval. This avoids sending a stream of screenshots through MCP just to determine whether a visual surface finished updating.

## Native dialogs and file panels

`ui_dialogs` discovers AX sheets/system dialogs and returns button refs. `ui_dialog_action` can press the default/cancel/named button.

`ui_file_dialog` deliberately drives only Apple's standard open/save panel path. It opens Go-to-Folder with the macOS shortcut, waits for the focused `PathTextField`, assigns the absolute path through AX, waits for navigation to settle, then confirms the panel semantically. Both NSOpenPanel and NSSavePanel are covered by the native integration fixture.

Custom application-specific file browsers remain ordinary UI and should be handled with `ui_tree`/`ui_screenshot`/`ui_action` instead.

## Helper lifecycle and performance

The helper remains short-lived rather than becoming a resident daemon. On the development M4 host, 20 `status` launches measured a **50.46 ms median** and **55.75 ms p95 excluding the one cold 313.78 ms outlier**. That startup cost is small relative to ScreenCaptureKit, Vision and model/tool round trips, while one-process-per-call gives simpler revocation and failure isolation.

Every helper process is detached into its own reclaimable group, tracked in the bridge's in-flight set, given a minimal environment allowlist and killed on bridge revocation/teardown. A resident helper is therefore intentionally not part of this release.

## Permissions

The helper observes but never modifies TCC:

- Accessibility is required for AX observation and synthesized input.
- Screen Recording is required for ScreenCaptureKit pixels/OCR/visual waits.
- Full Disk Access affects protected filesystem authority and is displayed separately in the menu-bar app.

The menu-bar app shows `AX`, `Screen` and `FDA` status and links to macOS Privacy & Security. Login/lock screens, Secure Input, passkeys, authorization dialogs and other security-sensitive OS surfaces remain subject to macOS restrictions.

## Approval and audit model

Relaxed mode is the default unrestricted-operator mode. Strict mode requires the existing single-use, app-scoped foreground grant for native mutation tools, including window/dialog/file-picker/drag operations. Semantic cross-application drag resolves every referenced pid and requires all involved applications in the same grant; a file-picker `path` is treated only as a file path, never as an application identity.

Sensitive input is always replaced before audit serialization, including full audit mode:

- `pty_write.data`
- `ui_keyboard.text`
- `ui_clipboard_write.text`
- `ui_action.value` for `set_value`

Observation itself is privileged: screenshots, OCR, clipboard reads and ordinary AX values can contain sensitive user-visible data.

## Browser relationship

Normal web work should still use the signed-in `chrome_*` MDB workspace because it can operate without routine focus theft. Direct Chrome AppleScript/JXA/executable/shell-web-open paths remain rejected by `shell_exec`/`shell_start`.

The native `ui_*` surface is deliberately capable of foreground browser/OS interaction when a background extension cannot own the surface, such as native panels or visual-only controls.

## Validation

The desktop layer has two test tiers:

1. deterministic protocol tests with a fake helper — tool advertisement, native image passthrough, observation binding, Strict approvals and audit redaction;
2. a real AppKit fixture — semantic set/press + postconditions, AX waits/assertions, ScreenCaptureKit window capture, Vision OCR, window geometry changes, native dialogs, visual-change waits, drag/drop, NSOpenPanel and NSSavePanel.

The native fixture test builds everywhere on macOS and automatically skips the runtime portion when CI does not grant Accessibility/Screen Recording.
