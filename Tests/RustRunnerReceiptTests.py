#!/usr/bin/env python3
"""Exercise the runner with synthetic Cargo artifacts; no process is launched."""
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('rust_runner', ROOT / 'Scripts/test-rust.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


def log(passed, failed=(), *, summary=True):
    text = ''.join(f'test {name} ... ok\n' for name in passed)
    text += ''.join(f'test {name} ... FAILED\n' for name in failed)
    if summary:
        status = 'FAILED' if failed else 'ok'
        text += f'test result: {status}. {len(passed)} passed; {len(failed)} failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.1s\n'
    return text


class RustRunnerReceiptTests(unittest.TestCase):
    def setUp(self):
        task = ROOT.parent if ROOT.name == '01_原始碼' else ROOT
        scratch = task / '.tmp'
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=scratch, prefix='runner-receipt-')
        self.addCleanup(self.temporary.cleanup)
        self.area = Path(self.temporary.name)
        self.output = self.area / 'results.json'
        self.rclone = self.area / 'rclone'
        self.rclone.write_bytes(b'non-executable synthetic rclone fixture')
        self.launcher = self.area / 'launcher.exe'
        self.launcher.write_bytes(b'non-executable synthetic launcher fixture')
        (self.area / 'target/release').mkdir(parents=True)
        self.executables = []
        for name in ('a_first', 'b_second'):
            path = self.area / name
            path.write_bytes(('non-executable synthetic artifact ' + name).encode())
            self.executables.append(path)
        self.executed = []

    def run_runner(self, results, *, compile_code=0):
        stream = ''.join(json.dumps({'reason': 'compiler-artifact', 'profile': {'test': True},
                                    'executable': str(path), 'target': {'name': path.name}}) + '\n'
                         for path in self.executables)
        build = SimpleNamespace(stdout=io.StringIO(stream), returncode=compile_code,
                                wait=lambda: compile_code)

        def execute(command, *, stdout, **kwargs):
            name = Path(command[0]).name
            self.executed.append(name)
            result = results[name]
            if isinstance(result, Exception):
                raise result
            text, code = result
            stdout.write(text)
            return SimpleNamespace(returncode=code)

        env = {'CARGO_TARGET_DIR': str(self.area / 'target'), 'RBN_TEST_ROOT': str(self.area / 'fixtures'),
               'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '42'}
        args = ['test-rust.py', '--rclone', str(self.rclone), '--launcher', str(self.launcher), '--output', str(self.output)]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(RUNNER.subprocess, 'Popen', return_value=build))
            stack.enter_context(mock.patch.object(RUNNER.subprocess, 'run', side_effect=execute))
            stack.enter_context(mock.patch.object(RUNNER.subprocess, 'check_output', return_value='rustc 1.90.0 (synthetic)\n'))
            stack.enter_context(mock.patch.dict(os.environ, env))
            stack.enter_context(mock.patch.object(sys, 'argv', args))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            RUNNER.main()

    def receipt(self):
        value = json.loads(self.output.read_text())
        for item in value['executables']:
            path = self.area / item['log']
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), item['logSha256'])
            self.assertEqual(hashlib.sha256((self.area / item['name']).read_bytes()).hexdigest(), item['sha256'])
        return value

    def test_all_successful_artifacts_produce_complete_passing_receipt(self):
        self.run_runner({'a_first': (log(['one']), 0), 'b_second': (log(['two', 'three']), 0)})
        value = self.receipt()
        self.assertTrue(value['passed'])
        self.assertEqual((value['testsPassed'], value['testsFailed'], value['testsIgnored']), (3, 0, 0))
        self.assertEqual(self.executed, ['a_first', 'b_second'])
        self.assertEqual(value['executables'][1]['cases'], ['two', 'three'])
        self.assertEqual((value['sourceCommit'], value['runID']), ('a' * 40, '42'))

    def test_complete_failed_artifact_continues_but_final_result_stays_failed(self):
        with self.assertRaises(SystemExit) as stopped:
            self.run_runner({'a_first': (log(['one'], ['broken']), 101), 'b_second': (log(['two', 'three']), 0)})
        self.assertEqual(stopped.exception.code, 101)
        value = self.receipt()
        self.assertFalse(value['passed'])
        self.assertNotIn('stoppedEarly', value)
        self.assertEqual(self.executed, ['a_first', 'b_second'])
        self.assertEqual((value['testsPassed'], value['testsFailed']), (3, 1))
        self.assertEqual(value['executables'][0]['failedCases'], ['broken'])

    def test_invalid_evidence_or_abnormal_exit_stops_before_next_artifact(self):
        variants = [(log(['same', 'same']), 0), (log(['one'], summary=False), 0),
                    (log(['one']) + log([]), 0), (log(['one'], ['one']), 101),
                    (log(['one'], ['broken']).replace('test broken ... FAILED\n', ''), 101),
                    (log(['one'], ['broken']), -9), (log(['one'], ['broken']), 3221225477)]
        for text, code in variants:
            with self.subTest(code=code, text=text):
                self.executed.clear()
                with self.assertRaises(SystemExit):
                    self.run_runner({'a_first': (text, code), 'b_second': (log(['later']), 0)})
                self.assertEqual(self.executed, ['a_first'])
                value = self.receipt()
                self.assertFalse(value['passed'])
                self.assertTrue(value['stoppedEarly'])

    def test_timeout_or_launch_failure_stops_and_retains_partial_receipt(self):
        for error in (subprocess.TimeoutExpired('synthetic-artifact', 1), OSError('synthetic launch failure')):
            with self.subTest(error=type(error).__name__):
                self.executed.clear()
                with self.assertRaises(type(error)):
                    self.run_runner({'a_first': error, 'b_second': (log(['later']), 0)})
                self.assertEqual(self.executed, ['a_first'])
                value = self.receipt()
                self.assertFalse(value['passed'])
                self.assertTrue(value['stoppedEarly'])
                self.assertEqual(value['error']['type'], type(error).__name__)

    def test_compile_failure_never_runs_artifacts(self):
        with self.assertRaises(SystemExit) as stopped:
            self.run_runner({}, compile_code=101)
        self.assertEqual(stopped.exception.code, 101)
        self.assertEqual(self.executed, [])
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
