#!/usr/bin/env python3
"""Name and hash the Windows repair installer without changing the Mac release.

The Windows-only Tauri override supplies numeric SemVer build metadata. Pinned
Tauri maps +1 to the fourth PE version component, 0.9.0.1, while NSIS retains
0.9.0+1 in DisplayVersion and compares it when rejecting downgrades.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    cache = args.cache.resolve(strict=True)
    config = json.loads((ROOT / "Compat/desktop/tauri.conf.json").read_text(encoding="utf-8"))
    override = json.loads((ROOT / "Compat/desktop/tauri.windows.conf.json").read_text(encoding="utf-8"))
    version = override.get("version", "")
    match = re.fullmatch(r"(0\.9\.0)\+([1-9][0-9]*)", version)
    if not match or not 1 <= int(match[2]) <= 65535:
        raise ValueError("Windows repair version must be 0.9.0 plus a positive numeric PE revision")
    base, revision = match[1], int(match[2])
    if (config.get("version") != base or config.get("identifier") != "org.rclone.browser.next"
            or config.get("productName") != "Rclone Browser Next"
            or "identifier" in override or "productName" in override
            or override.get("bundle", {}).get("windows", {}).get("allowDowngrades") is not False):
        raise ValueError("The repair must preserve the base app identity and reject silent downgrades")
    # Never select a stale installer by modification time or a broad glob.
    installer = cache / "target/release/bundle/nsis" / f"Rclone Browser Next_{version}_x64-setup.exe"
    if not installer.is_file():
        raise FileNotFoundError(f"The exact Windows candidate was not built: {installer}")
    runtime = json.loads((cache / "runtime/runtime-manifest.json").read_text(encoding="utf-8-sig"))
    if not runtime.get("libraries"):
        raise ValueError("The bundled runtime manifest is empty")
    destination = ROOT / "Distribution" / f"Rclone_Browser_Next_{base}_Windows_r{revision}_x64_Setup.exe"
    destination.parent.mkdir(exist_ok=True)
    shutil.copy2(installer, destination)
    digest = sha256(destination)
    if digest != sha256(installer):
        raise RuntimeError("The copied candidate differs from the built installer")
    destination.with_suffix(".exe.sha256").write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    receipt = {
        "schemaVersion": 1, "version": version, "baseVersion": base,
        "windowsRevision": revision, "releaseTag": f"windows-v{base}-r{revision}",
        "platform": "windows", "identifier": config["identifier"], "productName": config["productName"],
        "peVersion": [0, 9, 0, revision], "sourceCommit": commit,
        "file": destination.name, "bytes": destination.stat().st_size, "sha256": digest,
        "runtime": runtime,
    }
    (cache / "package-windows.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in receipt.items() if key != "runtime"}, indent=2))


if __name__ == "__main__":
    main()
