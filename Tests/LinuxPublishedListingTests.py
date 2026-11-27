#!/usr/bin/env python3
"""Test pinned release identity, extraction and runtime isolation without Linux binaries."""
from copy import deepcopy
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("linux_published_listing", ROOT / "Scripts/linux/verify-published-listing.py")
LINUX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINUX)


class LinuxPublishedListingTests(unittest.TestCase):
    def setUp(self):
        scratch = (ROOT / ".build-cache/python-tests" if os.environ.get("GITHUB_ACTIONS", "").lower() == "true"
                   else ROOT.parent / ".tmp")
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch, prefix="linux-oracle-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.asset = {"id": 749086416, "name": "Rclone_Browser_Next_0.11.0_Linux_amd64.deb",
                      "state": "uploaded", "size": 30556612,
                      "digest": "sha256:5492a55e7ca4b53f4b9886b3a7e36a60e4c63029ce8d7be0bc81edeeee747426",
                      "url": "https://api.github.com/repos/jason840709/RcloneBrowserNext/releases/assets/749086416",
                      "browser_download_url": "https://github.com/jason840709/RcloneBrowserNext/releases/download/v0.11.0/Rclone_Browser_Next_0.11.0_Linux_amd64.deb"}
        self.release = {"id": 445662659, "tag_name": "v0.11.0", "draft": False,
                        "prerelease": False, "published_at": "2026-11-14T23:14:15Z",
                        "immutable": False, "assets": [self.asset]}

    def test_official_linux_release_identity_matches(self):
        self.assertEqual(LINUX.validate_release(self.release), self.asset)

    def test_changed_release_identity_or_unpublished_status_is_rejected(self):
        for key, value in (("id", 1), ("tag_name", "v0.12.0"), ("draft", True),
                           ("prerelease", True), ("published_at", None)):
            with self.subTest(key=key):
                changed = deepcopy(self.release)
                changed[key] = value
                with self.assertRaises(AssertionError):
                    LINUX.validate_release(changed)

    def test_every_pinned_asset_field_is_required(self):
        for key, value in (("id", 2), ("state", "new"), ("size", 10), ("digest", "sha256:" + "a" * 64),
                           ("url", "https://example.test/asset"), ("browser_download_url", "https://example.test/deb")):
            with self.subTest(key=key):
                changed = deepcopy(self.release)
                changed["assets"][0][key] = value
                with self.assertRaises(AssertionError):
                    LINUX.validate_release(changed)

    def test_missing_or_duplicate_filename_is_rejected(self):
        for assets in ([], [deepcopy(self.asset), deepcopy(self.asset)]):
            with self.subTest(count=len(assets)):
                changed = deepcopy(self.release)
                changed["assets"] = assets
                with self.assertRaises(AssertionError):
                    LINUX.validate_release(changed)

    def test_only_a_byte_and_sha_verified_download_is_committed(self):
        payload = b"synthetic pinned deb"
        destination = self.root / "baseline.deb"
        with patch.dict(LINUX.BASELINE, bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest()), \
                patch.object(LINUX.HTTP, "request", return_value=io.BytesIO(payload)) as request:
            LINUX.download_asset(self.asset, destination)
        self.assertEqual(destination.read_bytes(), payload)
        self.assertFalse(destination.with_suffix(".download").exists())
        request.assert_called_once_with(self.asset["url"], binary=True)

    def test_truncated_oversized_or_altered_download_is_refused(self):
        original = b"correct deb"
        for index, payload in enumerate((b"short", original + b"extra", b"altered deb")):
            with self.subTest(payload=payload):
                destination = self.root / f"baseline-{index}.deb"
                with patch.dict(LINUX.BASELINE, bytes=len(original), sha256=hashlib.sha256(original).hexdigest()), \
                        patch.object(LINUX.HTTP, "request", return_value=io.BytesIO(payload)):
                    with self.assertRaises(AssertionError):
                        LINUX.download_asset(self.asset, destination)
                self.assertFalse(destination.exists())
                self.assertFalse(destination.with_suffix(".download").exists())

    def test_environment_has_no_old_library_sdk_account_or_token_injection(self):
        with patch.dict(os.environ, {"LD_LIBRARY_PATH": "/old/swift", "DYLD_LIBRARY_PATH": "/sdk",
                                   "SDKROOT": "/sdk", "RCLONE_CONFIG": "/real/config", "GH_TOKEN": "test-secret",
                                   "HOME": "/real/home", "PATH": "/swift/bin", "LANG": "C.UTF-8"}, clear=True):
            env = LINUX.isolated_environment(self.root / "environment")
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        self.assertEqual(env["LANG"], "C.UTF-8")
        self.assertEqual(set(env), {"PATH", "LANG", "HOME", "TMPDIR", "TMP", "TEMP", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"})
        for key in ("HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
            self.assertTrue(Path(env[key]).is_relative_to(self.root))
            self.assertTrue(Path(env[key]).is_dir())

    def test_dpkg_extracts_to_owned_directory_without_installing_the_app(self):
        deb, extracted = self.root / "baseline.deb", self.root / "extracted"

        def extract(argv, **kwargs):
            self.assertEqual(argv, ["dpkg-deb", "-x", str(deb), str(extracted)])
            helper = extracted / "usr/lib/app/runtime/rbn-engine"
            helper.parent.mkdir(parents=True)
            (helper.parent / "lib").mkdir()
            helper.write_bytes(b"synthetic helper")
            return subprocess.CompletedProcess(argv, 0)

        with patch.object(LINUX.subprocess, "run", side_effect=extract):
            helper = LINUX.extract_baseline(deb, extracted, {"PATH": "/usr/bin:/bin"})
        self.assertTrue(helper.is_relative_to(extracted))

    def test_extract_requires_an_original_helper_and_adjacent_libraries(self):
        extracted = self.root / "empty-extract"
        with patch.object(LINUX.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaisesRegex(AssertionError, "Expected one original helper"):
                LINUX.extract_baseline(self.root / "baseline.deb", extracted, {})

    def runtime(self, old_path=None, new_path=None, dynamic=None):
        extracted = self.root / "extracted"
        old_path = old_path or extracted / "usr/lib/app/runtime/lib/libswiftCore.so"
        new_path = new_path or Path("/lib/x86_64-linux-gnu/libc.so.6")
        dynamic = dynamic or "0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN/lib]\n"
        old_linked = f"libswiftCore.so => {old_path} (0x00001234)\nlibc.so.6 => /lib/libc.so.6 (0x00005678)\n"
        new_linked = f"libc.so.6 => {new_path} (0x00005678)\n"
        return dynamic, old_linked, new_linked, extracted

    def test_original_origin_runtime_and_separate_candidate_libraries_pass(self):
        result = LINUX.verify_dependency_separation(*self.runtime())
        self.assertEqual(result["oldRunpaths"], ["$ORIGIN/lib"])

    def test_old_swift_library_from_an_sdk_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, "outside its extracted runtime"):
            LINUX.verify_dependency_separation(*self.runtime(old_path=Path("/opt/swift/lib/libswiftCore.so")))

    def test_candidate_linked_to_any_old_library_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, "candidate unexpectedly depends"):
            LINUX.verify_dependency_separation(*self.runtime(new_path=self.root / "extracted/lib/libc.so.6"))
        dynamic, old, new, extracted = self.runtime()
        with self.assertRaisesRegex(AssertionError, "candidate unexpectedly depends"):
            LINUX.verify_dependency_separation(dynamic, old, new + "libFoundation.so => /opt/sdk/libFoundation.so (0x123)\n", extracted)

    def test_changed_origin_or_unresolved_libraries_are_rejected(self):
        with self.assertRaisesRegex(AssertionError, "original.*ORIGIN"):
            LINUX.verify_dependency_separation(*self.runtime(dynamic="(RUNPATH) Library runpath: [/opt/swift/lib]\n"))
        dynamic, old, new, extracted = self.runtime()
        with self.assertRaisesRegex(AssertionError, "unresolved runtime libraries"):
            LINUX.verify_dependency_separation(dynamic, old + "libmissing.so => not found\n", new, extracted)

    def test_each_helper_uses_the_exact_rclone_and_its_own_empty_configuration(self):
        calls, sessions = [], []

        class FakeClient:
            def __init__(self, binary, state, timeout):
                state.mkdir()
                self.state = state

            def call(self, method, *args):
                calls.append((method, args, self.state))
                return {"available": True}

            def finish(self):
                return {"exitCode": 0}

        protocol = SimpleNamespace(Client=FakeClient)
        rclone = self.root / "rclone"
        factory = LINUX.configured_client(protocol, rclone, sessions)
        binaries = [self.root / "old", self.root / "new"]
        for index, binary in enumerate(binaries):
            binary.write_bytes(str(index).encode())
            factory(binary, self.root / f"state-{index}", 30).finish()
        self.assertEqual(len(sessions), 2)
        self.assertNotEqual(calls[0][2], calls[1][2])
        for method, args, state in calls:
            self.assertEqual(method, "saveSettings")
            self.assertEqual(args[0]["rclonePath"], str(rclone))
            self.assertFalse(args[0]["autoCheckUpdates"])
            self.assertEqual(Path(args[0]["configPath"]).read_bytes(), b"")

    def test_linux_reuses_the_exact_original_and_expanded_fixture_bytes(self):
        self.assertEqual(len(LINUX.ORACLE.ORIGINAL_FILES) + len(LINUX.ORACLE.ORIGINAL_DIRECTORIES), 34)
        self.assertEqual(len(LINUX.ORACLE.EXTENDED_FILES) + len(LINUX.ORACLE.EXTENDED_DIRECTORIES), 143)
        self.assertEqual(LINUX.ORACLE.fixture_sha256(LINUX.ORACLE.ORIGINAL_FILES, LINUX.ORACLE.ORIGINAL_DIRECTORIES),
                         "4dd2769775e04d148121f41ff65cfcfd91781ada35abbad70648f5b137cf1887")


if __name__ == "__main__":
    unittest.main()
