# DarwinRelay Development Model

## Canonical source

The public repository **`dcierra/darwinrelay`** is the canonical source of truth for product development.

All normal work goes there:

- feature branches;
- bug fixes;
- pull requests;
- CI;
- issues/discussions;
- release tags and changelog entries;
- upstream synchronization decisions.

Do not maintain a second active copy of the product source in a private repository. That creates divergence and makes security/release provenance ambiguous.

## What happens to the old private repository

The existing private repository `dcierra/mac-developer-bridge-private` is retained temporarily as a **legacy production/rollback lineage** while the currently installed runtime still depends on that checkout and its 0.5.x identities/state.

It is not the place for new product development after DarwinRelay becomes public.

Once production is migrated to a verified DarwinRelay release, the old private repository should be archived read-only rather than deleted. Keeping it preserves historical PRs/releases and provides an additional forensic/rollback reference without inviting future divergence.

## The commits were not lost

The public repository contains the complete inherited/downstream Git graph rather than a one-commit source dump.

Before publication, maintainer commits that used the personal email `1cebergg@mail.ru` were rewritten to the GitHub noreply identity `44225844+dcierra@users.noreply.github.com`. Rewriting commit metadata necessarily changes SHA values for those commits and their descendants, but it does **not** discard their changes, authorship, dates, messages or topology.

Key lineage mapping at the public split:

```text
legacy private 0.5.2 head/tag target:
1faaef8caee42a9d1dbe1169bca5d88ae3d455be

same sanitized pre-rebrand tree/history point in public repository:
2c309e37abda896c320fee794c2a96db9b2b9aa1

first DarwinRelay public-edition commit:
87e2a5180ef314a4e3367dadef5a4685d03f615b
```

The public history still contains the original upstream authors and the later downstream development commits. Only the privacy rewrite and the new product rebrand cause SHA differences.

## Upstream relationship

DarwinRelay keeps the original project as a Git remote named `upstream`:

```text
upstream -> https://github.com/alexanderradahl/mac-developer-bridge.git
```

Upstream changes should be evaluated selectively. DarwinRelay has materially diverged in native desktop control, browser architecture, signing/TCC behavior, lifecycle and public product identity; blind merging is inappropriate.

When adopting an upstream change:

1. understand the upstream intent and security assumptions;
2. port/cherry-pick the change onto a DarwinRelay branch;
3. adapt names/paths/approval behavior to current DarwinRelay invariants;
4. run the normal public CI/test matrix;
5. preserve upstream authorship/attribution when appropriate.

## Private operational state

Machine-specific operational state is intentionally **not** synchronized through the source repository.

Examples:

- bearer/OAuth/tunnel credentials;
- Chrome profile contents;
- TCC grants;
- Apple signing private keys/certificates;
- the DarwinRelay Chrome extension private key;
- launch/runtime pidfiles;
- audit logs;
- rollback bundles;
- production-specific Cloudflare configuration.

These remain in macOS Keychain, Application Support, system privacy databases or other local operator-managed storage.

If private configuration ever becomes large enough to justify version control, use a separate small `darwinrelay-ops` repository that **pins a public DarwinRelay release/commit**. It must not copy/fork the product source tree and must not contain plaintext secrets.

## Normal future workflow

```text
issue / idea
    ↓
public DarwinRelay branch
    ↓
PR
    ↓
public hosted CI
    ↓
merge to public main
    ↓
verified release tag
    ↓
production deployment pins that release
```

The current legacy private production checkout is a temporary deployment concern, not a development branch.

## Production migration boundary

Rebranding changed application ids, environment prefixes, data paths, Chrome extension identity, Native Messaging host and LaunchAgent labels. Therefore moving a live 0.5.x installation to DarwinRelay 0.6.x is a real migration, not just `git pull`.

Perform that cutover separately with:

- explicit rollback to the existing 0.5.x installation;
- isolated DarwinRelay data/profile state;
- new macOS TCC grants for the DarwinRelay code identity if required;
- DarwinRelay Chrome profile/extension setup;
- transport/OAuth verification;
- direct `ui_*`, `chrome_*`, shell and PTY smoke tests.

Do not archive the legacy private repository until that production cutover is complete and verified.
