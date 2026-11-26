#!/usr/bin/env python3
"""Require the second Windows OS gate to reuse the complete original verification."""
import ast
import fnmatch
from pathlib import Path
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/macos.yml").read_text(encoding="utf-8")
VERSION = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]


def job(name):
    sections = list(re.finditer(r"(?m)^  ([A-Za-z][A-Za-z0-9_-]*):\n", WORKFLOW))
    for index, section in enumerate(sections):
        if section[1] == name:
            return WORKFLOW[section.start():sections[index + 1].start() if index + 1 < len(sections) else len(WORKFLOW)]
    raise AssertionError(f"Missing workflow job: {name}")


class WorkflowOracleGateTests(unittest.TestCase):
    def test_original_seventeen_baselines_and_server2025_are_retained(self):
        original = job("windows-verify")
        values = ast.literal_eval(re.search(r"(?m)^        baseline: (\[.*\])$", original)[1])
        self.assertEqual(values, ["0.7.0", "0.8.0", "0.8.1", "0.9.0", "0.9.0-r1", "0.9.1", "0.9.2",
                                  "0.9.3", "0.9.4", "0.9.5", "0.9.6", "0.10.1", "0.10.2", "0.10.3",
                                  "0.10.4", "0.10.6", "0.11.0"])
        self.assertIn("    runs-on: windows-2025\n", original)
        self.assertIn("      fail-fast: false\n", original)

    def test_2022_steps_equal_the_entire_existing_verification(self):
        original = job("windows-verify").split("    steps:\n", 1)[1]
        expected = original.replace("${{ matrix.baseline }}", "0.11.0").replace(
            "RcloneBrowserNext-Windows-verification-0.11.0", "RcloneBrowserNext-Windows-2022-verification-0.11.0")
        self.assertEqual(job("windows-verify-2022").split("    steps:\n", 1)[1].strip(), expected.strip())

    def test_2022_uses_only_published_011_and_reuses_this_runs_binaries(self):
        second = job("windows-verify-2022")
        self.assertIn("    needs: compat-windows\n", second)
        self.assertIn("    runs-on: windows-2022\n", second)
        self.assertEqual(re.findall(r'--baseline "([^\"]+)"', second), ["0.11.0"])
        self.assertNotIn("matrix.baseline", second)
        self.assertNotIn("    strategy:", second)
        self.assertIn("name: RcloneBrowserNext-Windows-x64\n", second)
        self.assertIn("name: RcloneBrowserNext-Windows-build-evidence\n", second)
        self.assertNotIn("run-id:", second)
        self.assertNotIn("Scripts/build-compat", second)
        self.assertNotRegex(second, r"(?m)^\s*(?:run: )?(?:cargo|rustup|rustc|swiftc|npm|npx)\s+")
        self.assertIn(f"Distribution/Rclone_Browser_Next_{VERSION}_Windows_x64_Setup.exe", second)

    def test_every_installed_product_probe_and_final_gate_remains_required(self):
        second = job("windows-verify-2022")
        for script in ("test-compat-ui.py", "windows/probe-filesystem.py", "windows/probe-mutations.py",
                       "windows/probe-ui.py", "windows/verify-candidate.py"):
            self.assertIn("Scripts/" + script, second)
        self.assertIn("--phase fresh", second)
        self.assertIn("--phase upgrade", second)
        self.assertNotIn("continue-on-error", second)
        self.assertNotRegex(second.split("    steps:\n", 1)[0], r"(?m)^    if:")

    def test_2022_evidence_has_a_unique_required_artifact(self):
        second = job("windows-verify-2022")
        self.assertIn("name: RcloneBrowserNext-Windows-2022-verification-0.11.0\n", second)
        self.assertIn("          path: .build-cache/windows-candidate/verification/\n", second)
        self.assertIn("          if-no-files-found: error\n", second)
        self.assertIn("          include-hidden-files: true\n", second)

    def test_release_requires_both_windows_os_gates_and_never_bypasses_failure(self):
        release = job("release")
        needs = [value.strip() for value in re.search(r"(?m)^    needs: \[(.*?)\]$", release)[1].split(",")]
        self.assertIn("windows-verify", needs)
        self.assertIn("windows-verify-2022", needs)
        self.assertEqual(len(needs), len(set(needs)))
        condition = re.search(r"(?m)^    if: (.*)$", release)[1]
        self.assertEqual(condition, "github.event_name == 'push' && github.ref == 'refs/heads/main'")
        self.assertNotIn("continue-on-error", release)

    def test_linux_collects_published_comparison_after_other_regressions(self):
        linux = job("compat-linux")
        self.assertEqual(linux.count("Scripts/linux/verify-published-listing.py"), 1)
        self.assertIn("if: always() && steps.linux-build.outcome == 'success' && steps.linux-rclone.outcome == 'success'", linux)
        self.assertIn("--engine .build-cache/compat/runtime/rbn-engine --rclone .build-cache/ci-engine/rclone", linux)
        self.assertLess(linux.index("Scripts/test-compat-ui.py"), linux.index("Scripts/linux/verify-published-listing.py"))
        self.assertNotIn("swiftc", linux)
        self.assertNotIn("toolchain install swift", linux)

    def test_linux_artifact_covers_both_exact_comparisons_without_the_old_deb(self):
        linux = job("compat-linux")
        paths = [line.strip() for line in linux.rsplit("          path: |\n", 1)[1].split("          include-hidden-files:", 1)[0].splitlines()]
        for suffix in ("", "-original-34", "-expanded-unicode", "-runtime-manifest"):
            name = f".build-cache/compat/smoke-published-listing-linux{suffix}.json"
            self.assertTrue(any(fnmatch.fnmatch(name, pattern) for pattern in paths), name)
        old_deb = ".build-cache/compat/published-listing-oracle/Rclone_Browser_Next_0.11.0_Linux_amd64.deb"
        self.assertFalse(any(fnmatch.fnmatch(old_deb, pattern) for pattern in paths))


if __name__ == "__main__":
    unittest.main()
