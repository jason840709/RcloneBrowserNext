#!/usr/bin/env python3
"""Retain license texts from the exact Cargo packages used by this build."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = ("license", "licence", "copying", "copyright", "notice", "unlicense")
FALLBACK_NAMES = {"dlopen2_derive": "dlopen2", "webview2-com-sys": "webview2-com"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default="x86_64-pc-windows-msvc" if os.name == "nt" else "x86_64-unknown-linux-gnu")
    parser.add_argument("--core-only", action="store_true", help="Only the shared engine, for the native Mac bundle")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    destination = args.output or ROOT / ".build-cache/compat/runtime/licenses"
    destination.mkdir(parents=True, exist_ok=True)
    packages = {}
    projects = (ROOT / "Sources/Rust",) if args.core_only else (ROOT / "Compat/desktop", ROOT / "Sources/Rust")
    for project in projects:
        metadata = json.loads(subprocess.check_output(
            ["cargo", "metadata", "--locked", "--offline", "--format-version", "1", "--filter-platform", args.target],
            cwd=project, text=True, encoding="utf-8"))
        for package in metadata["packages"]:
            if package["source"] is not None:
                packages[(package["name"], package["version"])] = package
    index = []
    missing = []
    for package in sorted(packages.values(), key=lambda p: (p["name"], p["version"])):
        if package["source"] is None:
            continue
        source = Path(package["manifest_path"]).parent
        files = [f for f in source.rglob("*") if f.is_file() and f.name.lower().startswith(PREFIXES)]
        if package.get("license_file"):
            explicit = source / package["license_file"]
            if explicit.is_file() and explicit not in files:
                files.append(explicit)
        fallback = ROOT / "Compat/licenses/crates" / FALLBACK_NAMES.get(package["name"], package["name"])
        if not files and fallback.is_dir():
            files = [f for f in fallback.iterdir() if f.is_file()]
            source = fallback
        if not files:
            missing.append(package["name"] + " " + package["version"])
        target = destination / "rust" / (package["name"] + "-" + package["version"])
        for file in files:
            relative = file.relative_to(source)
            if file.stat().st_size > 4 * 1024 * 1024:
                raise ValueError(f"Unexpectedly large license file: {file}")
            final = target / relative
            final.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, final)
        index.append({"name": package["name"], "version": package["version"], "license": package["license"],
                      "authors": package["authors"], "repository": package["repository"],
                      "source": f"https://crates.io/crates/{package['name']}/{package['version']}",
                      "texts": [str((target / f.relative_to(source)).relative_to(destination)) for f in files]})
    if missing:
        raise RuntimeError("Add the original license texts for: " + ", ".join(missing))
    # These are translated source algorithms and fixed Unicode data, not
    # additional Cargo packages or a redistributed Swift runtime.
    source_notices = [
        ("swift-stable-sorting", "Swift-LICENSE.txt", "Swift source sorting algorithm translated to Rust",
         "https://github.com/swiftlang/swift/blob/swift-6.1.2-RELEASE/stdlib/public/core/Sort.swift"),
    ]
    if "apple-darwin" not in args.target:
        source_notices += [
            ("foundation-string-comparison", "Foundation-LICENSE.txt", "CoreFoundation comparison and character data translated to Rust",
             "https://github.com/swiftlang/swift-corelibs-foundation/tree/swift-6.1.2-RELEASE/Sources/CoreFoundation"),
            ("unicode-character-data", "ICU-LICENSE.txt", "Unicode 15.1 character and grapheme data",
             "https://www.unicode.org/Public/15.1.0/ucd/"),
        ]
    source_index = []
    for name, license_name, description, upstream in source_notices:
        source = ROOT / "Compat/licenses" / license_name
        target = destination / "source" / name / "LICENSE.txt"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        texts = [str(target.relative_to(destination))]
        if name == "unicode-character-data":
            notice = destination / "source" / name / "NOTICE.txt"
            shutil.copyfile(ROOT / "Compat/licenses/Unicode-15.1-NOTICE.txt", notice)
            texts.append(str(notice.relative_to(destination)))
        source_index.append({"name": name, "description": description, "source": upstream,
                             "texts": texts})
    (destination / "ported-source-notices.json").write_text(
        json.dumps(source_index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (destination / "rust-packages.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Retained original license notices for {len(index)} pinned Rust packages")


if __name__ == "__main__":
    main()
