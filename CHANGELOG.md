# Changelog

All notable public DarwinRelay changes will be documented here.

## Unreleased

## 0.6.5 — 2026-08-22

- Doctor now reports a connected unpacked background-Chrome extension as `OPTIONAL / ACTION REQUIRED` when its version differs from the runtime package, instead of presenting a stale service worker as fully READY after an update.
- Added a canonical manual `scripts/update.sh` transaction for source-first installations: it updates only between immutable stable release tags from the canonical repository, refuses dirty/development or split-version installs, preserves rollback, restarts fail-closed through the HTTP LaunchAgent, and requires the authenticated doctor to return `CORE VERDICT: READY`. README and agent operations now document this as the supported release-to-release update path.
## 0.6.4 — 2026-08-22

- Fixed HTTP autostart from source checkouts under protected locations such as `~/Documents`: the LaunchAgent no longer asks launchd itself to `chdir` into the source tree before the signed DarwinRelay app starts; `DARWINRELAY_HOME` remains the explicit package locator used by the app.
- Fixed `scripts/deploy-menubar-update.sh` process discovery so busy process tables cannot turn a successful PID lookup into SIGPIPE/exit 141 under `pipefail`; lifecycle coverage now exercises that failure mode deterministically.
## 0.6.3 — 2026-08-22

- Made normal virtual AI cursor moves transient: `ui_cursor action=move` now auto-hides after 2.5 seconds by default (configurable per call, with `0` as an explicit persistent override), while `show` remains the deliberate persistent mode. This prevents the click-through DarwinRelay cursor from lingering on the operator desktop after an agent stops using it.
- Updated the menu-bar ChatGPT setup copy to the current Apps/developer-mode terminology, separated core runtime health from optional native/FDA capabilities, and routed permission remediation to the specific Accessibility, Screen Recording, or Full Disk Access pane.
- Reworked `scripts/doctor.sh` into a transport-aware core readiness gate with explicit remediation, app/runtime consistency checks, token-file mode validation, and a real local MCP `initialize → bridge_status` smoke probe; optional desktop/FDA/Chrome/Codex status no longer makes a healthy core coding path fail.
- Added request/session provenance to audit records: every bridge request gets a server-generated correlation id, HTTP requests carry a separate transport id, optional MCP session headers are converted to non-reversible opaque ids, and OAuth grants keep an opaque session lineage across refresh without logging or deriving ids from tokens.
- Background shell jobs and PTY metadata now retain the provenance of the request that created them, while `shell_exec` audit summaries record the spawned process id for process-level tracing.

## 0.6.2 — 2026-08-19

- Fixed `menubar/build.sh --build-only` so it genuinely performs a no-install build; lifecycle coverage now verifies the requested app version explicitly instead of relying on a non-fatal shell comparison.
- Redesigned the macOS menu bar around an explicit `DarwinRelay · v<version>` header, health summary, concise transport/desktop/safety status rows, and grouped Connection/Diagnostics submenus; menu action enablement is now deterministic instead of relying on AppKit auto-enable heuristics.
- Split Swift CodeQL into a path-filtered workflow: `main` re-analysis now runs only when Swift/SwiftPM analysis inputs change, while weekly/manual full scans remain available. Added dedicated JavaScript and Swift CodeQL badges and documented the policy for coding agents.
## 0.6.1 — 2026-08-19

- Hardened HTTP error boundaries so arbitrary request/bridge exception text is logged locally but never serialized to remote callers.
- Replaced the in-memory plain SHA-256 OAuth client-secret verifier with a bounded fixed-size `timingSafeEqual` representation that does not hash the secret.
- Strengthened the OAuth consent regression test to compare the exact validated redirect row rather than relying on URL substring matching.
- Replaced regex-based Cloudflare quick-tunnel URL extraction with structural URL/host validation and hostile-input native regression coverage.
- Added CodeQL scanning for JavaScript and Swift plus SwiftPM metadata for deterministic native analysis builds.

## 0.6.0 — Public edition

- Established **DarwinRelay** as an independently maintained open-source project with its own application, package, LaunchAgent, Native Messaging and Chrome-extension identities.
- Preserved the inherited Git history while sanitizing maintainer email metadata for public release.
- Added native macOS desktop control built on Accessibility/AXObserver, ScreenCaptureKit, Vision and CoreGraphics, including semantic hit-testing/query, windows/dialogs/file panels, OCR, raw-input fallback, visual waits, batched sequences and a virtual cursor.
- Added stable signing identifiers and nested helpers so TCC permissions can survive rebuilds when a persistent Apple signing identity is available.
- Added a managed background Chrome tab pool with explicit profile binding and a dedicated DarwinRelay extension/native-host identity.
- Added authenticated HTTP/OAuth transport hardening, PTY/process reclamation, strict approval mode, audit redaction and singleton menu ownership.
- Added atomic menu-app deployment/rollback and per-user HTTP/tunnel autostart support.
- Split public CI into named static, core/protocol, desktop and lifecycle checks, and added full-history gitleaks scanning.

### Pre-public lineage

Development before 0.6.0 is preserved in Git history, including the original upstream commits and the private downstream development that produced the native desktop/browser runtime. Earlier internal version labels are historical lineage, not DarwinRelay public releases.
