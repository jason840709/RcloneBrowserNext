#!/usr/bin/env python3
"""Recolor Jason Chen's v2 vector profiles and package transparent runtime icons.

Requires an existing Inkscape executable. No dependency installation is performed.
Only fill/stroke/color values and SVG titles change; the eye/body paths are retained.
Build outputs and the Inkscape cache stay in WebSource/.build-cache/theme-icons.
The regular Mac build uses the generated resources and does not run this script.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import struct
import subprocess
import xml.etree.ElementTree as ET

WEB = Path(__file__).resolve().parents[1]
ROOT = WEB.parent
OUT = WEB / '.build-cache/theme-icons'
PALETTES = {
    'blue': ['#CDDDED', '#98B4D2', '#6487AC', '#2D4057', '#4E6A88', '#435C78', '#26384C', '#354B63'],
    'green': ['#D1E4D6', '#A5C4AE', '#72967E', '#2B4132', '#526F5B', '#45624E', '#243A2B', '#364F3E'],
}
ORIGINAL = ['#D6C9E7', '#AD91C2', '#7D6391', '#3E2D50', '#68517C', '#59416C', '#352440', '#432E54']
ENTRIES = [
    (b'icp4', 16, 16), (b'icp5', 32, 32), (b'icp6', 64, 64),
    (b'ic07', 128, 128), (b'ic08', 256, 256), (b'ic09', 512, 512),
    (b'ic10', 512, 1024), (b'ic11', 16, 32), (b'ic12', 32, 64),
    (b'ic13', 128, 256), (b'ic14', 256, 512),
]

def shape(svg):
    root = ET.fromstring(svg)
    def walk(node):
        tag = node.tag.split('}')[-1]
        if tag in ('title', 'desc'):
            return None
        attrs = {k: (re.sub(r'#[0-9A-Fa-f]{6}', '#COLOR', v) if k in ('fill', 'stroke', 'color') else v) for k, v in node.attrib.items()}
        return [tag, attrs, [child for c in node if (child := walk(c)) is not None]]
    return json.dumps(walk(root), sort_keys=True, separators=(',', ':'))

def profile(size):
    return 'micro' if size <= 16 else 'small' if size <= 64 else 'dock' if size <= 128 else 'master'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    for key, folder in [('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data')]:
        local = OUT / folder; local.mkdir(exist_ok=True); env[key] = str(local)
    sources = {p: (WEB / f'assets/icons/canonical-{p}.svg').read_text() for p in ['micro','small','dock','master']}
    manifest = {'source': 'Jason Chen v2 optical SVG profiles; only colors and titles changed', 'families': {}}
    for family, colors in PALETTES.items():
        folder = OUT / family; folder.mkdir(exist_ok=True)
        mapping = dict(zip(ORIGINAL, colors))
        profiles = {}
        for name, source in sources.items():
            svg = re.sub(r'#[0-9A-Fa-f]{6}', lambda match: mapping.get(match.group().upper(), match.group()), source)
            svg = svg.replace('三重對稱粉紫蛇圖示', f'三重對稱蛇圖示 — {family}')
            assert shape(source) == shape(svg), f'Geometry changed: {family}/{name}'
            target = folder / f'{name}.svg'; target.write_text(svg); profiles[name] = target
        (WEB / f'renderer/favicon-{family}.svg').write_text(profiles['small'].read_text())
        payload = b''; sizes=[]
        for tag, logical, physical in ENTRIES:
            selected = profile(logical)
            png = folder / f'{tag.decode()}-{physical}.png'
            subprocess.run(['inkscape', str(profiles[selected]), '--export-type=png', '--export-area-page', '--export-background-opacity=0', f'--export-width={physical}', f'--export-height={physical}', f'--export-filename={png}'], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            data=png.read_bytes(); assert data[:8] == b'\x89PNG\r\n\x1a\n'
            payload += tag + struct.pack('>I', len(data)+8) + data
            sizes.append({'type': tag.decode(), 'logical': logical, 'pixels': physical, 'profile': selected})
        icon = ROOT / f'Resources/AppIcon-{family}.icns'
        icon.write_bytes(b'icns' + struct.pack('>I', len(payload)+8) + payload)
        manifest['families'][family] = {'colors': colors, 'bytes': icon.stat().st_size, 'sha256': hashlib.sha256(icon.read_bytes()).hexdigest(), 'geometryPreserved': True, 'representations': sizes}
    (OUT / 'icon-verification.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps({family: {k:v for k,v in info.items() if k in ('bytes','sha256','geometryPreserved')} for family,info in manifest['families'].items()}, indent=2))

if __name__ == '__main__':
    main()
