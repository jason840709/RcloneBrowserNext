#!/usr/bin/env python3
"""Package the exact installer for the unified app version, never a stale glob."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--platform', choices=['windows', 'linux'], required=True)
p.add_argument('--cache', type=Path, required=True)
args = p.parse_args()
version = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
config = json.loads((ROOT / 'Compat/desktop/tauri.conf.json').read_text())
assert config['version'] == version
if args.platform == 'windows':
    override = json.loads((ROOT / 'Compat/desktop/tauri.windows.conf.json').read_text())
    assert 'version' not in override and override['bundle']['windows']['allowDowngrades'] is False
    installer = args.cache / 'target/release/bundle/nsis' / f'Rclone Browser Next_{version}_x64-setup.exe'
    suffix = 'Windows_x64_Setup.exe'
else:
    installer = args.cache / 'target/release/bundle/deb' / f'Rclone Browser Next_{version}_amd64.deb'
    suffix = 'Linux_amd64.deb'
if not installer.is_file():
    raise FileNotFoundError(f'The exact current installer was not built: {installer}')
destination = ROOT / 'Distribution' / f'Rclone_Browser_Next_{version}_{suffix}'
destination.parent.mkdir(exist_ok=True)
shutil.copy2(installer, destination)
digest = hashlib.sha256(destination.read_bytes()).hexdigest()
destination.with_suffix(destination.suffix + '.sha256').write_text(f'{digest}  {destination.name}\n', encoding='utf-8')
receipt = {'version': version, 'releaseTag': 'v' + version, 'platform': args.platform,
           'identifier': config['identifier'], 'productName': config['productName'],
           'peVersion': [int(part) for part in version.split('.')] + [0],
           'sourceCommit': subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(),
           'file': destination.name, 'bytes': destination.stat().st_size, 'sha256': digest,
           'runtime': json.loads((args.cache / 'runtime/runtime-manifest.json').read_text(encoding='utf-8-sig'))}
(args.cache / f'package-{args.platform}.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
print(json.dumps({k:v for k,v in receipt.items() if k!='runtime'}, indent=2))
