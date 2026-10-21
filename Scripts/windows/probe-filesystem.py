#!/usr/bin/env python3
"""Diagnose an installed Windows helper without rebuilding it or changing user data.

Each case starts a fresh helper with its own state and an empty rclone directory.
Only the configured-bootstrap case enables the supplied rclone, with an empty
configuration. Home and the system drive are read only; all created files and
junctions are disposable fixtures. Sparse files consume negligible disk space.

Product failures are evidence, not a script failure: they are written to JSON
and the process exits 0. Invalid inputs, fixture failures and output failures
exit nonzero. This is a baseline probe, not proof that the Windows UI works.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable


SCHEMA_VERSION = 1
LOG_LIMIT = 128 * 1024
GIB = 1024 ** 3
SPARSE_SIZES = (2 * GIB - 1, 2 * GIB + 1, 3 * GIB, 4 * GIB + 1, 5 * GIB)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def file_metadata(path: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def normalized_path(value: str) -> str:
    return value.replace("\\", "/").rstrip("/").casefold()


def endpoint(path: Path | str) -> dict[str, Any]:
    return {"remote": None, "path": str(path)}


class ProductFailure(Exception):
    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


class BoundedLog:
    def __init__(self) -> None:
        self.parts: list[str] = []
        self.characters = 0
        self.discarded = 0

    def append(self, value: str) -> None:
        keep = max(0, LOG_LIMIT - self.characters)
        self.parts.append(value[:keep])
        self.characters += min(keep, len(value))
        self.discarded += max(0, len(value) - keep)

    def value(self) -> dict[str, Any]:
        return {"text": "".join(self.parts), "discardedCharacters": self.discarded}


def child_environment(directory: Path) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items()
           if not key.upper().startswith("RCLONE_")}
    temporary = directory / "tmp"
    temporary.mkdir()
    env.update(TMPDIR=str(temporary), TMP=str(temporary), TEMP=str(temporary))
    if os.name == "nt":
        system = Path(next((value for key, value in env.items()
                            if key.casefold() == "systemroot"), r"C:\Windows"))
        # Match the installed application's clean-runtime test. No Swift SDK or
        # development rclone can be found through the runner's original PATH.
        env = {key: value for key, value in env.items() if key.casefold() != "path"}
        env["PATH"] = os.pathsep.join(map(str, [system / "System32", system,
                                               system / "System32/WindowsPowerShell/v1.0"]))
    return env


class Client:
    """One disposable helper, with the real host's newline JSON protocol."""

    def __init__(self, executable: Path, directory: Path, timeout: float):
        self.timeout = timeout
        self.sequence = 0
        self.replies: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.requests: list[dict[str, Any]] = []
        self.events: list[Any] = []
        self.stdout = BoundedLog()
        self.stderr = BoundedLog()
        self.forced_termination = False
        self.shutdown_error: str | None = None
        directory.mkdir()
        (directory / "empty-engine").mkdir()
        self.environment = child_environment(directory)
        command = [str(executable), "--state-dir", str(directory / "state"),
                   "--engine-dir", str(directory / "empty-engine")]
        self.command = command
        try:
            self.child = subprocess.Popen(
                command, cwd=executable.parent, env=self.environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        except OSError as error:
            raise ProductFailure("launch_error", str(error)) from error
        self.readers = [threading.Thread(target=self.read_stdout, daemon=True),
                        threading.Thread(target=self.read_stderr, daemon=True)]
        for reader in self.readers:
            reader.start()

    def read_stdout(self) -> None:
        try:
            assert self.child.stdout is not None
            for line in self.child.stdout:
                self.stdout.append(line)
                try:
                    value = json.loads(line)
                except (ValueError, TypeError) as error:
                    self.replies.put(("protocol_error", str(error)))
                    continue
                if not isinstance(value, dict):
                    self.replies.put(("protocol_error", "Reply was not a JSON object"))
                elif "event" in value:
                    if len(self.events) < 100:
                        self.events.append(value["event"])
                else:
                    self.replies.put(("reply", value))
        except Exception as error:
            self.replies.put(("protocol_error", str(error)))
        finally:
            self.replies.put(("eof", None))

    def read_stderr(self) -> None:
        try:
            assert self.child.stderr is not None
            for line in self.child.stderr:
                self.stderr.append(line)
        except Exception as error:
            self.stderr.append("\n[probe reader error] " + str(error))

    def call(self, method: str, *values: Any, timeout: float | None = None) -> Any:
        self.sequence += 1
        ident = f"filesystem-{self.sequence}"
        request = {"id": ident, "method": method, "args": list(values)}
        record: dict[str, Any] = {"request": request, "startedUTC": utc_now()}
        self.requests.append(record)
        start = time.monotonic()
        try:
            if self.child.poll() is not None:
                raise ProductFailure("helper_exited", "Helper exited before the request")
            assert self.child.stdin is not None
            try:
                self.child.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
                self.child.stdin.flush()
            except (OSError, ValueError) as error:
                raise ProductFailure("pipe_error", str(error)) from error
            try:
                kind, reply = self.replies.get(timeout=self.timeout if timeout is None else timeout)
            except queue.Empty as error:
                raise ProductFailure("timeout", f"No reply to {method} within the timeout") from error
            if kind == "eof":
                raise ProductFailure("helper_exited", "Helper stdout ended before a reply")
            if kind != "reply":
                raise ProductFailure(kind, str(reply))
            record["response"] = reply
            if reply.get("id") != ident:
                raise ProductFailure("protocol_error", f"Expected reply {ident}, received {reply.get('id')!r}")
            if "error" in reply:
                raise ProductFailure("request_error", str(reply["error"]))
            if "result" not in reply:
                raise ProductFailure("protocol_error", "Reply has neither result nor error")
            return reply["result"]
        except ProductFailure as error:
            record["failure"] = {"kind": error.kind, "message": str(error)}
            raise
        finally:
            record["seconds"] = round(time.monotonic() - start, 4)

    def finish(self, force: bool = False) -> dict[str, Any]:
        if self.child.poll() is None and not force:
            try:
                self.call("_shutdown", timeout=min(5, self.timeout))
            except ProductFailure as error:
                self.shutdown_error = f"{error.kind}: {error}"
        if self.child.stdin is not None:
            try:
                self.child.stdin.close()
            except OSError:
                pass
        try:
            self.child.wait(timeout=1 if force else 5)
        except subprocess.TimeoutExpired:
            self.forced_termination = True
            self.child.kill()
            self.child.wait(timeout=5)
        for reader in self.readers:
            reader.join(timeout=2)
        exit_code = self.child.returncode
        return {"argv": self.command, "pid": self.child.pid,
                "exitCode": exit_code,
                "exitCodeHex": f"0x{exit_code & 0xffffffff:08X}" if exit_code is not None else None,
                "forcedTermination": self.forced_termination,
                "shutdownError": self.shutdown_error,
                "requests": self.requests, "events": self.events,
                "stdout": self.stdout.value(), "stderr": self.stderr.value(),
                "pathPolicy": "Windows system directories only; runtime is the working directory",
                "inheritedRcloneEnvironment": False}


def logical_drives() -> list[dict[str, Any]]:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetLogicalDrives.argtypes = []
    kernel.GetLogicalDrives.restype = wintypes.DWORD
    kernel.GetDriveTypeW.argtypes = [wintypes.LPCWSTR]
    kernel.GetDriveTypeW.restype = wintypes.UINT
    mask = kernel.GetLogicalDrives()
    if not mask:
        raise ctypes.WinError(ctypes.get_last_error())
    names = {0: "unknown", 1: "no_root", 2: "removable", 3: "fixed", 4: "network", 5: "cdrom", 6: "ramdisk"}
    values = []
    for index in range(26):
        if mask & (1 << index):
            root = f"{chr(ord('A') + index)}:\\"
            kind = int(kernel.GetDriveTypeW(root))
            values.append({"path": root, "type": kind, "kind": names.get(kind, "unknown")})
    return values


def create_sparse_file(path: Path, size: int) -> dict[str, Any]:
    import msvcrt

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.DeviceIoControl.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPVOID,
                                      wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                      ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
    kernel.DeviceIoControl.restype = wintypes.BOOL
    kernel.GetCompressedFileSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.GetCompressedFileSizeW.restype = wintypes.DWORD
    with path.open("xb") as target:
        returned = wintypes.DWORD()
        if not kernel.DeviceIoControl(msvcrt.get_osfhandle(target.fileno()), 0x000900C4,
                                      None, 0, None, 0, ctypes.byref(returned), None):
            raise ctypes.WinError(ctypes.get_last_error())
        target.truncate(size)
    attributes = path.stat()
    if attributes.st_size != size or not attributes.st_file_attributes & 0x200:
        raise RuntimeError("Sparse fixture was not created with the exact requested logical size")
    high = wintypes.DWORD()
    ctypes.set_last_error(0)
    low = kernel.GetCompressedFileSizeW(str(path), ctypes.byref(high))
    if low == 0xffffffff and ctypes.get_last_error():
        raise ctypes.WinError(ctypes.get_last_error())
    allocated = (int(high.value) << 32) | int(low)
    if allocated > 1024 * 1024:
        raise RuntimeError(f"Sparse fixture unexpectedly allocated {allocated} bytes")
    return {"path": str(path), "expectedSize": size, "pythonStatSize": attributes.st_size,
            "allocatedBytes": allocated, "sparseAttribute": True,
            "fixtureSizeSource": "Python stat and GetCompressedFileSizeW, independent of Swift Foundation"}


def create_broken_junction(parent: Path) -> tuple[Path, dict[str, Any]]:
    listing = parent / "junction-list"
    listing.mkdir()
    (listing / "neighbor.txt").write_bytes(b"keep this sibling\n")
    target = parent / "junction-target"
    target.mkdir()
    junction = listing / "broken-junction"
    command = [os.environ.get("COMSPEC", r"C:\Windows\System32\cmd.exe"), "/d", "/c",
               "mklink", "/J", str(junction), str(target)]
    completed = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=15)
    if completed.returncode != 0:
        raise RuntimeError(f"Could not create junction: {completed.returncode}: {completed.stdout} {completed.stderr}")
    attributes = junction.lstat()
    if attributes.st_reparse_tag != 0xA0000003:
        raise RuntimeError("The junction fixture is not an NTFS mount-point reparse point")
    target.rmdir()
    if target.exists() or not os.path.lexists(junction):
        raise RuntimeError("The broken junction fixture was not preserved after target removal")
    return junction, {"directory": str(listing), "junction": str(junction), "removedTarget": str(target),
                      "reparseTag": f"0x{attributes.st_reparse_tag:08X}", "targetExists": False,
                      "mklink": {"argv": command, "exitCode": completed.returncode,
                                 "stdout": completed.stdout, "stderr": completed.stderr}}


