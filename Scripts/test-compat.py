#!/usr/bin/env python3
"""Exercise the installed compatibility helper with disposable local files.

Uses the same framed pipe protocol as the native window. No configured user
remote, credential or application setting is read or modified.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import queue
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--engine", type=Path, required=True)
parser.add_argument("--rclone", type=Path, required=True)
parser.add_argument("--output", type=Path)
parser.add_argument("--clean-runtime", action="store_true", help="Remove development runtime paths from the child environment")
args = parser.parse_args()
engine_path = args.engine.resolve()
rclone_path = args.rclone.resolve()
cache = ROOT / ".build-cache/compat/smoke"
cache.mkdir(parents=True, exist_ok=True)
records = []
events = []


class Client:
    def __init__(self, directory):
        env = dict(os.environ)
        for key in list(env):
            if key.upper().startswith("RCLONE_"):
                del env[key]
        env.update(TMPDIR=str(directory / "tmp"), TMP=str(directory / "tmp"), TEMP=str(directory / "tmp"))
        if args.clean_runtime:
            env.pop("LD_LIBRARY_PATH", None)
            if os.name == "nt":
                system = Path(env.get("SystemRoot", r"C:\Windows"))
                env["PATH"] = os.pathsep.join(map(str, [system / "System32", system, system / "System32/WindowsPowerShell/v1.0"]))
                env.pop("Path", None)
        self.child = subprocess.Popen([str(engine_path), "--state-dir", str(directory / "state"), "--engine-dir", str(directory / "rclone")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, encoding="utf-8", bufsize=1)
        self.sequence = 0
        self.replies = queue.Queue()
        self.stderr = []
        def read():
            try:
                for line in self.child.stdout:
                    value = json.loads(line)
                    if "event" in value:
                        events.append(value["event"])
                    else:
                        self.replies.put(value)
            except Exception as error:
                self.replies.put({"error": str(error)})
            finally:
                self.replies.put({"error": "Helper output ended"})
        def read_error():
            for line in self.child.stderr:
                if len(self.stderr) < 20:
                    self.stderr.append(line.rstrip())
        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=read_error, daemon=True).start()

    def call(self, method, *values):
        self.sequence += 1
        ident = f"smoke-{self.sequence}"
        packet = {"id": ident, "method": method, "args": list(values)}
        self.child.stdin.write(json.dumps(packet, ensure_ascii=False) + "\n")
        self.child.stdin.flush()
        result = self.replies.get(timeout=90)
        if result.get("error"):
            raise RuntimeError(result["error"] + ("\n" + "\n".join(self.stderr) if self.stderr else ""))
        assert result["id"] == ident, result
        return result.get("result")

    def job(self, ident):
        return next(j for j in self.call("listJobs") if j["id"] == ident)

    def wait(self, ident, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            job = self.job(ident)
            if job["status"] in {"completed", "failed", "cancelled", "interrupted"}:
                return job
            time.sleep(0.1)
        raise TimeoutError("Transfer did not finish")

    def close(self):
        try:
            self.call("_shutdown")
        finally:
            self.child.stdin.close()
            self.child.wait(timeout=20)
            assert self.child.returncode == 0, self.stderr


def check(name, callback):
    start = time.monotonic()
    callback()
    records.append({"name": name, "status": "passed", "seconds": round(time.monotonic() - start, 3)})
    print("PASS", name, flush=True)


def endpoint(path):
    return {"remote": None, "path": str(path)}


with tempfile.TemporaryDirectory(prefix="fixture-", dir=cache) as value:
    fixture = Path(value)
    (fixture / "tmp").mkdir()
    config = fixture / "empty-rclone.conf"
    config.write_text("")
    source, target = fixture / "source 資料", fixture / "destination 資料"
    source.mkdir(); target.mkdir(); (source / "資料夾").mkdir()
    (source / "資料夾/測試.txt").write_text("A Unicode file path\n", encoding="utf-8")
    (source / "plain.txt").write_bytes(b"copy fixture\n")
    (target / "destination-only.txt").write_bytes(b"preserve during copy; delete during sync\n")
    client = Client(fixture)
    try:
        def bootstrap():
            environment = client.call("saveSettings", {"rclonePath": str(rclone_path), "rcloneDirectory": str(rclone_path.parent), "configPath": str(config), "autoCheckUpdates": False, "language": "en"})
            assert environment["available"] is True, environment
            boot = client.call("bootstrap")
            assert boot["environment"]["platform"] == ("win32" if os.name == "nt" else "linux"), boot["environment"]
            assert boot["resolvedLanguage"] == "en"
            assert any(x["name"] == "資料夾" for x in client.call("list", endpoint(source)))
        check("bootstrap, engine discovery and Unicode listing", bootstrap)
        if os.name == "nt":
            def account_launcher():
                launcher = engine_path.parent / "rbn-process-launcher.exe"
                completed = subprocess.run([str(launcher), "--interactive", str(rclone_path),
                                            "--config", str(config), "version"],
                                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NEW_CONSOLE,
                                           timeout=30)
                assert completed.returncode == 0, completed.returncode
            check("Windows account setup launcher", account_launcher)
        def account_preferences():
            context = client.call("_beginConfiguration")
            assert Path(context["binary"]).resolve() == rclone_path
            try:
                client.call("saveSettings", {"language": "ja", "interfaceScale": 125})
                state = client.call("_preferences")
                assert state["resolvedLanguage"] == "ja" and state["settings"]["interfaceScale"] == 125
                try:
                    client.call("saveSettings", {"rcloneDirectory": str(fixture / "different-engine")})
                except RuntimeError as error:
                    assert "アカウント設定" in str(error), str(error)
                else:
                    raise AssertionError("Engine settings changed while the account terminal was reserved")
            finally:
                client.call("_endConfiguration")
                client.call("saveSettings", {"language": "en", "interfaceScale": 100})
        check("account setup preserves its engine while appearance applies immediately", account_preferences)
        request = {"source": endpoint(source), "destination": endpoint(target), "mode": "sync", "selection": [], "dryRun": True,
                   "options": {"comparison": "default", "localHashPolicy": "none", "transfers": 1, "checkers": 10, "maxDelete": -1, "deleteMode": "during"}}
        def dry_run():
            job = client.wait(client.call("startTransfer", request)["id"])
            assert job["status"] == "completed", job
            assert not (target / "plain.txt").exists()
            assert (target / "destination-only.txt").exists()
            report = client.call("getJobReport", job["id"], {"category": "all", "cursor": 0, "limit": 100})
            assert report["available"] and report["items"], report
        check("dry run reports planned work without changing files", dry_run)
        request["dryRun"] = False; request["mode"] = "copy"
        completed = {}
        def copy():
            job = client.wait(client.call("startTransfer", request)["id"])
            assert job["status"] == "completed", job
            assert (source / "plain.txt").read_bytes() == (target / "plain.txt").read_bytes()
            assert (source / "資料夾/測試.txt").read_bytes() == (target / "資料夾/測試.txt").read_bytes()
            assert (target / "destination-only.txt").exists()
            completed.update(job)
        check("copy preserves destination-only files", copy)
        request["mode"] = "sync"
        def repeat_sync():
            job = client.wait(client.call("startTransfer", request)["id"])
            assert job["status"] == "completed", job
            assert job["stats"]["bytes"] == 0 and job["stats"]["transfers"] == 0, job["stats"]
            assert not (target / "destination-only.txt").exists()
            repeated = client.wait(client.call("startTransfer", request)["id"])
            assert repeated["status"] == "completed" and repeated["stats"]["bytes"] == 0, repeated
        check("repeat sync skips unchanged files and removes destination extras", repeat_sync)
        def reports_and_tasks():
            exported = fixture / "完整紀錄.jsonl"
            client.call("_exportTo", "report", completed["id"], str(exported), "jsonl")
            lines = [json.loads(line) for line in exported.read_text(encoding="utf-8").splitlines()]
            assert any(v.get("status") == "success" for v in lines)
            task = client.call("saveTask", "測試作業", request)
            tasks_file = fixture / "作業.json"
            client.call("_exportTasks", str(tasks_file))
            assert tasks_file.exists()
            client.call("deleteTask", task["id"])
            client.call("_importTasks", str(tasks_file))
            assert any(t["name"] == "測試作業" for t in client.call("listTasks"))
        check("complete reports and task export/import", reports_and_tasks)
        def cancellation():
            paths = {}
            for group in ["a", "b"]:
                a, b = fixture / f"slow-{group}", fixture / f"slow-{group}-destination"
                a.mkdir(); b.mkdir()
                (a / "000-complete.txt").write_bytes(b"completed file stays\n")
                (a / "999-in-progress.bin").write_bytes(b"x" * (8 * 1024 * 1024))
                (b / "999-in-progress.bin").write_bytes(b"previous complete version\n")
                slow = {**request, "source": endpoint(a), "destination": endpoint(b), "mode": "copy",
                        "options": {"transfers": 1, "checkers": 1, "bandwidth": "256K", "comparison": "size", "localHashPolicy": "none",
                                    "extraArgs": ["--local-no-clone", "--multi-thread-streams=0", "--order-by=name,ascending"]}}
                ident = client.call("startTransfer", slow)["id"]
                paths[group] = (ident, b)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if all((dest / "000-complete.txt").exists() and any("partial" in p.name for p in dest.iterdir()) for _, dest in paths.values()):
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("Cancellation fixture did not reach an in-progress write")
            first = paths["a"][0]
            client.call("cancelJob", first)
            stopped = client.wait(first, timeout=20)
            assert stopped["status"] == "cancelled", stopped
            assert stopped["cancellation"]["forced"] is False and stopped["cancellation"]["processExited"] is True, stopped["cancellation"]
            assert client.job(paths["b"][0])["status"] == "running", "Stopping one job affected another"
            client.call("cancelJob", paths["b"][0]); client.wait(paths["b"][0], timeout=20)
            for _, dest in paths.values():
                assert (dest / "000-complete.txt").read_bytes() == b"completed file stays\n"
                assert (dest / "999-in-progress.bin").read_bytes() == b"previous complete version\n"
                assert sorted(p.name for p in dest.iterdir()) == ["000-complete.txt", "999-in-progress.bin"]
        check("graceful cancellation cleans partials and preserves completed files", cancellation)
    finally:
        client.close()
    client = Client(fixture)
    try:
        def restart():
            jobs = client.call("listJobs")
            assert all(j["status"] != "completed" for j in jobs)
            assert len([j for j in jobs if j["status"] == "cancelled"]) == 2
            assert client.call("listTasks")
        check("restart clears successful history and retains stopped jobs and tasks", restart)
    finally:
        client.close()

output = args.output or (cache / f"{platform.system().lower()}-results.json")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({"platform": platform.platform(), "engineSha256": hashlib.sha256(engine_path.read_bytes()).hexdigest(),
    "rcloneSha256": hashlib.sha256(rclone_path.read_bytes()).hexdigest(), "passed": len(records), "failed": 0,
    "tests": records, "observedJobEvents": sum(v.get("type") == "jobUpdate" for v in events)}, indent=2) + "\n")
print(f"{len(records)} passed; {output}")
