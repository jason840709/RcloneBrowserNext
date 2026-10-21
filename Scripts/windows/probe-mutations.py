#!/usr/bin/env python3
"""Strict Windows helper regression for local mutations and junction boundaries.

Only disposable local fixtures are modified. The installed helper uses its real
newline JSON protocol and an isolated state directory for every case. Large files
are sparse; long fixtures use the Win32 extended prefix, while helper endpoints
use ordinary absolute paths. No cloud accounts or real user files are involved.

Exit 0 requires every case to pass. Product failures exit 1; incomplete execution
or fixture/infrastructure failures exit 2. This differs from the baseline probe.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable


_spec = importlib.util.spec_from_file_location("rbn_windows_filesystem_probe", Path(__file__).with_name("probe-filesystem.py"))
if _spec is None or _spec.loader is None:
    raise RuntimeError("Cannot load the shared installed-helper diagnostic client")
baseline = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(baseline)
Client, ProductFailure = baseline.Client, baseline.ProductFailure
GIB = 1024 ** 3


def extended(path: Path) -> Path:
    """Fixture access only. These namespace paths are never sent to the helper."""
    value = str(path)
    if value.startswith("\\\\?\\"):
        return path
    if value.startswith("\\\\"):
        return Path("\\\\?\\UNC\\" + value[2:])
    return Path("\\\\?\\" + value)


def endpoint(path: Path) -> dict[str, Any]:
    return {"remote": None, "path": path.as_posix()}


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def directory(path: Path) -> Path:
    extended(path).mkdir(parents=True)
    return path


def put(path: Path, content: bytes) -> None:
    extended(path).write_bytes(content)


def check(record: dict[str, Any], description: str, actual: Any, expected: Any) -> None:
    matches = actual == expected
    record.setdefault("checks", []).append({"description": description, "actual": actual,
                                            "expected": expected, "passed": matches})
    if not matches:
        raise ProductFailure("expectation_failed", f"{description}: expected {expected!r}, received {actual!r}")


def content(record: dict[str, Any], path: Path, expected: bytes) -> None:
    try:
        value = extended(path).read_bytes()
    except OSError as error:
        raise ProductFailure("file_changed", f"Cannot read the required fixture {path}: {error}") from error
    check(record, f"Content preserved: {path.name}", value.hex(), expected.hex())


def absent(record: dict[str, Any], path: Path) -> None:
    check(record, f"Entry removed: {path.name}", os.path.lexists(extended(path)), False)


def logical_size(record: dict[str, Any], path: Path, expected: int) -> None:
    try:
        value = extended(path).stat().st_size
    except OSError as error:
        raise ProductFailure("file_changed", f"Cannot stat required fixture {path}: {error}") from error
    check(record, f"Logical size preserved: {path.name}", value, expected)


def reject(client: Client, record: dict[str, Any], method: str, *arguments: Any) -> None:
    try:
        result = client.call(method, *arguments)
    except ProductFailure as error:
        if error.kind != "request_error":
            raise
        record.setdefault("expectedErrors", []).append({"method": method, "arguments": arguments,
                                                        "kind": error.kind, "message": str(error)})
        return
    raise ProductFailure("expected_rejection", f"{method} accepted an operation that must be rejected: {result!r}")


def mutate(client: Client, record: dict[str, Any], method: str, *arguments: Any) -> None:
    check(record, f"{method} success reply", client.call(method, *arguments), True if method == "remove" else None)


def listing(client: Client, record: dict[str, Any], path: Path, expected: dict[str, dict[str, Any]]) -> None:
    actual = client.call("list", endpoint(path))
    if not isinstance(actual, list) or any(not isinstance(item, dict) for item in actual):
        raise ProductFailure("unexpected_response", "list did not return an array of objects")
    entries = {item.get("name"): item for item in actual}
    for name, fields in expected.items():
        value = entries.get(name)
        if value is None:
            raise ProductFailure("listing_mismatch", f"Entry missing from list: {name}")
        for key, wanted in fields.items():
            check(record, f"list {name} {key}", value.get(key), wanted)


def junction(link: Path, target: Path, links: list[Path], record: dict[str, Any]) -> None:
    command = [os.environ.get("COMSPEC", r"C:\Windows\System32\cmd.exe"), "/d", "/c",
               "mklink", "/J", str(link), str(target)]
    result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=15)
    record.setdefault("junctionFixtures", []).append({"link": str(link), "target": str(target),
                                                      "exitCode": result.returncode,
                                                      "stdout": result.stdout, "stderr": result.stderr})
    if result.returncode:
        raise RuntimeError(f"Cannot create junction fixture: {result.stdout} {result.stderr}")
    links.append(link)
    if extended(link).lstat().st_reparse_tag != 0xA0000003:
        raise RuntimeError("Fixture is not an NTFS directory junction")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--rclone", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="JSON regression receipt")
    parser.add_argument("--timeout", type=float, default=30, help="Seconds per helper request")
    args = parser.parse_args()
    output = args.output.resolve()
    started = time.monotonic()
    report: dict[str, Any] = {"schemaVersion": 1, "probe": "windows-mutation-regression",
                              "diagnosticOnly": False, "productFailuresAllowed": False,
                              "startedUTC": baseline.utc_now(), "completed": False, "passed": False,
                              "host": {"system": platform.system(), "release": platform.release(),
                                       "machine": platform.machine(), "python": sys.version},
                              "cases": [], "infrastructureErrors": [],
                              "method": "Installed helper protocol; disposable local files and junctions; independent Python/Win32 filesystem assertions"}
    fixture: Path | None = None
    links: list[Path] = []
    kernel = None
    old_error_mode = None
    try:
        if os.name != "nt":
            raise RuntimeError("This strict regression must run on Windows")
        if not 1 <= args.timeout <= 300:
            raise ValueError("--timeout must be between 1 and 300 seconds")
        engine, rclone = args.engine.resolve(strict=True), args.rclone.resolve(strict=True)
        if not engine.is_file() or not rclone.is_file():
            raise ValueError("--engine and --rclone must identify executable files")
        report["engine"], report["rclone"] = baseline.file_metadata(engine), baseline.file_metadata(rclone)
        output.parent.mkdir(parents=True, exist_ok=True)
        # A short temp root also tests crossing MAX_PATH intentionally, rather
        # than depending on the checkout/output location to make it long.
        fixture = Path(tempfile.mkdtemp(prefix="rbn-mutations-", dir=os.environ.get("RUNNER_TEMP")))
        report["fixtureRoot"] = str(fixture)
        config = fixture / "empty-rclone.conf"
        config.write_text("", encoding="utf-8")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.SetErrorMode.argtypes = [wintypes.UINT]
        kernel.SetErrorMode.restype = wintypes.UINT
        old_error_mode = kernel.SetErrorMode(0x0001 | 0x0002 | 0x8000)

        def run_case(name: str, action: Callable[[Client, Path, dict[str, Any]], None]) -> None:
            number = len(report["cases"]) + 1
            root = directory(fixture / f"case-{number:02d}-{name}")
            record: dict[str, Any] = {"name": name, "status": "running", "startedUTC": baseline.utc_now(),
                                      "details": {"fixture": str(root)}}
            report["cases"].append(record)
            client = None
            force = False
            case_start = time.monotonic()
            try:
                client = Client(engine, fixture / f"helper-{number:02d}", args.timeout)
                record["configuration"] = client.call("saveSettings", {
                    "rclonePath": rclone.as_posix(), "rcloneDirectory": rclone.parent.as_posix(),
                    "configPath": config.as_posix(), "autoCheckUpdates": False, "language": "en"})
                action(client, root, record)
                check(record, "Helper responsive after operation", isinstance(client.call("_state"), dict), True)
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
                        if record["status"] == "passed" and (record["helper"]["exitCode"] != 0 or
                                record["helper"]["forcedTermination"] or record["helper"]["shutdownError"]):
                            record["status"] = "failed"
                            record["failure"] = {"kind": "shutdown_failed", "message": "Helper did not shut down cleanly"}
                    except Exception as error:
                        record["helper"] = {"pid": client.child.pid, "requests": client.requests,
                                            "stdout": client.stdout.value(), "stderr": client.stderr.value()}
                        record["status"] = "infrastructure_error"
                        report["infrastructureErrors"].append({"case": name, "cleanupError": str(error)})
                record["seconds"] = round(time.monotonic() - case_start, 4)
                write_json(output, report)
                print(f"{record['status'].upper()}: {name}", flush=True)

        def large_neighbor_rename(client, root, record):
            record["sparseFixture"] = baseline.create_sparse_file(extended(root / "large.bin"), 3 * GIB)
            put(root / "small.txt", b"ordinary neighbor\n")
            mutate(client, record, "rename", endpoint(root), "small.txt", "renamed 資料.txt", False)
            absent(record, root / "small.txt")
            content(record, root / "renamed 資料.txt", b"ordinary neighbor\n")
            logical_size(record, root / "large.bin", 3 * GIB)
            listing(client, record, root, {"large.bin": {"size": 3 * GIB, "isDir": False},
                                          "renamed 資料.txt": {"isDir": False}})

        def large_neighbor_remove(client, root, record):
            record["sparseFixture"] = baseline.create_sparse_file(extended(root / "large.bin"), 5 * GIB)
            put(root / "small.txt", b"ordinary neighbor\n")
            mutate(client, record, "remove", endpoint(root), [{"name": "small.txt", "isDir": False}])
            absent(record, root / "small.txt")
            logical_size(record, root / "large.bin", 5 * GIB)
            check(record, "Remaining folder size above 32-bit range", client.call("size", endpoint(root)),
                  {"count": 1, "bytes": 5 * GIB})

        def directory_rename(client, root, record):
            directory(root / "before" / "child")
            put(root / "before" / "child" / "marker.txt", b"directory payload\n")
            mutate(client, record, "rename", endpoint(root), "before", "after 資料夾", True)
            absent(record, root / "before")
            content(record, root / "after 資料夾" / "child" / "marker.txt", b"directory payload\n")

        def rename_collision(client, root, record):
            put(root / "source.txt", b"source\n")
            put(root / "target.txt", b"target must survive\n")
            for target in ["target.txt", "TARGET.TXT"]:
                reject(client, record, "rename", endpoint(root), "source.txt", target, False)
                content(record, root / "source.txt", b"source\n")
                content(record, root / "target.txt", b"target must survive\n")
            directory(root / "source-dir")
            directory(root / "target-dir")
            put(root / "source-dir" / "source-marker", b"source directory\n")
            put(root / "target-dir" / "target-marker", b"target directory\n")
            reject(client, record, "rename", endpoint(root), "source-dir", "target-dir", True)
            content(record, root / "source-dir" / "source-marker", b"source directory\n")
            content(record, root / "target-dir" / "target-marker", b"target directory\n")

        def rename_same(client, root, record):
            put(root / "same.txt", b"same file\n")
            directory(root / "same-dir")
            put(root / "same-dir" / "marker", b"same directory\n")
            mutate(client, record, "rename", endpoint(root), "same.txt", "same.txt", False)
            mutate(client, record, "rename", endpoint(root), "same-dir", "same-dir", True)
            content(record, root / "same.txt", b"same file\n")
            content(record, root / "same-dir" / "marker", b"same directory\n")

        def rename_type(client, root, record):
            put(root / "file.txt", b"file payload\n")
            directory(root / "folder")
            put(root / "folder" / "marker", b"folder payload\n")
            reject(client, record, "rename", endpoint(root), "file.txt", "file-renamed", True)
            reject(client, record, "rename", endpoint(root), "folder", "folder-renamed", False)
            # Even a same-name no-op must validate the source and declared type.
            reject(client, record, "rename", endpoint(root), "file.txt", "file.txt", True)
            reject(client, record, "rename", endpoint(root), "missing", "missing", False)
            content(record, root / "file.txt", b"file payload\n")
            content(record, root / "folder" / "marker", b"folder payload\n")
            absent(record, root / "file-renamed")
            absent(record, root / "folder-renamed")

        def rename_invalid(client, root, record):
            put(root / "keep.txt", b"invalid rename preserved\n")
            for name in ["../escape.txt", "nested\\escape.txt", "keep.txt:stream"]:
                reject(client, record, "rename", endpoint(root), "keep.txt", name, False)
                content(record, root / "keep.txt", b"invalid rename preserved\n")
            reject(client, record, "rename", endpoint(root), "missing.txt", "new.txt", False)
            absent(record, root / "new.txt")

        def mkdir_duplicate(client, root, record):
            mutate(client, record, "mkdir", endpoint(root), "新建資料夾")
            check(record, "New directory exists", extended(root / "新建資料夾").is_dir(), True)
            put(root / "新建資料夾" / "marker", b"existing directory\n")
            put(root / "occupied.txt", b"existing file\n")
            reject(client, record, "mkdir", endpoint(root), "新建資料夾")
            reject(client, record, "mkdir", endpoint(root), "occupied.txt")
            for invalid in ["..", "nested/child", "nested\\child", "directory:stream"]:
                reject(client, record, "mkdir", endpoint(root), invalid)
            content(record, root / "新建資料夾" / "marker", b"existing directory\n")
            content(record, root / "occupied.txt", b"existing file\n")

        def selection_missing(client, root, record):
            put(root / "first.txt", b"must not be partially deleted\n")
            reject(client, record, "remove", endpoint(root), [
                {"name": "first.txt", "isDir": False}, {"name": "missing.txt", "isDir": False}])
            content(record, root / "first.txt", b"must not be partially deleted\n")

        def selection_type(client, root, record):
            put(root / "first.txt", b"first retained\n")
            directory(root / "folder")
            put(root / "folder" / "marker", b"folder retained\n")
            reject(client, record, "remove", endpoint(root), [
                {"name": "first.txt", "isDir": False}, {"name": "folder", "isDir": False}])
            content(record, root / "first.txt", b"first retained\n")
            content(record, root / "folder" / "marker", b"folder retained\n")

        def selection_invalid(client, root, record):
            put(root / "first.txt", b"all names validated first\n")
            directory(root / "nested")
            put(root / "nested" / "target.txt", b"nested target retained\n")
            for invalid in ["nested/target.txt", "nested\\target.txt", "first.txt:stream"]:
                reject(client, record, "remove", endpoint(root), [
                    {"name": "first.txt", "isDir": False}, {"name": invalid, "isDir": False}])
                content(record, root / "first.txt", b"all names validated first\n")
                content(record, root / "nested" / "target.txt", b"nested target retained\n")
            reject(client, record, "remove", endpoint(root), [])
            reject(client, record, "remove", endpoint(root), [
                {"name": "first.txt", "isDir": False}, {"name": "first.txt", "isDir": False}])
            content(record, root / "first.txt", b"all names validated first\n")

        def remove_link(client, root, record, broken=False):
            target = directory(root / "target")
            parent = directory(root / "listing")
            put(parent / "neighbor", b"neighbor retained\n")
            link = parent / "junction"
            junction(link, target, links, record)
            if broken:
                extended(target).rmdir()
            else:
                put(target / "marker", b"junction target retained\n")
            listing(client, record, parent, {"junction": {"isDir": True, "isLink": True, "size": -1}})
            mutate(client, record, "remove", endpoint(parent), [{"name": "junction", "isDir": True}])
            absent(record, link)
            content(record, parent / "neighbor", b"neighbor retained\n")
            if broken:
                absent(record, target)
            else:
                content(record, target / "marker", b"junction target retained\n")

        def remove_nested(client, root, record):
            target = directory(root / "external-target")
            put(target / "marker", b"external target retained\n")
            victim = directory(root / "victim")
            nested = directory(victim / "nested")
            put(victim / "ordinary.txt", b"ordinary removal\n")
            put(nested / "child.txt", b"nested removal\n")
            junction(nested / "live", target, links, record)
            missing = directory(root / "removed-target")
            junction(nested / "broken", missing, links, record)
            extended(missing).rmdir()
            junction(nested / "cycle", victim, links, record)
            mutate(client, record, "remove", endpoint(root), [{"name": "victim", "isDir": True}])
            absent(record, victim)
            content(record, target / "marker", b"external target retained\n")
            absent(record, missing)

        def size_links(client, root, record):
            parent = directory(root / "listing")
            nested = directory(parent / "nested")
            put(parent / "ordinary", b"1234567")
            put(nested / "child", b"12345678901")
            target = directory(root / "external-target")
            put(target / "marker", b"must not be counted or modified")
            junction(parent / "live", target, links, record)
            missing = directory(root / "removed-target")
            junction(parent / "broken", missing, links, record)
            extended(missing).rmdir()
            junction(parent / "self-cycle", parent, links, record)
            junction(nested / "ancestor-cycle", parent, links, record)
            check(record, "Size excludes live/broken/cyclic junctions", client.call("size", endpoint(parent)),
                  {"count": 2, "bytes": 18})
            content(record, target / "marker", b"must not be counted or modified")

        def long_unicode(client, root, record):
            parent = root
            index = 0
            while len(str(parent)) < 380:
                index += 1
                parent = parent / (f"level-{index:02d}-資料夾-" + "長路徑" * 8)
            directory(parent)
            if len(str(parent)) <= 260 or str(parent).startswith("\\\\?\\"):
                raise RuntimeError("Long-path fixture must exceed MAX_PATH without exposing a namespace endpoint")
            record["details"].update({"normalEndpoint": endpoint(parent), "normalPathCharacters": len(str(parent)),
                                       "fixtureAccess": "Windows extended path prefix"})
            payload = "Unicode 檔案資料\n".encode("utf-8")
            put(parent / "original 資料.txt", payload)
            record["sparseFixture"] = baseline.create_sparse_file(extended(parent / "large.bin"), 4 * GIB + 1)
            listing(client, record, parent, {"original 資料.txt": {"isDir": False, "size": len(payload)},
                                            "large.bin": {"isDir": False, "size": 4 * GIB + 1}})
            check(record, "Long-path exact 64-bit total", client.call("size", endpoint(parent)),
                  {"count": 2, "bytes": 4 * GIB + 1 + len(payload)})
            mutate(client, record, "mkdir", endpoint(parent), "新建資料夾")
            check(record, "Long-path child created", extended(parent / "新建資料夾").is_dir(), True)
            mutate(client, record, "rename", endpoint(parent), "original 資料.txt", "renamed 資料.txt", False)
            absent(record, parent / "original 資料.txt")
            content(record, parent / "renamed 資料.txt", payload)
            mutate(client, record, "remove", endpoint(parent), [
                {"name": "renamed 資料.txt", "isDir": False}, {"name": "新建資料夾", "isDir": True}])
            absent(record, parent / "renamed 資料.txt")
            absent(record, parent / "新建資料夾")
            logical_size(record, parent / "large.bin", 4 * GIB + 1)

        cases = [
            ("rename-small-beside-3gib", large_neighbor_rename),
            ("remove-small-beside-5gib", large_neighbor_remove),
            ("rename-directory-with-content", directory_rename),
            ("rename-no-overwrite", rename_collision),
            ("rename-same-name", rename_same),
            ("rename-source-type-validation", rename_type),
            ("rename-invalid-name", rename_invalid),
            ("mkdir-and-duplicate", mkdir_duplicate),
            ("remove-preflight-missing", selection_missing),
            ("remove-preflight-type", selection_type),
            ("remove-preflight-invalid-selection", selection_invalid),
            ("remove-live-junction", remove_link),
            ("remove-broken-junction", lambda client, root, record: remove_link(client, root, record, True)),
            ("remove-directory-with-nested-junctions", remove_nested),
            ("size-skips-junctions-and-cycles", size_links),
            ("long-unicode-local-operations", long_unicode),
        ]
        report["requiredCases"] = [name for name, _ in cases]
        for name, action in cases:
            run_case(name, action)
        report["completed"] = True
    except Exception as error:
        report["infrastructureErrors"].append({"kind": type(error).__name__, "message": str(error)})
    finally:
        # Unlink only junction entries we created, before recursive fixture
        # cleanup. Never traverse a junction during cleanup, including cycles.
        for link in reversed(links):
            try:
                if os.path.lexists(extended(link)):
                    extended(link).rmdir()
            except OSError as error:
                report["infrastructureErrors"].append({"junctionCleanup": str(link), "message": str(error)})
        if fixture is not None:
            try:
                shutil.rmtree(extended(fixture))
                report["fixtureRemoved"] = True
            except OSError as error:
                report["fixtureRemoved"] = False
                report["infrastructureErrors"].append({"fixtureCleanup": str(error)})
        if kernel is not None and old_error_mode is not None:
            kernel.SetErrorMode(old_error_mode)
        report["completedUTC"] = baseline.utc_now()
        report["seconds"] = round(time.monotonic() - started, 4)
        report["summary"] = {"total": len(report["cases"]),
                             **{status: sum(case["status"] == status for case in report["cases"])
                                for status in ("passed", "failed", "infrastructure_error")},
                             "infrastructureErrors": len(report["infrastructureErrors"])}
        report["passed"] = (report["completed"] and bool(report["cases"]) and
                            report["summary"]["passed"] == len(report["requiredCases"]) and
                            not report["infrastructureErrors"])
        report["status"] = "passed" if report["passed"] else "infrastructure_error" if report["infrastructureErrors"] else "failed"
        try:
            write_json(output, report)
            print(json.dumps({"output": str(output), "status": report["status"], "summary": report["summary"]}), flush=True)
        except Exception as error:
            print(f"Cannot save mutation regression evidence: {error}", file=sys.stderr)
            return 2
    return 2 if report["infrastructureErrors"] or not report["completed"] else 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
