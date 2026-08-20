# DarwinRelay Roadmap

DarwinRelay is a source-first, self-hosted macOS MCP runtime for agents that need controlled access to shell/filesystem operations, real PTYs and jobs, background browser automation, and native macOS computer use.

This roadmap is directional rather than a promise of dates. Priorities may change as security work, real-world usage, and contributor feedback uncover better sequencing.

For implementation details, start with [AGENTS.md](AGENTS.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Security-sensitive reports should follow [SECURITY.md](SECURITY.md), not public issues.

## Now

### Multi-client execution safety and provenance

DarwinRelay can expose broad local authority, so concurrent clients and long-running agent turns need explicit ownership and traceability.

Current priorities:

- safer request/session correlation in audit metadata without logging credentials or sensitive browser/session data;
- cancellation propagation through the transport and tool-execution layers;
- stale-execution containment so superseded work cannot keep mutating resources indefinitely;
- resource-scoped writer ownership for mutation-heavy workflows such as Git repositories;
- adversarial concurrency and process-containment regression tests.

The goal is deterministic, auditable behavior when several agent sessions operate against the same Mac at once.

### Self-hosted install and lifecycle hardening

The primary distribution model remains:

```text
clone → install/build → grant macOS permissions → configure browser/MCP → run locally
```

Current priorities:

- reproducible fresh installs with no maintainer-machine assumptions;
- reliable autostart, singleton ownership, shutdown and orphan reclamation;
- safe detection/coexistence behavior around legacy runtime state;
- stronger install/reinstall/update/uninstall lifecycle coverage.

Paid Apple Developer membership, Developer ID distribution and notarization are not requirements for the current source-first product model.

## Next

### Faster agent-native browser control

The current background Chrome workspace already avoids routine foreground focus theft, but dynamic sites still create too many agent/browser reasoning round-trips.

Planned work includes:

- compact semantic page snapshots instead of CSS-selector-first interaction;
- stable element references and explicit stale-target behavior;
- browser-side waits for DOM/navigation conditions;
- bounded multi-step browser sequences so common workflows execute locally within one MCP call;
- compact observation deltas rather than repeatedly returning unchanged page state;
- task-scoped browser workspaces for safer concurrent sessions;
- benchmark fixtures for SPA rerenders, delayed controls, iframes, Shadow DOM and other dynamic UI cases.

Raw browser/CDP authority will remain a separate explicit opt-in surface. The normal fast path should stay constrained and auditable.

### Onboarding, permissions and diagnostics

Make a new installation explain exactly what is missing and how to fix it.

Planned work includes:

- independent Accessibility, Screen Recording, Input/Post Events and Full Disk Access diagnostics;
- correct links/actions for each macOS Privacy & Security permission;
- clearer dedicated-Chrome-profile, Native Messaging and extension onboarding;
- one authoritative `doctor`/health path covering runtime, permissions, browser, OAuth/transport, lifecycle and stale legacy processes;
- continued menu-bar UX refinement around version, health, transport, permissions and Safety mode.

## Later

### Documentation and demos

- tighter README first-run explanation and security model;
- architecture and runtime-operation documentation kept in sync with execution/browser changes;
- screenshots and compact demos for shell/PTY, background browser and native macOS workflows;
- end-to-end examples that combine multiple capability planes instead of isolated tool demos.

### Contributor experience and OSS surface

- continue improving issue/discussion templates and contributor guidance;
- identify focused `good first issue` / `help wanted` work as internal architecture stabilizes;
- keep CI/security checks descriptive and independently actionable;
- preserve upstream attribution and the existing public Git history.

### Capability expansion

New tool families and integrations should follow real workflows and user feedback rather than increasing surface area for its own sake. Candidate areas include stronger app-specific workflows, richer browser/native coordination, and higher-level orchestration once execution ownership is robust.

## Project principles

Roadmap work should preserve these constraints:

- unrestricted local execution remains explicit rather than pretending to be sandboxed;
- ambiguous security-sensitive state fails closed;
- credentials, cookies, OAuth state and private signing material do not enter logs or Git;
- the default browser path uses a dedicated local DarwinRelay Chrome profile rather than silently taking over a personal profile;
- Stop/disable and process reclamation remain security boundaries;
- raw CDP/browser authority remains explicit opt-in;
- public development happens only in `dcierra/darwinrelay`, with upstream attribution preserved.

## Contributing

Focused issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and required checks.

If you are interested in one of the roadmap areas, an issue describing a concrete use case, failure mode, benchmark or implementation proposal is more useful than a generic feature request.
