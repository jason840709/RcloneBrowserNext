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

ROOT = Path(__file__).resolve().parents[1]

def main():
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
    for exe, name in sorted(executables.items(), key=lambda item: item[1]):
        log = output.parent / f'{name}.log'
        with log.open('w', encoding='utf-8') as handle:
            # The ignored bridge is an RPC adapter for the unchanged Swift
            # recovery assertions, executed by test-local-recovery-mac.sh.
            run = subprocess.run([exe, '--include-ignored', '--skip', 'swift_assertion_bridge', '--test-threads=1', '--show-output'],
                                 cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT)
        text = log.read_text(encoding='utf-8')
        match = re.search(r'test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;', text)
        record = {'name': name, 'returncode': run.returncode, 'log': log.name, 'logSha256': hashlib.sha256(log.read_bytes()).hexdigest(),
                  'sha256': hashlib.sha256(Path(exe).read_bytes()).hexdigest()}
        if match:
            record.update(passed=int(match[2]), failed=int(match[3]), ignored=int(match[4]))
        record['cases'] = re.findall(r'^test ([^\r\n]+) \.\.\. ok\s*$', text, re.MULTILINE)
        records.append(record)
        named_complete = bool(match and len(record['cases']) == record['passed']
                              and len(set(record['cases'])) == len(record['cases']))
        print(f'{name}: {match[0] if match else "no result"}', flush=True)
        if run.returncode or not match or not named_complete:
            if not named_complete:
                print('Named test evidence is incomplete or duplicated.', flush=True)
            print(text[-16000:])
            output.write_text(json.dumps({'passed': False, 'executables': records}, indent=2) + '\n')
            raise SystemExit(run.returncode or 1)
    evidence = {'passed': True, 'sourceCommit': env.get('GITHUB_SHA') or env.get('RBN_SOURCE_COMMIT'), 'runID': env.get('GITHUB_RUN_ID'), 'rustcVersion': subprocess.check_output([env.get('RUSTC', 'rustc'), '--version'], env=env, text=True).strip(), 'rcloneSha256': hashlib.sha256(rclone.read_bytes()).hexdigest(),
                'testsPassed': sum(r['passed'] for r in records), 'testsIgnored': sum(r['ignored'] for r in records),
                'executables': records}
    output.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
    print(f"{evidence['testsPassed']} core tests passed; {output}")

if __name__ == '__main__':
    main()
