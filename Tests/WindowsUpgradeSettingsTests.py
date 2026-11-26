#!/usr/bin/env python3
"""Check upgrade expectations against the published Swift migration fixtures."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("windows_installation", ROOT / "Scripts/windows/verify-installation.py")
INSTALLATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLATION)
GOLDEN = json.loads((ROOT / "Sources/Rust/tests/fixtures/settings-0.11.0.json").read_text(encoding="utf-8"))


class WindowsUpgradeSettingsTests(unittest.TestCase):
    def previous(self, schema, scale):
        value = deepcopy(GOLDEN["defaults"])
        value.update(settingsSchemaVersion=schema, interfaceScale=scale, language="ja", theme="blue-light")
        value.pop("bounceDockOnCompletion")
        value.pop("retryScope")
        return value

    def test_schema6_scale_choices_match_published_swift_goldens(self):
        cases = [case for case in GOLDEN["cases"] if case["name"].startswith("schema-6-scale-")]
        self.assertEqual(len(cases), 6)
        for case in cases:
            with self.subTest(case=case["name"]):
                previous = self.previous(6, case["raw"]["interfaceScale"])
                original = deepcopy(previous)
                expected = INSTALLATION.expected_published_upgrade_settings(previous)
                self.assertEqual(expected["interfaceScale"],
                                 case["expected"].get("interfaceScale", GOLDEN["defaults"]["interfaceScale"]))
                self.assertEqual(expected["settingsSchemaVersion"], 7)
                self.assertEqual(previous, original)
                for key, value in previous.items():
                    if key not in {"settingsSchemaVersion", "interfaceScale"}:
                        self.assertEqual(expected[key], value, key)
                self.assertEqual(set(expected) - set(previous), {"bounceDockOnCompletion", "retryScope"})

    def test_schema7_keeps_every_existing_field_and_scale(self):
        for scale in (80, 90, 100, 110, 120, 125, 135):
            with self.subTest(scale=scale):
                previous = self.previous(7, scale)
                previous.update(bounceDockOnCompletion=False, retryScope="full")
                self.assertEqual(INSTALLATION.expected_published_upgrade_settings(previous), previous)

    def test_unsupported_or_noninteger_schema_is_rejected(self):
        for schema in (None, False, 0, 5, 8, "6", 6.0):
            with self.subTest(schema=schema):
                with self.assertRaisesRegex(AssertionError, "Unsupported published baseline settings schema"):
                    INSTALLATION.expected_published_upgrade_settings(self.previous(schema, 125))
        missing = self.previous(6, 125)
        del missing["settingsSchemaVersion"]
        with self.assertRaises(AssertionError):
            INSTALLATION.expected_published_upgrade_settings(missing)

    def test_explicit_newer_settings_are_never_replaced_with_defaults(self):
        previous = self.previous(6, 125)
        previous.update(bounceDockOnCompletion=False, retryScope="full")
        expected = INSTALLATION.expected_published_upgrade_settings(previous)
        self.assertFalse(expected["bounceDockOnCompletion"])
        self.assertEqual(expected["retryScope"], "full")
        self.assertEqual(expected["interfaceScale"], 135)

    def test_expected_nested_settings_do_not_alias_old_bootstrap(self):
        previous = self.previous(6, 125)
        expected = INSTALLATION.expected_published_upgrade_settings(previous)
        expected["defaultTransferOptions"]["include"].append("changed")
        self.assertEqual(previous["defaultTransferOptions"]["include"], [])


if __name__ == "__main__":
    unittest.main()
