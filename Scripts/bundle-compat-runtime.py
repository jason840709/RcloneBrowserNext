#!/usr/bin/env python3
"""Copy only the Swift runtime libraries used by the compatibility helper."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument("--swiftc", required=True)
p.add_argument("--runtime", type=Path, required=True)
args = p.parse_args()
target = json.loads(subprocess.check_output([args.swiftc, "-print-target-info"]))
roots = [Path(v).resolve() for v in target["paths"]["runtimeLibraryPaths"]]
lib = args.runtime / "lib"
lib.mkdir(exist_ok=True)
queue = [args.runtime / "rbn-engine"]
copied = set()
system = set()
env = dict(os.environ, LD_LIBRARY_PATH=os.pathsep.join(map(str, roots + [lib.resolve()])) )
while queue:
    current = queue.pop()
    output = subprocess.check_output(["ldd", str(current.resolve())], env=env, text=True)
    if "not found" in output:
        raise RuntimeError(output)
    for line in output.splitlines():
        match = re.search(r"^\s*(\S+)\s+=>\s+(/\S+)", line)
        if not match:
            continue
        name, source = match.group(1), Path(match.group(2)).resolve()
        if any(source.is_relative_to(root) for root in roots) or source.is_relative_to(lib.resolve()):
            if name not in copied:
                copied.add(name)
                # Keep the ELF dependency name when the SDK uses a symlink.
                dest = lib / name
                if source != dest.resolve():
                    shutil.copy2(source, dest)
                queue.append(dest)
        else:
            system.add(source.name)

manifest = {
    "swift": subprocess.check_output([args.swiftc, "--version"], text=True).strip(),
    "libraries": [{"name": f.name, "bytes": f.stat().st_size, "sha256": hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted(lib.iterdir()) if f.is_file()],
    "systemLibraries": sorted(system),
}
dynamic = subprocess.check_output(["readelf", "-d", str(args.runtime / "rbn-engine")], text=True)
runpaths = re.findall(r"(?:RUNPATH|RPATH).*\[(.*?)\]", dynamic)
if runpaths != ["$ORIGIN/lib"]:
    raise RuntimeError(f"The helper must use only its adjacent runtime libraries, found: {runpaths}")
manifest["helperRunpath"] = runpaths[0]
(args.runtime / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Bundled {len(manifest['libraries'])} Swift runtime libraries")
