#!/usr/bin/env python3
"""Read-only process and Restart Manager evidence for owned CI installations."""
import ctypes
from datetime import datetime, timedelta, timezone
import hashlib
import math
import os
from pathlib import Path, PureWindowsPath
import subprocess
import time


def stamp():
    return {"utc": datetime.now(timezone.utc).isoformat(), "monotonicSeconds": time.monotonic()}


def filetime_utc(ticks):
    return (datetime(1601, 1, 1, tzinfo=timezone.utc) + timedelta(microseconds=int(ticks) // 10)).isoformat()


def failure(error):
    return {"type": type(error).__name__, "message": str(error),
            "winError": getattr(error, "winerror", None)}


def source_identity():
    raw = Path(__file__).read_bytes()
    return {"file": "Scripts/windows/installation-diagnostics.py",
            "rawSHA256": hashlib.sha256(raw).hexdigest(),
            "canonicalLFSHA256": hashlib.sha256(raw.replace(b"\r\n", b"\n")).hexdigest(),
            "sourceCommit": os.environ.get("GITHUB_SHA"), "runID": os.environ.get("GITHUB_RUN_ID")}


def validate_source(value, source_commit, run_id):
    expected = source_identity()
    assert all(value.get(key) == expected[key] for key in ("file", "rawSHA256", "canonicalLFSHA256")), \
        "Installation diagnostic source SHA differs from this checkout"
    assert value.get("sourceCommit") == source_commit and value.get("runID") == run_id, \
        "Installation diagnostic source/run identity differs"


def validate_stamps(value, fields):
    previous = None
    for field in fields:
        item = value.get(field, {})
        assert isinstance(item.get("utc"), str) and datetime.fromisoformat(item["utc"]).tzinfo is not None, \
            "Missing diagnostic UTC timestamp"
        current = item.get("monotonicSeconds")
        assert type(current) in (int, float) and math.isfinite(current), "Missing diagnostic monotonic timestamp"
        assert previous is None or current >= previous, "Diagnostic timestamps are out of order"
        previous = current


def validate_rm(value):
    assert value.get("complete") is True and value.get("errors") == [], "Incomplete Restart Manager inventory"
    validate_stamps(value, ("started", "finished"))
    if value.get("applicable") is False:
        assert value.get("owners") is None and value.get("calls") == [] and value.get("reason"), \
            "A skipped inventory must not claim an empty owner list"
        return
    assert value.get("applicable") is True and isinstance(value.get("owners"), list), "Missing RM owner list"
    calls = value.get("calls", [])
    assert calls and calls[0] == {"api": "RmStartSession", "winError": 0} \
        and calls[-1] == {"api": "RmEndSession", "winError": 0}, "RM session lifecycle is incomplete"
    assert calls[1] == {"api": "RmRegisterResources", "winError": 0, "fileCount": 1}, "RM registered unexpected resources"
    reads = calls[2:-1]
    assert reads and all(c.get("api") == "RmGetList" and c.get("winError") in (0, 234) for c in reads) \
        and reads[-1]["winError"] == 0, "RM owner query failed or never completed"
    for owner in value["owners"]:
        assert type(owner.get("pid")) is int and owner["pid"] > 0 \
            and isinstance(owner.get("creationTime100ns"), str) and owner["creationTime100ns"].isdigit() \
            and isinstance(owner.get("creationTimeUTC"), str) and isinstance(owner.get("applicationName"), str) \
            and isinstance(owner.get("service"), str) and isinstance(owner.get("imagePath"), str) \
            and owner["imagePath"] and "inspectionError" not in owner, "RM owner identity is incomplete"


def validate_installer(value, source_commit, run_id, executable):
    validate_source(value.get("source", {}), source_commit, run_id)
    assert value.get("installerExitCode") == 0 and "error" not in value and "afterFailure" not in value, \
        "Installer diagnostic records a failure"
    validate_stamps(value, ("started", "installerStarted", "installerFinished", "finished"))
    queries = value.get("tasklistQueries", [])
    assert queries and all(q.get("complete") is True and q.get("returnCode") == 0
                           and isinstance(q.get("stdout"), str) and isinstance(q.get("stderr"), str)
                           and isinstance(q.get("matchingProcesses"), list) for q in queries), \
        "App preflight process queries are incomplete or failed"
    assert queries[-1]["matchingProcesses"] == [], "App process preflight did not reach an empty result"
    for query in queries:
        validate_source(query.get("source", {}), source_commit, run_id)
        validate_stamps(query, ("started", "finished"))
    before = value.get("before", {})
    validate_source(before.get("source", {}), source_commit, run_id)
    validate_rm(before)
    assert PureWindowsPath(before.get("resource", "")) == PureWindowsPath(executable), \
        "RM inventory targeted another executable"


def validate_helper(value, source_commit, run_id, executable):
    validate_source(value.get("diagnosticsSource", {}), source_commit, run_id)
    process = value.get("process", {})
    validate_source(process.get("source", {}), source_commit, run_id)
    assert type(value.get("pid")) is int and value["pid"] > 0 and process.get("pid") == value["pid"] \
        and process.get("complete") is True and process.get("creationTime100ns", "").isdigit() \
        and isinstance(process.get("creationTimeUTC"), str), "Owned helper identity is incomplete"
    assert PureWindowsPath(process.get("imagePath", "")) == PureWindowsPath(executable), \
        "Owned helper PID refers to another image"
    assert value.get("exitCode") == 0 and value.get("shutdownError") is None, "Owned helper did not exit cleanly"
    lifecycle = value.get("lifecycle", {})
    validate_stamps(lifecycle, ("spawnStarted", "spawnReturned", "shutdownRequested", "shutdownReplied",
                                "waitStarted", "waitFinished", "finished"))
    assert lifecycle.get("exitCode") == 0 and "fallbackKillRequested" not in lifecycle, \
        "Helper shutdown required a fallback termination"


def validate_ui_cleanup(value, source_commit, run_id, pid):
    validate_source(value.get("source", {}), source_commit, run_id)
    assert type(pid) is int and pid > 0 and value.get("pid") == pid \
        and value.get("complete") is True and value.get("errors") == [], "Owned UI cleanup failed or is incomplete"
    validate_stamps(value, ("started", "finished"))
    assert type(value.get("exitCode")) is int, "Owned UI final exit code is missing"
    if value.get("exitBeforeCleanup") is None:
        assert value.get("taskkill", {}).get("returnCode") == 0 and value.get("outcome") == "taskkill-succeeded", \
            "Owned UI taskkill did not succeed"
        validate_stamps(value, ("taskkillStarted", "taskkillFinished", "waitStarted", "waitFinished"))
    else:
        assert "taskkill" not in value and value.get("outcome") == "already-exited-before-cleanup" \
            and value["exitBeforeCleanup"] == value["exitCode"], "Already-exited UI cleanup was misreported"


class WindowsReadOnlyAPI:
    def __init__(self):
        if os.name != "nt" or os.environ.get("GITHUB_ACTIONS", "").lower() != "true":
            raise RuntimeError("Native installation diagnostics require a disposable Windows Actions runner")
        from ctypes import wintypes
        self.w = wintypes

        class FILETIME(ctypes.Structure):
            _fields_ = [("low", ctypes.c_uint32), ("high", ctypes.c_uint32)]

        class UNIQUE_PROCESS(ctypes.Structure):
            _fields_ = [("pid", ctypes.c_uint32), ("created", FILETIME)]

        class PROCESS_INFO(ctypes.Structure):
            _fields_ = [("process", UNIQUE_PROCESS), ("name", ctypes.c_wchar * 256),
                        ("service", ctypes.c_wchar * 64), ("applicationType", ctypes.c_int32),
                        ("status", ctypes.c_uint32), ("sessionID", ctypes.c_uint32),
                        ("restartable", ctypes.c_int32)]

        self.FILETIME, self.PROCESS_INFO = FILETIME, PROCESS_INFO
        if ctypes.sizeof(FILETIME) != 8 or ctypes.sizeof(PROCESS_INFO) != 668:
            raise RuntimeError("Unexpected Windows Restart Manager structure layout")
        self.rm = ctypes.WinDLL("rstrtmgr", use_last_error=True)
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.rm.RmStartSession.argtypes = [ctypes.POINTER(wintypes.DWORD), wintypes.DWORD, wintypes.LPWSTR]
        self.rm.RmRegisterResources.argtypes = [wintypes.DWORD, wintypes.UINT, ctypes.POINTER(wintypes.LPCWSTR),
                                              wintypes.UINT, ctypes.c_void_p, wintypes.UINT, ctypes.c_void_p]
        self.rm.RmGetList.argtypes = [wintypes.DWORD, ctypes.POINTER(wintypes.UINT), ctypes.POINTER(wintypes.UINT),
                                    ctypes.POINTER(PROCESS_INFO), ctypes.POINTER(wintypes.DWORD)]
        self.rm.RmEndSession.argtypes = [wintypes.DWORD]
        for name in ("RmStartSession", "RmRegisterResources", "RmGetList", "RmEndSession"):
            getattr(self.rm, name).restype = wintypes.DWORD
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(FILETIME)] * 4
        self.kernel.GetProcessTimes.restype = wintypes.BOOL
        self.kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                          ctypes.POINTER(wintypes.DWORD)]
        self.kernel.QueryFullProcessImageNameW.restype = wintypes.BOOL
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL

    @staticmethod
    def ticks(value):
        return (value.high << 32) | value.low

    def start_session(self):
        handle, key = self.w.DWORD(), ctypes.create_unicode_buffer(33)
        code = self.rm.RmStartSession(ctypes.byref(handle), 0, key)
        return int(code), int(handle.value)

    def register_file(self, handle, path):
        files = (self.w.LPCWSTR * 1)(path)
        return int(self.rm.RmRegisterResources(handle, 1, files, 0, None, 0, None))

    def get_list(self, handle, capacity):
        needed, count, reboot = self.w.UINT(), self.w.UINT(capacity), self.w.DWORD()
        buffer = (self.PROCESS_INFO * capacity)() if capacity else None
        code = int(self.rm.RmGetList(handle, ctypes.byref(needed), ctypes.byref(count), buffer, ctypes.byref(reboot)))
        owners = []
        if code == 0 and buffer is not None:
            if count.value > capacity:
                raise RuntimeError("Restart Manager returned more records than its buffer capacity")
            for row in buffer[:count.value]:
                ticks = self.ticks(row.process.created)
                owners.append({"pid": int(row.process.pid), "creationTime100ns": str(ticks),
                               "creationTimeUTC": filetime_utc(ticks), "applicationName": row.name,
                               "service": row.service, "applicationType": int(row.applicationType),
                               "applicationStatus": int(row.status), "sessionID": int(row.sessionID),
                               "restartable": bool(row.restartable)})
        return code, int(needed.value), owners, int(reboot.value)

    def end_session(self, handle):
        return int(self.rm.RmEndSession(handle))

    def process_info(self, pid):
        # Query limited metadata only; no process termination, VM read or command line.
        handle = self.kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            values = [self.FILETIME() for _ in range(4)]
            if not self.kernel.GetProcessTimes(handle, *(ctypes.byref(value) for value in values)):
                raise ctypes.WinError(ctypes.get_last_error())
            ticks = self.ticks(values[0])
            path, length = ctypes.create_unicode_buffer(32768), self.w.DWORD(32768)
            if not self.kernel.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(length)):
                raise ctypes.WinError(ctypes.get_last_error())
            return {"pid": pid, "creationTime100ns": str(ticks), "creationTimeUTC": filetime_utc(ticks),
                    "imagePath": path.value}
        finally:
            if not self.kernel.CloseHandle(handle):
                raise ctypes.WinError(ctypes.get_last_error())


