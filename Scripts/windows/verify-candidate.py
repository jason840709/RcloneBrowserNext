#!/usr/bin/env python3
"""Require complete installed-product evidence before a Windows candidate passes.

The baseline probes deliberately return success for observed product defects.
This separate gate checks every required case, counts, binary identity and raw
receipt hash; a diagnostic process exiting zero is insufficient for release.
"""
from pathlib import Path
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import sys
import traceback


ROOT = Path(__file__).resolve().parents[2]
VERSION = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
NUMERIC_VERSION = [int(part) for part in VERSION.split(".")] + [0]
FILESYSTEM_CASES = {"bootstrap-unconfigured", "bootstrap-configured", "list-unicode", "list-user-home",
                    "list-system-drive-root", "list-broken-junction"} | {
    f"{operation}-sparse-{size}" for operation in ("list", "size")
    for size in (2 * 1024**3 - 1, 2 * 1024**3 + 1, 3 * 1024**3, 4 * 1024**3 + 1, 5 * 1024**3)
}
MUTATION_CASES = {
    "rename-small-beside-3gib", "remove-small-beside-5gib", "rename-directory-with-content", "rename-no-overwrite",
    "rename-same-name", "rename-source-type-validation", "rename-invalid-name", "mkdir-and-duplicate",
    "remove-preflight-missing", "remove-preflight-type", "remove-preflight-invalid-selection", "remove-live-junction",
    "remove-broken-junction", "remove-directory-with-nested-junctions", "size-skips-junctions-and-cycles", "long-unicode-local-operations",
}
UI_CASES = {f"{size}-{side}-pointer-probe-{index:02d}" for size in ("normal", "compact")
            for side in ("left", "right") for index in (1, 9, 17)} | {
    f"{size}-{side}-keyboard-middle" for size in ("normal", "compact") for side in ("left", "right")
} | {"normal-left-local-navigation", "normal-right-local-navigation", "windows-drive-catalog",
     "endpoint-editor-startup-remote", "native-minimum-window-125-percent", "compact-endpoint-editor-startup-remote"}


