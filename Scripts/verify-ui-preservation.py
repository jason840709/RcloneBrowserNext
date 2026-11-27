#!/usr/bin/env python3
"""Verify UI preservation, including the explicit 0.12.1 and 0.12.2 page-switch fixes."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    fixture = json.loads((ROOT / 'Tests/fixtures/ui-baseline-0.11.0.json').read_text())
    version = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString'].encode()
    actual = {}
    for base in ('WebSource', 'Resources/Web'):
        for directory, folders, names in os.walk(ROOT / base):
            folders[:] = [d for d in folders if d not in ('node_modules', '.test-results', 'test-results', 'playwright-report', '.cache')]
            for name in names:
                if name == '.DS_Store':
                    continue
                path = Path(directory) / name
                if path.is_symlink():
                    raise RuntimeError(f'Unexpected UI source symlink: {path}')
                data = path.read_bytes()
                if path.suffix in ('.tsx', '.ts', '.js', '.json'):
                    data = data.replace(version, b'@VERSION@')
                actual[path.relative_to(ROOT).as_posix()] = hashlib.sha256(data).hexdigest()
    expected = dict(fixture['files'])
    if tuple(map(int, version.decode().split('.'))) >= (0, 12, 1):
        # Only these pinned outputs may differ from the phase-one baseline.
        # Styles, wording and existing web tests retain their original hashes.
        reviewed = json.loads((ROOT / 'Tests/fixtures/ui-changes-0.12.1.json').read_text())
        expected.update(reviewed['files'])
    if tuple(map(int, version.decode().split('.'))) >= (0, 12, 2):
        reviewed = json.loads((ROOT / 'Tests/fixtures/ui-changes-0.12.2.json').read_text())
        expected.update(reviewed['files'])
    differences = sorted(path for path in set(expected) | set(actual) if expected.get(path) != actual.get(path))
    result = {'passed': not differences, 'baselineVersion': fixture['baselineVersion'],
              'candidateVersion': version.decode(), 'checkedFiles': len(actual), 'differences': differences}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(bool(differences))

if __name__ == '__main__':
    main()
