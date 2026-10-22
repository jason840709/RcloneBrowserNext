#!/usr/bin/env python3
"""Package tracked source and the successfully verified platform builds."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import stat
import subprocess
import zipfile


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise SystemExit('Invalid release version')
    output = args.output.resolve()
    output.mkdir(exist_ok=False)
    prefix = f'Rclone_Browser_Next_{version}'
    for arch in ('arm64', 'x86_64'):
        candidates = list(args.artifacts.rglob(f'{prefix}_macOS_{arch}_*.zip'))
        if len(candidates) != 1:
            raise SystemExit(f'Expected one verified {arch} archive, found {len(candidates)}')
        archive = candidates[0]
        checksum = Path(str(archive) + '.sha256').read_text().strip().split(None, 1)
        if len(checksum) != 2 or checksum[1].strip() != archive.name or sha256(archive) != checksum[0]:
            raise SystemExit(f'Checksum does not match {archive.name}')
        with zipfile.ZipFile(archive) as packed:
            if packed.testzip() is not None:
                raise SystemExit(f'Corrupt archive: {archive.name}')
            plist_paths = [name for name in packed.namelist() if name == 'Rclone Browser Next.app/Contents/Info.plist']
            if len(plist_paths) != 1 or plistlib.loads(packed.read(plist_paths[0]))['CFBundleShortVersionString'] != version:
                raise SystemExit(f'App version does not match {archive.name}')
        shutil.copyfile(archive, output / f'{prefix}_macOS_{arch}.zip')

    for suffix in ('Windows_x64_Setup.exe', 'Linux_amd64.deb'):
        candidates = list(args.artifacts.rglob(f'{prefix}_{suffix}'))
        if len(candidates) != 1:
            raise SystemExit(f'Expected one verified {suffix}, found {len(candidates)}')
        package = candidates[0]
        checksum = Path(str(package) + '.sha256').read_text().strip().split(None, 1)
        if len(checksum) != 2 or checksum[1].strip() != package.name or sha256(package) != checksum[0]:
            raise SystemExit(f'Checksum does not match {package.name}')
        shutil.copyfile(package, output / package.name)

    staged = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).decode().split('\0')
    modes = {entry.split('\t', 1)[1]: int(entry.split(' ', 1)[0], 8) for entry in staged if entry}
    tracked = list(modes)
    files = {}
    for relative in sorted(filter(None, tracked)):
        if relative == 'SOURCE_MANIFEST.json':
            continue
        path = root / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise SystemExit(f'Unsupported tracked source: {relative}')
        files[relative] = {'bytes': path.stat().st_size, 'sha256': sha256(path)}
    manifest = json.dumps({'version': version, 'file_count_excluding_manifest': len(files),
                           'total_bytes_excluding_manifest': sum(entry['bytes'] for entry in files.values()),
                           'files': files}, ensure_ascii=False, indent=2).encode() + b'\n'
    source = output / f'{prefix}_Source.zip'
    with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as packed:
        for relative in [*files, 'SOURCE_MANIFEST.json']:
            data = manifest if relative == 'SOURCE_MANIFEST.json' else (root / relative).read_bytes()
            entry = zipfile.ZipInfo(f'{prefix}/{relative}', date_time=(2026, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = modes[relative] & 0o777
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            packed.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    with zipfile.ZipFile(source) as packed:
        if packed.testzip() is not None:
            raise SystemExit('Source archive failed CRC verification')
    checksums = ''.join(f'{sha256(path)}  {path.name}\n' for path in sorted(output.iterdir()) if path.is_file())
    (output / f'SHA256SUMS_{version}.txt').write_text(checksums)
    print(checksums, end='')


if __name__ == '__main__':
    main()
