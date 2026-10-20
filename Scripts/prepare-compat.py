#!/usr/bin/env python3
"""Prepare the compatibility host from the committed Mac/web resources.

Only project-local build files are written. This does not download dependencies
or alter the original app icon or Mac web bundle.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build-cache" / "compat"


def png_from_icns(path: Path) -> bytes:
    raw = path.read_bytes()
    if raw[:4] != b"icns" or struct.unpack(">I", raw[4:8])[0] != len(raw):
        raise ValueError(f"Invalid ICNS: {path.name}")
    offset = 8
    while offset < len(raw):
        kind, size = raw[offset:offset+4], struct.unpack(">I", raw[offset+4:offset+8])[0]
        if size < 8 or offset+size > len(raw):
            raise ValueError("Invalid ICNS member")
        content = raw[offset+8:offset+size]
        if kind == b"ic08" and content.startswith(b"\x89PNG\r\n\x1a\n"):
            return content
        offset += size
    raise ValueError("The icon has no 256 px PNG member")


def main() -> None:
    web = CACHE / "web"
    runtime = CACHE / "runtime"
    # These are generated staging folders. A rebuild must not retain an old
    # Swift runtime, removed web assets or a previous CI test executable.
    for stage in (web, runtime):
        if stage.is_symlink():
            raise ValueError(f"The build staging directory must not be a symlink: {stage}")
        if stage.exists():
            shutil.rmtree(stage)
    web.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    licenses = runtime / "licenses"
    shutil.copytree(ROOT / "Compat/licenses", licenses, dirs_exist_ok=True)
    shutil.copy2(ROOT / "LICENSE", licenses / "Rclone-Browser-Next-LICENSE.txt")
    shutil.copy2(ROOT / "Resources/Web/THIRD_PARTY_NOTICES.txt", licenses / "Web-THIRD-PARTY-NOTICES.txt")
    shutil.copy2(ROOT / "Compat/THIRD_PARTY_NOTICES.md", runtime / "THIRD_PARTY_NOTICES.md")
    for source in (ROOT / "Resources" / "Web").iterdir():
        if source.is_file():
            shutil.copy2(source, web / source.name)
    index = web / "index.html"
    markup = index.read_text(encoding="utf-8")
    if "connect-src 'none'" not in markup:
        raise ValueError("Review the web CSP before preparing a compatibility build")
    index.write_text(markup.replace("connect-src 'none'", "connect-src ipc: http://ipc.localhost"), encoding="utf-8")

    icons = ROOT / "Compat" / "desktop" / "icons"
    icons.mkdir(parents=True, exist_ok=True)
    for color, name in [("purple", "AppIcon.icns"), ("blue", "AppIcon-blue.icns"), ("green", "AppIcon-green.icns")]:
        png = png_from_icns(ROOT / "Resources" / name)
        (runtime / f"icon-{color}.png").write_bytes(png)
        if color == "purple":
            (icons / "icon.png").write_bytes(png)
            # Windows accepts PNG payloads in ICO; retain the exact original pixels.
            header = struct.pack("<HHH", 0, 1, 1)
            entry = struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png), 22)
            (icons / "icon.ico").write_bytes(header + entry + png)
    version = plistlib.loads((ROOT / "Resources" / "Info.plist").read_bytes())["CFBundleShortVersionString"]
    config = json.loads((ROOT / "Compat" / "desktop" / "tauri.conf.json").read_text())
    if config["version"] != version:
        raise ValueError(f"Tauri version {config['version']} differs from Info.plist {version}")
    receipt = {
        "version": version,
        "web": {p.name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(web.iterdir()) if p.is_file()},
        "icons": "Exact PNG image members from the original ICNS files; no recolouring during packaging.",
    }
    (CACHE / "prepared-assets.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Prepared compatibility resources for {version}")


if __name__ == "__main__":
    main()
