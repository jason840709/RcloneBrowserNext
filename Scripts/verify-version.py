#!/usr/bin/env python3
"""Check unified version metadata and preserve the verified Windows filesystem."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]
def require(value, message):
    if not value: raise AssertionError(message)
def text(path): return (ROOT / path).read_text(encoding='utf-8')
def load(path): return json.loads(text(path))
def git(*args): return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()

def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--output',type=Path); args=parser.parse_args()
    plist=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes()); version=plist['CFBundleShortVersionString']
    require(re.fullmatch(r'\d+\.\d+\.\d+',version), 'Expected a unified stable version')
    require(plist['CFBundleIdentifier']=='org.rclone.browser.next.lite','Mac identity must not change')
    require(f'static let version = "{version}"' in text('Sources/Core/AppReleaseChecker.swift'),'Core version differs')
    require(f'RBN_VERSION="{version}"' in text('Scripts/common-mac.sh'),'Mac build version differs')
    require(f'className="statusbar-version">{version}<' in text('WebSource/renderer/App.tsx'),'Visible Web version differs')
    for directory in ['WebSource','Compat/cli']:
        require(load(directory+'/package.json')['version']==version,'NPM version differs: '+directory)
        lock=load(directory+'/package-lock.json')
        require(lock['version']==lock['packages']['']['version']==version,'NPM lock version differs: '+directory)
    require(tomllib.loads(text('Compat/desktop/Cargo.toml'))['package']['version']==version,'Cargo version differs')
    packages=tomllib.loads(text('Compat/desktop/Cargo.lock'))['package']
    require([p['version'] for p in packages if p['name']=='rclone-browser-next']==[version],'Cargo lock app version differs')
    config=load('Compat/desktop/tauri.conf.json'); windows=load('Compat/desktop/tauri.windows.conf.json')
    require(config['version']==version and config['identifier']=='org.rclone.browser.next','Compatibility version/identity differs')
    require('version' not in windows and windows['bundle']['windows']['allowDowngrades'] is False,'Windows must inherit the unified version and reject downgrades')
    pinned={
        'Sources/Core/EngineModels.swift':'2b4e3b156274b607778ca68e3bfd18e3583e6773',
        'Sources/Core/EngineStorage.swift':'b9baea9703c1ebfd75b211a6e16c40931fccd760',
    }
    # These additional Windows implementation blobs are pinned to the released
    # r1 tag, rather than duplicating them into a second platform source tree.
    for path in ['Sources/Compat/WindowsLocalFileSystem.swift','Sources/Compat/CompatMain.swift','Scripts/native/WindowsRcloneLauncher.c']:
        pinned[path]=git('rev-parse','windows-v0.9.0-r1:'+path)
    for path, blob in pinned.items():
        require(git('hash-object','--path='+path,path)==blob,'Verified Windows filesystem changed: '+path)
    result={'passed':True,'version':version,'macBuild':plist['CFBundleVersion'],
            'sourceCommit':git('rev-parse','HEAD'),'windowsFilesystemUnchanged':True,'windowsFilesystemBlobs':pinned}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
