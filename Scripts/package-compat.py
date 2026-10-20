#!/usr/bin/env python3
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument("--platform", choices=["windows", "linux"], required=True)
p.add_argument("--cache", type=Path, required=True)
args = p.parse_args()
version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
pattern, suffix = ("nsis/*.exe", "Windows_x64_Setup.exe") if args.platform == "windows" else ("deb/*.deb", "Linux_amd64.deb")
candidates = list((args.cache / "target/release/bundle").glob(pattern))
if len(candidates) != 1:
    raise ValueError(f"Expected one current installer, found {len(candidates)}")
destination = ROOT / "Distribution" / f"Rclone_Browser_Next_{version}_{suffix}"
destination.parent.mkdir(exist_ok=True)
shutil.copy2(candidates[0], destination)
digest = hashlib.sha256(destination.read_bytes()).hexdigest()
destination.with_suffix(destination.suffix + ".sha256").write_text(f"{digest}  {destination.name}\n")
receipt = {"version": version, "platform": args.platform, "file": destination.name,
           "bytes": destination.stat().st_size, "sha256": digest,
           "runtime": json.loads((args.cache / "runtime/runtime-manifest.json").read_text(encoding="utf-8-sig"))}
(args.cache / f"package-{args.platform}.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps({k: v for k, v in receipt.items() if k != "runtime"}, indent=2))
