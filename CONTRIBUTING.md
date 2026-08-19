# Contributing to DarwinRelay

Issues and focused pull requests are welcome.

## Development setup

Requirements are macOS, Node.js 18+, and Xcode Command Line Tools for the native helpers.

```bash
git clone https://github.com/dcierra/darwinrelay.git
cd darwinrelay
npm run check
npm test
```

For faster iteration the suite is split into the same groups exposed by CI:

```bash
npm run test:core
npm run test:desktop
npm run test:lifecycle
```

The deterministic desktop protocol suite runs in CI. The mutable AppKit E2E requires a logged-in Mac with Accessibility/Screen Recording permissions:

```bash
DARWINRELAY_RUN_NATIVE_DESKTOP_E2E=1 node tests/desktop-control-native.mjs
```

## Pull requests

Keep changes scoped and explain the security/permission impact when touching shell execution, HTTP/OAuth, browser routing, Accessibility/input delivery, process reclamation, signing or launchd.

Before opening a PR:

1. Run `npm run check`.
2. Run the relevant test group; run `npm test` for cross-cutting changes.
3. Add regression coverage for bug fixes.
4. Do not weaken fail-closed behavior merely to make an automation path more convenient.
5. Do not commit generated `.app` bundles, credentials, OAuth/tunnel state, Chrome profile data, machine-specific paths or signing private keys.

## Security reports

Do not open a public issue for a vulnerability that could expose credentials, bypass authentication, weaken the explicit unlock, escape a containment claim, or broaden remote execution. Use GitHub private vulnerability reporting so the issue can be investigated before disclosure.

## Project lineage

DarwinRelay is derived from Mac Developer Bridge under the MIT license. Preserve attribution and the existing license notices when redistributing substantial portions. See [UPSTREAM.md](UPSTREAM.md).
