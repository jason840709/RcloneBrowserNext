#!/usr/bin/env python3
"""Record the Rust helper's actual Linux system imports; no Swift runtime is bundled."""
from pathlib import Path
import argparse
import json
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--runtime', type=Path, required=True)
a = p.parse_args()
helper = a.runtime / 'rbn-engine'
linked = subprocess.check_output(['ldd', str(helper.resolve())], text=True)
if 'not found' in linked:
    raise RuntimeError(linked)
if re.search(r'swift|foundation|libdispatch', linked, re.I):
    raise RuntimeError('The Rust helper unexpectedly depends on a Swift runtime')
libraries = sorted(set(re.findall(r'^\s*(\S+)\s+=>', linked, re.M)))
manifest = {'rust': subprocess.check_output(['rustc', '--version'], text=True).strip(),
            'engine': 'Rust', 'libraries': [], 'systemLibraries': libraries}
(a.runtime / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Rust helper uses {len(libraries)} system libraries; no Swift runtime bundled')
