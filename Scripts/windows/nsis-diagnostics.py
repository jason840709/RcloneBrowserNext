#!/usr/bin/env python3
"""Pin the NSIS error-console-only diagnostic to the exact upstream macro."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
CLI_VERSION = "2.12.3"
UPSTREAM_COMMIT = "59b63ab500da9859f12d8888c3298bc29bba0b92"
ORIGINAL_MACRO_SHA256 = "a1ffd19992f3ddc58540a8f86b097a94c40491cee76b4a2cf50abff6bfa14f33"
ORIGINAL_UTILS_SHA256 = "78272bd40b8a783c0ab94e4bcb400fd947ba306a7575f2bbbbccb7478f40447f"
HOOK_RELATIVE = "Scripts/windows/nsis-diagnostics.nsh"
HOOK_CONFIG = "../../" + HOOK_RELATIVE
HOOK_PREFIX = "; Copyright 2019-2024 Tauri Programme within The Commons Conservancy\n; SPDX-License-Identifier: Apache-2.0 OR MIT\n; Source: https://github.com/tauri-apps/tauri/blob/59b63ab500da9859f12d8888c3298bc29bba0b92/crates/tauri-bundler/src/bundle/windows/nsis/utils.nsh\n; Tauri CLI 2.12.3. The original macro and every diagnostic insertion are pinned.\n; Successful installations add no diagnostic I/O. The existing silent error\n; console gains one line, using its existing handle; the original Abort remains.\n!ifmacrondef CheckIfAppIsRunning\n  !error \"The pinned Tauri CheckIfAppIsRunning macro must be included first.\"\n!endif\n!macroundef CheckIfAppIsRunning\nVar RbnRmShutdownCode\nVar RbnRmWriteHadError\n\n"
INSERTIONS = {"save-shutdown-returncode":"            ; RBN_NSIS_DIAGNOSTIC_BEGIN save-shutdown-returncode\n            StrCpy $RbnRmShutdownCode $0\n            ; RBN_NSIS_DIAGNOSTIC_END save-shutdown-returncode\n","append-existing-error-console":"                ; RBN_NSIS_DIAGNOSTIC_BEGIN append-existing-error-console\n                StrCpy $RbnRmWriteHadError 0\n                IfErrors 0 +2\n                StrCpy $RbnRmWriteHadError 1\n                FileWrite $0 'RBN_NSIS_RM_DIAGNOSTIC target=\"${executablePath}\" shutdown=$RbnRmShutdownCode register=0 getList=234 needed=$1 count=$2 rebootReasons=$3$\\n'\n                ${If} $RbnRmWriteHadError = 1\n                  SetErrors\n                ${Else}\n                  ClearErrors\n                ${EndIf}\n                ; RBN_NSIS_DIAGNOSTIC_END append-existing-error-console\n"}


def require(value, message):
    if not value:
        raise AssertionError(message)


def canonical(raw):
    return raw.decode("utf-8-sig").replace("\r\n", "\n")


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def macro(text):
    values = re.findall(r"^!macro CheckIfAppIsRunning executablePath productName\n[\s\S]*?^!macroend\n", text, re.MULTILINE)
    require(len(values) == 1, "Expected exactly one upstream CheckIfAppIsRunning macro")
    return values[0]


def original_macro(hook):
    current = macro(hook)
    require(hook == HOOK_PREFIX + current, "Unexpected code outside the pinned diagnostic macro")
    for name, insertion in INSERTIONS.items():
        require(current.count(insertion) == 1, "Missing or altered NSIS diagnostic insertion: " + name)
        current = current.replace(insertion, "")
    require("RBN_NSIS_DIAGNOSTIC" not in current, "Unexpected NSIS diagnostic block")
    require(sha(current.encode("utf-8")) == ORIGINAL_MACRO_SHA256,
            "The original NSIS control flow/API calls/prompt text changed")
    branch = '          ${Else}\n            IfSilent silent_${UniqueID} ui_${UniqueID}\n'
    prompt = '                FileWrite $0 "$R1$\\n"\n'
    require(current.count(branch) == current.count(prompt) == 1, "The upstream diagnostic anchor changed")
    expected = current.replace(branch, branch.splitlines(keepends=True)[0] + INSERTIONS["save-shutdown-returncode"] + branch.splitlines(keepends=True)[1])
    expected = expected.replace(prompt, prompt + INSERTIONS["append-existing-error-console"])
    require(macro(hook) == expected, "The NSIS diagnostic is outside the existing silent failure branch")
    return current


def file_identity(path):
    raw = path.read_bytes()
    return {"bytes": len(raw), "rawSHA256": sha(raw),
            "canonicalLFSHA256": sha(canonical(raw).encode("utf-8"))}


def verify_source(root=ROOT):
    root = Path(root)
    read = lambda name: json.loads((root / name).read_text(encoding="utf-8-sig"))
    manifest, lock = read("Compat/cli/package.json"), read("Compat/cli/package-lock.json")
    require(manifest["dependencies"]["@tauri-apps/cli"] == CLI_VERSION
            and lock["packages"][""]["dependencies"]["@tauri-apps/cli"] == CLI_VERSION
            and lock["packages"]["node_modules/@tauri-apps/cli"]["version"] == CLI_VERSION,
            "The diagnostic macro requires the pinned Tauri CLI " + CLI_VERSION)
    windows = read("Compat/desktop/tauri.windows.conf.json")
    require(windows["bundle"]["windows"]["nsis"]["installerHooks"] == HOOK_CONFIG,
            "The Windows installer does not include the pinned NSIS diagnostic hook")
    hook = root / HOOK_RELATIVE
    original_macro(canonical(hook.read_bytes()))
    return {"cliVersion": CLI_VERSION, "upstreamCommit": UPSTREAM_COMMIT,
            "originalMacroSHA256": ORIGINAL_MACRO_SHA256, "hook": file_identity(hook),
            "windowsConfig": file_identity(root / "Compat/desktop/tauri.windows.conf.json"),
            "originalControlFlowPreserved": True,
            "addedIO": "One FileWrite after the existing silent error message only"}


def verify_generated(path):
    path = Path(path)
    raw = path.read_bytes()
    text = canonical(raw)
    require(sha(text.encode("utf-8")) == ORIGINAL_UTILS_SHA256
            and sha(macro(text).encode("utf-8")) == ORIGINAL_MACRO_SHA256,
            "The actually generated Tauri NSIS utils/macro differs from CLI " + CLI_VERSION)
    installer = canonical(path.with_name("installer.nsi").read_bytes())
    include_utils = installer.find('!include "utils.nsh"')
    hooks = [m.start() for m in re.finditer(r'^!include "[^"\r\n]*nsis-diagnostics\.nsh"', installer, re.MULTILINE)]
    calls = [m.start() for m in re.finditer(r'^\s*!insertmacro CheckIfAppIsRunning "\$INSTDIR\\\$\{MAINBINARYNAME\}\.exe" "\$\{PRODUCTNAME\}"', installer, re.MULTILINE)]
    require(len(hooks) == 1 and len(calls) == 2 and 0 <= include_utils < hooks[0] < calls[0],
            "The generated installer does not retain the upstream hook order and both original macro call sites")
    return {"utils": file_identity(path), "originalMacroSHA256": ORIGINAL_MACRO_SHA256,
            "installer": file_identity(path.with_name("installer.nsi")), "originalCallSites": 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installed-cli", type=Path)
    parser.add_argument("--generated-utils", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = {"passed": True, "sourceCommit": os.environ.get("GITHUB_SHA"),
              "runID": os.environ.get("GITHUB_RUN_ID"), **verify_source()}
    if args.installed_cli:
        actual = json.loads(args.installed_cli.read_text(encoding="utf-8-sig"))
        require(actual.get("version") == CLI_VERSION, "The installed build CLI differs from its macro pin")
        result["installedCLI"] = file_identity(args.installed_cli)
    if args.generated_utils:
        result["generatedNSIS"] = verify_generated(args.generated_utils)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
