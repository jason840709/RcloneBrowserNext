#!/usr/bin/env python3
"""Verify the repair's installed files, versions and 0.9.0 upgrade on disposable CI.

The fresh phase leaves its app installed for the filesystem and WebView2 probes.
The upgrade phase removes only that owned installation, installs the pinned
published 0.9.0, saves synthetic settings/tasks through its real helper, and
upgrades it in place. Raw before/after snapshots and their hashes are retained.
No Swift SDK or compiler is needed by this verifier or its child processes.
"""
from pathlib import Path
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
import platform
import queue
import shutil
import struct
import subprocess
import sys
import threading
import time
import traceback


ROOT = Path(__file__).resolve().parents[2]
APP_ID = "org.rclone.browser.next"
PRODUCT = "Rclone Browser Next"
VERSION = "0.9.0+1"
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Rclone Browser Next"
OWNED_CACHE = ROOT / ".build-cache/windows-candidate-install"


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def metadata(path):
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest(path)}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def clean_environment():
    env = {key: value for key, value in os.environ.items()
           if key.upper() not in {"PATH", "SDKROOT", "LD_LIBRARY_PATH", "GH_TOKEN", "GITHUB_TOKEN"}
           and not key.upper().startswith("RCLONE_")}
    system = Path(env.get("SystemRoot", r"C:\Windows"))
    env["PATH"] = os.pathsep.join(map(str, [system / "System32", system, system / "System32/WindowsPowerShell/v1.0"]))
    return env