def inspect_listing(client: Client, path: Path | str, record: dict[str, Any],
                    expected: dict[str, dict[str, Any]] | None = None) -> None:
    record["path"] = str(path)
    record["expectedEntries"] = expected or {}
    value = client.call("list", endpoint(path))
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise ProductFailure("unexpected_response", "list did not return an array of objects")
    record["entryCount"] = len(value)
    by_name = {item.get("name"): item for item in value if isinstance(item.get("name"), str)}
    record["expectations"] = []
    mismatches = []
    for name, fields in (expected or {}).items():
        actual = by_name.get(name)
        match = actual is not None and all(actual.get(key) == wanted for key, wanted in fields.items())
        record["expectations"].append({"name": name, "expected": fields, "actual": actual, "matches": match})
        if not match:
            mismatches.append(name)
    record["helperResponsiveAfterOperation"] = isinstance(client.call("_state"), dict)
    if not record["helperResponsiveAfterOperation"]:
        raise ProductFailure("unexpected_response", "Helper returned an invalid state after list")
    if mismatches:
        raise ProductFailure("metadata_mismatch", "Missing entry or incorrect metadata: " + ", ".join(mismatches))


def inspect_bootstrap(client: Client, record: dict[str, Any], drives: list[dict[str, Any]],
                      rclone: Path | None = None, config: Path | None = None) -> None:
    if rclone is not None:
        environment = client.call("saveSettings", {"rclonePath": str(rclone), "rcloneDirectory": str(rclone.parent),
                                  "configPath": str(config), "autoCheckUpdates": False, "language": "en"})
        record["configuredEnvironment"] = environment
    boot = client.call("bootstrap")
    if not isinstance(boot, dict):
        raise ProductFailure("unexpected_response", "bootstrap did not return an object")
    record["home"] = boot.get("home")
    record["localLocations"] = boot.get("localLocations")
    record["environment"] = boot.get("environment")
    home = boot.get("home")
    locations = boot.get("localLocations")
    if not isinstance(home, str) or not os.path.isabs(home) or not isinstance(locations, list):
        raise ProductFailure("unexpected_response", "bootstrap home/localLocations are invalid")
    paths = {normalized_path(item["path"]) for item in locations
             if isinstance(item, dict) and isinstance(item.get("path"), str)}
    coverage = [{**drive, "presentInLocalLocations": normalized_path(drive["path"]) in paths}
                for drive in drives]
    record["driveCoverage"] = coverage
    record["requiredDrivePolicy"] = "All GetLogicalDrives entries reported as fixed drives"
    record["missingFixedDrives"] = [item["path"] for item in coverage
                                    if item["type"] == 3 and not item["presentInLocalLocations"]]
    record["helperResponsiveAfterOperation"] = isinstance(client.call("_state"), dict)
    errors = []
    if record["missingFixedDrives"]:
        errors.append("No localLocations entry for fixed drives: " + ", ".join(record["missingFixedDrives"]))
    environment = boot.get("environment")
    if not isinstance(environment, dict) or environment.get("platform") != "win32":
        errors.append("bootstrap environment.platform is not win32")
    if rclone is not None and (not isinstance(environment, dict) or environment.get("available") is not True):
        errors.append("Explicit rclone with an empty configuration is unavailable")
    if not record["helperResponsiveAfterOperation"]:
        errors.append("Helper returned an invalid state after bootstrap")
    if errors:
        raise ProductFailure("bootstrap_observation_failed", "; ".join(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, type=Path, help="Installed runtime/rbn-engine.exe")
    parser.add_argument("--rclone", required=True, type=Path, help="An independently verified rclone.exe")
    parser.add_argument("--output", required=True, type=Path, help="JSON diagnostic receipt")
    parser.add_argument("--timeout", type=float, default=30, help="Seconds per helper request (default: 30)")
    args = parser.parse_args()
    started = time.monotonic()
    report: dict[str, Any] = {"schemaVersion": SCHEMA_VERSION, "probe": "installed-windows-filesystem",
                              "diagnosticOnly": True, "productFailuresAllowed": True,
                              "startedUTC": utc_now(), "host": {"system": platform.system(),
                              "release": platform.release(), "machine": platform.machine(),
                              "python": sys.version, "pythonExecutable": sys.executable},
                              "cases": [], "infrastructureErrors": []}
    output = args.output.resolve()
    junctions: list[Path] = []
    try:
        if os.name != "nt":
            raise RuntimeError("This probe must run on Windows against the installed Windows helper")
        if not 1 <= args.timeout <= 300:
            raise ValueError("--timeout must be between 1 and 300 seconds")
        engine, rclone = args.engine.resolve(strict=True), args.rclone.resolve(strict=True)
        if not engine.is_file() or not rclone.is_file():
            raise ValueError("--engine and --rclone must identify files")
        report["engine"] = file_metadata(engine)
        report["rclone"] = file_metadata(rclone)
        report["requestTimeoutSeconds"] = args.timeout
        output.parent.mkdir(parents=True, exist_ok=True)
        # Prevent Windows Error Reporting dialogs from turning a crash into an
        # indefinite wait. Child processes inherit this error mode.
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.SetErrorMode.argtypes = [wintypes.UINT]
        kernel.SetErrorMode.restype = wintypes.UINT
        previous_error_mode = kernel.SetErrorMode(0x0001 | 0x0002 | 0x8000)
        report["logicalDrives"] = drives = logical_drives()
        with tempfile.TemporaryDirectory(prefix="filesystem-fixture-", dir=output.parent) as temporary:
            fixture = Path(temporary)
            config = fixture / "empty-rclone.conf"
            config.write_text("", encoding="utf-8")

            def run_case(name: str, action: Callable[[Client, dict[str, Any]], None],
                         details: dict[str, Any] | None = None) -> dict[str, Any]:
                record: dict[str, Any] = {"name": name, "status": "running", "startedUTC": utc_now(),
                                          "details": details or {}}
                report["cases"].append(record)
                client: Client | None = None
                case_start = time.monotonic()
                force = False
                try:
                    client = Client(engine, fixture / f"helper-{len(report['cases']):02d}", args.timeout)
                    action(client, record)
                    record["status"] = "passed"
                except ProductFailure as error:
                    record["status"] = "failed"
                    record["failure"] = {"kind": error.kind, "message": str(error)}
                    force = error.kind in {"timeout", "protocol_error", "pipe_error"}
                except Exception as error:
                    record["status"] = "infrastructure_error"
                    record["failure"] = {"kind": type(error).__name__, "message": str(error)}
                    report["infrastructureErrors"].append({"case": name, **record["failure"]})
                    force = True
                finally:
                    if client is not None:
                        try:
                            record["helper"] = client.finish(force=force)
                        except Exception as error:
                            record["helper"] = {"argv": client.command, "pid": client.child.pid,
                                                "exitCode": client.child.poll(),
                                                "requests": client.requests,
                                                "stdout": client.stdout.value(), "stderr": client.stderr.value(),
                                                "cleanupError": str(error)}
                            record["status"] = "infrastructure_error"
                            report["infrastructureErrors"].append({"case": name, "cleanupError": str(error)})
                        if record["status"] == "passed" and (record["helper"]["exitCode"] != 0 or
                                record["helper"]["forcedTermination"] or record["helper"]["shutdownError"]):
                            record["status"] = "failed"
                            record["failure"] = {"kind": "shutdown_failed", "message": "Helper did not shut down cleanly"}
                    else:
                        record["helper"] = {"exitCode": None, "pid": None, "requests": [],
                                            "launchError": record.get("failure")}
                    record["seconds"] = round(time.monotonic() - case_start, 4)
                    print(f"{record['status'].upper()}: {name}", flush=True)
                return record

            default = run_case("bootstrap-unconfigured", lambda client, record: inspect_bootstrap(client, record, drives),
                               {"configuration": "Empty app state and empty engine directory; no RCLONE_* environment"})
            run_case("bootstrap-configured", lambda client, record: inspect_bootstrap(client, record, drives, rclone, config),
                     {"configuration": "Explicit rclone path and disposable empty rclone configuration"})
            unicode_directory = fixture / "一般 Unicode 資料"
            unicode_directory.mkdir()
            (unicode_directory / "資料夾").mkdir()
            unicode_bytes = "Unicode 檔案\n".encode("utf-8")
            (unicode_directory / "測試.txt").write_bytes(unicode_bytes)
            run_case("list-unicode", lambda client, record: inspect_listing(client, unicode_directory, record,
                     {"資料夾": {"isDir": True, "size": -1}, "測試.txt": {"isDir": False, "size": len(unicode_bytes)}}))
            home = default.get("home") or str(Path.home())
            run_case("list-user-home", lambda client, record: inspect_listing(client, home, record),
                     {"homeSource": "bootstrap" if default.get("home") else "Python fallback after invalid bootstrap", "readOnly": True})
            system_drive = Path(os.environ.get("SystemDrive", Path(os.environ.get("SystemRoot", r"C:\Windows")).drive) + "\\")
            run_case("list-system-drive-root", lambda client, record: inspect_listing(client, system_drive, record), {"readOnly": True})
            try:
                junction, information = create_broken_junction(fixture)
                junctions.append(junction)
                run_case("list-broken-junction", lambda client, record: inspect_listing(client, junction.parent, record,
                         {"neighbor.txt": {"isDir": False, "size": len(b"keep this sibling\n")}}), information)
            except Exception as error:
                report["infrastructureErrors"].append({"fixture": "broken-junction", "kind": type(error).__name__, "message": str(error)})
            for size in SPARSE_SIZES:
                directory = fixture / f"sparse-{size}"
                directory.mkdir()
                try:
                    information = create_sparse_file(directory / "large.bin", size)
                    neighbor_bytes = b"ordinary neighboring file\n"
                    (directory / "neighbor.txt").write_bytes(neighbor_bytes)
                except Exception as error:
                    report["infrastructureErrors"].append({"fixture": f"sparse-{size}", "kind": type(error).__name__, "message": str(error)})
                    continue
                run_case(f"list-sparse-{size}", lambda client, record, path=directory, expected_size=size:
                         inspect_listing(client, path, record, {"large.bin": {"isDir": False, "size": expected_size},
                                         "neighbor.txt": {"isDir": False, "size": len(neighbor_bytes)}}), information)

                def inspect_size(client: Client, record: dict[str, Any], path: Path = directory,
                                 expected_size: int = size + len(neighbor_bytes)) -> None:
                    record["expected"] = {"count": 2, "bytes": expected_size}
                    value = client.call("size", endpoint(path))
                    record["actual"] = value
                    record["helperResponsiveAfterOperation"] = isinstance(client.call("_state"), dict)
                    if value != record["expected"] or not record["helperResponsiveAfterOperation"]:
                        raise ProductFailure("size_mismatch", "Folder size/count is incorrect or helper became unresponsive")

                run_case(f"size-sparse-{size}", inspect_size, information)
            for junction in junctions:
                if os.path.lexists(junction):
                    junction.rmdir()
            junctions.clear()
        kernel.SetErrorMode(previous_error_mode)
    except Exception as error:
        report["infrastructureErrors"].append({"kind": type(error).__name__, "message": str(error)})
    finally:
        # TemporaryDirectory also avoids following junctions on supported Python
        # versions. Explicit unlinking above makes the intended cleanup clear.
        report["completedUTC"] = utc_now()
        report["seconds"] = round(time.monotonic() - started, 4)
        report["summary"] = {"total": len(report["cases"]),
                             **{status: sum(case["status"] == status for case in report["cases"])
                                for status in ("passed", "failed", "infrastructure_error")},
                             "infrastructureErrors": len(report["infrastructureErrors"])}
        report["status"] = ("infrastructure_error" if report["infrastructureErrors"] else
                            "completed_with_product_failures" if report["summary"]["failed"] else "completed")
        try:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(json.dumps({"output": str(output), "status": report["status"], "summary": report["summary"]}), flush=True)
        except Exception as error:
            print(f"Could not write diagnostic output: {error}", file=sys.stderr)
            return 2
    return 1 if report["infrastructureErrors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
