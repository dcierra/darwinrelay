# Native Desktop Control

This document describes the private full-control extension of Mac Developer Bridge. The goal is to let the ChatGPT-side agent observe and operate a logged-in macOS desktop while preserving the existing shell/filesystem/PTY/browser architecture and kill switch.

## Design goals

1. Keep ChatGPT as the only reasoning loop. The Mac side exposes deterministic execution/observation primitives.
2. Prefer semantic APIs over coordinates: Accessibility first, visual input second.
3. Return screenshots as native MCP image content so the model can inspect pixels directly.
4. Keep desktop control optional. If the native helper is missing or cannot build, the existing bridge remains usable.
5. Do not weaken macOS TCC, SIP, Keychain, or secure-input boundaries.
6. Make stale UI targets fail closed before an action.
7. Keep the current global unlock/kill-switch semantics and reclaim any in-flight native helper.

## P0 architecture

```text
ChatGPT
  |
  | MCP
  v
bridge.mjs
  |-- shell / filesystem / PTY / Codex
  |-- Background Chrome extension
  `-- ui_* tools
        |
        | bounded JSON stdin/stdout, one process per call
        v
      MacUIHelper (Swift)
        |-- AppKit / NSWorkspace
        |-- ApplicationServices / AXUIElement
        |-- ScreenCaptureKit
        |-- CoreGraphics / CGEvent
        `-- NSPasteboard
```

`MacUIHelper` is intentionally not a long-lived daemon in P0. This makes lifecycle and revocation straightforward: every call is a detached child tracked in `bridge.mjs`'s in-flight set, and the existing teardown path kills that process group if the bridge is revoked or terminated.

## Observe -> act -> verify

The intended control loop is:

```text
ui_observe
  -> choose semantic AX element when possible
  -> ui_action / ui_keyboard
  -> ui_observe
  -> verify state
  -> visual ui_mouse fallback only when needed
```

For a canvas/RDP/custom-rendered surface the AX tree may contain little useful detail. In that case the model can use the screenshot returned by `ui_observe` and operate global coordinates with `ui_mouse`/`ui_keyboard`.

## Tool surface

### Observation

- `ui_status`: Accessibility/Screen Recording state, frontmost app, displays.
- `ui_app_list`: running application metadata.
- `ui_window_list`: CoreGraphics window metadata and bounds.
- `ui_tree`: bounded AX hierarchy for a pid or the frontmost application.
- `ui_screenshot`: scaled display capture as MCP image content.
- `ui_observe`: status + AX tree + optional screenshot in one call.

### Actions

- `ui_app_launch`: launch by path, bundle id, or name.
- `ui_app_activate`: bring a running app forward.
- `ui_action`: semantic AX press/focus/set-value and related actions.
- `ui_mouse`: move/click/double-click/right-click/scroll.
- `ui_keyboard`: Unicode typing or supported key/modifier combinations.
- `ui_clipboard_read` / `ui_clipboard_write`: general pasteboard text.

## AX references

Observation returns refs in this form:

```text
ax:<pid>:<child.path>:<fingerprint>
```

The path locates the element in the current AX hierarchy. The 64-bit FNV-1a fingerprint is calculated from role, subrole, identifier, title, description, and rounded frame. Before `ui_action` executes, the helper resolves the path again and compares the fingerprint. A missing path or mismatch produces `UI_ELEMENT_STALE` before any action is sent.

The fingerprint is a correctness guard, not authentication. It prevents the common stale-target failure mode; it is not intended to resist a hostile same-user process capable of rewriting bridge/helper code.

## Screenshot transport

`ui_screenshot` and screenshot-enabled `ui_observe` use the bridge's existing raw-MCP-content escape:

```text
content[0] = structured/text metadata
content[1] = { type: "image", mimeType, data }
```

The base64 image payload is not copied into structured metadata or audit entries. The structured part retains width, height, display id, status, and AX tree as applicable.

P0 supports display capture and scales down without upscaling. JPEG is the default to keep MCP response size bounded; PNG is available when lossless pixels matter.

## Permissions

The helper observes, but does not alter, macOS permission state:

- Accessibility is required for AX tree access and synthesized input.
- Screen Recording is required for ScreenCaptureKit screenshots.
- Full Disk Access remains relevant to filesystem/shell authority but is independent of AX/Screen Recording.

`ui_status` is the first diagnostic call after installation or a TCC change.

## Approval model

Relaxed mode matches the existing unrestricted-operator model and allows native mutations directly.

Strict mode extends the existing one-use foreground GUI grant to dedicated native mutation tools. The bridge resolves the target app from name, bundle id, pid/ref, or the current frontmost application and consumes `FOREGROUND_GUI_APPROVED` before the action.

The approval mechanism is not a sandbox: unrestricted shell authority can bypass same-user policy mechanisms. It is meant to prevent accidental/unattended foreground drift and make operator intent observable.

## Audit handling

The following fields are always replaced before audit serialization, including full audit mode:

- `pty_write.data`
- `ui_keyboard.text`
- `ui_clipboard_write.text`
- `ui_action.value` when `action=set_value`

The replacement records byte length plus a short SHA-256 prefix. Observation tools can inherently return sensitive visible state, so screenshots, clipboard reads, and ordinary AX text should be treated as privileged data.

## Browser relationship

For normal web automation, Background Chrome remains preferred because it reuses the signed-in MDB tab pool without routine focus theft. `shell_exec` and `shell_start` continue to reject direct Chrome automation paths.

The private full-desktop `ui_*` surface is deliberately capable of operating a foreground Chrome window. That is needed for browser/OS surfaces the extension cannot own, including some native dialogs and visual-only flows. Therefore "Chrome is background-only" is no longer a universal statement once full desktop control is enabled.

## P1 roadmap

- `ui_wait_for` backed by `AXObserver` notifications with bounded polling fallback.
- Window- and region-targeted ScreenCaptureKit capture.
- Native window focus/move/resize/minimize/full-screen primitives.
- Mouse drag and richer key-code mapping.
- File-picker helpers and drag/drop workflows.
- Observation generations and optional stronger target preconditions for consequential actions.
- Post-action verification helpers that can assert target state without requiring a full observation.
- Dedicated deterministic native UI fixture for local integration testing.

## P2 roadmap

- Vision OCR as a fallback for inaccessible/custom-rendered UI.
- Multi-display/Spaces coordinate normalization and explicit display routing.
- Image-diff/change detection for efficient visual waits.
- Higher-level native dialog handling.
- Optional long-lived helper only if profiling proves per-call process startup is a material bottleneck; lifecycle/kill-switch containment must be preserved.

## Production rollout rule

Do not replace a working production MDB in place while developing this line. Keep a separate checkout/data directory, run protocol/unit/native read-only tests there, and only switch the menu-bar app/tunnel after the candidate branch passes the full suite and the operator explicitly chooses the cutover.
