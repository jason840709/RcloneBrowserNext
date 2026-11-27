#!/usr/bin/env python3
"""Reject wrong private ICU runtimes using synthetic files; no native tools run."""
from copy import deepcopy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UNICODE = load("private_unicode", ROOT / "Scripts/windows/unicode-runtime.py")
BUILDER = load("private_unicode_builder", ROOT / "Scripts/windows/build-unicode-runtime.py")
RUNNER = load("private_unicode_runner", ROOT / "Scripts/test-rust.py")
PROBE = load("private_unicode_probe", ROOT / "Scripts/windows/probe-runtime-provenance.py")


class WindowsUnicodeRuntimeTests(unittest.TestCase):
    def setUp(self):
        task = ROOT.parent if ROOT.name == "01_原始碼" else ROOT
        scratch = ROOT / ".build-cache/python-tests" if os.environ.get("GITHUB_ACTIONS", "").lower() == "true" else task / ".tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch, prefix="unicode-runtime-test-")
        self.addCleanup(self.temp.cleanup)
        self.area = Path(self.temp.name)
        self.library = self.area / "runtime/RBNUnicode.dll"
        self.library.parent.mkdir()
        self.library.write_bytes(b"synthetic private ICU, not an executable")
        self.receipt = {"schemaVersion": 1, "sourcePin": UNICODE.load_pin(), "machine": "0x8664",
                        "library": {"name": "RBNUnicode.dll", "bytes": self.library.stat().st_size, "sha256": UNICODE.digest(self.library)},
                        "apiVersion": [74, 1, 0, 0], "requiredExports": list(UNICODE.REQUIRED_EXPORTS), "collatorOpened": True,
                        "build": {"language": "CXX", "runtime": "MT", "embeddedData": True,
                                  "wrapperSHA256": UNICODE.wrapper_digest(), "wrapperNewlines": "LF",
                                  "wrapperRawSHA256": UNICODE.digest(UNICODE.WRAPPER), "pinRawSHA256": UNICODE.digest(UNICODE.PIN_PATH),
                                  "pinCanonicalSHA256": UNICODE.pin_digest(UNICODE.load_pin()),
                                  "compilerID": "Clang", "frontendVariant": "MSVC",
                                  "compilerVersion": "19.synthetic", "cmakeVersion": "cmake version 3.synthetic",
                                  "sourceTree": {"sha256": "a" * 64, "files": 3}}}
        self.package = {"unicodeRuntime": self.receipt, "libraries": [self.receipt["library"]], "systemLibraries": ["KERNEL32.dll"]}
        (self.library.parent / "unicode-runtime.json").write_text(json.dumps(self.receipt), encoding="utf-8")

    def test_pin_identifies_exact_source_and_suffixed_abi(self):
        pin = UNICODE.load_pin()
        self.assertEqual(pin["commit"], "7e255a994ec26a08214f8fea2fdaf60b296e1f22")
        self.assertEqual(pin["archiveBytes"], 26058201)
        self.assertEqual(pin["archiveSHA256"], "72993b303a16ce7b8b5dac801c60282965ab79eeab3f3aad9986bb70f9c164bb")
        self.assertEqual(pin["requiredExports"], ["u_getVersion_74", "ucol_open_74", "ucol_close_74", "ucol_setAttribute_74", "ucol_strcoll_74"])

    def test_verified_private_library_package_passes(self):
        self.assertEqual(UNICODE.validate_package(self.package, directory=self.library.parent), self.receipt)

    def test_native_probe_requires_all_five_suffixed_exports_and_data(self):
        exports = list(UNICODE.REQUIRED_EXPORTS) + ["u_getVersion", "ucol_open", "ucol_getVersion_74"]
        measured = {"icuVersion": [74, 1, 0, 0], "loadedPath": str(self.library),
                    "probeCollator": {"opened": True, "errorCode": 0}}
        with patch.object(PROBE, "pe_exports", return_value=("0x8664", exports)), \
                patch.object(PROBE, "icu_probe", return_value=measured) as inspect:
            self.assertEqual(PROBE.private_unicode_record(self.library)["apiVersion"], [74, 1, 0, 0])
            self.assertTrue(all(name.endswith("_74") for name in inspect.call_args.args[1]))
        with patch.object(PROBE, "pe_exports", return_value=("0x8664", exports[1:])), \
                patch.object(PROBE, "icu_probe") as inspect:
            with self.assertRaisesRegex(AssertionError, "Missing pinned private ICU exports"):
                PROBE.private_unicode_record(self.library)
            inspect.assert_not_called()

    def test_missing_or_changed_private_dll_is_rejected(self):
        self.library.unlink()
        with self.assertRaisesRegex(AssertionError, "differs from its verified"):
            UNICODE.validate_package(self.package, directory=self.library.parent)
        self.library.write_bytes(b"different DLL")
        with self.assertRaises(AssertionError):
            UNICODE.validate_package(self.package, directory=self.library.parent)

    def test_wrong_version_arch_exports_or_missing_embedded_data_is_rejected(self):
        for key, value in (("apiVersion", [64, 2, 0, 0]), ("apiVersion", [74, 1, False, 0]), ("machine", "0x014c"),
                           ("requiredExports", list(UNICODE.REQUIRED_EXPORTS[:-1])), ("collatorOpened", False)):
            with self.subTest(key=key):
                changed = deepcopy(self.receipt)
                changed[key] = value
                with self.assertRaises(AssertionError):
                    UNICODE.validate_receipt(changed)

    def test_wrong_source_pin_or_build_configuration_is_rejected(self):
        changes = (("sourcePin", "commit", "b" * 40), ("build", "runtime", "MD"),
                   ("build", "language", "Swift"), ("build", "embeddedData", False),
                   ("build", "wrapperSHA256", "b" * 64), ("build", "sourceTree", {}))
        for section, key, value in changes:
            with self.subTest(section=section, key=key):
                changed = deepcopy(self.receipt)
                changed[section][key] = value
                with self.assertRaises(AssertionError):
                    UNICODE.validate_receipt(changed)

    def test_missing_duplicate_or_wrong_manifest_identity_is_rejected(self):
        variants = [[], [self.receipt["library"], self.receipt["library"]],
                    [{**self.receipt["library"], "sha256": "b" * 64}]]
        for libraries in variants:
            with self.subTest(libraries=libraries):
                with self.assertRaises(AssertionError):
                    UNICODE.validate_package({**self.package, "libraries": libraries})
        with self.assertRaises(AssertionError):
            UNICODE.validate_package({"libraries": [], "systemLibraries": []})

    def test_system_icu_dependency_is_rejected(self):
        for name in ("icu.dll", "icuuc.dll", "icuin.dll", "icuuc74.dll", "icudt74.dll", "icuio74.dll"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(AssertionError, "system ICU"):
                    UNICODE.validate_package({**self.package, "systemLibraries": [name]})

    def test_every_cargo_artifact_and_release_receive_exact_same_dll(self):
        release = self.area / "cargo/release"
        deps = release / "deps"
        deps.mkdir(parents=True)
        exes = [deps / "first.exe", deps / "second.exe"]
        for exe in exes:
            exe.write_bytes(b"synthetic Rust executable")
        launcher = self.area / "launcher.exe"
        launcher.write_bytes(b"synthetic unchanged launcher")
        value, placements = RUNNER.place_windows_runtime(exes, release, launcher, self.library)
        self.assertEqual(value, self.receipt)
        self.assertEqual(len(placements), 2)
        for directory in (deps, release):
            self.assertEqual((directory / "RBNUnicode.dll").read_bytes(), self.library.read_bytes())
            self.assertEqual((directory / "rbn-process-launcher.exe").read_bytes(), launcher.read_bytes())
        as_windows = lambda path: "D:/synthetic/" + Path(path).relative_to(self.area).as_posix()
        core = {"unicodeRuntime": value,
                "unicodeRuntimePlacements": [{**item, "path": as_windows(item["path"])} for item in placements],
                "executables": [{"executablePath": as_windows(exe), "unicodeRuntimePath": as_windows(exe.parent / "RBNUnicode.dll")} for exe in exes]}
        self.assertEqual(UNICODE.validate_core(core, self.package), self.receipt)

    def test_core_must_identify_all_adjacent_dlls_and_match_package(self):
        placement = {"path": "D:/target/release/deps/RBNUnicode.dll", **self.receipt["library"]}
        core = {"unicodeRuntime": self.receipt, "unicodeRuntimePlacements": [placement],
                "executables": [{"executablePath": "D:/target/release/deps/first.exe", "unicodeRuntimePath": placement["path"]}]}
        for key, value in (("unicodeRuntime", {}), ("unicodeRuntimePlacements", []),
                           ("unicodeRuntimePlacements", [placement, placement]),
                           ("executables", []), ("executables", [{"executablePath": "D:/target/release/deps/first.exe", "unicodeRuntimePath": "D:/unrecorded/RBNUnicode.dll"}])):
            with self.subTest(key=key):
                with self.assertRaises(AssertionError):
                    UNICODE.validate_core({**core, key: value}, self.package)

    def test_recorded_dll_in_another_executables_directory_is_rejected(self):
        first = {"path": "D:/target/first/RBNUnicode.dll", **self.receipt["library"]}
        second = {"path": "D:/target/second/RBNUnicode.dll", **self.receipt["library"]}
        core = {"unicodeRuntime": self.receipt, "unicodeRuntimePlacements": [first, second],
                "executables": [{"executablePath": "D:/target/first/test.exe", "unicodeRuntimePath": second["path"]}]}
        self.assertIn(core["executables"][0]["unicodeRuntimePath"], [item["path"] for item in core["unicodeRuntimePlacements"]])
        with self.assertRaisesRegex(AssertionError, "own adjacent"):
            UNICODE.validate_core(core, self.package)

    def test_builder_configures_only_cpp_static_crt_and_original_data(self):
        with patch.object(BUILDER.shutil, "which", return_value="C:/LLVM/bin/clang-cl.exe"):
            configure, build = BUILDER.cmake_commands(self.area / "source", self.area / "build", 2)
        self.assertIn("-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded", configure)
        self.assertEqual(build[-2:], ["--parallel", "2"])
        text = UNICODE.WRAPPER.read_text(encoding="utf-8")
        self.assertIn("project(RBNUnicodeRuntime LANGUAGES CXX)", text)
        self.assertNotIn("LANGUAGES CXX Swift", text)
        for flag in ("U_DISABLE_RENAMING=0", "U_COMBINED_IMPLEMENTATION", "USE_PACKAGE_DATA=1", "APPLE_ICU_CHANGES=1", "OUTPUT_NAME RBNUnicode"):
            self.assertIn(flag, text)
        with patch.object(BUILDER.shutil, "which", return_value="C:/Program Files/Swift/Toolchains/6.1.2/usr/bin/clang-cl.exe"):
            with self.assertRaisesRegex(AssertionError, "standalone LLVM"):
                BUILDER.cmake_commands(self.area / "source", self.area / "build", 2)

    def source_archive(self):
        archive = self.area / "source.tar.gz"
        root = "icu-synthetic"
        files = {"icuSources/include/_foundation_unicode/uvernum.h":
                 b"#define U_ICU_VERSION_MAJOR_NUM 74\n#define U_ICU_VERSION_MINOR_NUM 1\n#define U_ICU_VERSION_PATCHLEVEL_NUM 0\n",
                 "icuSources/common/data.cpp": b"int x;"}
        with tarfile.open(archive, "w:gz") as package:
            for name, data in files.items():
                item = tarfile.TarInfo(root + "/" + name)
                item.size = len(data)
                package.addfile(item, io.BytesIO(data))
        pin = {**UNICODE.load_pin(), "sourceRoot": root, "archiveBytes": archive.stat().st_size,
               "archiveSHA256": UNICODE.digest(archive)}
        return archive, pin

    def test_cached_source_is_rechecked_against_archive_without_rewriting(self):
        archive, pin = self.source_archive()
        source, tree = BUILDER.verified_source(archive, self.area / "extracted", pin)
        path = source / "icuSources/common/data.cpp"
        before = path.stat().st_mtime_ns
        self.assertEqual(BUILDER.verified_source(archive, self.area / "extracted", pin), (source, tree))
        self.assertEqual(path.stat().st_mtime_ns, before)
        path.write_bytes(b"int y;")
        with self.assertRaisesRegex(AssertionError, "differs from its pinned archive"):
            BUILDER.verified_source(archive, self.area / "extracted", pin)

    def test_changed_archive_pin_hard_fails_before_extraction(self):
        archive, pin = self.source_archive()
        with self.assertRaisesRegex(AssertionError, "fixed pin"):
            BUILDER.verified_source(archive, self.area / "should-not-exist", {**pin, "archiveSHA256": "b" * 64})
        self.assertFalse((self.area / "should-not-exist").exists())

    def test_source_download_rejects_repack_instead_of_changing_pin(self):
        payload = b"wrong upstream bytes"
        path = self.area / "download.tar.gz"
        pin = {**UNICODE.load_pin(), "archiveBytes": len(payload), "archiveSHA256": "b" * 64}
        opener = unittest.mock.Mock()
        opener.open.return_value = io.BytesIO(payload)
        with patch.object(BUILDER.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(AssertionError, "fixed pin"):
                BUILDER.download_source(path, pin)
        self.assertFalse(path.exists())
        self.assertEqual(path.with_suffix(".download").read_bytes(), payload)
        self.assertEqual(pin["archiveSHA256"], "b" * 64)

    def test_redirect_drops_token_and_rejects_unapproved_hosts(self):
        request = urllib.request.Request("https://api.github.com/source", headers={"Authorization": "Bearer synthetic"})
        handler = BUILDER.SourceRedirect()
        redirected = handler.redirect_request(request, None, 302, "", {}, "https://codeload.github.com/source")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(AssertionError):
            handler.redirect_request(request, None, 302, "", {}, "https://example.test/source")


if __name__ == "__main__":
    unittest.main()
