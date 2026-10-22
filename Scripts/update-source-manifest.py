#!/usr/bin/env python3
"""Refresh the tracked source inventory after staging source/resource changes."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
ROOT=Path(__file__).resolve().parents[1]
files={}
for name in sorted(filter(None,subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0'))):
    if name=='SOURCE_MANIFEST.json': continue
    path=ROOT/name
    if not path.is_file() or path.is_symlink(): raise ValueError('Invalid tracked input: '+name)
    raw=path.read_bytes(); files[name]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
version=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
(ROOT/'SOURCE_MANIFEST.json').write_text(json.dumps({'version':version,'file_count_excluding_manifest':len(files),'total_bytes_excluding_manifest':sum(v['bytes'] for v in files.values()),'files':files},ensure_ascii=False,indent=2)+'\n')
