#!/usr/bin/env python3
"""Portable mocks for read-only Windows installation evidence and its gates."""
from copy import deepcopy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


DIAG = load("portable_installation_diagnostics", ROOT / "Scripts/windows/installation-diagnostics.py")
INSTALL = load("portable_installation_verifier", ROOT / "Scripts/windows/verify-installation.py")
COMMIT, RUN = "a" * 40, "123"


class FakeAPI:
    def __init__(self, image):
        self.image, self.calls, self.codes = str(image), [], {}
        self.owner = {"pid": 4242, "creationTime100ns": "123", "creationTimeUTC": DIAG.filetime_utc(123),
                      "applicationName": "fixture reader", "service": "", "applicationType": 1,
                      "applicationStatus": 1, "sessionID": 1, "restartable": False}
        self.reads = [(234, 1, [], 0), (0, 1, [self.owner], 0)]
        self.query_error = None
        self.reused = False

    def start_session(self):
        self.calls.append(("start",))
        return self.codes.get("start", 0), 7

    def register_file(self, handle, path):
        self.calls.append(("register", handle, path))
        return self.codes.get("register", 0)

    def get_list(self, handle, capacity):
        self.calls.append(("get", handle, capacity))
        return deepcopy(self.reads.pop(0))

    def end_session(self, handle):
        self.calls.append(("end", handle))
        return self.codes.get("end", 0)

    def process_info(self, pid):
        self.calls.append(("process", pid))
        if self.query_error:
            raise self.query_error
        return {"pid": pid, "creationTime100ns": "456" if self.reused else "123",
                "creationTimeUTC": DIAG.filetime_utc(123), "imagePath": self.image}


class FakeProcess:
    def __init__(self):
        self.pid, self.returncode, self.waits, self.killed = 4242, None, [], False
        self.stdin, self.stdout, self.stderr = io.StringIO(), io.StringIO(), io.StringIO()
        self.timeout_first = False

    def poll(self):
        return self.returncode

    def wait(self, timeout):
        self.waits.append(timeout)
        if self.timeout_first and len(self.waits) == 1:
            raise subprocess.TimeoutExpired("owned helper", timeout)
        if self.returncode is None:
            self.returncode = 0
        return self.returncode

    def kill(self):
        self.killed, self.returncode = True, -9


class WindowsInstallationDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        task = ROOT.parent if ROOT.name == "01_原始碼" else ROOT
        scratch = ROOT / ".build-cache/python-tests" if os.environ.get("GITHUB_ACTIONS", "").lower() == "true" else task / ".tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch, prefix="installation-diagnostic-test-")
        self.addCleanup(self.temp.cleanup)
        self.area = Path(self.temp.name)
        self.image = self.area / "upgrade/rclone-browser-next.exe"
        self.image.parent.mkdir()
        self.image.write_bytes(b"non-executable fixture")
        self.env = patch.dict(os.environ, {"GITHUB_SHA": COMMIT, "GITHUB_RUN_ID": RUN})
        self.env.start()
        self.addCleanup(self.env.stop)

    def inventory(self, api=None):
        return DIAG.restart_manager_snapshot(self.image, self.area, api=api or FakeAPI(self.image))

    def test_rm_reads_exact_owned_resource_and_preserves_owner_identity(self):
        api = FakeAPI(self.image)
        value = self.inventory(api)
        self.assertTrue(value["complete"])
        self.assertEqual(value["owners"][0]["pid"], 4242)
        self.assertEqual(value["owners"][0]["imagePath"], str(self.image))
        self.assertEqual(api.calls, [("start",), ("register", 7, str(self.image)), ("get", 7, 0),
                                     ("get", 7, 1), ("process", 4242), ("end", 7)])
        DIAG.validate_rm(value)

    def test_successful_empty_rm_query_is_distinct_from_unobserved(self):
        api = FakeAPI(self.image)
        api.reads = [(0, 0, [], 0)]
        value = self.inventory(api)
        self.assertTrue(value["complete"])
        self.assertEqual(value["owners"], [])
        DIAG.validate_rm(value)

    def test_missing_main_executable_skips_api_without_claiming_no_owners(self):
        self.image.unlink()
        api = FakeAPI(self.image)
        value = self.inventory(api)
        self.assertFalse(value["applicable"])
        self.assertIsNone(value["owners"])
        self.assertEqual(api.calls, [])
        DIAG.validate_rm(value)

    def test_rm_start_register_query_and_end_errors_remain_failures(self):
        for stage in ("start", "register", "get", "end"):
            with self.subTest(stage=stage):
                api = FakeAPI(self.image)
                if stage == "get":
                    api.reads = [(5, 0, [], 0)]
                else:
                    api.codes[stage] = 5
                value = self.inventory(api)
                self.assertFalse(value["complete"])
                self.assertTrue(value["errors"])
                if stage != "end":
                    self.assertIsNone(value["owners"])
                if stage != "start":
                    self.assertEqual(api.calls[-1], ("end", 7))
                with self.assertRaises(AssertionError):
                    DIAG.validate_rm(value)

    def test_uninspectable_owner_is_retained_instead_of_empty_list(self):
        api = FakeAPI(self.image)
        api.query_error = OSError("access denied")
        value = self.inventory(api)
        self.assertFalse(value["complete"])
        self.assertEqual(value["owners"][0]["pid"], 4242)
        self.assertIn("inspectionError", value["owners"][0])

    def test_reused_owner_pid_is_not_misattributed(self):
        api = FakeAPI(self.image)
        api.reused = True
        value = self.inventory(api)
        self.assertFalse(value["complete"])
        self.assertIn("reused", value["owners"][0]["inspectionError"]["message"])

    def test_resource_outside_owned_root_or_relative_path_is_rejected_without_api(self):
        for path in (self.area.parent / "rclone-browser-next.exe", Path("rclone-browser-next.exe")):
            api = FakeAPI(self.image)
            value = DIAG.restart_manager_snapshot(path, self.area, api=api)
            self.assertFalse(value["complete"])
            self.assertIsNone(value["owners"])
            self.assertEqual(api.calls, [])

    def test_tasklist_records_actual_table_and_checked_return_code(self):
        raw = '"rclone-browser-next.exe","4242","Console","1","4,000 K"\n'
        value = DIAG.tasklist_snapshot({"rclone-browser-next.exe"}, {},
                                       runner=Mock(return_value=SimpleNamespace(returncode=0, stdout=raw, stderr="")))
        self.assertEqual(value["stdout"], raw)
        self.assertEqual(value["matchingProcesses"], [{"image": "rclone-browser-next.exe", "pid": "4242"}])
        self.assertTrue(value["complete"])

    def test_failed_tasklist_is_never_an_empty_process_list(self):
        value = DIAG.tasklist_snapshot(set(), {},
                                       runner=Mock(return_value=SimpleNamespace(returncode=1, stdout="", stderr="query failed")))
        self.assertFalse(value["complete"])
        self.assertIsNone(value["matchingProcesses"])
        queries = []
        with patch.object(INSTALL.DIAGNOSTICS, "tasklist_snapshot", return_value=value):
            with self.assertRaisesRegex(AssertionError, "process query failed"):
                INSTALL.running_apps(queries)
        self.assertEqual(queries, [value])

    def test_installer_exit_two_is_not_retried_or_accepted(self):
        queries = []
        def waited(path, **kwargs):
            kwargs["queries"].extend(queries)
        before, after = self.inventory(), self.inventory()
        log = self.area / "upgrade-installer.log"
        with patch.object(INSTALL, "OWNED_CACHE", self.area), patch.object(INSTALL, "wait_for_app_exit", side_effect=waited), \
                patch.object(INSTALL.DIAGNOSTICS, "restart_manager_snapshot", side_effect=[before, after]) as probe, \
                patch.object(INSTALL.subprocess, "run", return_value=SimpleNamespace(returncode=2)) as run:
            with self.assertRaisesRegex(AssertionError, "Installer failed with exit code 2"):
                INSTALL.run_installer(self.area / "setup.exe", self.image.parent, log)
        recorded = json.loads(log.with_suffix(".diagnostics.json").read_text())
        self.assertEqual(run.call_count, 1)
        self.assertEqual(probe.call_count, 2)
        self.assertEqual(recorded["installerExitCode"], 2)
        self.assertEqual(recorded["afterFailure"], after)
        self.assertEqual(run.call_args.kwargs["timeout"], 240)

    def test_installer_positive_receipt_binds_complete_query_rm_and_source(self):
        query = DIAG.tasklist_snapshot(set(), {},
                                      runner=Mock(return_value=SimpleNamespace(returncode=0, stdout="actual table\n", stderr="")))
        log = self.area / "fresh-installer.log"
        with patch.object(INSTALL, "OWNED_CACHE", self.area), \
                patch.object(INSTALL.DIAGNOSTICS, "tasklist_snapshot", return_value=query), \
                patch.object(INSTALL.DIAGNOSTICS, "restart_manager_snapshot", return_value=self.inventory()), \
                patch.object(INSTALL.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            self.assertEqual(INSTALL.run_installer(self.area / "setup.exe", self.image.parent, log), 0)
        value = json.loads(log.with_suffix(".diagnostics.json").read_text())
        DIAG.validate_installer(value, COMMIT, RUN, str(self.image))
        self.assertEqual(run.call_count, 1)
        for key in ("tasklistQueries", "before", "source"):
            broken = {**value, key: [] if key == "tasklistQueries" else {}}
            with self.assertRaises(AssertionError):
                DIAG.validate_installer(broken, COMMIT, RUN, str(self.image))

    def test_failed_process_query_stops_before_installer_and_retains_error(self):
        query = DIAG.tasklist_snapshot(set(), {},
                                      runner=Mock(return_value=SimpleNamespace(returncode=1, stdout="", stderr="query failed")))
        log = self.area / "upgrade-installer.log"
        with patch.object(INSTALL.DIAGNOSTICS, "tasklist_snapshot", return_value=query), \
                patch.object(INSTALL.subprocess, "run") as run:
            with self.assertRaisesRegex(AssertionError, "process query failed"):
                INSTALL.run_installer(self.area / "setup.exe", self.image.parent, log)
        run.assert_not_called()
        value = json.loads(log.with_suffix(".diagnostics.json").read_text())
        self.assertEqual(value["tasklistQueries"], [query])
        self.assertIsNone(value["installerExitCode"])

    def test_new_diagnostic_files_use_original_fresh_and_upgrade_collector_prefixes(self):
        for phase in ("fresh", "upgrade"):
            area = self.area / phase
            area.mkdir(exist_ok=True)
            old = {f"{phase}-before.json": b"before", f"{phase}-after.json": b"after", f"{phase}-installer.log": b"log"}
            for name, content in old.items():
                (area / name).write_bytes(content)
            original = INSTALL.collect_installation_evidence(area, phase)
            name = f"{phase}-installer.diagnostics.json"
            (area / name).write_text(json.dumps(self.inventory()), encoding="utf-8")
            actual = INSTALL.collect_installation_evidence(area, phase)
            rows = {row["file"]: row for row in actual}
            self.assertEqual(set(rows), set(old) | {name})
            self.assertEqual([rows[row["file"]] for row in original], original)

    def test_ui_taskkill_records_exact_existing_policy_and_exit(self):
        process = FakeProcess()
        def killed(command, **kwargs):
            self.assertEqual(command, ["taskkill.exe", "/PID", "4242", "/T", "/F"])
            self.assertEqual(kwargs["timeout"], 30)
            process.returncode = 1
            return SimpleNamespace(returncode=0, stdout="terminated 4242", stderr="")
        value = DIAG.terminate_owned_ui_process(process, runner=killed)
        self.assertEqual(process.waits, [10])
        self.assertEqual(value["exitCode"], 1)
        DIAG.validate_ui_cleanup(value, COMMIT, RUN, 4242)

    def test_ui_already_exited_never_receives_taskkill(self):
        process, run = FakeProcess(), Mock()
        process.returncode = 0
        value = DIAG.terminate_owned_ui_process(process, runner=run)
        run.assert_not_called()
        self.assertEqual(value["outcome"], "already-exited-before-cleanup")
        DIAG.validate_ui_cleanup(value, COMMIT, RUN, 4242)

    def test_nonzero_taskkill_distinguishes_exit_race_and_running_process(self):
        for exited in (True, False):
            process = FakeProcess()
            def killed(*args, **kwargs):
                if exited:
                    process.returncode = 0
                return SimpleNamespace(returncode=128, stdout="actual output", stderr="actual error")
            value = DIAG.terminate_owned_ui_process(process, runner=killed)
            self.assertFalse(value["complete"])
            self.assertEqual(value["taskkill"], {"returnCode": 128, "stdout": "actual output", "stderr": "actual error"})
            self.assertEqual(value["outcome"], "taskkill-failed-process-exited" if exited else "taskkill-failed-process-running")
            with self.assertRaises(AssertionError):
                DIAG.validate_ui_cleanup(value, COMMIT, RUN, 4242)

    def test_taskkill_timeout_preserves_partial_output_and_does_not_invent_exit(self):
        process = FakeProcess()
        run = Mock(side_effect=subprocess.TimeoutExpired("taskkill", 30, output=b"partial stdout", stderr=b"partial stderr"))
        value = DIAG.terminate_owned_ui_process(process, runner=run)
        self.assertFalse(value["complete"])
        self.assertEqual(value["taskkill"]["stdout"], "partial stdout")
        self.assertIsNone(value["taskkill"]["returnCode"])
        self.assertEqual(process.waits, [])

    def client(self, process):
        info = DIAG.process_snapshot(process.pid, api=FakeAPI(self.image))
        with patch.object(INSTALL.subprocess, "Popen", return_value=process), \
                patch.object(INSTALL.threading, "Thread"), patch.object(INSTALL.DIAGNOSTICS, "process_snapshot", return_value=info):
            client = INSTALL.StateClient(self.image, self.area, self.area, self.area, "upgrade-old")
        client.call = Mock(return_value=True)
        return client

    def test_owned_helper_pid_creation_and_shutdown_wait_are_recorded(self):
        process = FakeProcess()
        client = self.client(process)
        client.close()
        value = json.loads((self.area / "upgrade-old-helper.json").read_text())
        self.assertEqual(value["pid"], process.pid)
        self.assertEqual(process.waits, [20])
        self.assertFalse(process.killed)
        DIAG.validate_helper(value, COMMIT, RUN, str(self.image))

    def test_owned_helper_timeout_keeps_original_fallback_and_failure(self):
        process = FakeProcess()
        process.timeout_first = True
        client = self.client(process)
        with self.assertRaises(subprocess.TimeoutExpired):
            client.close()
        value = json.loads((self.area / "upgrade-old-helper.json").read_text())
        self.assertTrue(process.killed)
        self.assertEqual(process.waits, [20, 10])
        self.assertEqual(value["exitCode"], -9)
        self.assertIn("fallbackKillRequested", value["lifecycle"])

    def test_helper_metadata_failure_is_retained_after_clean_child_shutdown(self):
        process = FakeProcess()
        client = self.client(process)
        client.process_evidence = {"pid": process.pid, "complete": False, "error": {"message": "query failed"}}
        with self.assertRaisesRegex(AssertionError, "creation/image inventory failed"):
            client.close()
        value = json.loads((self.area / "upgrade-old-helper.json").read_text())
        self.assertFalse(value["process"]["complete"])
        self.assertEqual(value["exitCode"], 0)
        self.assertEqual(process.waits, [20])
        self.assertFalse(process.killed)

    def test_source_hash_and_source_run_identity_are_required(self):
        identity = DIAG.source_identity()
        DIAG.validate_source(identity, COMMIT, RUN)
        for key in ("rawSHA256", "canonicalLFSHA256", "sourceCommit", "runID"):
            changed = {**identity, key: "wrong"}
            with self.assertRaises(AssertionError):
                DIAG.validate_source(changed, COMMIT, RUN)


if __name__ == "__main__":
    unittest.main()
