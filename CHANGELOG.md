# Changelog

All notable public DarwinRelay changes will be documented here.

## Unreleased

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
