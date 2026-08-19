# AGENTS.md

This file is the primary repository guide for coding agents working on DarwinRelay. Read it before modifying code. Human-facing product documentation starts in `README.md`; runtime architecture and security details live under `docs/` and in `SECURITY.md`.

## What DarwinRelay is

DarwinRelay is a macOS MCP execution runtime. It intentionally exposes broad local authority to an MCP client: shell/filesystem operations, real PTYs, long-running jobs, persisted Codex history, a managed background Chrome workspace, and native desktop control through Accessibility, ScreenCaptureKit, Vision and CoreGraphics.

It is **not a sandbox**. Security work in this repository is about making powerful authority explicit, bounded, auditable and fail-closed — not pretending arbitrary shell access is contained.

## Read these files first

For any non-trivial task, inspect:

1. `README.md` — product surface and user workflows.
2. `AGENTS.md` — coding-agent rules and repository map.
3. `SECURITY.md` — trust boundaries and failure semantics.
4. `docs/ARCHITECTURE.md` — component/data-flow architecture.
5. `docs/AGENT_OPERATIONS.md` — runtime tool catalog and agent operating guidance.
6. `docs/DESKTOP_CONTROL.md` — native UI control model and limitations.
7. `UPSTREAM.md` — upstream lineage and attribution policy.

## Repository map

- `bridge.mjs` — MCP server, tool schemas, dispatch, shell/filesystem/jobs/Codex/native-UI integration and high-level policy.
- `mcp-http.mjs` — authenticated HTTP/OAuth MCP transport.
- `lib/` — PTY/federation/browser/native helper clients and shared runtime modules.
- `desktop-helper/` — Swift native desktop-control helper and virtual cursor source.
- `chrome-extension/` — unpacked Chrome extension for the managed background browser workspace.
- `scripts/chrome-native-host.mjs` — Native Messaging host implementation installed into Application Support.
- `menubar/` — Swift menu-bar app and bundle builder.
- `launchd/` — LaunchAgent templates.
- `scripts/` — install, signing, diagnostics, lifecycle, browser-profile and deployment helpers.
- `tests/` — deterministic protocol/integration/lifecycle tests plus the mutable native AppKit fixture.
- `.github/workflows/ci.yml` — public GitHub-hosted CI split into descriptive jobs.

## Canonical identities

Do not reintroduce inherited runtime namespaces.

- Product: `DarwinRelay`
- Package/repository: `darwinrelay`, `dcierra/darwinrelay`
- MCP name: `io.github.dcierra.darwinrelay`
- Menu bundle id: `io.github.dcierra.darwinrelay`
- Native helper ids:
  - `io.github.dcierra.darwinrelay.ui-helper`
  - `io.github.dcierra.darwinrelay.cursor-overlay`
- HTTP LaunchAgent: `io.github.dcierra.darwinrelay.http`
- Secure-tunnel LaunchAgent: `io.github.dcierra.darwinrelay.tunnel`
- Chrome Native Messaging host: `io.github.dcierra.darwinrelay`
- Environment prefix: `DARWINRELAY_`
- Default state directory: `~/Library/Application Support/DarwinRelay`
- Default logs: `~/Library/Logs/DarwinRelay`
- Menu/tab-group short label: `DR`

Old `Mac Developer Bridge`, `MDB`, `MAC_DEV_BRIDGE_*`, `com.openai.mac-developer-bridge-*`, `local.mac-developer-bridge.*` and `io.github.alexanderradahl.*` identifiers must only appear in explicit historical attribution such as `UPSTREAM.md`, never in current runtime code/configuration.

## Development commands

Use Node.js 22 for parity with CI.

```bash
npm run check
npm run test:core
npm run test:desktop
npm run test:lifecycle
npm test
```

What each group means:

- `npm run check` — JS syntax checks plus native helper/menu/fixture build validation.
- `npm run test:core` — MCP smoke/integration/adversarial, HTTP/OAuth, PTY, federation, background Chrome and optional advanced-browser protocol tests.
- `npm run test:desktop` — deterministic desktop protocol tests plus native fixture build/runtime boundary behavior.
- `npm run test:lifecycle` — Chrome host installer, HTTP autostart, atomic menu deployment, singleton ownership and full installer mock.

Real mutable AppKit E2E requires a logged-in Mac with TCC permissions:

```bash
DARWINRELAY_RUN_NATIVE_DESKTOP_E2E=1 node tests/desktop-control-native.mjs
```

Do not weaken tests merely because hosted macOS cannot provide reliable interactive Accessibility/CGEvent delivery. Keep deterministic protocol tests in hosted CI and treat real mutable GUI E2E as a local maintainer verification.

## CI expectations

Public CI runs on GitHub-hosted macOS, not a maintainer workstation. The expected visible checks are:

- `Static checks`
- `Core & protocol tests`
- `Desktop control tests`
- `Install & lifecycle tests`

`Static checks` also scans full Git history with gitleaks. If you add an intentional non-secret that triggers detection, justify it narrowly in `.gitleaks.toml`; do not broadly suppress rules.

## Security invariants

Treat these as product requirements, not implementation suggestions:

