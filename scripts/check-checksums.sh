#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
python3 - <<'PY'
from pathlib import Path
import hashlib, subprocess, sys
root = Path.cwd()
manifest = root / "SHA256SUMS"
if not manifest.is_file():
    raise SystemExit("SHA256SUMS is missing")
expected = {}
for lineno, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
    if not line.strip():
        continue
    if "  " not in line:
        raise SystemExit(f"SHA256SUMS:{lineno}: malformed line")
    digest, rel = line.split("  ", 1)
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise SystemExit(f"SHA256SUMS:{lineno}: invalid sha256")
    if rel in expected:
        raise SystemExit(f"SHA256SUMS:{lineno}: duplicate path {rel!r}")
    expected[rel] = digest

tracked = []
for raw in subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0"):
    if not raw:
        continue
    rel = raw.decode("utf-8", "surrogateescape")
    if rel == "SHA256SUMS":
        continue
    path = root / rel
    if path.is_file() and not path.is_symlink():
        tracked.append(rel)
tracked.sort()
manifest_paths = sorted(expected)
if tracked != manifest_paths:
    missing = sorted(set(tracked) - set(manifest_paths))
    extra = sorted(set(manifest_paths) - set(tracked))
    if missing:
        print("missing from SHA256SUMS:", *missing, sep="\n  ", file=sys.stderr)
    if extra:
        print("not tracked but present in SHA256SUMS:", *extra, sep="\n  ", file=sys.stderr)
    raise SystemExit(1)

bad = []
for rel in tracked:
    actual = hashlib.sha256((root / rel).read_bytes()).hexdigest()
    if actual != expected[rel]:
        bad.append(rel)
if bad:
    print("checksum mismatch:", *bad, sep="\n  ", file=sys.stderr)
    raise SystemExit(1)
print(f"SHA256SUMS verified: {len(tracked)}/{len(tracked)} tracked regular files")
PY