def process_snapshot(pid, *, api=None):
    result = {"pid": pid, "started": stamp(), "complete": False, "source": source_identity()}
    try:
        result.update((api or WindowsReadOnlyAPI()).process_info(pid))
        result["complete"] = True
    except Exception as error:
        result["error"] = failure(error)
    result["finished"] = stamp()
    return result


def restart_manager_snapshot(executable, owned_root, *, api=None):
    result = {"started": stamp(), "complete": False, "applicable": True,
              "owners": None, "calls": [], "errors": [], "resource": str(executable), "source": source_identity()}
    handle = None
    try:
        executable, owned_root = Path(executable), Path(owned_root)
        if not executable.is_absolute() or not owned_root.is_absolute():
            raise RuntimeError("Restart Manager resource and owned root must be absolute paths")
        executable, owned_root = executable.resolve(), owned_root.resolve()
        if not executable.is_absolute() or not executable.is_relative_to(owned_root) or executable == owned_root:
            raise RuntimeError("Restart Manager resource must be the owned installation's main executable")
        result["resource"] = str(executable)
        if executable.name.casefold() not in {"rclone-browser-next.exe", "rclone browser next.exe"}:
            raise RuntimeError("Restart Manager resource is not the owned main executable")
        if not executable.exists():
            result.update(complete=True, applicable=False, reason="No installed main executable exists at this stage")
            return result
        if not executable.is_file():
            raise RuntimeError("Restart Manager resource is not the owned main executable")
        api = api or WindowsReadOnlyAPI()
        code, candidate = api.start_session()
        result["calls"].append({"api": "RmStartSession", "winError": code})
        if code:
            raise RuntimeError(f"RmStartSession failed with Win32 error {code}")
        handle = candidate
        code = api.register_file(handle, str(executable))
        result["calls"].append({"api": "RmRegisterResources", "winError": code, "fileCount": 1})
        if code:
            raise RuntimeError(f"RmRegisterResources failed with Win32 error {code}")
        capacity = 0
        for _ in range(5):
            code, needed, owners, reboot = api.get_list(handle, capacity)
            result["calls"].append({"api": "RmGetList", "winError": code, "capacity": capacity,
                                    "needed": needed, "rebootReasons": reboot})
            if code == 234:
                if not 0 < needed <= 4096:
                    raise RuntimeError("Restart Manager returned an invalid owner buffer size")
                capacity = needed
                continue
            if code:
                raise RuntimeError(f"RmGetList failed with Win32 error {code}")
            result["owners"] = owners
            for owner in owners:
                try:
                    observed = api.process_info(owner["pid"])
                    if observed["creationTime100ns"] != owner["creationTime100ns"]:
                        raise RuntimeError("Owner PID was reused after the Restart Manager snapshot")
                    owner["imagePath"] = observed["imagePath"]
                except Exception as error:
                    owner["inspectionError"] = failure(error)
                    result["errors"].append({"ownerPID": owner["pid"], **failure(error)})
            result["complete"] = not result["errors"]
            break
        else:
            raise RuntimeError("Restart Manager owner list kept changing beyond the bounded diagnostic reads")
    except Exception as error:
        result["errors"].append(failure(error))
    finally:
        if handle is not None:
            try:
                code = api.end_session(handle)
                result["calls"].append({"api": "RmEndSession", "winError": code})
                if code:
                    result["errors"].append({"type": "Win32Error", "message": "RmEndSession failed", "winError": code})
            except Exception as error:
                result["errors"].append(failure(error))
        if result["errors"]:
            result["complete"] = False
        result["finished"] = stamp()
    return result