RUST_SPEC = importlib.util.spec_from_file_location("windows_rust_regressions", ROOT / "Scripts/windows/verify-rust-regressions.py")
RUST_REGRESSIONS = importlib.util.module_from_spec(RUST_SPEC)
RUST_SPEC.loader.exec_module(RUST_REGRESSIONS)
ORACLE_SPEC = importlib.util.spec_from_file_location("windows_listing_oracle", ROOT / "Tests/windows-local-list-oracle.py")
LISTING_ORACLE = importlib.util.module_from_spec(ORACLE_SPEC)
ORACLE_SPEC.loader.exec_module(LISTING_ORACLE)
UNICODE_SPEC = importlib.util.spec_from_file_location("windows_unicode_runtime", ROOT / "Scripts/windows/unicode-runtime.py")
UNICODE = importlib.util.module_from_spec(UNICODE_SPEC)
UNICODE_SPEC.loader.exec_module(UNICODE)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def complete_cases(value, expected, label, *, ui=False):
    cases = value.get("cases", [])
    names = [case.get("name") for case in cases]
    require(len(names) == len(set(names)) and set(names) == expected, f"{label}: required cases are missing, duplicated or unexpected")
    require(all(case.get("passed") is True if ui else case.get("status") == "passed" for case in cases), f"{label}: at least one product case failed")
    if ui:
        require(value.get("totals") == {"passed": len(cases), "failed": 0}, f"{label}: result totals disagree with cases")
    else:
        require(value.get("summary") == {"total": len(cases), "passed": len(cases), "failed": 0,
                                         "infrastructure_error": 0, "infrastructureErrors": 0}, f"{label}: result totals disagree with cases")
        require(value.get("infrastructureErrors") == [], f"{label}: infrastructure or cleanup failed")
    return len(cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--build-evidence", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    args = parser.parse_args()
    evidence, build = args.evidence.resolve(), args.build_evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "passed": False, "sourceCommit": os.environ.get("GITHUB_SHA"),
              "runID": os.environ.get("GITHUB_RUN_ID"), "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
              "version": VERSION, "releaseTag": "v" + VERSION, "inputReceipts": [], "suites": []}
    recorded = set()

    def record(path, label):
        require(path.is_file(), f"Missing evidence: {label}")
        if label not in recorded:
            report["inputReceipts"].append({"file": label, "bytes": path.stat().st_size, "sha256": sha256(path)})
            recorded.add(label)

    def read(path, label):
        record(path, label)
        return json.loads(path.read_text(encoding="utf-8-sig"))

    def text(path, label):
        record(path, label)
        return path.read_text(encoding="utf-8-sig")

    try:
        require(re.fullmatch(r"[0-9a-f]{40}", report["sourceCommit"] or "") and re.fullmatch(r"[0-9]+", report["runID"] or ""), "Missing immutable Actions source/run identity")
        package = read(args.package, "package-windows.json")
        require(package.get("version") == report["version"] and package.get("releaseTag") == report["releaseTag"]
                and package.get("identifier") == "org.rclone.browser.next" and package.get("peVersion") == NUMERIC_VERSION
                and package.get("sourceCommit") == report["sourceCommit"], "Package identity differs from this candidate run")
        report["package"] = {key: package[key] for key in ("file", "version", "bytes", "sha256", "identifier", "peVersion")}
        report["installerSha256"] = package["sha256"]
        report["packageReceiptSHA256"] = sha256(args.package)
        installer = ROOT / "Distribution" / package["file"]
        require(installer.name == f"Rclone_Browser_Next_{VERSION}_Windows_x64_Setup.exe" and installer.stat().st_size == package["bytes"]
                and sha256(installer) == package["sha256"], "The downloaded installer differs from the package receipt")
        checksum = installer.with_suffix(".exe.sha256")
        require(checksum.read_text(encoding="utf-8").strip() == f"{package['sha256']}  {installer.name}", "The package checksum file does not match")
        runtime = package.get("runtime", {})
        require(runtime.get("engine") == "Rust" and re.fullmatch(r"rustc 1\.90\.0(?:\s.+)?", runtime.get("rust", "")),
                "The Windows package was not built with the Rust engine and pinned minimum toolchain")
        require(isinstance(runtime.get("libraries"), list) and isinstance(runtime.get("systemLibraries"), list)
                and not any(re.search(r"swift|foundation|dispatch", name, re.IGNORECASE)
                            for name in [item.get("name", "") for item in runtime["libraries"]] + runtime["systemLibraries"]),
                "The Rust candidate unexpectedly contains or imports Swift runtime libraries")
        UNICODE.validate_package(runtime)
        guard = read(build / "source-check.json", "build/source-check.json")
        require(guard.get("passed") is True and guard.get("version") == VERSION
                and guard.get("sourceCommit") == report["sourceCommit"]
                and guard.get("windowsFilesystemImplementation") == "Rust"
                and guard.get("windowsLauncherUnchanged") is True
                and guard.get("windowsLauncherBaseline") == {"ref": "windows-v0.9.0-r1", "blob": "d12569ca65804e8976d516980cdcacde934be122"},
                "Unified version or unchanged Windows launcher source check failed")
        report.update(windowsFilesystemImplementation="Rust", windowsLauncherUnchanged=True,
                      windowsLauncherBaseline=guard["windowsLauncherBaseline"])

        build_log = text(build / "build.log", "build/build.log")
        rust = re.findall(r"test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored;", build_log)
        rust_cases = re.findall(r"^test tests::[^\r\n]+ \.\.\. ok\s*$", build_log, re.MULTILINE)
        require(len(rust) == 1 and int(rust[0][0]) >= 5 and int(rust[0][0]) == len(rust_cases)
                and rust[0][1:] == ("0", "0"), "Native Rust test results are missing, incomplete or failing")
        report["suites"].append({"name": "native-host-rust", "passed": int(rust[0][0]), "failed": 0, "skipped": 0})
        transfers = read(build / "transfer.json", "build/transfer.json")
        require(transfers.get("passed") == 11 and transfers.get("failed") == 0 and len(transfers.get("tests", [])) == 11
                and all(item.get("status") == "passed" for item in transfers["tests"]), "Existing transfers/cancellation regressions did not all pass")
        barrier_tests = [item for item in transfers["tests"]
                         if item.get("name") == "scoped folder cancellation bypasses queued native state barriers"]
        require(len(barrier_tests) == 1, "Missing native queued-barrier cancellation regression")
        barrier_proof = barrier_tests[0].get("evidence", {})
        require(barrier_proof.get("loopbackOnly") is True
                and barrier_proof.get("stateBarrierQueuedFirst") is True
                and barrier_proof.get("httpGateStillClosedAtAck") is True
                and barrier_proof.get("childrenAliveAfterAck") == 0
                and len(barrier_proof.get("actualRclonePIDs", [])) >= 1,
                "Native listing cancellation did not bypass a queued state barrier and reap its real child")
        report["suites"].append({"name": "existing-transfers-and-cancellation", "passed": 11,
                                 "failed": 0, "skipped": None, "queuedBarrierCancellation": barrier_proof})
        core = read(build / "core-rust.json", "build/core-rust.json")
        test_map = read(ROOT / "Tests/rust-test-map.json", "source/rust-test-map.json")

        def core_log(name):
            path = (build / name).resolve(strict=True)
            require(path.parent == build, "Core Rust log is outside its evidence directory")
            record(path, "build/" + name)
            return path.read_bytes()

        UNICODE.validate_core(core, runtime)
        verified_core = RUST_REGRESSIONS.verify_receipt(core, test_map, core_log,
                        source_commit=report["sourceCommit"], run_id=report["runID"],
                        rclone_sha256=transfers.get("rcloneSha256"))
        report["coreRust"] = {"testsPassed": verified_core["testsPassed"], "testsIgnored": verified_core["testsIgnored"],
                              "rustcVersion": core["rustcVersion"]}
        report["suites"].extend(verified_core["suites"])

        installations = {}
        for phase in ("fresh", "upgrade"):
            receipt = read(evidence / f"{phase}-installation.json", f"{phase}-installation.json")
            require(receipt.get("passed") is True and receipt.get("phase") == phase and receipt.get("version") == report["version"]
                    and receipt.get("sourceCommit") == report["sourceCommit"] and receipt.get("runID") == report["runID"]
                    and receipt.get("installer", {}).get("sha256") == package["sha256"]
                    and receipt.get("packageReceiptSHA256") == report["packageReceiptSHA256"], f"{phase} installation did not verify this candidate")
            require(receipt.get("evidence"), f"{phase}: no raw installation snapshots were retained")
            for item in receipt["evidence"]:
                path = (evidence / item["file"]).resolve()
                require(path.parent == evidence, "Installation receipt references a file outside its evidence directory")
                record(path, item["file"])
                require(path.stat().st_size == item["bytes"] and sha256(path) == item["sha256"], "Raw installation evidence changed")
            for name in (f"{phase}-before.json", f"{phase}-after.json"):
                require(name in {item["file"] for item in receipt["evidence"]}, f"{phase}: missing before/after snapshot")
            installations[phase] = receipt
            probe_name = f"{phase}-unicode-runtime.json"
            require(probe_name in {item["file"] for item in receipt["evidence"]},
                    "The installed private ICU probe was not retained")
            private_probe = read(evidence / probe_name, probe_name)
            UNICODE.validate_probe(private_probe)
            require(private_probe == receipt.get("unicodeRuntimeProbe")
                    and private_probe["library"] == runtime["unicodeRuntime"]["library"]
                    and private_probe.get("sourceCommit") == report["sourceCommit"]
                    and private_probe.get("runID") == report["runID"],
                    "The installed private ICU runtime differs from the package or raw probe")
        fresh, upgrade = installations["fresh"], installations["upgrade"]
        require(all(upgrade.get(key) is True for key in ("settingsPreservedByteForByte", "tasksPreservedByteForByte",
                    "configurationPreservedByteForByte", "savedStateReloadedByInstalledHelper", "ownedStateRemoved"))
                and upgrade.get("downgradeGuard", {}).get("passed") is True, "Upgrade/state preservation or downgrade protection failed")
        if upgrade.get("upgradeFrom") == "0.11.0":
            original_listing = upgrade.get("originalListingOracle", {})
            require(original_listing.get("passed") is True and original_listing.get("entries") == 34
                    and isinstance(original_listing.get("swift"), list) and len(original_listing["swift"]) == 34
                    and original_listing.get("rust") == original_listing["swift"]
                    and original_listing.get("fieldDifferences") == [],
                    "The installed 0.11.0 and candidate Unicode listings did not match completely")
            require("windows-listing-oracle.log" in {item["file"] for item in upgrade["evidence"]},
                    "The original Windows listing oracle log is not retained in the upgrade receipt")
            require(read(evidence / "windows-listing-oracle.log", "windows-listing-oracle.log") == original_listing,
                    "The original Windows listing oracle differs from its retained raw output")
            LISTING_ORACLE.verify_group_receipt(original_listing, LISTING_ORACLE.ORIGINAL_FILES,
                                                LISTING_ORACLE.ORIGINAL_DIRECTORIES, "original-34")
            expanded_listing = upgrade.get("expandedListingOracle", {})
            expanded_count = LISTING_ORACLE.verify_group_receipt(expanded_listing, LISTING_ORACLE.EXTENDED_FILES,
                                                LISTING_ORACLE.EXTENDED_DIRECTORIES, "expanded-unicode")
            require("windows-listing-oracle-extended.json" in {item["file"] for item in upgrade["evidence"]}
                    and read(evidence / "windows-listing-oracle-extended.json", "windows-listing-oracle-extended.json") == expanded_listing,
                    "The expanded Windows listing oracle differs from its retained raw output")
            provenance = upgrade.get("baselineRuntimeProvenance", {})
            require("windows-listing-oracle-runtime.json" in {item["file"] for item in upgrade["evidence"]}
                    and read(evidence / "windows-listing-oracle-runtime.json", "windows-listing-oracle-runtime.json") == provenance,
                    "The baseline runtime inventory differs from its retained raw output")
            require(provenance.get("stage") == "baseline-installed-before-candidate"
                    and provenance.get("sourceCommit") == report["sourceCommit"]
                    and provenance.get("runID") == report["runID"] and provenance.get("icuLibraries")
                    and provenance.get("helper", {}).get("sha256")
                        == original_listing.get("binaries", {}).get("swift", {}).get("sha256"),
                    "The baseline runtime inventory is incomplete or does not identify the original helper")
            if provenance.get("manifest", {}).get("present") is True:
                manifest = provenance["manifest"]
                require(manifest.get("evidenceFile") == "windows-listing-oracle-runtime-manifest.json"
                        and manifest["evidenceFile"] in {item["file"] for item in upgrade["evidence"]}
                        and sha256(evidence / manifest["evidenceFile"]) == manifest["sha256"],
                        "The original baseline runtime manifest bytes are not retained")
            for listing in (original_listing, expanded_listing):
                require(listing.get("sourceCommit") == report["sourceCommit"] and listing.get("runID") == report["runID"]
                        and listing.get("binaries") == original_listing.get("binaries")
                        and listing.get("binaries", {}).get("rust", {}).get("sha256")
                            == fresh["installedExecutables"]["engine"]["sha256"]
                        and listing.get("binaries", {}).get("rustUnicodeRuntime") == runtime["unicodeRuntime"],
                        "The Windows listing oracle did not compare this candidate and the original helper")
            report["suites"].append({"name": "published-0.11.0-unicode-listing-oracle", "passed": 34,
                                     "failed": 0, "skipped": 0, "unit": "complete ordered file and directory entries"})
            report["suites"].append({"name": "published-0.11.0-expanded-unicode-listing-oracle", "passed": expanded_count,
                                     "failed": 0, "skipped": 0, "unit": "complete ordered file and directory entries"})
        engine_hash = fresh["installedExecutables"]["engine"]["sha256"]
        app_hash = fresh["installedExecutables"]["app"]["sha256"]
        rclone_hash = fresh["rclone"]["sha256"]
        require(transfers.get("engineSha256") == engine_hash and transfers.get("rcloneSha256") == rclone_hash,
                "Installed helper or rclone differs from the transfer-tested binaries")
        require(upgrade["installedExecutables"]["engine"]["sha256"] == engine_hash
                and upgrade["installedExecutables"]["app"]["sha256"] == app_hash, "Fresh and upgraded applications differ")
        report["suites"].append({"name": "fresh-install-and-upgrade", "passed": 2, "failed": 0, "skipped": None,
                                 "unit": "completed installation phases, including PE/registration and saved-state assertions"})

        for filename, expected, probe in (("filesystem.json", FILESYSTEM_CASES, "installed-windows-filesystem"),
                                           ("mutations.json", MUTATION_CASES, "windows-mutation-regression")):
            value = read(evidence / filename, filename)
            require(value.get("probe") == probe and value.get("engine", {}).get("sha256") == engine_hash
                    and value.get("rclone", {}).get("sha256") == rclone_hash, f"{filename}: the installed binaries were not tested")
            require(value.get("status") == ("completed" if filename == "filesystem.json" else "passed"), f"{filename}: probe did not complete successfully")
            if filename == "mutations.json":
                require(value.get("completed") is True and value.get("passed") is True
                        and set(value.get("requiredCases", [])) == MUTATION_CASES, "Mutation regression was incomplete")
            count = complete_cases(value, expected, filename)
            report["suites"].append({"name": probe, "passed": count, "failed": 0, "skipped": None})

        ui = read(evidence / "ui/probe-ui.json", "ui/probe-ui.json")
        require(ui.get("completed") is True and ui.get("passed") is True and ui.get("ownedStateRemoved") is True
                and not ui.get("pageErrors") and not ui.get("cleanupErrors") and ui.get("app", {}).get("sha256") == app_hash
                and ui.get("rclone", {}).get("sha256") == rclone_hash, "Normal WebView2 UI verification did not pass completely")
        count = complete_cases(ui, UI_CASES, "normal WebView2 UI", ui=True)
        for case in ui["cases"]:
            if case["name"] != "windows-drive-catalog":
                require(case.get("trustedClicks", 0) + case.get("trustedKeys", 0) > 0, "UI case did not use trusted pointer or keyboard input")
            screenshot = case.get("screenshot")
            require(screenshot and Path(screenshot).name == screenshot and not case.get("evidenceError"), "UI screenshot evidence is missing")
            record(evidence / "ui" / screenshot, "ui/" + screenshot)
        record(evidence / "ui/trace.zip", "ui/trace.zip")
        report["suites"].append({"name": "normal-installed-webview2-ui", "passed": count, "failed": 0, "skipped": None})
        smoke = read(evidence / "native-smoke.json", "native-smoke.json")
        require(smoke.get("passed") is True and smoke.get("exitCode") == 0 and smoke.get("version") == report["version"]
                and smoke.get("installer", {}).get("sha256") == package["sha256"], "The existing installed native UI smoke did not pass this revision")
        report["suites"].append({"name": "existing-native-ui-smoke", "passed": 1, "failed": 0, "skipped": None, "unit": "aggregate native UI receipt"})
        report["scope"] = ["Windows part of the unified desktop release, including scoped directory listing cancellation",
                           "Fresh Windows verification runner has no Swift setup; installed child PATH contains system directories only",
                           "Local filesystem and synthetic rclone alias remotes; no real cloud credentials or user data",
                           "Upgrade uses a published Windows stable baseline through 0.11.0 or the historical 0.9.0-r1 prerelease, pinned by asset ID and SHA-256, and verifies preserved saved state",
                           "NSIS downgrade check temporarily raises only the owned registry DisplayVersion to the next patch version",
                           "Publication requires successful Web, Mac, Linux and every Windows upgrade matrix job from this same source commit"]
        report["passed"] = True
    except Exception as error:
        report["error"] = {"type": type(error).__name__, "message": str(error), "traceback": traceback.format_exc()}
    report["verifiedAt"] = datetime.now(timezone.utc).isoformat()
    (evidence / "candidate-verification.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report.get(key) for key in ("passed", "version", "sourceCommit", "runID", "installerSha256", "suites", "error")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
