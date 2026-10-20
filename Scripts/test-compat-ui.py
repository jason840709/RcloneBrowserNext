#!/usr/bin/env python3
"""Exercise the packaged native UI with an isolated, empty application state.

Run under xvfb-run on a headless Linux runner. Windows installs the built NSIS
package into the project cache and removes that test installation afterward.
The receipt comes from the bundled page through the actual native IPC bridge.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    cache = ROOT / ".build-cache" / "compat"
    platform_name = "windows" if os.name == "nt" else "linux"
    package = json.loads((cache / f"package-{platform_name}.json").read_text(encoding="utf-8"))
    installer = ROOT / "Distribution" / package["file"]
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    if digest != package["sha256"]:
        raise AssertionError("The installer differs from its packaging receipt")
    installed = Path(tempfile.mkdtemp(prefix=f"ui-installed-{platform_name}-", dir=cache))
    uninstaller = None
    if os.name == "nt":
        # /D must be the final NSIS argument; it is parsed as the entire tail.
        subprocess.run([str(installer), "/S", f"/D={installed}"], check=True, timeout=180)
        candidates = [installed / "rclone-browser-next.exe", installed / "Rclone Browser Next.exe"]
        candidates = [p for p in candidates if p.is_file()]
        uninstallers = [p for p in installed.glob("*.exe") if p.name.lower().startswith("uninstall")]
        uninstaller = uninstallers[0] if len(uninstallers) == 1 else None
    else:
        subprocess.run(["dpkg-deb", "--extract", str(installer), str(installed)], check=True, timeout=60)
        candidates = [installed / "usr/bin/rclone-browser-next"]
        candidates = [p for p in candidates if p.is_file()]
    if len(candidates) != 1:
        raise AssertionError(f"The installed app was not found: {[str(p.relative_to(installed)) for p in installed.rglob('*.exe')]}")
    executable = candidates[0]
    environment = dict(os.environ)
    # The installed app must find its own Swift libraries, not the build SDK.
    environment.pop("LD_LIBRARY_PATH", None)
    if os.name == "nt":
        system_root = Path(environment.get("SystemRoot", r"C:\Windows"))
        environment["PATH"] = os.pathsep.join(map(str, [system_root / "System32", system_root, system_root / "System32/WindowsPowerShell/v1.0"]))
    else:
        environment.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
    process = subprocess.Popen([str(executable), "--smoke-ui", str(output)],
                               cwd=installed, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
                               start_new_session=os.name != "nt")
    try:
        try:
            log, _ = process.communicate(timeout=80)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], check=False)
            else:
                os.killpg(process.pid, signal.SIGKILL)
            log, _ = process.communicate(timeout=10)
            raise AssertionError(f"Native UI test timed out.\n{log[-12000:]}")
        if not output.is_file():
            raise AssertionError(f"The native UI did not write its receipt (exit {process.returncode}).\n{log[-12000:]}")
        receipt = json.loads(output.read_text(encoding="utf-8"))
        receipt["installer"] = {"name": installer.name, "sha256": digest, "bytes": installer.stat().st_size}
        receipt["system"] = platform.platform()
        receipt["exitCode"] = process.returncode
        receipt["installedApp"] = str(executable.relative_to(installed))
        if log.strip():
            receipt["nativeLog"] = log[-12000:]
        output.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        if not receipt.get("passed") or process.returncode != 0:
            raise AssertionError(json.dumps(receipt, indent=2))
        print(json.dumps(receipt, indent=2))
    finally:
        if uninstaller is not None:
            # _?= keeps NSIS in the known test directory until uninstall ends.
            subprocess.run([str(uninstaller), "/S", f"_?={installed}"], check=True, timeout=60)


if __name__ == "__main__":
    main()