def tasklist_snapshot(names, environment, *, runner=None):
    result = {"started": stamp(), "complete": False, "matchingProcesses": None, "source": source_identity()}
    try:
        query = (runner or subprocess.run)(["tasklist", "/FO", "CSV", "/NH"], capture_output=True,
                                           text=True, encoding="utf-8", errors="replace", env=environment, timeout=30)
        result.update(returnCode=query.returncode, stdout=query.stdout, stderr=query.stderr)
        if query.returncode:
            raise RuntimeError(f"tasklist query failed with exit code {query.returncode}")
        found = []
        for line in query.stdout.splitlines():
            fields = [field.strip('"') for field in line.split('\",\"')]
            if fields and fields[0].casefold() in names:
                found.append({"image": fields[0], "pid": fields[1] if len(fields) > 1 else ""})
        result.update(complete=True, matchingProcesses=found)
    except Exception as error:
        result["error"] = failure(error)
    result["finished"] = stamp()
    return result


def terminate_owned_ui_process(process, *, runner=None):
    """Record the existing UI fixture's taskkill /T /F and wait policy."""
    result = {"pid": process.pid, "started": stamp(), "exitBeforeCleanup": process.poll(),
              "complete": False, "errors": [], "source": source_identity(), "outcome": "already-exited-before-cleanup"}
    if result["exitBeforeCleanup"] is None:
        try:
            result["taskkillStarted"] = stamp()
            killed = (runner or subprocess.run)(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                                                capture_output=True, text=True, encoding="utf-8",
                                                errors="replace", timeout=30)
            result["taskkillFinished"] = stamp()
            result["taskkill"] = {"returnCode": killed.returncode, "stdout": killed.stdout, "stderr": killed.stderr}
            result["exitAfterTaskkillCommand"] = process.poll()
            result["outcome"] = "taskkill-succeeded"
            if killed.returncode:
                result["outcome"] = ("taskkill-failed-process-exited" if result["exitAfterTaskkillCommand"] is not None
                                     else "taskkill-failed-process-running")
                result["errors"].append({"type": "CommandError", "message": "Owned UI taskkill failed",
                                         "returnCode": killed.returncode})
            result["waitStarted"] = stamp()
            try:
                process.wait(timeout=10)
            finally:
                result["waitFinished"] = stamp()
        except Exception as error:
            result["outcome"] = "cleanup-command-or-wait-exception"
            if "taskkill" not in result:
                def captured(value):
                    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
                result["taskkill"] = {"returnCode": None, "stdout": captured(getattr(error, "stdout", None)),
                                     "stderr": captured(getattr(error, "stderr", None)),
                                     "timedOut": isinstance(error, subprocess.TimeoutExpired)}
            result["errors"].append(failure(error))
    result.update(exitCode=process.poll(), finished=stamp(), complete=not result["errors"])
    return result
