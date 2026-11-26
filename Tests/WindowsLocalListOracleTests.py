#!/usr/bin/env python3
"""Check physical-fixture integrity and strict independent helper comparison."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ORACLE = load("windows_listing_oracle", ROOT / "Tests/windows-local-list-oracle.py")
PROVENANCE = load("windows_runtime_provenance", ROOT / "Scripts/windows/probe-runtime-provenance.py")
FILES, DIRECTORIES = ("a.txt", "b.txt"), ("folder",)
ENTRIES = [{"name": "folder", "isDir": True, "size": 0},
           {"name": "a.txt", "isDir": False, "size": 1},
           {"name": "b.txt", "isDir": False, "size": 2}]


class WindowsLocalListOracleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT.parent / ".tmp", prefix="oracle-receipt-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = []
        self.responses = {"swift.exe": deepcopy(ENTRIES), "rust.exe": deepcopy(ENTRIES)}
        test = self

        class Client:
            def __init__(self, binary, state, timeout):
                self.binary = binary
                test.calls.append((binary.name, state, timeout))

            def call(self, method, params):
                test.assertEqual(method, "list")
                test.assertIsNone(params["remote"])
                test.assertEqual({item.name for item in Path(params["path"]).iterdir()},
                                 set(FILES) | set(DIRECTORIES))
                return deepcopy(test.responses[self.binary.name])

            def finish(self):
                return {"exitCode": 0}

        self.client = Client

    def compare(self):
        return ORACLE.compare_group(self.client, Path("swift.exe"), Path("rust.exe"), self.root / "group",
                                    FILES, DIRECTORIES, "unit", {})

    def verify(self, value):
        return ORACLE.verify_group_receipt(value, FILES, DIRECTORIES, "unit")

    def test_original_34_fixture_is_unchanged(self):
        self.assertEqual(len(ORACLE.ORIGINAL_FILES), 29)
        self.assertEqual(len(ORACLE.ORIGINAL_DIRECTORIES), 5)
        self.assertEqual(ORACLE.fixture_sha256(ORACLE.ORIGINAL_FILES, ORACLE.ORIGINAL_DIRECTORIES),
                         "4dd2769775e04d148121f41ff65cfcfd91781ada35abbad70648f5b137cf1887")

    def test_expanded_names_are_legal_distinct_windows_leaves(self):
        names = ORACLE.EXTENDED_FILES + ORACLE.EXTENDED_DIRECTORIES
        self.assertEqual(len(names), 133)
        self.assertEqual(len({name.casefold() for name in names}), len(names))
        self.assertEqual(set(ORACLE.EXTENDED_FILE_GROUPS),
                         {"ascii_numbers", "punctuation", "case", "latin_and_combining", "width", "scripts",
                          "unicode_numbers", "emoji", "long_combining_boundaries"})
        for name in names:
            with self.subTest(name=name):
                self.assertFalse(set(name) & set('<>:"/\\|?*'))
                self.assertFalse(any(ord(character) < 32 for character in name))
                self.assertFalse(name.endswith((" ", ".")))
                self.assertLessEqual(len(name.encode("utf-16-le")) // 2, 255)
                self.assertNotIn(name.partition(".")[0].upper(),
                                 {"CON", "PRN", "AUX", "NUL"} | {f"{kind}{number}" for kind in ("COM", "LPT") for number in range(1, 10)})

    def test_long_combining_cases_keep_exact_codepoints(self):
        self.assertEqual(ORACLE.EXTENDED_FILE_GROUPS["long_combining_boundaries"], (
            "Ä" + "\u0327" * 65 + "\u200dAǺ2",
            "A\u0308" + "\u0327" * 65 + "\u200dAA\u030a\u030102",
            "Ä" + "\u0308" * 62 + "\u093eã",
            "A\u0308" + "\u0308" * 62 + "\u093ea\u0303",
        ))

    def test_helpers_independently_list_the_same_physical_fixture(self):
        receipt = self.compare()
        self.assertEqual(self.verify(receipt), 3)
        self.assertEqual([call[0] for call in self.calls], ["swift.exe", "rust.exe"])
        self.assertNotEqual(self.calls[0][1], self.calls[1][1])

    def test_real_response_order_is_never_rewritten(self):
        self.responses["rust.exe"] = [deepcopy(ENTRIES[0]), deepcopy(ENTRIES[2]), deepcopy(ENTRIES[1])]
        receipt = self.compare()
        self.assertFalse(receipt["passed"])
        self.assertEqual(receipt["rust"], ["folder", "b.txt", "a.txt"])
        with self.assertRaises(AssertionError):
            self.verify(receipt)

    def test_metadata_difference_fails_even_when_name_order_matches(self):
        self.responses["rust.exe"][1]["size"] = 99
        receipt = self.compare()
        self.assertEqual(receipt["swift"], receipt["rust"])
        self.assertFalse(receipt["passed"])
        with self.assertRaises(AssertionError):
            self.verify(receipt)

    def test_missing_candidate_entry_cannot_hide_behind_zipped_differences(self):
        self.responses["rust.exe"].pop()
        receipt = self.compare()
        self.assertEqual(receipt["fieldDifferences"], [])
        with self.assertRaises(AssertionError):
            self.verify(receipt)

    def test_incomplete_original_listing_is_an_infrastructure_failure(self):
        self.responses["swift.exe"].pop()
        with self.assertRaisesRegex(RuntimeError, "complete physical fixture"):
            self.compare()

    def test_altered_receipt_fixture_identity_or_metadata_is_rejected(self):
        valid = self.compare()
        mutations = {
            "fixtureSha256": "a" * 64, "entries": 2, "candidateEntries": 2,
            "group": "another-group", "swift": ["folder", "b.txt", "a.txt"],
            "rustEntries": [{"name": "folder", "isDir": True, "size": 1}, *ENTRIES[1:]],
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                altered = deepcopy(valid)
                altered[key] = value
                with self.assertRaises(AssertionError):
                    self.verify(altered)

    def test_icu_export_names_are_read_without_loading_a_dll(self):
        # Minimal PE32+ image with one section and two export names.
        image = bytearray(0x500)
        image[:2] = b"MZ"
        struct.pack_into("<I", image, 0x3c, 0x80)
        image[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<HH", image, 0x84, 0x8664, 1)
        struct.pack_into("<H", image, 0x94, 240)
        struct.pack_into("<H", image, 0x98, 0x20b)
        struct.pack_into("<II", image, 0x108, 0x1000, 0x100)
        struct.pack_into("<IIII", image, 0x190, 0x300, 0x1000, 0x300, 0x200)
        struct.pack_into("<I", image, 0x218, 2)
        struct.pack_into("<I", image, 0x220, 0x1040)
        struct.pack_into("<II", image, 0x240, 0x1060, 0x1080)
        for offset, value in ((0x260, b"u_getVersion_74\0"), (0x280, b"ucol_open_74\0")):
            image[offset:offset + len(value)] = value
        path = self.root / "fake-icu.dll"
        path.write_bytes(image)
        self.assertEqual(PROVENANCE.pe_exports(path), ("0x8664", ["u_getVersion_74", "ucol_open_74"]))


if __name__ == "__main__":
    unittest.main()
