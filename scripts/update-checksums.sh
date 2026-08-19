#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
python3 - <<'PY'
from pathlib import Path
import hashlib, os, subprocess
root = Path.cwd()
paths = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
rows = []
for raw in paths:
    if not raw:
        continue
    rel = raw.decode("utf-8", "surrogateescape")
    if rel == "SHA256SUMS":
        continue
    path = root / rel
    if not path.is_file() or path.is_symlink():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    rows.append((rel, digest))
rows.sort(key=lambda item: item[0])
tmp = root / ".SHA256SUMS.tmp"
with tmp.open("w", encoding="utf-8", newline="\n") as f:
    for rel, digest in rows:
        f.write(f"{digest}  {rel}\n")
os.replace(tmp, root / "SHA256SUMS")
print(f"updated SHA256SUMS for {len(rows)} tracked regular files")
PY