def pe_version(path):
    """Read both the PE machine and fixed/string version resources via Win32."""
    with path.open("rb") as source:
        require(source.read(2) == b"MZ", f"Not a PE executable: {path.name}")
        source.seek(0x3c)
        source.seek(struct.unpack("<I", source.read(4))[0])
        require(source.read(4) == b"PE\0\0", f"Invalid PE signature: {path.name}")
        machine = struct.unpack("<H", source.read(2))[0]
    api = ctypes.WinDLL("version", use_last_error=True)
    api.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    api.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    api.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    api.GetFileVersionInfoW.restype = wintypes.BOOL
    api.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
    api.VerQueryValueW.restype = wintypes.BOOL
    size = api.GetFileVersionInfoSizeW(str(path), None)
    require(size > 0, f"Missing PE version resource: {path.name}")
    buffer = ctypes.create_string_buffer(size)
    require(api.GetFileVersionInfoW(str(path), 0, size, buffer), f"Cannot read PE version: {path.name}")

    def query(key):
        pointer, length = ctypes.c_void_p(), wintypes.UINT()
        require(api.VerQueryValueW(buffer, key, ctypes.byref(pointer), ctypes.byref(length)), f"Missing PE version entry {key}")
        return pointer, length.value

    pointer, length = query("\\")
    require(length >= 52, "Truncated VS_FIXEDFILEINFO")
    fixed = struct.unpack("<13I", ctypes.string_at(pointer, 52))
    require(fixed[0] == 0xFEEF04BD, "Invalid VS_FIXEDFILEINFO signature")
    pointer, length = query(r"\VarFileInfo\Translation")
    translations = struct.unpack("<" + "H" * (length // 2), ctypes.string_at(pointer, length))
    require(len(translations) >= 2 and len(translations) % 2 == 0, "Missing PE resource languages")
    strings = []
    for language, codepage in zip(translations[::2], translations[1::2]):
        values = {"language": f"{language:04x}", "codepage": f"{codepage:04x}"}
        for key in ("FileVersion", "ProductVersion"):
            pointer, length = query(f"\\StringFileInfo\\{language:04x}{codepage:04x}\\{key}")
            values[key] = ctypes.wstring_at(pointer, length).rstrip("\0")
        strings.append(values)
    parts = lambda high, low: [high >> 16, high & 65535, low >> 16, low & 65535]
    return {"machine": f"0x{machine:04x}", "fileVersion": parts(fixed[2], fixed[3]),
            "productVersion": parts(fixed[4], fixed[5]), "strings": strings}


def verify_version(path, expected, numeric, *, application=False):
    value = pe_version(path)
    require(value["fileVersion"] == numeric and value["productVersion"] == numeric,
            f"Unexpected fixed PE version in {path.name}: {value}")
    require(all(item["FileVersion"] == expected and item["ProductVersion"] == expected for item in value["strings"]),
            f"Unexpected string PE version in {path.name}: {value}")
    if application:
        require(value["machine"] == "0x8664", "The installed application must be x64")
    return value


def registration():
    import winreg
    result = []
    for name, view in (("32", winreg.KEY_WOW64_32KEY), ("64", winreg.KEY_WOW64_64KEY)):
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY, 0, winreg.KEY_READ | view) as key:
                values = {}
                for field in ("DisplayName", "DisplayVersion", "InstallLocation", "UninstallString"):
                    try:
                        values[field] = winreg.QueryValueEx(key, field)[0]
                    except FileNotFoundError:
                        values[field] = None
                result.append({"hive": "HKCU", "view": name, "key": UNINSTALL_KEY, **values})
        except FileNotFoundError:
            pass
    return result


def installed_paths(directory):
    apps = [directory / name for name in ("rclone-browser-next.exe", PRODUCT + ".exe")]
    apps = [path for path in apps if path.is_file()]
    engines = list(directory.rglob("rbn-engine.exe"))
    uninstallers = [path for path in directory.glob("*.exe") if path.name.lower().startswith("uninstall")]
    require(len(apps) == len(engines) == len(uninstallers) == 1, "Expected one installed app, helper and uninstaller")
    return {"app": apps[0], "engine": engines[0], "uninstaller": uninstallers[0]}


def snapshot(directory, state, *, installed=False):
    value = {"at": utc_now(), "installDirectory": str(directory), "registration": registration(),
             "stateDirectory": str(state), "stateExists": state.exists(), "stateFiles": {}}
    for name in ("settings.json", "tasks.json", "jobs.json"):
        path = state / name
        if path.is_file():
            value["stateFiles"][name] = {**metadata(path), "value": json.loads(path.read_text(encoding="utf-8-sig"))}
    if installed:
        value["installedExecutables"] = {name: metadata(path) for name, path in installed_paths(directory).items()}
        value["appPE"] = pe_version(Path(value["installedExecutables"]["app"]["path"]))
    return value


def validate_installed(directory, version, numeric, package=None):
    paths = installed_paths(directory)
    records = registration()
    require(records and all(record["DisplayVersion"] == version for record in records), "NSIS DisplayVersion does not match the installed revision")
    # Tauri's pinned NSIS template stores InstallLocation with surrounding
    # quotes. Retain the raw registry value in snapshots, unquote only here.
    def location(value):
        if isinstance(value, str) and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        return Path(value).resolve() if value else None
    require(all(location(record["InstallLocation"]) == directory for record in records),
            "The registered installation is not the owned test directory")
    verify_version(paths["app"], version, numeric, application=True)
    if package:
        for library in package["runtime"]["libraries"]:
            candidate = paths["engine"].parent / library["name"]
            require(candidate.is_file() and candidate.stat().st_size == library["bytes"] and digest(candidate) == library["sha256"],
                    f"Installed runtime library differs from its build receipt: {library['name']}")
    return paths


def run_installer(installer, directory, log_path, *, allow_failure=False):
    # NSIS /D must remain the final argument and must not contain extra quotes.
    with log_path.open("w", encoding="utf-8") as log:
        result = subprocess.run([str(installer), "/S", f"/D={directory}"],
                                stdout=log, stderr=subprocess.STDOUT, env=clean_environment(), timeout=240)
    if not allow_failure:
        require(result.returncode == 0, f"Installer failed with exit code {result.returncode}")
    return result.returncode


def uninstall(directory, expected_uninstaller, evidence):
    require(directory.is_relative_to(OWNED_CACHE.resolve()), "Refusing to uninstall a directory outside the owned cache")
    executable = Path(expected_uninstaller["path"])
    require(executable.parent == directory and digest(executable) == expected_uninstaller["sha256"], "The owned uninstaller changed")
    with (evidence / "fresh-uninstall.log").open("w", encoding="utf-8") as log:
        result = subprocess.run([str(executable), "/S", f"_?={directory}"],
                                stdout=log, stderr=subprocess.STDOUT, env=clean_environment(), timeout=90)
    require(result.returncode == 0 and not registration(), "The fresh test installation did not uninstall cleanly")


class StateClient:
    """The actual helper protocol, using the real app state path on this CI user."""
    def __init__(self, engine, state, fixture, evidence, label):
        self.evidence, self.label = evidence, label
        self.records, self.stderr, self.stdout, self.events = [], [], [], []
        self.replies, self.sequence = queue.Queue(), 0
        self.process = subprocess.Popen([str(engine), "--state-dir", str(state), "--engine-dir", str(fixture / "empty-engine")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
            errors="replace", bufsize=1, env=clean_environment())

        def read():
            try:
                for line in self.process.stdout:
                    self.stdout.append(line.rstrip())
                    value = json.loads(line)
                    if "event" in value:
                        self.events.append(value["event"])
                    else:
                        self.replies.put(value)
            except Exception as error:
                self.replies.put({"error": str(error)})
            finally:
                self.replies.put({"error": "Helper output ended"})

        def read_error():
            for line in self.process.stderr:
                self.stderr.append(line.rstrip())

        self.readers = [threading.Thread(target=read, daemon=True), threading.Thread(target=read_error, daemon=True)]
        for reader in self.readers:
            reader.start()

    def call(self, method, *values):
        self.sequence += 1
        request = {"id": f"upgrade-{self.sequence}", "method": method, "args": list(values)}
        record = {"request": request}
        self.records.append(record)
        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        reply = self.replies.get(timeout=45)
        record["response"] = reply
        require(not reply.get("error") and reply.get("id") == request["id"], f"Helper request failed: {reply}")
        return reply.get("result")

    def close(self):
        error = None
        try:
            self.call("_shutdown")
            self.process.stdin.close()
            self.process.wait(timeout=20)
            require(self.process.returncode == 0, "The installed helper did not exit cleanly")
        except Exception as failure:
            error = failure
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=10)
        finally:
            for reader in self.readers:
                reader.join(timeout=2)
            write_json(self.evidence / f"{self.label}-helper.json", {
                "requests": self.records, "events": self.events, "stdout": self.stdout, "stderr": self.stderr,
                "exitCode": self.process.returncode, "shutdownError": str(error) if error else None,
                "runtimePathPolicy": "System directories only; SDKROOT and RCLONE_* removed",
            })
        if error:
            raise error


def baseline_installer(evidence):
    spec = importlib.util.spec_from_file_location("rbn_baseline", Path(__file__).with_name("prepare-baseline.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with module.request(f"https://api.github.com/repos/{module.REPOSITORY}/releases/tags/v0.9.0") as response:
        raw = response.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, "Unexpectedly large baseline release metadata")
    (evidence / "upgrade-baseline-release.json").write_bytes(raw)
    asset = module.validate_release(json.loads(raw), "0.9.0")
    installer = OWNED_CACHE / asset["name"]
    module.download_installer(asset, installer, module.BASELINES["0.9.0"])
    return installer, {**metadata(installer), "assetID": asset["id"], "apiDigest": asset["digest"],
                       "knownReleaseHashVerified": True, "apiDigestVerified": True}


def reject_lower_revision(candidate, directory, state, evidence):
    """Exercise NSIS's real +metadata comparison with an owned higher registry value."""
    import winreg
    before = snapshot(directory, state, installed=True)
    records = before["registration"]
    require(records and all(item["DisplayVersion"] == VERSION for item in records), "Only the owned candidate registration may be changed")
    write_json(evidence / "downgrade-before.json", before)
    changed = []
    try:
        for record in records:
            view = winreg.KEY_WOW64_32KEY if record["view"] == "32" else winreg.KEY_WOW64_64KEY
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY, 0, winreg.KEY_SET_VALUE | view) as key:
                winreg.SetValueEx(key, "DisplayVersion", 0, winreg.REG_SZ, "0.9.0+2")
            changed.append(view)
        code = run_installer(candidate, directory, evidence / "downgrade-rejected.log", allow_failure=True)
        after = snapshot(directory, state, installed=True)
        write_json(evidence / "downgrade-after.json", after)
        require(code != 0, "NSIS accepted a silent downgrade from +2 to +1")
        require(all(item["DisplayVersion"] == "0.9.0+2" for item in after["registration"]), "A rejected downgrade changed registration")
        for name in before["installedExecutables"]:
            require(before["installedExecutables"][name]["sha256"] == after["installedExecutables"][name]["sha256"], "A rejected downgrade changed an installed executable")
        require(before["stateFiles"] == after["stateFiles"], "A rejected downgrade changed saved state")
        return {"passed": True, "installerExitCode": code, "simulatedInstalledDisplayVersion": "0.9.0+2",
                "candidateVersion": VERSION, "scope": "The owned registry DisplayVersion is raised temporarily; no r2 app is claimed to be installed"}
    finally:
        for view in changed:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY, 0, winreg.KEY_SET_VALUE | view) as key:
                winreg.SetValueEx(key, "DisplayVersion", 0, winreg.REG_SZ, VERSION)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["fresh", "upgrade"], required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--rclone", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(os.name == "nt" and platform.machine().lower() in {"amd64", "x86_64"}
            and os.environ.get("GITHUB_ACTIONS", "").lower() == "true", "Run only on a disposable Windows x64 Actions runner")
    evidence = args.output.resolve()
    require(evidence.is_relative_to((ROOT / ".build-cache/windows-candidate").resolve()), "Evidence must stay inside the candidate cache")
    evidence.mkdir(parents=True, exist_ok=True)
    OWNED_CACHE.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "phase": args.phase, "passed": False, "startedAt": utc_now(),
              "runID": os.environ.get("GITHUB_RUN_ID"), "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
              "sourceCommit": os.environ.get("GITHUB_SHA"), "system": platform.platform(), "version": VERSION}
    state, owned_state = None, False
    try:
        candidate, rclone = args.candidate.resolve(strict=True), args.rclone.resolve(strict=True)
        package = json.loads(args.receipt.read_text(encoding="utf-8"))
        require(package.get("version") == VERSION and package.get("identifier") == APP_ID and package.get("peVersion") == [0, 9, 0, 1], "Unexpected candidate identity/version")
        require(package.get("sourceCommit") == report["sourceCommit"], "The package was built from a different commit")
        require(candidate.name == package["file"] and candidate.stat().st_size == package["bytes"] and digest(candidate) == package["sha256"], "The candidate does not match its package receipt")
        report["installer"] = metadata(candidate)
        report["installerPE"] = verify_version(candidate, VERSION, [0, 9, 0, 1])
        report["rclone"] = metadata(rclone)
        report["packageReceiptSHA256"] = digest(args.receipt)
        roaming = ctypes.create_unicode_buffer(32768)
        require(ctypes.windll.shell32.SHGetFolderPathW(None, 0x001A, None, 0, roaming) == 0, "Cannot resolve the actual RoamingAppData folder")
        state = Path(roaming.value) / APP_ID
        require(not state.exists(), "Refusing to touch pre-existing application state; the UI probe must clean up its owned fixture")
        directory = (OWNED_CACHE / args.phase).resolve()
        require(not directory.exists(), "Refusing to reuse a previous installation directory")
        directory.mkdir()
        if args.phase == "fresh":
            before = snapshot(directory, state)
            write_json(evidence / "fresh-before.json", before)
            require(not before["registration"], "A pre-existing installation registration is present")
            report["installerExitCode"] = run_installer(candidate, directory, evidence / "fresh-installer.log")
            paths = validate_installed(directory, VERSION, [0, 9, 0, 1], package)
            write_json(evidence / "fresh-after.json", snapshot(directory, state, installed=True))
            report["installedExecutables"] = {name: metadata(path) for name, path in paths.items()}
            report["installDirectory"] = str(directory)
            report["runtimeLibrariesVerified"] = len(package["runtime"]["libraries"])
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                    print(f"app={paths['app']}\nengine={paths['engine']}", file=output)
        else:
            fresh = json.loads((evidence / "fresh-installation.json").read_text(encoding="utf-8"))
            require(fresh.get("passed") is True and fresh.get("sourceCommit") == report["sourceCommit"], "The fresh installation phase did not pass")
            uninstall(Path(fresh["installDirectory"]), fresh["installedExecutables"]["uninstaller"], evidence)
            baseline, report["baselineInstaller"] = baseline_installer(evidence)
            report["baselineInstallerExitCode"] = run_installer(baseline, directory, evidence / "upgrade-baseline-installer.log")
            old = validate_installed(directory, "0.9.0", [0, 9, 0, 0])
            fixture = OWNED_CACHE / "upgrade-fixture"
            fixture.mkdir()
            (fixture / "empty-engine").mkdir()
            source, target = fixture / "source 資料", fixture / "target 資料"
            source.mkdir(); target.mkdir()
            (source / "keep.txt").write_text("upgrade fixture\n", encoding="utf-8")
            config = fixture / "rclone.conf"
            config.write_text(f"[upgrade-alias]\ntype = alias\nremote = {target.as_posix()}\n", encoding="utf-8")
            state.mkdir()
            owned_state = True
            settings = {"rclonePath": str(rclone), "rcloneDirectory": str(rclone.parent), "configPath": str(config),
                        "autoCheckUpdates": False, "language": "ja", "theme": "blue-light", "interfaceScale": 125,
                        "initialLocations": {"left": {"remote": None, "path": source.as_posix()}, "right": {"remote": "upgrade-alias", "path": ""}}}
            transfer = {"source": {"remote": None, "path": source.as_posix()}, "destination": {"remote": "upgrade-alias", "path": ""},
                        "mode": "copy", "selection": [{"name": "keep.txt", "isDir": False}], "dryRun": True,
                        "options": {"comparison": "default", "localHashPolicy": "none", "transfers": 2, "checkers": 4, "bandwidth": "7M"}}
            client = StateClient(old["engine"], state, fixture, evidence, "upgrade-old")
            try:
                require(client.call("saveSettings", settings).get("available") is True, "Old version cannot load the synthetic rclone configuration")
                client.call("saveTask", "升級保留作業", transfer)
                expected_boot = client.call("bootstrap")
                expected_tasks = client.call("listTasks")
            finally:
                client.close()
            before = snapshot(directory, state, installed=True)
            before["configurationFile"] = {**metadata(config), "text": config.read_text(encoding="utf-8")}
            write_json(evidence / "upgrade-before.json", before)
            require({"settings.json", "tasks.json"}.issubset(before["stateFiles"]), "The published app did not persist settings and tasks")
            report["installerExitCode"] = run_installer(candidate, directory, evidence / "upgrade-installer.log")
            paths = validate_installed(directory, VERSION, [0, 9, 0, 1], package)
            after = snapshot(directory, state, installed=True)
            after["configurationFile"] = {**metadata(config), "text": config.read_text(encoding="utf-8")}
            write_json(evidence / "upgrade-after.json", after)
            require(before["stateFiles"] == after["stateFiles"] and before["configurationFile"] == after["configurationFile"], "The installer changed saved settings, tasks, history or rclone configuration")
            for name in ("app", "engine"):
                require(after["installedExecutables"][name]["sha256"] == fresh["installedExecutables"][name]["sha256"], "Upgrade installed different bytes from the verified fresh candidate")
            client = StateClient(paths["engine"], state, fixture, evidence, "upgrade-new")
            try:
                actual_boot, actual_tasks = client.call("bootstrap"), client.call("listTasks")
                require(actual_boot["settings"] == expected_boot["settings"], "The upgraded helper did not reload the saved settings")
                require(actual_tasks == expected_tasks and len(actual_tasks) == 1, "The upgraded helper did not reload the saved task")
                require(actual_boot["environment"]["available"] is True and actual_boot["resolvedLanguage"] == "ja", "The upgraded helper lost the configured engine or language")
            finally:
                client.close()
            write_json(evidence / "upgrade-reloaded.json", {"beforeBootstrap": expected_boot, "afterBootstrap": actual_boot,
                       "beforeTasks": expected_tasks, "afterTasks": actual_tasks})
            report["settingsPreservedByteForByte"] = True
            report["tasksPreservedByteForByte"] = True
            report["configurationPreservedByteForByte"] = True
            report["savedStateReloadedByInstalledHelper"] = True
            report["downgradeGuard"] = reject_lower_revision(candidate, directory, state, evidence)
            validate_installed(directory, VERSION, [0, 9, 0, 1], package)
            report["installedExecutables"] = after["installedExecutables"]
            report["installDirectory"] = str(directory)
        report["passed"] = True
    except Exception as error:
        report["error"] = {"type": type(error).__name__, "message": str(error), "traceback": traceback.format_exc()}
    finally:
        if owned_state and state is not None:
            try:
                shutil.rmtree(state)
                report["ownedStateRemoved"] = True
            except Exception as error:
                report["passed"] = False
                report["cleanupError"] = str(error)
        report["finishedAt"] = utc_now()
        prefixes = ("fresh-before", "fresh-after", "fresh-installer") if args.phase == "fresh" else ("upgrade-", "downgrade-", "fresh-uninstall")
        report["evidence"] = [{"file": path.name, "bytes": path.stat().st_size, "sha256": digest(path)}
                              for path in sorted(evidence.iterdir()) if path.is_file() and path.name != f"{args.phase}-installation.json"
                              and path.name.startswith(prefixes)]
        write_json(evidence / f"{args.phase}-installation.json", report)
    print(json.dumps({key: report.get(key) for key in ("phase", "passed", "sourceCommit", "version", "error", "cleanupError")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
