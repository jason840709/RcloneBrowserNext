#!/usr/bin/env python3
"""Inventory the installed baseline runtime in a short-lived, read-only child.

ICU probes describe this diagnostic process. They do not claim that the old
Swift helper used its default locale or the system ICU implementation.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import struct
import sys


SPEC = importlib.util.spec_from_file_location("windows_unicode_runtime", Path(__file__).with_name("unicode-runtime.py"))
UNICODE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UNICODE)

def metadata(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": value.hexdigest()}


def pe_exports(path):
    """Read the export names without loading the DLL or any dependency."""
    data = path.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError("Not a PE file")
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Invalid PE signature")
    machine, sections = struct.unpack_from("<HH", data, pe + 4)
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directory_offset = {0x10b: 96, 0x20b: 112}.get(magic)
    if directory_offset is None:
        raise ValueError("Unsupported PE optional header")
    export_rva, _ = struct.unpack_from("<II", data, optional + directory_offset)
    section_table = optional + optional_size

    def file_offset(rva):
        for index in range(sections):
            virtual_size, address, raw_size, raw_offset = struct.unpack_from(
                "<IIII", data, section_table + index * 40 + 8)
            if address <= rva < address + max(virtual_size, raw_size):
                delta = rva - address
                if delta >= raw_size or raw_offset + delta >= len(data):
                    break
                return raw_offset + delta
        raise ValueError("PE RVA does not map to file data")

    if not export_rva:
        return f"0x{machine:04x}", []
    export = file_offset(export_rva)
    count = struct.unpack_from("<I", data, export + 24)[0]
    if count > 65536:
        raise ValueError("Unreasonable PE export name count")
    pointers = file_offset(struct.unpack_from("<I", data, export + 32)[0])
    names = []
    for index in range(count):
        offset = file_offset(struct.unpack_from("<I", data, pointers + index * 4)[0])
        end = data.find(b"\0", offset, offset + 256)
        if end < 0:
            raise ValueError("Invalid PE export name")
        names.append(data[offset:end].decode("ascii"))
    return f"0x{machine:04x}", names


def pe_version(path):
    api = ctypes.WinDLL("version", use_last_error=True)
    api.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    api.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    api.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    api.GetFileVersionInfoW.restype = wintypes.BOOL
    api.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
    api.VerQueryValueW.restype = wintypes.BOOL
    size = api.GetFileVersionInfoSizeW(str(path), None)
    if not size:
        return {"available": False, "winError": ctypes.get_last_error()}
    buffer = ctypes.create_string_buffer(size)
    if not api.GetFileVersionInfoW(str(path), 0, size, buffer):
        raise ctypes.WinError(ctypes.get_last_error())

    def query(key):
        pointer, length = ctypes.c_void_p(), wintypes.UINT()
        if not api.VerQueryValueW(buffer, key, ctypes.byref(pointer), ctypes.byref(length)):
            return None, 0
        return pointer, length.value

    pointer, length = query("\\")
    if pointer is None or length < 52:
        raise ValueError("Missing fixed PE version")
    fixed = struct.unpack("<13I", ctypes.string_at(pointer, 52))
    if fixed[0] != 0xFEEF04BD:
        raise ValueError("Invalid fixed PE version signature")
    parts = lambda high, low: [high >> 16, high & 65535, low >> 16, low & 65535]
    strings = []
    pointer, length = query(r"\VarFileInfo\Translation")
    if pointer is not None and length % 4 == 0:
        translations = struct.unpack("<" + "H" * (length // 2), ctypes.string_at(pointer, length))
        for language, codepage in zip(translations[::2], translations[1::2]):
            values = {"language": f"{language:04x}", "codepage": f"{codepage:04x}"}
            for key in ("FileVersion", "ProductVersion"):
                item, count = query(f"\\StringFileInfo\\{language:04x}{codepage:04x}\\{key}")
                if item is not None:
                    values[key] = ctypes.wstring_at(item, count).rstrip("\0")
            strings.append(values)
    return {"available": True, "fileVersion": parts(fixed[2], fixed[3]),
            "productVersion": parts(fixed[4], fixed[5]), "strings": strings}


def windows_locale():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    result = {"environment": {key: os.environ[key] for key in ("LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE")
                              if key in os.environ}}
    for label, symbol in (("userDefaultLocaleName", "GetUserDefaultLocaleName"),
                          ("systemDefaultLocaleName", "GetSystemDefaultLocaleName")):
        function = getattr(kernel, symbol)
        function.argtypes = [wintypes.LPWSTR, ctypes.c_int]
        function.restype = ctypes.c_int
        value = ctypes.create_unicode_buffer(85)
        if not function(value, len(value)):
            raise ctypes.WinError(ctypes.get_last_error())
        result[label] = value.value
    kernel.GetThreadLocale.argtypes = []
    kernel.GetThreadLocale.restype = wintypes.DWORD
    result["probeThreadLCID"] = kernel.GetThreadLocale()
    return result


def icu_probe(path, names):
    # This module is only launched as a child. The verifier waits for its exit
    # before invoking the candidate installer, releasing every old DLL handle.
    library = ctypes.CDLL(str(path), winmode=0x100 | 0x1000)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetModuleFileNameW.argtypes = [wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
    kernel.GetModuleFileNameW.restype = wintypes.DWORD
    loaded = ctypes.create_unicode_buffer(32768)
    if not kernel.GetModuleFileNameW(library._handle, loaded, len(loaded)):
        raise ctypes.WinError(ctypes.get_last_error())
    if not Path(loaded.value).samefile(path):
        raise ValueError("Windows loaded a different DLL from the requested absolute path")
    symbols = {}

    def function(base, args, result):
        candidates = [name for name in names if re.fullmatch(r"_?" + base + r"(?:_[A-Za-z0-9]+)*", name)]
        if len(candidates) != 1:
            return None
        symbol = candidates[0]
        value = getattr(library, symbol)
        value.argtypes, value.restype = args, result
        symbols[base] = symbol
        return value

    version_array = ctypes.c_uint8 * 4
    version_pointer = ctypes.POINTER(ctypes.c_uint8)
    output = {"loadedPath": loaded.value, "scope": "ICU loaded in the diagnostic child; old helper locale/initialization is unobserved"}
    get_version = function("u_getVersion", [version_pointer], None)
    if get_version is not None:
        value = version_array()
        get_version(value)
        output["icuVersion"] = list(value)
    get_locale = function("uloc_getDefault", [], ctypes.c_char_p)
    if get_locale is not None:
        locale = get_locale()
        output["probeDefaultLocale"] = locale.decode("ascii") if locale else None
    open_collator = function("ucol_open", [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int32)], ctypes.c_void_p)
    close_collator = function("ucol_close", [ctypes.c_void_p], None)
    collation_version = function("ucol_getVersion", [ctypes.c_void_p, version_pointer], None)
    uca_version = function("ucol_getUCAVersion", [ctypes.c_void_p, version_pointer], None)
    if open_collator is not None and close_collator is not None:
        error = ctypes.c_int32(0)
        collator = open_collator(b"", ctypes.byref(error))
        output["probeCollator"] = {"requestedLocale": "", "errorCode": error.value, "opened": bool(collator)}
        if collator:
            try:
                if error.value <= 0:
                    for key, getter in (("version", collation_version), ("ucaVersion", uca_version)):
                        if getter is not None:
                            value = version_array()
                            getter(collator, value)
                            output["probeCollator"][key] = list(value)
            finally:
                close_collator(collator)
    output["symbols"] = symbols
    return output


def library_record(path):
    value = metadata(path)
    value["peVersion"] = pe_version(path)
    try:
        value["machine"], exports = pe_exports(path)
        value["icuProbe"] = icu_probe(path, exports)
    except Exception as error:
        value["icuProbe"] = {"error": {"type": type(error).__name__, "message": str(error)}}
    return value


def private_unicode_record(path):
    pin = UNICODE.load_pin()
    machine, names = pe_exports(path)
    UNICODE.require(all(name in names for name in pin["requiredExports"]), "Missing pinned private ICU exports")
    # Explicitly inspect the suffixed ABI. No unversioned/system alternative is
    # considered if an export or version is missing.
    measured = icu_probe(path, [name for name in names if name.endswith("_74")])
    record = {"library": {"name": path.name, "bytes": path.stat().st_size, "sha256": UNICODE.digest(path)},
              "machine": machine, "apiVersion": measured.get("icuVersion"),
              "requiredExports": list(pin["requiredExports"]),
              "collatorOpened": measured.get("probeCollator", {}).get("opened") is True
                                  and measured.get("probeCollator", {}).get("errorCode", 1) <= 0,
              "loadedPath": measured["loadedPath"], "probe": measured}
    UNICODE.validate_probe(record, library=path, pin=pin)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest-output", type=Path)
    parser.add_argument("--unicode-library", type=Path)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This inventory requires native Windows")
    if args.unicode_library is not None:
        if any(value is not None for value in (args.runtime, args.helper, args.manifest_output)):
            parser.error("A private DLL probe cannot be combined with a baseline inventory")
        value = private_unicode_record(args.unicode_library.resolve(strict=True))
        value.update(sourceCommit=os.environ.get("GITHUB_SHA"), runID=os.environ.get("GITHUB_RUN_ID"),
                     stage="private-runtime-native-probe")
        args.output.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps({"library": value["library"], "apiVersion": value["apiVersion"]}))
        return 0
    if any(value is None for value in (args.runtime, args.helper, args.manifest_output)):
        parser.error("Baseline inventory needs --runtime, --helper and --manifest-output")
    runtime, helper = args.runtime.resolve(strict=True), args.helper.resolve(strict=True)
    if not helper.is_relative_to(runtime) or args.output.resolve().is_relative_to(runtime) or args.manifest_output.resolve().is_relative_to(runtime):
        parser.error("Only the separate evidence directory may be written")
    manifest = runtime / "runtime-manifest.json"
    value = {"schemaVersion": 1, "capturedAt": datetime.now(timezone.utc).isoformat(),
             "stage": "baseline-installed-before-candidate", "system": platform.platform(),
             "sourceCommit": os.environ.get("GITHUB_SHA"), "runID": os.environ.get("GITHUB_RUN_ID"),
             "pythonVersion": platform.python_version(), "helper": metadata(helper),
             "runtimeDirectory": str(runtime), "locale": windows_locale(),
             "oldHelperRuntimeLocale": "not observed inside the published Swift process",
             "manifest": {"present": manifest.is_file()}}
    if manifest.is_file():
        raw = manifest.read_bytes()
        args.manifest_output.write_bytes(raw)
        value["manifest"] = {"present": True, **metadata(manifest), "evidenceFile": args.manifest_output.name}
    value["icuLibraries"] = []
    for path in sorted(runtime.rglob("*.dll")):
        if "icu" in path.name.lower():
            entry = library_record(path.resolve(strict=True))
            entry["relativePath"] = path.relative_to(runtime).as_posix()
            value["icuLibraries"].append(entry)
    system_icu = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/icu.dll"
    value["systemICU"] = {"present": system_icu.is_file(), "scope": "Windows system library; not evidence of old Swift linkage"}
    if system_icu.is_file():
        value["systemICU"]["library"] = library_record(system_icu.resolve(strict=True))
    args.output.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"icuLibraries": len(value["icuLibraries"]), "manifestPresent": value["manifest"]["present"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
