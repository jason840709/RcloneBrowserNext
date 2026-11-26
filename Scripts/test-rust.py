#!/usr/bin/env python3
"""Build and run core regression executables, preserving the Windows launcher layout."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def configure_output():
    # Rust renders source excerpts as UTF-8. A redirected Windows Python
    # stream otherwise uses the system code page and can abort the runner
    # before Cargo finishes reporting a compiler diagnostic.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')

def main():
    configure_output()
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rclone', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--launcher', type=Path)
    p.add_argument('--test', action='append', default=[])
    args = p.parse_args()
    rclone = args.rclone.resolve(strict=True)
    env = dict(os.environ, CARGO_INCREMENTAL='0', RBN_TEST_RCLONE=str(rclone))
    env['RBN_TEST_ROOT'] = str(Path(env.get('RBN_TEST_ROOT', args.output.parent / 'fixtures')).resolve())
    command = [env.get('RBN_CARGO', 'cargo'), 'test', '-j', env.get('CARGO_BUILD_JOBS', '2'), '--release', '--locked', '--no-run', '--message-format=json', '--manifest-path', str(ROOT / 'Sources/Rust/Cargo.toml')]
    for target in args.test:
        command.extend(['--test', target])
    build = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, text=True, encoding='utf-8')
    executables = {}
    for line in build.stdout:
        try:
            item = json.loads(line)
        except ValueError:
            print(line, end='')
            continue
        if item.get('reason') == 'compiler-message':
            print(item.get('message', {}).get('rendered', ''), end='')
        if item.get('reason') == 'compiler-artifact' and item.get('profile', {}).get('test') and item.get('executable'):
            executables[item['executable']] = item['target']['name']
    if build.wait():
        raise SystemExit(build.returncode)
    if not executables:
        raise RuntimeError('Cargo did not report any test executables')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if os.name == 'nt':
        launcher = args.launcher or ROOT / '.build-cache/compat/runtime/rbn-process-launcher.exe'
        if not launcher.is_file():
            raise FileNotFoundError('Build the unchanged Windows process launcher before running the core tests')
        # Each test executable launches rclone exactly as production does: its
        # own adjacent launcher. No test-only launcher search or override exists.
        destinations = {Path(exe).parent / 'rbn-process-launcher.exe' for exe in executables}
        target = Path(env.get('CARGO_TARGET_DIR', ROOT / 'Sources/Rust/target')).resolve()
        release = target / env['CARGO_BUILD_TARGET'] / 'release' if env.get('CARGO_BUILD_TARGET') else target / 'release'
        destinations.add(release / 'rbn-process-launcher.exe')
        for destination in destinations:
            shutil.copy2(launcher, destination)
    records = []
    identity = {'sourceCommit': env.get('GITHUB_SHA') or env.get('RBN_SOURCE_COMMIT'),
                'runID': env.get('GITHUB_RUN_ID'),
                'rustcVersion': subprocess.check_output([env.get('RUSTC', 'rustc'), '--version'], env=env, text=True).strip(),
                'rcloneSha256': hashlib.sha256(rclone.read_bytes()).hexdigest()}

    def save_results(passed, *, stopped_early=False, error=None):
        evidence = dict(identity, passed=passed,
                        testsPassed=sum(r.get('passed', 0) for r in records),
                        testsFailed=sum(r.get('failed', 0) for r in records),
                        testsIgnored=sum(r.get('ignored', 0) for r in records),
                        executables=records)
        if stopped_early:
            evidence['stoppedEarly'] = True
        if error:
            evidence['error'] = error
        output.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        return evidence

    failure_code = 0
    for exe, name in sorted(executables.items(), key=lambda item: item[1]):
        log = output.parent / f'{name}.log'
        record = {'name': name, 'log': log.name,
                  'sha256': hashlib.sha256(Path(exe).read_bytes()).hexdigest()}
        try:
            with log.open('w', encoding='utf-8') as handle:
                # The ignored bridge is an RPC adapter for the unchanged Swift
                # recovery assertions, executed by test-local-recovery-mac.sh.
                run = subprocess.run([exe, '--include-ignored', '--skip', 'swift_assertion_bridge', '--test-threads=1', '--show-output'],
                                     cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT)
        except (subprocess.TimeoutExpired, OSError) as error:
            if log.is_file():
                record['logSha256'] = hashlib.sha256(log.read_bytes()).hexdigest()
            record['executionError'] = {'type': type(error).__name__, 'message': str(error)}
            records.append(record)
            save_results(False, stopped_early=True, error=record['executionError'])
            # A timeout or launch/cleanup failure is not an ordinary failed
            # assertion. Preserve it and stop rather than starting more work.
            raise
        text = log.read_text(encoding='utf-8')
        summaries = re.findall(r'^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;', text, re.MULTILINE)
        summary = summaries[0] if len(summaries) == 1 else None
        record.update(returncode=run.returncode, logSha256=hashlib.sha256(log.read_bytes()).hexdigest())
        if summary:
            record.update(passed=int(summary[1]), failed=int(summary[2]), ignored=int(summary[3]))
        record['cases'] = re.findall(r'^test ([^\r\n]+) \.\.\. ok\s*$', text, re.MULTILINE)
        record['failedCases'] = re.findall(r'^test ([^\r\n]+) \.\.\. FAILED\s*$', text, re.MULTILINE)
        records.append(record)
        names = record['cases'] + record['failedCases']
        named_complete = bool(summary and len(record['cases']) == record['passed']
                              and len(record['failedCases']) == record['failed']
                              and len(set(names)) == len(names) and record['ignored'] == 0)
        ordinary_success = bool(summary and summary[0] == 'ok' and record['failed'] == 0 and run.returncode == 0)
        # libtest exits 101 after reporting failed assertions. A signal,
        # unexpected exit, incomplete summary or missing names must still stop.
        ordinary_failure = bool(summary and summary[0] == 'FAILED' and record['failed'] > 0 and run.returncode == 101)
        summary_text = (f"test result: {summary[0]}. {record['passed']} passed; {record['failed']} failed; {record['ignored']} ignored;"
                        if summary else 'no unique result')
        print(f'{name}: {summary_text}', flush=True)
        if not named_complete or not (ordinary_success or ordinary_failure):
            print('Test execution or named evidence is incomplete, duplicated or inconsistent.', flush=True)
            print(text[-16000:])
            save_results(False, stopped_early=True)
            raise SystemExit(run.returncode or 1)
        if ordinary_failure:
            failure_code = run.returncode
            print(text[-16000:])
            save_results(False)
    evidence = save_results(failure_code == 0)
    print(f"{evidence['testsPassed']} core tests passed; {evidence['testsFailed']} failed; {output}", flush=True)
    if failure_code:
        raise SystemExit(failure_code)

if __name__ == '__main__':
    main()
