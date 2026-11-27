#!/usr/bin/env python3
"""Verify version metadata, the unchanged Windows launcher and UI source inventory.

Windows file operations are now guarded by Rust regressions and the unchanged
installed Windows probes, rather than a fingerprint of removed Swift code.
This checker never invokes Git or a credential helper.
"""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_LAUNCHER_BLOB = 'd12569ca65804e8976d516980cdcacde934be122'

def require(value, message):
    if not value:
        raise AssertionError(message)

def text(path):
    return (ROOT / path).read_text(encoding='utf-8')

def load(path):
    return json.loads(text(path))

def blob_id(raw):
    return hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path)
    # Kept for older local invocation scripts. The Windows C baseline is pinned
    # directly above from the immutable windows-v0.9.0-r1 GitHub tree.
    p.add_argument('--reference-json', type=Path)
    a = p.parse_args()
    plist = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version = plist['CFBundleShortVersionString']
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Expected one version for all platforms')
    require(plist['CFBundleIdentifier'] == 'org.rclone.browser.next.lite', 'Mac identity changed')
    require(f'RBN_VERSION="{version}"' in text('Scripts/common-mac.sh'), 'Mac build version differs')
    require(f'className="statusbar-version">{version}<' in text('WebSource/renderer/App.tsx'), 'Visible UI version differs')
    for directory in ('WebSource', 'Compat/cli'):
        require(load(directory + '/package.json')['version'] == version, f'NPM version differs: {directory}')
        lock = load(directory + '/package-lock.json')
        require(lock['version'] == lock['packages']['']['version'] == version, f'NPM lock version differs: {directory}')
    for directory, name in (('Compat/desktop', 'rclone-browser-next'), ('Sources/Rust', 'rbn-core')):
        manifest = tomllib.loads(text(directory + '/Cargo.toml'))
        require(manifest['package']['version'] == version, f'Rust version differs: {directory}')
        packages = tomllib.loads(text(directory + '/Cargo.lock'))['package']
        require([item['version'] for item in packages if item['name'] == name] == [version], f'Rust lock version differs: {directory}')
        require(not (ROOT / directory / 'rust-toolchain.toml').exists(), 'Unexpected per-project toolchain installation')
    config = load('Compat/desktop/tauri.conf.json')
    windows = load('Compat/desktop/tauri.windows.conf.json')
    require(config['version'] == version and config['identifier'] == 'org.rclone.browser.next', 'Compatibility version or identity differs')
    require('version' not in windows and windows['bundle']['windows']['allowDowngrades'] is False, 'Windows version inheritance or downgrade protection changed')
    nsis_spec = importlib.util.spec_from_file_location('windows_nsis_diagnostics', ROOT / 'Scripts/windows/nsis-diagnostics.py')
    nsis = importlib.util.module_from_spec(nsis_spec)
    nsis_spec.loader.exec_module(nsis)
    nsis_guard = nsis.verify_source(ROOT)
    launcher = text('Scripts/native/WindowsRcloneLauncher.c').encode('utf-8')
    require(blob_id(launcher) == WINDOWS_LAUNCHER_BLOB, 'The verified Windows C launcher changed')
    require(hashlib.sha256(text('Scripts/reviewed-wording-0.11.0.json').encode('utf-8')).hexdigest() ==
            'b95afe3c37b65a4f13d4801bad9a4a07cb34e3bbda9d61f4d48c6e3e2d91268d', 'Reviewed wording inventory changed')
    for path in ('Scripts/windows/probe-filesystem.py', 'Scripts/windows/probe-mutations.py', 'Sources/Rust/src/windows_local.rs'):
        require((ROOT / path).is_file(), f'Missing Windows filesystem gate: {path}')
    result = {'passed': True, 'version': version, 'macBuild': plist['CFBundleVersion'],
              'sourceCommit': os.environ.get('GITHUB_SHA') or os.environ.get('RBN_SOURCE_COMMIT'), 'usedLocalGit': False,
              'windowsFilesystemImplementation': 'Rust', 'windowsLauncherUnchanged': True,
              'windowsLauncherBaseline': {'ref': 'windows-v0.9.0-r1', 'blob': WINDOWS_LAUNCHER_BLOB},
              'windowsFilesystemGates': ['core-rust.json', 'filesystem.json', 'mutations.json'],
              'windowsNSISDiagnostic': nsis_guard}
    if a.output:
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))

if __name__ == '__main__':
    main()
