#!/usr/bin/env python3
"""Compare installed 0.11.0 and Rust helper listings on the same disposable Windows files."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


# Keep this first fixture byte-for-byte equivalent to the original 34-entry
# comparison. The second fixture is independent; neither response is sorted by
# the test before the complete ordered entries are compared.
ORIGINAL_FILES = (
    "File 2.txt", "file 02.txt", "file 10.txt", "file 100.txt", "FILE-revised.txt",
    ".hidden", "_a", "(a)", "‐dash", "dash-two", "A..txt", "B_.txt", "A-1", "A 1",
    "Ångström", "Ångström-2", "Café", "Café", "資料 02", "資料 2", "资料 20",
    "一", "あ 02", "ア 2", "ｱ 2", "ａ ３", "a 04", "👨‍👩‍👧 ספר", "🙂",
)
ORIGINAL_DIRECTORIES = ("Folder 2", "Folder 10", "資料夾", "ä_dir", "é directory")
EXTENDED_FILE_GROUPS = {
    "ascii_numbers": (
        "num0.txt", "num00.txt", "num000.txt", "num1.txt", "num01.txt", "num001.txt",
        "num2.txt", "num02.txt", "num002.txt", "num9.txt", "num09.txt", "num10.txt",
        "num010.txt", "num20.txt", "num100.txt", "num1000.txt", "num1-part2.txt",
        "num1-part02.txt", "num01-part2.txt", "num1-part10.txt",
    ),
    "punctuation": (
        "punct-a.txt", "punct_a.txt", "punct.a.txt", "punct a.txt", "punct(a).txt",
        "punct[a].txt", "punct{a}.txt", "punct+a.txt", "punct=a.txt", "punct&a.txt",
        "punct#a.txt", "punct$a.txt", "punct!a.txt", "punct'a.txt", "punct,a.txt",
        "punct;a.txt", "punct@a.txt", "punct%a.txt", "punct^a.txt", "punct~a.txt",
        "punct`a.txt", "punct‐a.txt", "punct–a.txt", "punct—a.txt", ".start.txt",
        "_start.txt", "(start).txt",
    ),
    "case": (
        "Case 2.txt", "case 02.txt", "CASE 002.txt", "Case 10.txt",
        "mix-a1.txt", "mix-A01.txt", "MIX-a001.txt", "mix-B2.txt",
    ),
    "latin_and_combining": (
        "Latin-é.txt", "Latin-e\u0301.txt", "Latin-Å.txt", "Latin-A\u030a.txt",
        "Latin-ö.txt", "Latin-o\u0308.txt", "Latin-ñ.txt", "Latin-n\u0303.txt",
        "Latin-ß 1.txt", "Latin-ss 01.txt", "Latin-æ 2.txt", "Latin-ae 02.txt",
        "Turk-I1.txt", "Turk-ı01.txt", "Turk-İ2.txt", "Turk-i02.txt",
    ),
    "width": (
        "ＡＢ1.txt", "AB01.txt", "ａｂ001.txt", "width２.txt", "width2.txt",
        "width02.txt", "width１２.txt", "width12.txt", "width012.txt", "space　wide.txt",
    ),
    "scripts": (
        "Greek-α1.txt", "Greek-Α01.txt", "Greek-ς2.txt", "Greek-σ02.txt",
        "Кирилл-Ё1.txt", "кирилл-е\u030801.txt", "資料1.txt", "資料01.txt",
        "资料2.txt", "資料2.txt", "かな1.txt", "カナ01.txt", "ｶﾅ001.txt",
        "が1.txt", "か\u309901.txt", "한글1.txt", "한글01.txt",
        "עברית1.txt", "العربية2.txt", "ไทย3.txt",
    ),
    "unicode_numbers": (
        "digits١.txt", "digits1.txt", "digits01.txt", "digits१.txt",
        "digits๒.txt", "digits2.txt", "digits02.txt", "digits².txt",
    ),
    "emoji": (
        "emoji-😀1.txt", "emoji-🙂2.txt", "emoji-👩‍💻01.txt", "emoji-👨‍👩‍👧‍👦2.txt",
        "emoji-❤1.txt", "emoji-❤️01.txt", "emoji-☀2.txt", "emoji-☀️02.txt",
    ),
    "long_combining_boundaries": (
        "Ä" + "\u0327" * 65 + "\u200dAǺ2",
        "A\u0308" + "\u0327" * 65 + "\u200dAA\u030a\u030102",
        "Ä" + "\u0308" * 62 + "\u093eã",
        "A\u0308" + "\u0308" * 62 + "\u093ea\u0303",
    ),
    "unicode_assignment_boundaries": (
        "uca-a", "uca-一", "uca-🙂", "uca-\U0001fae0", "uca-\U0001fae1",
        "uca-\U0001fae8", "uca-\U0001f979", "uca-\U0002ebf0", "uca-\U0002ebef", "uca-\U000f0000",
    ),
}
EXTENDED_FILES = tuple(name for names in EXTENDED_FILE_GROUPS.values() for name in names)
EXTENDED_DIRECTORIES = (
    "Dir2", "Dir02", "dir002", "Dir10", "目录1", "目錄01",
    "カタカナ2", "ｶﾀｶﾅ02", "é-dir", "e\u0301-dir", "Ａ-dir1", "A-dir01",
)


def fixture_sha256(files, directories):
    value = json.dumps({"files": list(files), "directories": list(directories)},
                       ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def binary_metadata(path):
    return {"name": path.name, "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def browse(client_type, binary, state, folder):
    client = client_type(binary, state, 30)
    try:
        return client.call("list", {"remote": None, "path": folder.as_posix()})
    finally:
        receipt = client.finish()
        if receipt.get("exitCode") != 0 or receipt.get("forcedTermination") or receipt.get("shutdownError"):
            raise RuntimeError(f"Helper failed to shut down: {binary.name}")


def compare_group(client_type, swift, rust, root, files, directories, group, binaries):
    root.mkdir()
    folder = root / "listing"
    folder.mkdir()
    for index, name in enumerate(files):
        with (folder / name).open("xb") as output:
            output.write(bytes([index]) * (1 + index))
    for name in directories:
        (folder / name).mkdir()
    expected = browse(client_type, swift, root / "swift-state", folder)
    actual = browse(client_type, rust, root / "rust-state", folder)
    if not isinstance(expected, list) or not isinstance(actual, list):
        raise RuntimeError("Original/candidate response is not an entry list")
    names = [entry.get("name") for entry in expected]
    if len(names) != len(files) + len(directories) or set(names) != set(files) | set(directories):
        raise RuntimeError("The published helper did not enumerate the complete physical fixture")
    return {"passed": actual == expected, "entries": len(expected),
            "swift": names, "rust": [entry.get("name") for entry in actual],
            "fieldDifferences": [{"swift": a, "rust": b}
                                 for a, b in zip(expected, actual) if a != b],
            "swiftEntries": expected, "rustEntries": actual,
            "candidateEntries": len(actual), "group": group,
            "fixtureSha256": fixture_sha256(files, directories), "binaries": binaries,
            "sourceCommit": os.environ.get("GITHUB_SHA"), "runID": os.environ.get("GITHUB_RUN_ID")}


def verify_group_receipt(value, files, directories, group):
    """Require the declared fixture and full ordered metadata, not just names."""
    count = len(files) + len(directories)
    expected, actual = value.get("swiftEntries"), value.get("rustEntries")
    if not (value.get("passed") is True and value.get("group") == group
            and value.get("fixtureSha256") == fixture_sha256(files, directories)
            and value.get("entries") == count and value.get("candidateEntries") == count
            and isinstance(expected, list) and len(expected) == count
            and isinstance(actual, list) and actual == expected
            and all(isinstance(entry, dict) and isinstance(entry.get("name"), str) for entry in expected)
            and len({entry["name"] for entry in expected}) == count
            and {entry["name"] for entry in expected} == set(files) | set(directories)
            and value.get("swift") == [entry["name"] for entry in expected]
            and value.get("rust") == value["swift"] and value.get("fieldDifferences") == []):
        raise AssertionError(f"The {group} listing oracle is incomplete or differs in order/metadata")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", type=Path, required=True, help="original installed 0.11.0 helper")
    parser.add_argument("--rust", type=Path, required=True, help="candidate installed Rust helper")
    parser.add_argument("--scratch", type=Path, required=True, help="existing disposable local test directory")
    parser.add_argument("--extended-output", type=Path, required=True, help="independent expanded fixture receipt")
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
    binaries = {"swift": binary_metadata(swift), "rust": binary_metadata(rust)}
    unicode_spec = importlib.util.spec_from_file_location("windows_unicode_runtime", probe.with_name("unicode-runtime.py"))
    unicode = importlib.util.module_from_spec(unicode_spec)
    unicode_spec.loader.exec_module(unicode)
    private = json.loads((rust.parent / "unicode-runtime.json").read_text(encoding="utf-8"))
    unicode.validate_receipt(private, library=rust.parent / "RBNUnicode.dll")
    binaries["rustUnicodeRuntime"] = private
    with tempfile.TemporaryDirectory(dir=args.scratch.resolve(strict=True), prefix="windows-local-oracle-") as temp:
        root = Path(temp)
        original = compare_group(module.Client, swift, rust, root / "original", ORIGINAL_FILES,
                                 ORIGINAL_DIRECTORIES, "original-34", binaries)
        expanded = compare_group(module.Client, swift, rust, root / "expanded", EXTENDED_FILES,
                                 EXTENDED_DIRECTORIES, "expanded-unicode", binaries)
        expanded["categories"] = {key: len(names) for key, names in EXTENDED_FILE_GROUPS.items()}
        expanded["directories"] = len(EXTENDED_DIRECTORIES)
    args.extended_output.write_text(json.dumps(expanded, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(original, ensure_ascii=False))
    return 0 if original["passed"] and expanded["passed"] else 1

if __name__ == "__main__":
    sys.exit(main())
