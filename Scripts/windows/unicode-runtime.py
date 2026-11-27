#!/usr/bin/env python3
"""Shared positive identity checks for the private Windows ICU runtime."""
import hashlib
import json
from pathlib import Path, PureWindowsPath
import re


HERE = Path(__file__).resolve().parent
PIN_PATH = HERE / "icu-source.json"
WRAPPER = HERE / "icu-wrapper/CMakeLists.txt"
REQUIRED_EXPORTS = ("u_getVersion_74", "ucol_open_74", "ucol_close_74", "ucol_setAttribute_74", "ucol_strcoll_74")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def load_pin():
    pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
    require(pin.get("schemaVersion") == 1 and pin.get("library") == "RBNUnicode.dll"
            and pin.get("icuVersion") == [74, 1, 0, 0]
            and pin.get("requiredExports") == list(REQUIRED_EXPORTS)
            and re.fullmatch(r"[0-9a-f]{40}", pin.get("commit", ""))
            and re.fullmatch(r"[0-9a-f]{64}", pin.get("archiveSHA256", ""))
            and type(pin.get("archiveBytes")) is int and pin["archiveBytes"] > 0,
            "The private ICU source pin is invalid")
    require(pin.get("repository") == "swiftlang/swift-foundation-icu"
            and pin.get("tag") == "swift-6.1.2-RELEASE"
            and pin.get("archiveURL") == f"https://api.github.com/repos/{pin['repository']}/tarball/{pin['commit']}",
            "The private ICU source URL does not identify its pinned commit")
    return pin


def wrapper_digest():
    # GitHub Windows checkouts use CRLF; CMake's source text has the same
    # meaning on every host. The receipt explicitly hashes canonical LF text.
    return hashlib.sha256(WRAPPER.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def pin_digest(pin):
    return hashlib.sha256(json.dumps(pin, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def validate_probe(probe, *, library=None, pin=None):
    pin = pin or load_pin()
    value = probe.get("library", {})
    require(probe.get("machine") == "0x8664" and probe.get("apiVersion") == pin["icuVersion"]
            and isinstance(probe.get("apiVersion"), list) and all(type(item) is int for item in probe["apiVersion"])
            and probe.get("requiredExports") == pin["requiredExports"]
            and probe.get("collatorOpened") is True,
            "The private ICU DLL lacks the pinned x64 ABI, version or embedded collation data")
    require(value.get("name") == pin["library"] and type(value.get("bytes")) is int and value["bytes"] > 0
            and re.fullmatch(r"[0-9a-f]{64}", value.get("sha256", "")),
            "The private ICU DLL identity is missing")
    if library is not None:
        require(library.is_file() and library.name == pin["library"]
                and library.stat().st_size == value["bytes"] and digest(library) == value["sha256"],
                "The private ICU DLL differs from its verified bytes/SHA-256")
    return value


def validate_receipt(value, *, library=None, pin=None):
    pin = pin or load_pin()
    require(type(value.get("schemaVersion")) is int and value["schemaVersion"] == 1
            and json.dumps(value.get("sourcePin"), sort_keys=True) == json.dumps(pin, sort_keys=True),
            "The private ICU runtime comes from a different source pin")
    validate_probe(value, library=library, pin=pin)
    build = value.get("build", {})
    tree = build.get("sourceTree", {})
    require(build.get("language") == "CXX" and build.get("runtime") == "MT"
            and build.get("embeddedData") is True
            and build.get("wrapperSHA256") == wrapper_digest() and build.get("wrapperNewlines") == "LF"
            and re.fullmatch(r"[0-9a-f]{64}", build.get("wrapperRawSHA256", ""))
            and re.fullmatch(r"[0-9a-f]{64}", build.get("pinRawSHA256", ""))
            and build.get("pinCanonicalSHA256") == pin_digest(pin)
            and build.get("compilerID") == "Clang" and build.get("frontendVariant") == "MSVC"
            and isinstance(build.get("compilerVersion"), str) and build["compilerVersion"]
            and isinstance(build.get("cmakeVersion"), str) and build["cmakeVersion"],
            "The private ICU runtime build configuration is incomplete or changed")
    require(re.fullmatch(r"[0-9a-f]{64}", tree.get("sha256", ""))
            and type(tree.get("files")) is int and tree["files"] > 0,
            "The compiled ICU source tree was not verified against its pinned archive")
    return value


def validate_package(runtime, *, directory=None):
    value = runtime.get("unicodeRuntime", {})
    validate_receipt(value, library=directory / "RBNUnicode.dll" if directory is not None else None)
    libraries = runtime.get("libraries", [])
    matches = [item for item in libraries if item.get("name", "").casefold() == "rbnunicode.dll"]
    require(len(matches) == 1 and matches[0] == value["library"],
            "The package must contain exactly the verified private ICU DLL")
    require(not any(re.fullmatch(r"icu[A-Za-z0-9_-]*\.dll", name, re.I)
                    for name in runtime.get("systemLibraries", [])),
            "The private Windows ICU runtime must not depend on system ICU")
    return value


def validate_core(receipt, runtime):
    expected = validate_package(runtime)
    require(receipt.get("unicodeRuntime") == expected,
            "The core tests used a different private ICU runtime from the package")
    placements = receipt.get("unicodeRuntimePlacements", [])
    require(isinstance(placements, list) and placements, "No private ICU test executable placements were recorded")
    def windows_path(value):
        require(isinstance(value, str) and value, "A private ICU executable/placement path is missing")
        path = PureWindowsPath(value)
        require(path.is_absolute() and ".." not in path.parts,
                "A private ICU executable/placement path is not absolute")
        return path

    names = []
    for item in placements:
        require({key: item.get(key) for key in ("name", "bytes", "sha256")} == expected["library"]
                and isinstance(item.get("path"), str) and item["path"], "A private ICU placement differs from the package")
        names.append(windows_path(item["path"]).as_posix().casefold())
        require(names[-1].rsplit("/", 1)[-1] == "rbnunicode.dll", "A private ICU placement has the wrong filename")
    require(len(set(names)) == len(names), "Duplicate private ICU placements")
    executables = receipt.get("executables", [])
    require(isinstance(executables, list) and executables, "No Cargo test executables identify their adjacent private ICU DLL")
    for item in executables:
        executable = windows_path(item.get("executablePath"))
        expected_path = (executable.parent / expected["library"]["name"]).as_posix().casefold()
        actual_path = windows_path(item.get("unicodeRuntimePath")).as_posix().casefold()
        require(actual_path == expected_path and actual_path in names,
                "A Cargo test executable lacks its own adjacent private ICU DLL")
    return expected
