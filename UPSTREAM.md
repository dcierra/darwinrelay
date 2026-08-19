# Upstream lineage and attribution

DarwinRelay originated from the MIT-licensed project **Mac Developer Bridge** by Alexander Rådahl Benz:

- Upstream repository: `alexanderradahl/mac-developer-bridge`
- License: MIT
- Original copyright: `Copyright (c) 2026 Alexander Rådahl Benz`

The public DarwinRelay repository preserves the inherited Git history rather than importing the upstream source as an unattributed snapshot. The upstream lineage present before DarwinRelay-specific development includes commits through `b9b6f8ba01f7862531815e773efdd7a710c60e5f` (`fix: route legacy Chrome opens through MDB (#10)`). DarwinRelay-specific native desktop work begins immediately after that point in the preserved history.

DarwinRelay has since substantially diverged in native desktop control, background browser routing, signing/TCC behavior, deployment lifecycle, CI, branding and release engineering. It is independently maintained by Sergey Borisov (`@dcierra`).

The original MIT notice is retained in `LICENSE` as required. DarwinRelay adds its own copyright line for subsequent modifications; this does not remove or replace the upstream copyright.

The DarwinRelay name, identifiers and Chrome extension identity are intentionally independent. Runtime identifiers do not use the upstream maintainer's namespace or an OpenAI namespace.

DarwinRelay is not affiliated with or endorsed by Alexander Rådahl Benz, OpenAI, Apple, Google or Cloudflare.