1. **Explicit full-access acknowledgement** — unrestricted local execution must remain gated by the unlock/ack mechanism.
2. **No false sandbox claims** — effective access equals the macOS account, subject to TCC/ACL/sudo.
3. **Fail closed on ambiguity** — stale AX refs, ambiguous Chrome profile bindings, invalid OAuth state, malformed identifiers and uncertain process ownership should fail rather than guess.
4. **Secret redaction** — keyboard text, clipboard writes, AX `set_value`, browser raw params and PTY keystrokes must not become plaintext audit records.
5. **Process reclamation** — bridge revocation/teardown must reclaim PTYs, in-flight helpers and supervised processes.
6. **Singleton menu ownership** — a second menu app must not reclaim another instance's pidfiles/unlock/transport state.
7. **Chrome routing** — normal web work goes through `chrome_*`; shell/AppleScript/JXA routes that bypass the managed background workspace remain blocked.
8. **Strict approvals remain meaningful** — never silently bypass URL/app scopes when Strict mode is enabled.
9. **Raw CDP is a separate authority surface** — keep it explicit opt-in and blocked under Strict approvals.
10. **TCC identity stability** — app/helper/cursor should share a stable signing identity when available, with stable designated identifiers.

Read `SECURITY.md` before changing any of these paths.

## Native desktop-control rules

Prefer this order:

1. Semantic AX observation/query.
2. Semantic `ui_action` with pre/postconditions.
3. Background PID-targeted input when appropriate and verifiable.
4. Foreground raw mouse/keyboard only as compatibility fallback.
5. Visual coordinate/OCR fallback only when semantics are unavailable.

Do not treat successful `CGEvent` posting as proof that an app consumed the event. Consequential raw input needs semantic verification.

Fingerprint/stale-ref behavior is deliberate. Do not make refs silently rebind to a different element merely to reduce `UI_ELEMENT_STALE` errors.

## Chrome profile rules

Default browser setup is intentionally isolated:

```bash
./scripts/install-background-chrome.sh
```

This creates or reuses a signed-out local Chrome profile named **DarwinRelay** and binds the Native Messaging host to it in `dedicated-local` mode. First-time creation must fail while Chrome is running; ask the user to quit Chrome once rather than racing Chrome's `Local State` writer. Rebinding an existing DarwinRelay profile may proceed while Chrome is open.

Explicit alternatives:

```bash
./scripts/install-background-chrome.sh --profile 'Some Existing Profile'
./scripts/install-background-chrome.sh --use-current-profile
```

`--use-current-profile` is an explicit opt-in and requires the current profile to be signed in. Never silently fall back from the dedicated profile to a user's everyday profile.

The installer must not delete the dedicated Chrome profile during uninstall; profile data is user data.

## Signing and release rules

- `package.json.version` is the canonical bridge version source.
- Chrome service-worker handshake version comes from `manifest.json`, not another hardcoded constant.
- Keep app/helper/cursor signing identifiers stable.
- Build/install code must fail closed on unexpected designated-requirement changes unless an explicit signing-change override is supplied.
- Do not commit Apple signing private material or Chrome extension private keys. Only the public Chrome manifest key belongs in Git.
- Generated `.app` bundles are not source artifacts and must remain untracked.

Before a public release:

```bash
npm run check
npm test
gitleaks git --config .gitleaks.toml --redact=100 .
```

Then regenerate and verify `SHA256SUMS` for tracked regular source files, ensure the tree is clean, and tag the exact verified commit.

## Upstream attribution

DarwinRelay is derived from the MIT-licensed Mac Developer Bridge project. Do not delete the original copyright notice from `LICENSE`, rewrite inherited authorship, or remove `UPSTREAM.md` attribution.

New product ownership/metadata belongs to DarwinRelay and Sergey Borisov (`@dcierra`); upstream attribution belongs in `LICENSE`, Git history, `UPSTREAM.md`, and contributor metadata — not in current runtime namespaces.

## Working with Git history

The public repository preserves inherited and downstream development history. Do not squash the project into a synthetic one-commit import for convenience.

If history rewriting is ever required for secret removal or privacy sanitization:

- preserve authors/dates/topology where possible;
- document why SHA values changed;
- run gitleaks on the rewritten full history before publishing;
- never rewrite already-consumed public releases casually.

## Files that must never be committed

- bearer/OAuth/tunnel credentials or state
- contents of `~/Library/Application Support/DarwinRelay`
- Chrome profile directories or cookies/storage
- Apple signing private keys/certificates exported from Keychain
- DarwinRelay Chrome extension private key
- generated `.app` bundles
- machine-specific rollback snapshots
- personal filesystem paths/log dumps unless deliberately redacted fixtures

## How to explain this repository to a user

When asked to summarize DarwinRelay, explain the trust model first: it is a powerful local MCP runtime with the authority of the logged-in macOS user. Then describe the four main capability planes — terminal/filesystem, PTY/jobs, background Chrome, native desktop control — and the two transport modes — local stdio and authenticated HTTP/OAuth behind a tunnel.

For runtime usage, direct the reader to `docs/AGENT_OPERATIONS.md`. For implementation/trust boundaries, use `docs/ARCHITECTURE.md` and `SECURITY.md`.
