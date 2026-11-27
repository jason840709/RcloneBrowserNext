#!/usr/bin/env python3
"""Build the checksum-pinned, self-contained C++ ICU DLL on Windows only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location("private_unicode_runtime", HERE / "unicode-runtime.py")
UNICODE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UNICODE)


class SourceRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        UNICODE.require(parsed.scheme == "https" and parsed.hostname in {"api.github.com", "codeload.github.com"},
                        "Unexpected ICU source redirect")
        result = super().redirect_request(req, fp, code, msg, headers, newurl)
        if result is not None and parsed.hostname != "api.github.com":
            result.remove_header("Authorization")
        return result


def verify_archive(path, pin):
    UNICODE.require(path.is_file() and path.stat().st_size == pin["archiveBytes"]
                    and UNICODE.digest(path) == pin["archiveSHA256"],
                    "ICU source archive size/SHA-256 differs from the fixed pin; stop instead of rebuilding a different archive")


def download_source(path, pin):
    if path.exists():
        verify_archive(path, pin)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".download")
    UNICODE.require(not temporary.exists(), "A previous ICU download is incomplete")
    headers = {"User-Agent": "RcloneBrowserNext-Pinned-ICU", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    request = urllib.request.Request(pin["archiveURL"], headers=headers)
    with urllib.request.build_opener(SourceRedirect()).open(request, timeout=120) as source, temporary.open("xb") as output:
        count = 0
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            count += len(chunk)
            UNICODE.require(count <= pin["archiveBytes"], "ICU source archive exceeds the fixed size")
            output.write(chunk)
    # A repacked/mismatching upstream archive is retained as .download for
    # diagnosis and fails hard. No digest or source pin is rewritten.
    verify_archive(temporary, pin)
    temporary.replace(path)


def verified_source(archive, parent, pin):
    verify_archive(archive, pin)
    source = parent / pin["sourceRoot"]
    with tarfile.open(archive, "r:gz") as package:
        members = package.getmembers()
        for member in members:
            name = PurePosixPath(member.name)
            UNICODE.require(not name.is_absolute() and ".." not in name.parts and "\\" not in member.name
                            and name.parts and name.parts[0] == pin["sourceRoot"]
                            and (member.isfile() or member.isdir()), "Unsafe or unexpected member in the pinned ICU source")
        if not source.exists():
            parent.mkdir(parents=True, exist_ok=True)
            package.extractall(parent, members=members, filter="data")
        expected = set()
        records = []
        # Check cached extracted files against the actual pinned archive, not a
        # mutable cache-side manifest. This reads existing data without rewrite.
        for member in members:
            if not member.isfile():
                continue
            relative = PurePosixPath(member.name).relative_to(pin["sourceRoot"])
            path = source.joinpath(*relative.parts)
            UNICODE.require(path.is_file() and not path.is_symlink() and path.stat().st_size == member.size,
                            "The cached ICU source tree is incomplete or changed")
            value = hashlib.sha256()
            with package.extractfile(member) as raw:
                for chunk in iter(lambda: raw.read(1024 * 1024), b""):
                    value.update(chunk)
            UNICODE.require(UNICODE.digest(path) == value.hexdigest(), "The cached ICU source differs from its pinned archive")
            expected.add(relative.as_posix())
            records.append(relative.as_posix() + "\0" + value.hexdigest())
        actual = {path.relative_to(source).as_posix() for path in source.rglob("*") if path.is_file()}
        UNICODE.require(actual == expected, "Unexpected files were added to the pinned ICU source tree")
    header = (source / "icuSources/include/_foundation_unicode/uvernum.h").read_text(encoding="utf-8")
    version = [int(re.search(r"^#define U_ICU_VERSION_" + field + r"_NUM\s+(\d+)", header, re.M)[1])
               for field in ("MAJOR", "MINOR", "PATCHLEVEL")]
    UNICODE.require(version == pin["icuVersion"][:3], "The verified ICU source header has the wrong version")
    tree_sha = hashlib.sha256("\n".join(sorted(records)).encode("utf-8")).hexdigest()
    return source, {"sha256": tree_sha, "files": len(records)}


def allowed_compiler(path):
    return not re.search(r"(?:^|[/\\])swift(?:[/\\\d-]|$)|\.xctoolchain(?:[/\\]|$)", str(path), re.I)


def select_compiler(output, environment=None):
    env = environment if environment is not None else os.environ
    headers = []
    if env.get("VCToolsInstallDir"):
        headers.append(Path(env["VCToolsInstallDir"]) / "include/yvals_core.h")
    headers.extend(Path(part) / "yvals_core.h" for part in env.get("INCLUDE", "").split(";") if part)
    header = next((path for path in headers if path.is_file()), None)
    UNICODE.require(header is not None, "The active MSVC STL header is missing; use its x64 developer environment")
    text = header.read_text(encoding="utf-8")
    minimums = {int(value) for value in re.findall(r"Unexpected compiler version, expected Clang\s+(\d+)", text)}
    UNICODE.require(len(minimums) == 1, "Cannot establish the active MSVC STL's minimum Clang version")
    minimum = minimums.pop()
    report = {"schemaVersion": 1, "stl": {"path": str(header.resolve()), "sha256": UNICODE.digest(header),
               "minimumClangMajor": minimum, "toolsetVersion": env.get("VCToolsVersion")}, "candidates": [], "selected": None}
    paths = []
    if env.get("llvmX64"):
        paths.append((Path(env["llvmX64"]) / "clang-cl.exe", "active VS llvmX64"))
    if env.get("VCINSTALLDIR"):
        paths.append((Path(env["VCINSTALLDIR"]) / "Tools/Llvm/x64/bin/clang-cl.exe", "active VC LLVM"))
    if env.get("VSINSTALLDIR"):
        paths.append((Path(env["VSINSTALLDIR"]) / "VC/Tools/Llvm/x64/bin/clang-cl.exe", "active VS LLVM"))
    paths.extend((Path(part) / "clang-cl.exe", "PATH") for part in env.get("PATH", "").split(";") if part)
    seen = set()
    for path, origin in paths:
        if not path.is_file():
            if origin != "PATH":
                report["candidates"].append({"path": str(path), "origin": origin, "accepted": False, "reason": "not installed"})
            continue
        actual = path.resolve(strict=True)
        key = str(actual).casefold()
        if key in seen:
            continue
        seen.add(key)
        record = {"path": str(actual), "origin": origin, "accepted": False}
        report["candidates"].append(record)
        if not allowed_compiler(actual):
            record["reason"] = "Swift toolchain is not allowed"
            continue
        try:
            result = subprocess.run([str(actual), "--version"], capture_output=True, text=True,
                                    encoding="utf-8", timeout=15)
            version_text = (result.stdout + result.stderr).strip()
            match = re.search(r"(?:clang|LLVM)(?:-cl)?\s+version\s+(\d+(?:\.\d+)*)", version_text, re.I)
            target = re.search(r"^Target:\s*(\S+)", version_text, re.M)
            record.update(exitCode=result.returncode, versionOutput=version_text)
            if result.returncode != 0 or match is None or target is None:
                record["reason"] = "compiler version/target could not be verified"
                continue
            record.update(version=match[1], major=int(match[1].split(".")[0]), target=target[1])
            if not target[1].startswith("x86_64-") or "windows-msvc" not in target[1]:
                record["reason"] = "compiler does not target Windows x64 MSVC"
            elif record["major"] < minimum:
                record["reason"] = f"active STL requires Clang {minimum} or newer"
            else:
                record.update(accepted=True, reason="verified compiler/active STL and x64 MSVC target are compatible")
                if report["selected"] is None:
                    report["selected"] = dict(record)
        except (OSError, subprocess.TimeoutExpired) as error:
            record["reason"] = f"version probe failed: {error}"
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"privateICUCompilerSelection": report}, indent=2))
    UNICODE.require(report["selected"] is not None,
                    "No existing non-Swift clang-cl satisfies the active MSVC STL; no mismatch override or tool installation is permitted")
    return report


def cmake_commands(source, build, jobs, compiler):
    UNICODE.require(allowed_compiler(compiler), "Use a non-Swift clang-cl compiler")
    return (["cmake", "-S", str(HERE / "icu-wrapper"), "-B", str(build), "-G", "Ninja",
             "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_CXX_COMPILER=" + compiler,
             "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded", "-DRBN_ICU_SOURCE=" + str(source)],
            ["cmake", "--build", str(build), "--config", "Release", "--target", "_FoundationICU", "--parallel", str(jobs)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source-archive", type=Path)
    args = parser.parse_args()
    UNICODE.require(os.name == "nt" and platform.machine().lower() in {"amd64", "x86_64"},
                    "Build the private ICU DLL only on native Windows x64")
    pin = UNICODE.load_pin()
    cache = ROOT / ".build-cache/compat/icu-74.1" / pin["commit"]
    cache.mkdir(parents=True, exist_ok=True)
    selection = select_compiler(cache / "compiler-selection.json")
    archive = args.source_archive.resolve(strict=True) if args.source_archive else cache / "source.tar.gz"
    if args.source_archive is None:
        download_source(archive, pin)
    source, tree = verified_source(archive, cache / "source", pin)
    selected = selection["selected"]
    fingerprint = hashlib.sha256(json.dumps({"compiler": selected["path"], "version": selected["version"],
                    "stl": selection["stl"]["sha256"], "wrapper": UNICODE.wrapper_digest()}, sort_keys=True).encode()).hexdigest()[:16]
    build = cache / ("build-" + fingerprint)
    jobs = max(1, min(2, int(os.environ.get("CARGO_BUILD_JOBS", "2"))))
    for command in cmake_commands(source, build, jobs, selected["path"]):
        subprocess.run(command, check=True)
    library = build / "bin" / pin["library"]
    UNICODE.require(library.is_file(), "CMake did not produce the private ICU DLL")
    measured_path = cache / "private-probe.json"
    env = {key: value for key, value in os.environ.items()
           if not key.upper().startswith(("ICU_", "RCLONE_")) and key.upper() != "SDKROOT"}
    system = Path(os.environ.get("SystemRoot", r"C:\Windows"))
    env["PATH"] = os.pathsep.join(map(str, (system / "System32", system)))
    env["ICU_DATA"] = str(cache / "no-external-icu-data")
    subprocess.run([sys.executable, "-X", "utf8", "-B", str(HERE / "probe-runtime-provenance.py"),
                    "--unicode-library", str(library), "--output", str(measured_path)],
                   check=True, env=env, timeout=45)
    measured = json.loads(measured_path.read_text(encoding="utf-8"))
    UNICODE.validate_probe(measured, library=library, pin=pin)
    cmake_version = subprocess.check_output(["cmake", "--version"], text=True).splitlines()[0]
    compiler_file = build / "CMakeFiles" / cmake_version.split()[-1] / "CMakeCXXCompiler.cmake"
    UNICODE.require(compiler_file.is_file(), "Cannot identify the actual C++ compiler version")
    compiler_settings = compiler_file.read_text(encoding="utf-8")
    compiler = re.search(r'set\(CMAKE_CXX_COMPILER_VERSION "([^\"]+)"\)', compiler_settings)
    UNICODE.require(compiler, "The configured C++ compiler version is missing")
    UNICODE.require(int(compiler[1].split(".")[0]) == selected["major"]
                    and selected["major"] >= selection["stl"]["minimumClangMajor"],
                    "CMake's actual compiler differs from the verified compatible selection")
    UNICODE.require('set(CMAKE_CXX_COMPILER_ID "Clang")' in compiler_settings
                    and 'set(CMAKE_CXX_COMPILER_FRONTEND_VARIANT "MSVC")' in compiler_settings,
                    "CMake did not configure the requested standalone clang-cl MSVC ABI")
    receipt = {key: measured[key] for key in ("library", "machine", "apiVersion", "requiredExports", "collatorOpened")}
    receipt.update(schemaVersion=1, sourcePin=pin, build={"language": "CXX", "runtime": "MT", "embeddedData": True,
                    "wrapperSHA256": UNICODE.wrapper_digest(), "wrapperNewlines": "LF",
                    "wrapperRawSHA256": UNICODE.digest(UNICODE.WRAPPER), "pinRawSHA256": UNICODE.digest(UNICODE.PIN_PATH),
                    "pinCanonicalSHA256": UNICODE.pin_digest(pin), "sourceTree": tree,
                    "compilerID": "Clang", "frontendVariant": "MSVC",
                    "compilerVersion": compiler[1], "cmakeVersion": cmake_version, "compilerSelection": selection})
    args.runtime.mkdir(parents=True, exist_ok=True)
    destination = args.runtime / pin["library"]
    # The probe child has exited and released the DLL before either copy.
    shutil.copy2(library, destination)
    UNICODE.validate_receipt(receipt, library=destination, pin=pin)
    (args.runtime / "unicode-runtime.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"privateUnicodeRuntime": receipt}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
