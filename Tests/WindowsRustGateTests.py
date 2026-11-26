#!/usr/bin/env python3
"""Verify that incomplete or altered Rust parity evidence cannot pass the gate."""
from pathlib import Path
import hashlib
import importlib.util
import json
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("windows_rust_regressions", ROOT / "Scripts/windows/verify-rust-regressions.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
COMMIT = "a" * 40
RUN = "12345"
RCLONE = "b" * 64


class WindowsRustGateTests(unittest.TestCase):
    def setUp(self):
        self.mapping = {"formatVersion": 1, "cases": []}
        self.logs = {}
        self.receipt = {"passed": True, "sourceCommit": COMMIT, "runID": RUN,
                        "rustcVersion": "rustc 1.90.0 (1159e78c4 2025-09-14)",
                        "rcloneSha256": RCLONE, "testsPassed": 0, "testsIgnored": 0, "executables": []}
        self.real = {"pid": 300, "aliveAfterAck": False, "elapsedSeconds": 0.15,
                     "transferStillRunning": True, "loopbackOnly": True}
        self.child = {"pid": 100, "otherPID": 101, "aliveAfterAck": False,
                      "actualChildPIDs": [200, 201], "actualChildrenAliveAfterAck": 1}
        for swift_file, original, _ in GATE.SUITES:
            target = "lib" if "Platform" in swift_file else "listing"
            names = [f"original_case_{index}" for index, _ in enumerate(sorted(original))]
            self.mapping["cases"].extend(
                {"swiftFile": swift_file, "swiftName": name, "platforms": ["windows"],
                 "rustCases": [{"target": target, "name": rust_name}]}
                for name, rust_name in zip(sorted(original), names)
            )
            record = {"name": "rbn_core" if target == "lib" else target, "returncode": 0,
                      "log": target + ".log", "sha256": "c" * 64,
                      "passed": len(names), "failed": 0, "ignored": 0, "cases": names}
            self.receipt["executables"].append(record)
            self.receipt["testsPassed"] += len(names)
        self.write_logs()

    def write_logs(self):
        for record in self.receipt["executables"]:
            text = "\n".join(f"test {name} ... ok" for name in record["cases"]) + "\n"
            if record["name"] == "listing":
                text += "REAL_LISTING_CANCEL_EVIDENCE " + json.dumps(self.real) + "\n"
                text += "LISTING_CANCEL_EVIDENCE " + json.dumps(self.child) + "\n"
            text += f"test result: ok. {record['passed']} passed; {record['failed']} failed; {record['ignored']} ignored; 0 measured; 0 filtered out; finished in 0.1s\n"
            self.logs[record["log"]] = text.encode()
            record["logSha256"] = hashlib.sha256(self.logs[record["log"]]).hexdigest()

    def verify(self):
        return GATE.verify_receipt(self.receipt, self.mapping, self.logs.__getitem__,
                                   source_commit=COMMIT, run_id=RUN, rclone_sha256=RCLONE)

    def test_complete_named_original_cases_pass(self):
        value = self.verify()
        self.assertEqual([suite["passed"] for suite in value["suites"]], [9, 12])
        self.assertEqual(value["suites"][1]["realRcloneCancellation"], self.real)
        self.assertEqual(value["suites"][1]["childProcessCancellation"], self.child)

    def test_original_case_missing_even_when_rust_totals_still_pass(self):
        self.mapping["cases"].pop()
        with self.assertRaisesRegex(AssertionError, "Original Windows cases"):
            self.verify()

    def test_original_case_replacement_at_same_total_is_rejected(self):
        self.mapping["cases"][0]["swiftName"] = "replacement case"
        with self.assertRaisesRegex(AssertionError, "Original Windows cases"):
            self.verify()

    def test_duplicate_original_case_is_rejected(self):
        self.mapping["cases"].append(self.mapping["cases"][-1])
        with self.assertRaisesRegex(AssertionError, "Original Windows cases"):
            self.verify()

    def test_mapping_to_unexecuted_rust_case_is_rejected(self):
        self.mapping["cases"][0]["rustCases"][0]["name"] = "not_executed"
        with self.assertRaisesRegex(AssertionError, "did not execute"):
            self.verify()

    def test_multiple_rust_tests_for_one_original_case_are_required(self):
        self.mapping["cases"][0]["rustCases"].append({"target": "lib", "name": "not_executed"})
        with self.assertRaisesRegex(AssertionError, "did not execute"):
            self.verify()

    def test_altered_log_is_rejected(self):
        self.logs["lib.log"] += b"changed after execution\n"
        with self.assertRaisesRegex(AssertionError, "log differs"):
            self.verify()

    def test_receipt_case_not_in_retained_log_is_rejected(self):
        self.receipt["executables"][0]["cases"][0] = "different_name"
        with self.assertRaisesRegex(AssertionError, "named cases"):
            self.verify()

    def test_duplicate_executable_is_rejected(self):
        self.receipt["executables"].append(self.receipt["executables"][0])
        with self.assertRaisesRegex(AssertionError, "targets are missing or duplicated"):
            self.verify()

    def test_ignored_original_regressions_are_rejected(self):
        self.receipt["executables"][0]["ignored"] = 1
        self.write_logs()
        with self.assertRaisesRegex(AssertionError, "omitted tests"):
            self.verify()

    def test_aggregate_total_mismatch_is_rejected(self):
        self.receipt["testsPassed"] += 1
        with self.assertRaisesRegex(AssertionError, "aggregate totals"):
            self.verify()

    def test_another_source_or_run_is_rejected(self):
        for key, bad in (("sourceCommit", "d" * 40), ("runID", "99999")):
            with self.subTest(key=key):
                original = self.receipt[key]
                self.receipt[key] = bad
                with self.assertRaisesRegex(AssertionError, "different source or Actions run"):
                    self.verify()
                self.receipt[key] = original

    def test_newer_rust_does_not_count_as_minimum_version_evidence(self):
        self.receipt["rustcVersion"] = "rustc 1.100.0 (example 2026-11-01)"
        with self.assertRaisesRegex(AssertionError, "minimum Rust 1.90.0"):
            self.verify()

    def test_another_rclone_is_rejected(self):
        self.receipt["rcloneSha256"] = "d" * 64
        with self.assertRaisesRegex(AssertionError, "pinned transfer-tested rclone"):
            self.verify()

    def test_log_path_outside_evidence_is_rejected(self):
        for path in ("../listing.log", "..\\listing.log", "/listing.log"):
            with self.subTest(path=path):
                self.receipt["executables"][0]["log"] = path
                with self.assertRaisesRegex(AssertionError, "outside the evidence"):
                    self.verify()

    def test_live_child_or_stopped_independent_transfer_is_rejected(self):
        for key, bad in (("aliveAfterAck", True), ("transferStillRunning", False), ("loopbackOnly", False),
                         ("elapsedSeconds", 5), ("elapsedSeconds", -1), ("elapsedSeconds", float("nan")),
                         ("pid", 0)):
            with self.subTest(key=key, value=bad):
                original = self.real[key]
                self.real[key] = bad
                self.write_logs()
                with self.assertRaisesRegex(AssertionError, "independently within five seconds"):
                    self.verify()
                self.real[key] = original

    def test_wrong_other_pane_process_evidence_is_rejected(self):
        for key, bad in (("aliveAfterAck", True), ("actualChildPIDs", [200, 200]),
                         ("actualChildrenAliveAfterAck", 0), ("otherPID", 100)):
            with self.subTest(key=key):
                original = self.child[key]
                self.child[key] = bad
                self.write_logs()
                with self.assertRaisesRegex(AssertionError, "other pane"):
                    self.verify()
                self.child[key] = original

    def test_missing_or_duplicate_cancellation_evidence_is_rejected(self):
        listing = self.receipt["executables"][1]
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                self.write_logs()
                marker = "REAL_LISTING_CANCEL_EVIDENCE " + json.dumps(self.real) + "\n"
                self.logs["listing.log"] = self.logs["listing.log"].replace(marker.encode(), marker.encode() * (2 if duplicate else 0))
                listing["logSha256"] = hashlib.sha256(self.logs["listing.log"]).hexdigest()
                with self.assertRaisesRegex(AssertionError, "Missing or duplicated"):
                    self.verify()


if __name__ == "__main__":
    unittest.main(verbosity=2)
