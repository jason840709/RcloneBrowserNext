#!/usr/bin/env python3
"""Reject changes outside the Windows repair boundary of the released Mac app.

This checks Git content and modes, respecting checkout line-ending conversion.
It neither builds nor modifies a Mac app. The baseline is the completed 0.9.0
source and validation commit, not a moving branch name.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess


ROOT = Path(__file__).resolve().parents[2]
BASE = "7ec095e9b9c949a79ff55cbd40d0fda9499b4faa"


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def allowed(path):
    return (path.startswith(("Compat/desktop/", "Sources/Compat/", "Scripts/windows/", "docs/"))
            or path.startswith(".github/workflows/windows-") and path.endswith((".yml", ".yaml"))
            or path in {"Scripts/build-compat-windows.ps1", "SOURCE_MANIFEST.json"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if git("rev-parse", BASE + "^{commit}").decode().strip() != BASE:
        raise RuntimeError("The fixed Mac 0.9.0 baseline is unavailable")
    changed = [p for p in git("diff", "--name-only", "-z", BASE, "--").decode().split("\0") if p]
    untracked = [p for p in git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0") if p]
    forbidden = sorted({p for p in changed + untracked if not allowed(p)})
    if forbidden:
        raise RuntimeError("Changes outside the Windows-only repair boundary: " + ", ".join(forbidden))
    protected = []
    for entry in git("ls-tree", "-r", "-z", BASE).split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        name = raw_name.decode()
        if not allowed(name):
            protected.append({"path": name, "mode": mode, "type": kind, "gitObject": oid})
    encoded = json.dumps(protected, sort_keys=True, separators=(",", ":")).encode()
    receipt = {
        "baselineCommit": BASE,
        "checkedCommit": git("rev-parse", "HEAD").decode().strip(),
        "comparison": "Git tracked content and mode, accounting for checkout line-ending normalization",
        "protectedFileCount": len(protected),
        "protectedInventorySHA256": hashlib.sha256(encoded).hexdigest(),
        "protectedFiles": protected,
        "allowedChangedPaths": sorted(set(changed + untracked)),
        "macInputsUnchanged": True,
        "existingMacWorkflowUnchanged": True,
        "existingMacVersionUnchanged": True,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: v for k, v in receipt.items() if k != "protectedFiles"}, indent=2))


if __name__ == "__main__":
    main()
