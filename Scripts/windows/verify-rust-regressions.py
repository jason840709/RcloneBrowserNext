#!/usr/bin/env python3
"""Check the original Windows regression cases against executed Rust artifacts.

Totals alone cannot establish parity. Every original Platform and Listing case
must map to named Rust tests that passed in the retained, hashed executable log.
The listing process receipts retain the pre-migration cancellation conditions.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import os
import re


ROOT = Path(__file__).resolve().parents[2]
PLATFORM_CASES = {
    "JSON booleans stay distinct from numeric values",
    "Windows paths require an absolute drive or complete UNC share",
    "POSIX paths retain colon and backslash filename semantics",
    "destination roots include drive and UNC share roots",
    "exclusive UTF-8 file creation preserves an existing file",
    "regular file reader handles missing and existing files",
    "atomic replacement commits complete bytes over an existing file",
    "removing a missing file is harmless and removing a directory is rejected",
    "real rclone format and declared OS requirements are validated",
}
LISTING_CASES = {
    "browse preserves legacy arrays and starts only one lsjson per ready remote listing",
    "cancellation before dispatch prevents spawn and rejects reused active request IDs",
    "context reset cancels a reserved worker before it starts",
    "cancel reaps only its child while same-folder other pane and newer request continue",
    "cancel covers environment discovery and allows a clean retry",
    "native deadline stops its listing process and reports an error rather than empty success",
    "connection change cancels old reading and queued requests before publishing new settings",
    "cancel during a replacement environment probe never waits for or stops the unrelated probe",
    "shutdown reaps both listing children and prevents reserved late workers",
    "local adapter keeps original errors and pre-cancel performs no filesystem read",
    "real rclone keeps Unicode names sizes modification times and missing-remote errors",
    "real throttled HTTP listing cancellation reaps rclone and preserves a running transfer",
}
SUITES = (("Tests/PlatformTests.swift", PLATFORM_CASES, "existing-platform"),
          ("Tests/ListingTests.swift", LISTING_CASES, "scoped-directory-listing"))
RESULT = re.compile(r"^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;", re.MULTILINE)
PASSED_CASE = re.compile(r"^test ([^\r\n]+) \.\.\. ok\s*$", re.MULTILINE)
SHA256 = re.compile(r"[0-9a-f]{64}")


def require(value, message):
    if not value:
        raise AssertionError(message)


def count(value):
    return type(value) is int and value >= 0


def pid(value):
    return type(value) is int and value > 0


def seconds(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def listing_evidence(log):
    def one(marker):
        matches = re.findall(r"^" + re.escape(marker) + r" (.+)$", log, re.MULTILINE)
        require(len(matches) == 1, "Missing or duplicated " + marker)
        value = json.loads(matches[0])
        require(isinstance(value, dict), "Invalid " + marker)
        return value

    real = one("REAL_LISTING_CANCEL_EVIDENCE")
    require(pid(real.get("pid")) and real.get("aliveAfterAck") is False
            and real.get("transferStillRunning") is True and real.get("loopbackOnly") is True
            and seconds(real.get("elapsedSeconds")) and real["elapsedSeconds"] < 5,
            "Real listing cancellation did not reap its process independently within five seconds")
    child = one("LISTING_CANCEL_EVIDENCE")
    children = child.get("actualChildPIDs", [])
    require(pid(child.get("pid")) and pid(child.get("otherPID"))
            and child["pid"] != child["otherPID"] and child.get("aliveAfterAck") is False
            and isinstance(children, list) and len(children) == 2
            and all(pid(value) for value in children) and len(set(children)) == 2
            and child.get("actualChildrenAliveAfterAck") == 1,
            "Directory cancellation did not isolate its actual child from the other pane")
    return real, child


def verify_receipt(receipt, test_map, read_log, *, source_commit, run_id, rclone_sha256):
    """Return verified original-case suites; read_log(name) supplies raw bytes."""
    require(re.fullmatch(r"[0-9a-f]{40}", source_commit or "") and re.fullmatch(r"[0-9]+", run_id or ""),
            "Missing immutable Actions source/run identity for core Rust results")
    require(receipt.get("passed") is True and receipt.get("sourceCommit") == source_commit
            and receipt.get("runID") == run_id, "Core Rust results belong to a different source or Actions run")
    require(re.fullmatch(r"rustc 1\.90\.0(?:\s.+)?", receipt.get("rustcVersion", "")),
            "Core Rust regressions were not built with the pinned minimum Rust 1.90.0")
    require(receipt.get("rcloneSha256") == rclone_sha256 and SHA256.fullmatch(rclone_sha256 or ""),
            "Core Rust regressions did not use the pinned transfer-tested rclone")
    records = receipt.get("executables", [])
    require(isinstance(records, list) and records, "Core Rust results contain no executed artifacts")
    targets, logs = {}, {}
    for item in records:
        name, filename = item.get("name"), item.get("log")
        require(isinstance(name, str) and name and name not in targets,
                "Core Rust test targets are missing or duplicated")
        require(isinstance(filename, str) and filename and "/" not in filename and "\\" not in filename
                and ":" not in filename and filename not in (".", "..") and filename not in logs,
                "A core Rust log is duplicated or outside the evidence directory")
        require(item.get("returncode") == 0 and count(item.get("passed"))
                and item.get("failed") == 0 and item.get("ignored") == 0
                and SHA256.fullmatch(item.get("sha256", "")),
                "Core Rust test executable failed, omitted tests or has no binary identity: " + name)
        raw = read_log(filename)
        require(isinstance(raw, bytes) and hashlib.sha256(raw).hexdigest() == item.get("logSha256"),
                "Core Rust log differs from the execution receipt: " + filename)
        log = raw.decode("utf-8-sig")
        matches = RESULT.findall(log)
        require(matches == [("ok", str(item["passed"]), "0", "0")],
                "Core Rust test summary is incomplete or differs from its receipt: " + name)
        actual = PASSED_CASE.findall(log)
        reported = item.get("cases", [])
        require(isinstance(reported, list) and all(isinstance(case, str) for case in reported)
                and len(actual) == len(set(actual)) == item["passed"]
                and len(reported) == len(set(reported)) == item["passed"]
                and set(actual) == set(reported),
                "Core Rust named cases are missing, duplicated or disagree with the retained log: " + name)
        targets[name] = set(reported)
        logs[filename] = log
    require(count(receipt.get("testsPassed")) and receipt["testsPassed"] == sum(item["passed"] for item in records)
            and receipt.get("testsIgnored") == 0, "Core Rust aggregate totals disagree with the executed artifacts")
    require(test_map.get("formatVersion") == 1 and isinstance(test_map.get("cases"), list),
            "Missing versioned original-to-Rust test mapping")
    suites = []
    for swift_file, expected, suite_name in SUITES:
        rows = [row for row in test_map["cases"]
                if row.get("swiftFile") == swift_file and "windows" in row.get("platforms", [])]
        names = [row.get("swiftName") for row in rows]
        require(len(names) == len(set(names)) and set(names) == expected,
                "Original Windows cases are missing, duplicated or unexpected in " + swift_file)
        for row in rows:
            mapped = row.get("rustCases", [])
            require(isinstance(mapped, list) and mapped, "Original case has no executed Rust counterpart: " + row["swiftName"])
            pairs = []
            for case in mapped:
                target = "rbn_core" if case.get("target") == "lib" else case.get("target")
                name = case.get("name")
                require(isinstance(target, str) and isinstance(name, str) and name
                        and name in targets.get(target, set()),
                        "Original Windows case did not execute its named Rust counterpart: " + row["swiftName"])
                pairs.append((target, name))
            require(len(pairs) == len(set(pairs)), "Duplicated Rust mapping for " + row["swiftName"])
        suites.append({"name": suite_name, "passed": len(expected), "failed": 0, "skipped": 0,
                       "unit": "original Swift cases covered by named executed Rust tests", "caseMapping": rows})
    listing = next((item for item in records if item["name"] == "listing"), None)
    require(listing is not None, "Missing listing executable and process evidence")
    real, child = listing_evidence(logs[listing["log"]])
    suites[1].update(realRcloneCancellation=real, childProcessCancellation=child)
    return {"testsPassed": receipt["testsPassed"], "testsIgnored": 0, "suites": suites}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--test-map", type=Path, default=ROOT / "Tests/rust-test-map.json")
    parser.add_argument("--rclone", type=Path, required=True)
    args = parser.parse_args()
    base = args.receipt.resolve().parent

    def read_log(name):
        path = (base / name).resolve(strict=True)
        require(path.parent == base, "Core Rust log is outside its evidence directory")
        return path.read_bytes()

    result = verify_receipt(json.loads(args.receipt.read_text(encoding="utf-8-sig")),
                            json.loads(args.test_map.read_text(encoding="utf-8")), read_log,
                            source_commit=os.environ.get("GITHUB_SHA"), run_id=os.environ.get("GITHUB_RUN_ID"),
                            rclone_sha256=hashlib.sha256(args.rclone.read_bytes()).hexdigest())
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
