#!/usr/bin/env python3
"""Reject changes outside the Windows repair boundary of the released Mac app.

This checks Git content and modes, respecting checkout line-ending conversion.
Two protected Core files contain three exact, reviewed Windows-only insertions.
Their complete expected blobs and insertion positions are pinned below; removing
those blocks must recover the baseline bytes. All other protected files remain
byte-identical in Git. This neither builds nor modifies a Mac app.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess


ROOT = Path(__file__).resolve().parents[2]
BASE = "7ec095e9b9c949a79ff55cbd40d0fda9499b4faa"
# These are exact exceptions, not an allowance for arbitrary Windows branches.
# Keep Core outside allowed() and in the original protected-file inventory.
WINDOWS_INSERTIONS = {
    "Sources/Core/EngineModels.swift": {
        "gitObject": "2b4e3b156274b607778ca68e3bfd18e3583e6773",
        "blocks": [("WINDOWS_DRIVE_ROOT_ENDPOINT", 12,
                    "6d13f70885fbf32fe8bfd02b428bd8a0c160ee44f7beedd1a57518e9b2e0f9df",
                    b"            remote = nil\n", "after")],
    },
    "Sources/Core/EngineStorage.swift": {
        "gitObject": "b9baea9703c1ebfd75b211a6e16c40931fccd760",
        "blocks": [("WINDOWS_DRIVE_ROOT_COMPARISON_INPUT", 8,
                    "c1896ea6260a99489de204e1972e7cadb1da7df0d423236022993b8f0be43c25",
                    b"    static func canonicalLocal(_ input: String) throws -> String {\n", "after"),
                   ("WINDOWS_DRIVE_ROOT_COMPARISON_RESULT", 8,
                    "fe1e0efc9ec5e788a3bd2f2629b49046f7fd373c010c9ed6e052d1a836963d24",
                    b"        var result = candidate.resolvingSymlinksInPath()\n", "before")],
    },
}


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT)


def allowed(path):
    return (path.startswith(("Compat/desktop/", "Sources/Compat/", "Scripts/windows/", "docs/"))
            or path.startswith(".github/workflows/windows-") and path.endswith((".yml", ".yaml"))
            or path in {"Scripts/build-compat-windows.ps1", "SOURCE_MANIFEST.json"})


def blob_hash(value):
    return hashlib.sha1(b"blob " + str(len(value)).encode() + b"\0" + value).hexdigest()


def windows_insertion_receipts():
    receipts = []
    for name, specification in WINDOWS_INSERTIONS.items():
        path = ROOT / name
        baseline = git("show", BASE + ":" + name)
        actual_object = git("hash-object", "--path=" + name, name).decode().strip()
        if actual_object != specification["gitObject"]:
            raise RuntimeError("Protected Core file differs from its exact reviewed Windows insertion: " + name)
        entries = git("ls-files", "--stage", "-z", "--", name).split(b"\0")
        if (path.is_symlink() or len(entries) != 2 or not entries[0].startswith(b"100644 ")
                or b" 0\t" not in entries[0] or git("diff", "--summary", BASE, "--", name).strip()):
            raise RuntimeError("Protected Core file mode or index changed: " + name)
        # CRLF is accepted only when Git's own path filters prove that this
        # normalized byte string is precisely the pinned Git blob above.
        actual = path.read_bytes().replace(b"\r\n", b"\n")
        if blob_hash(actual) != actual_object:
            raise RuntimeError("Unexpected checkout encoding/filter for protected Core file: " + name)
        recovered, expected, blocks = actual, baseline, []
        for marker, indentation, digest, anchor, position in specification["blocks"]:
            prefix = b" " * indentation
            begin = prefix + b"// BEGIN " + marker.encode() + b"\n"
            end = prefix + b"// END " + marker.encode() + b"\n"
            if actual.count(begin) != 1 or actual.count(end) != 1 or baseline.count(anchor) != 1:
                raise RuntimeError("Windows insertion marker/anchor is not unique: " + marker)
            start = actual.index(begin)
            block = actual[start:actual.index(end, start) + len(end)]
            if (hashlib.sha256(block).hexdigest() != digest
                    or not block.startswith(begin + prefix + b"#if os(Windows)\n")
                    or not block.endswith(prefix + b"#endif\n" + end)):
                raise RuntimeError("Windows-only block differs from its reviewed bytes: " + marker)
            recovered = recovered.replace(block, b"", 1)
            replacement = anchor + block if position == "after" else block + anchor
            expected = expected.replace(anchor, replacement, 1)
            blocks.append({"marker": marker, "bytes": len(block), "sha256": digest,
                           "condition": "#if os(Windows)", "exactPositionVerified": True})
        if recovered != baseline or expected != actual:
            raise RuntimeError("Removing Windows insertions does not restore the exact Mac baseline: " + name)
        receipts.append({"path": name, "baselineGitObject": blob_hash(baseline),
                         "checkedGitObject": actual_object, "recoveredBaselineGitObject": blob_hash(recovered),
                         "originalModePreserved": True, "nonWindowsActiveSourceUnchanged": True, "blocks": blocks})
    return receipts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if git("rev-parse", BASE + "^{commit}").decode().strip() != BASE:
        raise RuntimeError("The fixed Mac 0.9.0 baseline is unavailable")
    changed = [p for p in git("diff", "--name-only", "-z", BASE, "--").decode().split("\0") if p]
    untracked = [p for p in git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0") if p]
    insertions = windows_insertion_receipts()
    forbidden = sorted({p for p in changed + untracked if not allowed(p) and p not in WINDOWS_INSERTIONS})
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
        "comparison": "160 protected files retain Git content/mode; removing three exact Windows-only insertions in two files recovers their complete baseline files; checkout line endings follow Git",
        "macInputsUnchangedMeaning": "All active Mac source, resources, build inputs, versions and workflow are unchanged; three pinned #if os(Windows) blocks in two Core files are excluded from Mac compilation",
        "protectedFileCount": len(protected),
        "protectedByteIdenticalFileCount": len(protected) - len(insertions),
        "protectedInventorySHA256": hashlib.sha256(encoded).hexdigest(),
        "protectedFiles": protected,
        "allowedChangedPaths": sorted(set(changed + untracked)),
        "windowsOnlyInsertions": insertions,
        "nonWindowsActiveSourceUnchanged": True,
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
