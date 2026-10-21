#!/usr/bin/env python3
"""Download a pinned, checksum-verified rclone fixture into a CI checkout."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = 'v1.75.2'

def main():
    if os.environ.get('CI', '').lower() != 'true':
        raise SystemExit('This fixture installer runs only in CI.')
    system = {'Windows': 'windows', 'Linux': 'linux'}.get(platform.system())
    if not system or platform.machine().lower() not in ('amd64', 'x86_64'):
        raise SystemExit('This fixture supports Windows and Linux x64.')
    cache = ROOT / '.build-cache' / 'ci-engine'
    if cache.is_symlink() or cache.parent.is_symlink():
        raise SystemExit('Fixture cache cannot be a symbolic link.')
    cache.mkdir(parents=True, exist_ok=True)
    stem = f'rclone-{VERSION}-{system}-amd64'
    filename = stem + '.zip'
    base = f'https://github.com/rclone/rclone/releases/download/{VERSION}/'
    headers = {'User-Agent': 'RcloneBrowserNext-CI/0.9.0'}
    checksum_request = urllib.request.Request(base + 'SHA256SUMS', headers=headers)
    with urllib.request.urlopen(checksum_request, timeout=60) as response:
        sums = response.read().decode("utf-8")
    matches = [line.split()[0] for line in sums.splitlines()
               if len(line.split()) == 2 and line.split()[1].lstrip('*') == filename]
    if len(matches) != 1:
        raise SystemExit('Expected exactly one official checksum.')
    archive = cache / filename
    archive_request = urllib.request.Request(base + filename, headers=headers)
    with urllib.request.urlopen(archive_request, timeout=180) as response, archive.open('wb') as out:
        while chunk := response.read(1024 * 1024):
            out.write(chunk)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != matches[0].lower():
        raise SystemExit('Official rclone archive checksum failed.')
    executable = 'rclone.exe' if system == 'windows' else 'rclone'
    with zipfile.ZipFile(archive) as packed:
        member = stem + '/' + executable
        if packed.namelist().count(member) != 1:
            raise SystemExit('Expected one rclone executable in the official archive.')
        (cache / executable).write_bytes(packed.read(member))
    (cache / executable).chmod(0o755)
    subprocess.run([str(cache / executable), 'version'], check=True)
    print(f'Verified {filename}: {digest}')

if __name__ == '__main__':
    main()
