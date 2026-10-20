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
    args = parser.parse_args()
    destination = ROOT / ".build-cache/compat/runtime/licenses"
    destination.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--locked", "--offline", "--format-version", "1", "--filter-platform", args.target],
        cwd=ROOT / "Compat/desktop", text=True, encoding="utf-8"))
    index = []
    missing = []
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
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
    (destination / "rust-packages.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Retained original license notices for {len(index)} pinned Rust packages")


if __name__ == "__main__":
    main()
