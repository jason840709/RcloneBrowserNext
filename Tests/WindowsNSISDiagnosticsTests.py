#!/usr/bin/env python3
"""Portable source/pin checks for NSIS error-console diagnostics; no NSIS runs."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pinned_nsis_diagnostics", ROOT / "Scripts/windows/nsis-diagnostics.py")
NSIS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NSIS)


class WindowsNSISDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        task = ROOT.parent if ROOT.name == "01_原始碼" else ROOT
        scratch = ROOT / ".build-cache/python-tests" if os.environ.get("GITHUB_ACTIONS", "").lower() == "true" else task / ".tmp"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch, prefix="nsis-diagnostic-test-")
        self.addCleanup(self.temp.cleanup)
        self.area = Path(self.temp.name)
        for name in ("Compat/cli/package.json", "Compat/cli/package-lock.json",
                     "Compat/desktop/tauri.windows.conf.json", NSIS.HOOK_RELATIVE):
            path = self.area / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())
        self.hook = NSIS.canonical((ROOT / NSIS.HOOK_RELATIVE).read_bytes())
        self.original = NSIS.original_macro(self.hook)

    def test_hook_strips_to_exact_official_cli_macro(self):
        result = NSIS.verify_source(self.area)
        self.assertEqual(result["cliVersion"], "2.12.3")
        self.assertEqual(hashlib.sha256(self.original.encode()).hexdigest(),
                         "a1ffd19992f3ddc58540a8f86b097a94c40491cee76b4a2cf50abff6bfa14f33")
        self.assertTrue(result["originalControlFlowPreserved"])

    def test_crlf_checkout_preserves_canonical_pin_and_distinguishes_raw_sha(self):
        path = self.area / NSIS.HOOK_RELATIVE
        path.write_bytes(self.hook.replace("\n", "\r\n").encode())
        result = NSIS.verify_source(self.area)
        self.assertNotEqual(result["hook"]["rawSHA256"], result["hook"]["canonicalLFSHA256"])
        self.assertEqual(result["hook"]["canonicalLFSHA256"], hashlib.sha256(self.hook.encode()).hexdigest())

    def test_original_api_control_flow_and_prompt_tampering_fail(self):
        for old, new in (("RmForceShutdown", "0"), ("Abort\n", "Return\n"),
                         ("$0 = 0", "$0 != 0"), ('"$R1$\\n"', '"changed prompt$\\n"')):
            with self.subTest(original=old):
                with self.assertRaises(AssertionError):
                    NSIS.original_macro(self.hook.replace(old, new, 1))

    def test_diagnostic_cannot_move_before_existing_silent_error_message(self):
        addition = NSIS.INSERTIONS["append-existing-error-console"]
        moved = self.hook.replace(addition, "")
        moved = moved.replace("  !define UniqueID", addition + "  !define UniqueID", 1)
        with self.assertRaisesRegex(AssertionError, "outside the existing silent failure"):
            NSIS.original_macro(moved)

    def test_diagnostic_cannot_modify_registers_or_add_calls(self):
        for old, new in (("StrCpy $RbnRmShutdownCode $0", "StrCpy $0 0"),
                         ("ClearErrors", "Sleep 250"),
                         ("FileWrite $0 'RBN_NSIS", "System::Call 'RBN_NSIS")):
            with self.subTest(original=old):
                with self.assertRaises(AssertionError):
                    NSIS.original_macro(self.hook.replace(old, new, 1))

    def test_missing_duplicate_or_external_code_is_rejected(self):
        block = NSIS.INSERTIONS["save-shutdown-returncode"]
        for changed in (self.hook.replace(block, ""), self.hook.replace(block, block + block),
                        self.hook + "Quit\n"):
            with self.subTest(changed=changed[-24:]):
                with self.assertRaises(AssertionError):
                    NSIS.original_macro(changed)

    def test_cli_manifest_and_both_lock_entries_must_match_pin(self):
        paths = ["Compat/cli/package.json", "Compat/cli/package-lock.json"]
        for location in ("manifest", "lock-root", "lock-cli"):
            with self.subTest(location=location):
                path = self.area / paths[location != "manifest"]
                raw = path.read_bytes()
                data = json.loads(raw)
                if location == "manifest":
                    data["dependencies"]["@tauri-apps/cli"] = "2.12.4"
                elif location == "lock-root":
                    data["packages"][""]["dependencies"]["@tauri-apps/cli"] = "2.12.4"
                else:
                    data["packages"]["node_modules/@tauri-apps/cli"]["version"] = "2.12.4"
                path.write_text(json.dumps(data))
                with self.assertRaisesRegex(AssertionError, "pinned Tauri CLI"):
                    NSIS.verify_source(self.area)
                path.write_bytes(raw)

    def test_missing_installer_hook_configuration_is_rejected(self):
        path = self.area / "Compat/desktop/tauri.windows.conf.json"
        data = json.loads(path.read_text())
        del data["bundle"]["windows"]["nsis"]
        path.write_text(json.dumps(data))
        with self.assertRaises((AssertionError, KeyError)):
            NSIS.verify_source(self.area)

    def generated_fixture(self):
        # Other utils are synthetic here. The real build checks the full pinned
        # official utils SHA too, before package-compat may publish its receipt.
        utils = self.area / "generated/utils.nsh"
        utils.parent.mkdir(exist_ok=True)
        canonical = "; synthetic surrounding helpers\n" + self.original
        utils.write_bytes(b"\xef\xbb\xbf" + canonical.replace("\n", "\r\n").encode())
        dollar = chr(36)
        call = '!insertmacro CheckIfAppIsRunning "' + dollar + 'INSTDIR\\' + dollar + '{MAINBINARYNAME}.exe" "' + dollar + '{PRODUCTNAME}"\n'
        installer = '!include "utils.nsh"\n!include "C:\\owned\\nsis-diagnostics.nsh"\n' + call + call
        utils.with_name("installer.nsi").write_text(installer)
        return utils, hashlib.sha256(canonical.encode()).hexdigest()

    def test_generated_bom_crlf_original_macro_and_two_call_sites_pass(self):
        utils, synthetic_hash = self.generated_fixture()
        with patch.object(NSIS, "ORIGINAL_UTILS_SHA256", synthetic_hash):
            self.assertEqual(NSIS.verify_generated(utils)["originalCallSites"], 2)

    def test_actual_generated_utils_full_hash_or_original_macro_mismatch_fails(self):
        utils, synthetic_hash = self.generated_fixture()
        with self.assertRaisesRegex(AssertionError, "actually generated"):
            NSIS.verify_generated(utils)
        with patch.object(NSIS, "ORIGINAL_UTILS_SHA256", synthetic_hash):
            utils.write_bytes(utils.read_bytes().replace(b"RmShutdown", b"RmRestart"))
            with self.assertRaisesRegex(AssertionError, "actually generated"):
                NSIS.verify_generated(utils)

    def test_generated_hook_order_or_missing_call_site_fails(self):
        utils, synthetic_hash = self.generated_fixture()
        installer = utils.with_name("installer.nsi")
        raw = installer.read_text()
        for changed in (raw.replace('!include "utils.nsh"\n', "") + '!include "utils.nsh"\n',
                        raw[:raw.rfind("!insertmacro")]):
            with self.subTest(changed=changed[-40:]):
                installer.write_text(changed)
                with patch.object(NSIS, "ORIGINAL_UTILS_SHA256", synthetic_hash):
                    with self.assertRaisesRegex(AssertionError, "hook order"):
                        NSIS.verify_generated(utils)

    def test_new_instructions_preserve_original_registers_stack_and_io_error_flag(self):
        # Execute only the small NSIS diagnostic insertion with a portable
        # interpreter. This is not a Windows/NSIS native compiler result.
        code = [line.strip() for line in NSIS.INSERTIONS["append-existing-error-console"].splitlines()
                if line.strip() and not line.strip().startswith(";")]
        for old_error in (False, True):
            for write_fails in (False, True):
                with self.subTest(old_error=old_error, write_fails=write_fails):
                    registers = {str(i): 100 + i for i in range(10)}
                    registers.update({"R" + str(i): "old-" + str(i) for i in range(10)})
                    original_registers, stack = dict(registers), ["original caller stack"]
                    variables, error, writes, pc = {}, old_error, [], 0
                    while pc < len(code):
                        line = code[pc]
                        if line.startswith("StrCpy "):
                            _, variable, value = line.split()
                            variables[variable] = value
                        elif line == "IfErrors 0 +2":
                            if not error:
                                pc += 1
                        elif line.startswith("FileWrite "):
                            writes.append(line)
                            error = write_fails
                        elif line == chr(36) + "{If} $RbnRmWriteHadError = 1":
                            if variables["$RbnRmWriteHadError"] != "1":
                                pc = code.index(chr(36) + "{Else}")
                        elif line == chr(36) + "{Else}":
                            pc = code.index(chr(36) + "{EndIf}")
                        elif line == "SetErrors":
                            error = True
                        elif line == "ClearErrors":
                            error = False
                        elif line != chr(36) + "{EndIf}":
                            self.fail("Unexpected diagnostic instruction: " + line)
                        pc += 1
                    self.assertEqual(error, old_error)
                    self.assertEqual(registers, original_registers)
                    self.assertEqual(stack, ["original caller stack"])
                    self.assertEqual(len(writes), 1)
                    self.assertIn('target="', writes[0])
                    for field in ("shutdown=$RbnRmShutdownCode", "needed=$1", "count=$2", "rebootReasons=$3"):
                        self.assertIn(field, writes[0])
        capture = self.hook.index("StrCpy $RbnRmShutdownCode $0")
        self.assertLess(self.hook.index("RmShutdown"), capture)
        self.assertLess(capture, self.hook.index("AttachConsole"))
        between = self.hook[self.hook.index("RmGetList"):self.hook.index("RmShutdown")]
        self.assertNotIn("FileWrite", between)
        self.assertNotIn("System::Call", NSIS.INSERTIONS["append-existing-error-console"])
        self.assertNotIn("Push", "".join(NSIS.INSERTIONS.values()))
        self.assertNotIn("Pop", "".join(NSIS.INSERTIONS.values()))


if __name__ == "__main__":
    unittest.main()
