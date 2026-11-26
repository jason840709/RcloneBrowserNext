#!/usr/bin/env python3
"""Compare installed 0.11.0 and Rust helper listings on the same disposable Windows files."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

def browse(client_type, binary, state, folder):
    client = client_type(binary, state, 30)
    try:
        return client.call("list", {"remote": None, "path": folder.as_posix()})
    finally:
        receipt = client.finish()
        if receipt.get("exitCode") != 0 or receipt.get("forcedTermination") or receipt.get("shutdownError"):
            raise RuntimeError(f"Helper failed to shut down: {binary.name}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, required=True, help="original installed 0.11.0 helper")
    parser.add_argument("--rust", type=Path, required=True, help="candidate installed Rust helper")
    parser.add_argument("--scratch", type=Path, required=True, help="existing disposable local test directory")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This comparison requires the Windows helpers on native Windows.")
    swift, rust = args.swift.resolve(strict=True), args.rust.resolve(strict=True)
    if swift.samefile(rust):
        parser.error("The baseline and candidate must be distinct executables.")
    probe = Path(__file__).resolve().parents[1] / "Scripts/windows/probe-filesystem.py"
    spec = importlib.util.spec_from_file_location("rbn_original_probe", probe)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    examples = [
        "File 2.txt", "file 02.txt", "file 10.txt", "file 100.txt", "FILE-revised.txt",
        ".hidden", "_a", "(a)", "‐dash", "dash-two", "A..txt", "B_.txt", "A-1", "A 1",
        "Ångström", "Ångström-2", "Café", "Café", "資料 02", "資料 2", "资料 20",
        "一", "あ 02", "ア 2", "ｱ 2", "ａ ３", "a 04", "👨‍👩‍👧 ספר", "🙂",
    ]
    with tempfile.TemporaryDirectory(dir=args.scratch.resolve(strict=True), prefix="windows-local-oracle-") as temp:
        root = Path(temp)
        folder = root / "listing"
        folder.mkdir()
        for index, name in enumerate(examples):
            with (folder / name).open("xb") as output:
                output.write(bytes([index]) * (1 + index))
        for name in ("Folder 2", "Folder 10", "資料夾", "ä_dir", "é directory"):
            (folder / name).mkdir()
        expected = browse(module.Client, swift, root / "swift-state", folder)
        actual = browse(module.Client, rust, root / "rust-state", folder)
    if not isinstance(expected,list) or not isinstance(actual,list) or len(expected)!=len(examples)+5:
        raise RuntimeError("Original/candidate response or fixture count is invalid")
    print(json.dumps({"passed":actual == expected,"entries":len(expected),
                      "swift":[r["name"] for r in expected],"rust":[r["name"] for r in actual],
                      "fieldDifferences":[{"swift":a,"rust":b} for a,b in zip(expected,actual) if a!=b]},
                     ensure_ascii=False))
    return 0 if actual == expected else 1

if __name__ == "__main__":
    sys.exit(main())
