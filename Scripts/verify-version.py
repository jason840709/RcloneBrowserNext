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
def git(*args): return subprocess.check_output(['git', *args], cwd=ROOT, text=True, encoding='utf-8').strip()

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
    instructions=text('docs/BUILD_COMPATIBILITY.md')
    for suffix in ['Windows_x64_Setup.exe','Linux_amd64.deb','Source.zip']:
        require(f'Rclone_Browser_Next_{version}_{suffix}' in instructions,
      'Current installation instructions reference another version: '+suffix)
    require(f'releases/tag/v{version}' in instructions,'Current installation release link differs')
    pinned={
        'Sources/Core/EngineModels.swift':'2b4e3b156274b607778ca68e3bfd18e3583e6773',
        'Sources/Core/EngineStorage.swift':'b9baea9703c1ebfd75b211a6e16c40931fccd760',
    }
    # These additional Windows implementation blobs are pinned to the released
    # r1 tag, rather than duplicating them into a second platform source tree.
    for path in ['Sources/Compat/WindowsLocalFileSystem.swift','Scripts/native/WindowsRcloneLauncher.c']:
        pinned[path]=git('rev-parse','windows-v0.9.0-r1:'+path)
    for path, blob in pinned.items():
        require(git('hash-object','--path='+path,path)==blob,'Verified Windows filesystem changed: '+path)
    compat_addition='        case "accountConfig":\n            guard !tools.hasActiveSessions, !controlLock.holding({ configuring || closing }) else { throw EngineError("請先結束終端機設定或播放，再開啟圖形帳號設定。") }\n            return try engine.invoke(method, arguments: arguments)\n        case "_accountAuthorization": return try engine.accounts.authorizationURL().absoluteString\n'
    baseline=git('show','windows-v0.9.0-r1:Sources/Compat/CompatMain.swift')
    compat_source=text('Sources/Compat/CompatMain.swift')
    # 0.9.4 adds scoped listing lifetime around the unchanged Windows adapter.
    # Reverse only these reviewed dispatch/cancellation additions before the
    # complete r1 host comparison; filesystem implementation hashes stay pinned.
    listing_routes={
        '        case "_cancelListings": engine.cancelListings(); return true\n':'',
        '"bootstrap", "list", "cancelList", "mkdir"':'"bootstrap", "list", "mkdir"',
        'case "list": return try engine.listDirectory(endpoint, options: argument(1), localListing: WindowsLocalFileSystem.list)':
            'case "list": return try WindowsLocalFileSystem.list(endpoint)',
        '                if method == "list" {\n                    do { try host.engine.prepareListing(options: arguments.count > 1 ? arguments[1] : nil) }\n                    catch { host.send(["id": id, "error": host.translatedError(error.localizedDescription)]); continue }\n                }\n':'',
        '                // Stop listings before placing shutdown behind their workers.\n                // Waiting at the barrier first would defer cancellation until\n                // the very directory read we intend to stop had timed out.\n                if method == "_shutdown" { host.engine.cancelListings() }\n':'',
        '            host.engine.cancelListings()\n':'',
        '                // Stop controls must bypass a previously queued state barrier;\n                // that barrier may itself be waiting for the folder being read.\n                let targetQueue = ["cancelList", "_cancelListings"].contains(method) ? DispatchQueue.global(qos: .userInitiated) : queue\n                targetQueue.async(flags: flags) {':
            '                queue.async(flags: flags) {',
    }
    for addition, original in listing_routes.items():
        require(compat_source.count(addition)==1, 'Reviewed listing host route changed: '+addition.splitlines()[0])
        compat_source=compat_source.replace(addition,original,1)
    require(compat_source.replace(compat_addition,'').strip()==baseline,
            'Compatibility host changed outside the reviewed account and listing routes')
    result={'passed':True,'version':version,'macBuild':plist['CFBundleVersion'],
            'sourceCommit':git('rev-parse','HEAD'),'windowsFilesystemUnchanged':True,'windowsFilesystemBlobs':pinned}
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
