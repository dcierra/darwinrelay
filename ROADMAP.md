# DarwinRelay Roadmap

DarwinRelay is a source-first, self-hosted macOS MCP runtime that lets ChatGPT and other MCP clients act on the Mac they are connected to: shell/filesystem operations, real PTYs and jobs, background browser automation, and native macOS computer use.

This roadmap is directional rather than a promise of dates. Priorities may change as security work, real-world usage, and contributor feedback uncover better sequencing.

For implementation details, start with [AGENTS.md](AGENTS.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Security-sensitive reports should follow [SECURITY.md](SECURITY.md), not public issues.

## Now

### Multi-client execution safety and provenance

DarwinRelay can expose broad local authority, so concurrent clients and long-running agent turns need explicit ownership and traceability.

Completed foundation:

- request/session correlation and provenance in audit metadata without logging credentials or raw MCP session identifiers.

Current priorities:

- cancellation propagation through the transport and tool-execution layers;
- stale-execution containment so superseded work cannot keep mutating resources indefinitely;
- resource-scoped writer ownership for mutation-heavy workflows such as Git repositories;
- adversarial concurrency and process-containment regression tests.

The goal is deterministic, auditable behavior when several agent sessions operate against the same Mac at once.

### Self-hosted install and lifecycle hardening

The primary distribution model remains:

```text
clone → self-build → start core transport → connect MCP client → verify → add optional capabilities
```

The locally built menu app may live in `/Applications` while intentionally resolving the runtime from the user's DarwinRelay source checkout. A prebuilt `.app`/`.dmg`, Developer ID distribution certificate, Apple notarization, and paid Apple Developer Program membership are not requirements for the current source-first product model.

Current priorities:

- reproducible fresh installs with no maintainer-machine assumptions;
- validate the agent-assisted install path on a clean/typical setup: `agent prompt -> clone -> dependencies -> build -> app install -> macOS consent handoff -> bridge start/verify`; if the agent has to guess, improve the scripts/docs instead of expanding the prompt;
- make the source-checkout ↔ locally built app relationship explicit and reliable;
- keep generic build/install separate from transport-specific setup such as the OpenAI Secure MCP Tunnel installer;
- reliable autostart, singleton ownership, shutdown, and orphan reclamation;
- safe detection/coexistence behavior around legacy runtime state;
- stronger install/reinstall/update/uninstall lifecycle coverage.

### ChatGPT onboarding and first useful task

The canonical ChatGPT path should converge on:

```text
clone → self-build → Start → connect ChatGPT → bridge_status → inspect a repo → first real task
```

The first shell/filesystem coding workflow must not require Chrome, Codex history, Accessibility, Screen Recording, or Input/Post Events permissions. Full Disk Access is capability-specific and should only be required when a task needs macOS-protected paths.

Current product requirements:

- keep [docs/CHATGPT.md](docs/CHATGPT.md) as the canonical ChatGPT onboarding guide;
- keep ChatGPT plan/workspace availability explicit instead of implying that every plan exposes write/modify MCP actions;
- update menu-bar **Copy ChatGPT Setup** wording to the current ChatGPT **Apps** terminology and avoid stale `Plugins` labels;
- make a read-only `bridge_status` + repository inspection the first verification step;
- make the first real example a direct ChatGPT → local repo → test/fix/verify loop, with Codex continuity secondary.

### Onboarding, permissions, and diagnostics

A new installation should explain whether the **core coding path is ready** separately from optional feature planes.

Required readiness groups:

```text
Core / MCP coding path        READY | ACTION REQUIRED
Native desktop               READY | OPTIONAL / ACTION REQUIRED
Protected filesystem (FDA)   READY | OPTIONAL / ACTION REQUIRED
Background Chrome            READY | OPTIONAL / ACTION REQUIRED
Codex continuity             READY | OPTIONAL / NOT CONFIGURED
```

Core readiness should cover the pieces required to connect and execute a basic local developer workflow: source/runtime/app consistency, runtime package resolution, Node, the selected MCP transport, full-access latch state while running, local HTTP/OAuth health where applicable, and a real bridge/status smoke check.

Planned work includes:

- independent Accessibility, Screen Recording, Input/Post Events, and Full Disk Access diagnostics;
- route each missing permission to the correct macOS Privacy & Security pane instead of always opening Accessibility;
- do not report a healthy core shell/filesystem setup as globally degraded merely because an optional desktop/browser/Codex capability is not configured;
- make each failed check name the component, why it matters, and the exact next action;
- detect app/runtime version mismatch, missing source/runtime package, stale legacy processes, and invalid lifecycle state;
- verify HTTP/OAuth metadata and public-origin consistency for the HTTP transport;
- clearer dedicated-Chrome-profile, Native Messaging, extension, and workspace diagnostics;
- one authoritative `doctor`/health path whose default verdict distinguishes blocking failures from optional capabilities;
- continued menu-bar UX refinement around version, core health, transport, permissions, and Safety mode.

The current `scripts/doctor.sh` remains useful during this transition, but it is not yet the final first-run health gate.

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
- benchmark fixtures for SPA rerenders, delayed controls, iframes, Shadow DOM, and other dynamic UI cases.

Raw browser/CDP authority will remain a separate explicit opt-in surface. The normal fast path should stay constrained and auditable.

## Later

### Documentation and demos

- keep the product-first README and ChatGPT onboarding aligned with real runtime behavior and current client availability;
- architecture and runtime-operation documentation kept in sync with execution/browser changes;
- screenshots and compact demos for shell/PTY, background browser, and native macOS workflows;
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
- credentials, cookies, OAuth state, and private signing material do not enter logs or Git;
- the default browser path uses a dedicated local DarwinRelay Chrome profile rather than silently taking over a personal profile;
- Stop/disable and process reclamation remain security boundaries;
- raw CDP/browser authority remains explicit opt-in;
- public development happens only in `dcierra/darwinrelay`, with upstream attribution preserved.

## Contributing

Focused issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and required checks.

If you are interested in one of the roadmap areas, an issue describing a concrete use case, failure mode, benchmark, or implementation proposal is more useful than a generic feature request.
