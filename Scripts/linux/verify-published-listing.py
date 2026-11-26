#!/usr/bin/env python3
"""Compare the released Linux Swift helper with the current packaged Rust helper.

The pinned .deb is extracted on a disposable Linux runner, never installed.
Both helpers receive separate local state and the same checksum-pinned rclone.
The old helper retains its original $ORIGIN/lib; no SDK path is injected.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import locale
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import traceback


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "jason840709/RcloneBrowserNext"
BASELINE = {"version": "0.11.0", "tag": "v0.11.0", "releaseID": 445662659,
            "assetID": 749086416, "bytes": 30556612,
            "sha256": "5492a55e7ca4b53f4b9886b3a7e36a60e4c63029ce8d7be0bc81edeeee747426",
            "filename": "Rclone_Browser_Next_0.11.0_Linux_amd64.deb"}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Reuse only the existing redirect/credential-safe public release HTTP client.
# None of its Windows installer functions or main entry point are executed.
HTTP = load("published_baseline_http", ROOT / "Scripts/windows/prepare-baseline.py")
ORACLE = load("published_listing_fixture", ROOT / "Tests/windows-local-list-oracle.py")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def metadata(path):
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": HTTP.digest_file(path)}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_release(release):
    require(release.get("id") == BASELINE["releaseID"] and release.get("tag_name") == BASELINE["tag"]
            and release.get("draft") is False and release.get("prerelease") is False
            and release.get("published_at"), "The published Linux release identity changed")
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == BASELINE["filename"]]
    require(len(matches) == 1, "Expected exactly one published Linux baseline deb")
    asset = matches[0]
    require(asset.get("id") == BASELINE["assetID"] and asset.get("state") == "uploaded"
            and asset.get("size") == BASELINE["bytes"] and asset.get("digest") == "sha256:" + BASELINE["sha256"]
            and asset.get("url") == f"https://api.github.com/repos/{REPOSITORY}/releases/assets/{BASELINE['assetID']}"
            and asset.get("browser_download_url") == f"https://github.com/{REPOSITORY}/releases/download/{BASELINE['tag']}/{BASELINE['filename']}",
            "The Linux deb differs from the pinned release asset receipt")
    return asset


def download_asset(asset, destination):
    require(not destination.exists(), "Refusing to replace an existing baseline download")
    temporary = destination.with_suffix(".download")
    require(not temporary.exists(), "Refusing to reuse a partial baseline download")
    try:
        with HTTP.request(asset["url"], binary=True) as source, temporary.open("xb") as output:
            count = 0
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                count += len(chunk)
                require(count <= BASELINE["bytes"], "The Linux deb exceeds its pinned byte count")
                output.write(chunk)
        require(count == BASELINE["bytes"] and HTTP.digest_file(temporary) == BASELINE["sha256"],
                "The Linux deb failed its pinned SHA-256 or size check")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def isolated_environment(directory):
    directory.mkdir(parents=True, exist_ok=True)
    paths = {"HOME": directory / "home", "TMPDIR": directory / "tmp",
             "XDG_CONFIG_HOME": directory / "config", "XDG_CACHE_HOME": directory / "cache",
             "XDG_DATA_HOME": directory / "data"}
    for path in paths.values():
        path.mkdir(exist_ok=True)
    # Whitelisting avoids SDK/LD_LIBRARY_PATH, rclone account settings and tokens.
    env = {key: value for key, value in os.environ.items()
           if key in {"LANG", "LANGUAGE", "TZ"} or key.startswith("LC_")}
    env.update({key: str(path) for key, path in paths.items()})
    env.update(PATH="/usr/bin:/bin", TMP=env["TMPDIR"], TEMP=env["TMPDIR"])
    return env


def extract_baseline(deb, destination, env):
    require(not destination.exists(), "Refusing to reuse a baseline extraction directory")
    subprocess.run(["dpkg-deb", "-x", str(deb), str(destination)], check=True,
                   capture_output=True, text=True, encoding="utf-8", env=env, timeout=60)
    helpers = [path for path in destination.rglob("rbn-engine") if path.is_file()]
    require(len(helpers) == 1 and helpers[0].resolve().is_relative_to(destination.resolve()),
            "Expected one original helper inside the extracted Linux deb")
    require((helpers[0].parent / "lib").is_dir(), "The published helper's adjacent runtime/lib is missing")
    return helpers[0].resolve()


def parsed_links(text):
    require("not found" not in text.lower(), "A helper has unresolved runtime libraries")
    return [{"name": match[0], "path": match[1]}
            for match in re.findall(r"^\s*(\S+)\s+=>\s+(/.+?)\s+\(0x[0-9a-fA-F]+\)", text, re.M)]


def verify_dependency_separation(old_dynamic, old_linked, new_linked, extracted):
    runpaths = [part for value in re.findall(r"\((?:RPATH|RUNPATH)\).*?\[(.*?)\]", old_dynamic)
                for part in value.split(":")]
    require(runpaths == ["$ORIGIN/lib"], "The published helper's original $ORIGIN/lib changed")
    old, new = parsed_links(old_linked), parsed_links(new_linked)
    require(old and new, "No resolved shared libraries were recorded")
    swift = re.compile(r"swift|foundation|libdispatch|libblocksruntime", re.I)
    require(any(swift.search(item["name"]) for item in old), "The baseline did not load its original Swift runtime")
    require(all(Path(item["path"]).resolve().is_relative_to(extracted.resolve()) for item in old if swift.search(item["name"])),
            "The old helper resolved a Swift library outside its extracted runtime")
    require(not any(swift.search(item["name"]) or Path(item["path"]).resolve().is_relative_to(extracted.resolve()) for item in new),
            "The candidate unexpectedly depends on the old Swift runtime")
    return {"oldRunpaths": runpaths, "oldLibraries": old, "candidateLibraries": new}


def configured_client(protocol, rclone, sessions):
    protocol.child_environment = isolated_environment

    class Client:
        def __init__(self, binary, state, timeout):
            self.binary = binary
            self.client = protocol.Client(binary, state, timeout)
            try:
                config = state / "oracle-rclone.conf"
                config.write_text("", encoding="utf-8")
                result = self.client.call("saveSettings", {"rclonePath": str(rclone), "configPath": str(config),
                                                          "autoCheckUpdates": False})
                require(result.get("available") is True, "A helper did not load the exact pinned rclone fixture")
            except BaseException:
                self.finish()
                raise

        def call(self, method, value):
            return self.client.call(method, value)

        def finish(self):
            receipt = self.client.finish()
            receipt["pathPolicy"] = "Linux system PATH only; isolated HOME/state/TMP; no loader or SDK environment"
            sessions.append({"binary": metadata(self.binary), "receipt": receipt})
            return receipt

    return Client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--rclone", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "linux" and platform.machine() == "x86_64"
            and os.environ.get("GITHUB_ACTIONS", "").lower() == "true",
            "Run only on a disposable Linux x64 Actions runner")
    output = args.output.resolve()
    cache = (ROOT / ".build-cache/compat").resolve()
    require(output.parent == cache, "The oracle evidence must stay inside the existing compatibility cache")
    cache.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "passed": False, "startedAt": datetime.now(timezone.utc).isoformat(),
              "sourceCommit": os.environ.get("GITHUB_SHA"), "runID": os.environ.get("GITHUB_RUN_ID"),
              "system": platform.platform(), "libc": platform.libc_ver(), "baseline": BASELINE,
              "scope": "published deb extraction only; no installation, SDK injection or user data",
              "sessions": [], "evidence": []}
    try:
        engine, rclone = args.engine.resolve(strict=True), args.rclone.resolve(strict=True)
        require(engine == cache / "runtime/rbn-engine"
                and rclone == (ROOT / ".build-cache/ci-engine/rclone").resolve(),
                "Use this run's built runtime and checksum-pinned rclone fixture")
        report["candidate"], report["rclone"] = metadata(engine), metadata(rclone)
        report["localeEnvironment"] = {key: value for key, value in os.environ.items()
                                        if key in {"LANG", "LANGUAGE"} or key.startswith("LC_")}
        try:
            report["probeCollateLocale"] = locale.setlocale(locale.LC_COLLATE, "")
        except locale.Error as error:
            report["probeCollateLocaleError"] = str(error)
        report["oldHelperRuntimeLocale"] = "not observed inside the published Swift process"
        working = cache / "published-listing-oracle"
        require(not working.exists(), "Refusing to reuse the oracle's extraction or state directories")
        working.mkdir()
        env = isolated_environment(working / "inspection")
        with HTTP.request(f"https://api.github.com/repos/{REPOSITORY}/releases/tags/{BASELINE['tag']}") as response:
            raw = response.read(1024 * 1024 + 1)
        require(len(raw) <= 1024 * 1024, "Unexpectedly large Linux release metadata")
        release = json.loads(raw)
        asset = validate_release(release)
        report["releaseMetadata"] = release
        deb = working / BASELINE["filename"]
        download_asset(asset, deb)
        report["download"] = metadata(deb)
        extracted = working / "baseline"
        swift = extract_baseline(deb, extracted, env)
        report["oldHelper"] = metadata(swift)
        old_dynamic = subprocess.check_output(["readelf", "-d", str(swift)], text=True, encoding="utf-8", env=env, timeout=30)
        old_linked = subprocess.check_output(["ldd", str(swift)], text=True, encoding="utf-8", env=env, timeout=30)
        new_linked = subprocess.check_output(["ldd", str(engine)], text=True, encoding="utf-8", env=env, timeout=30)
        report["runtime"] = verify_dependency_separation(old_dynamic, old_linked, new_linked, extracted)
        report["runtime"].update(oldDynamic=old_dynamic, oldLdd=old_linked, candidateLdd=new_linked)
        for item in report["runtime"]["oldLibraries"]:
            if re.search(r"swift|foundation|libdispatch|libblocksruntime|icu", item["name"], re.I):
                item["file"] = metadata(Path(item["path"]))
        manifest = swift.parent / "runtime-manifest.json"
        if manifest.is_file():
            saved = output.with_name(output.stem + "-runtime-manifest.json")
            saved.write_bytes(manifest.read_bytes())
            report["runtimeManifest"] = metadata(manifest)
            report["evidence"].append(metadata(saved))
        protocol = load("linux_listing_protocol", ROOT / "Scripts/windows/probe-filesystem.py")
        client = configured_client(protocol, rclone, report["sessions"])
        binaries = {"swift": ORACLE.binary_metadata(swift), "rust": ORACLE.binary_metadata(engine)}
        comparisons = (("original-34", ORACLE.ORIGINAL_FILES, ORACLE.ORIGINAL_DIRECTORIES),
                       ("expanded-unicode", ORACLE.EXTENDED_FILES, ORACLE.EXTENDED_DIRECTORIES))
        report["groups"] = []
        for group, files, directories in comparisons:
            result = ORACLE.compare_group(client, swift, engine, working / group, files, directories, group, binaries)
            path = output.with_name(output.stem + "-" + group + ".json")
            write_json(path, result)
            report["groups"].append(result)
            report["evidence"].append(metadata(path))
        # Collect both groups before refusing any mismatch; never retry a list
        # or change the original helper's order/metadata to make it pass.
        for result, (group, files, directories) in zip(report["groups"], comparisons):
            ORACLE.verify_group_receipt(result, files, directories, group)
        report["passed"] = True
    except Exception as error:
        report["error"] = {"type": type(error).__name__, "message": str(error), "traceback": traceback.format_exc()}
    finally:
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        write_json(output, report)
    print(json.dumps({key: report.get(key) for key in ("passed", "sourceCommit", "error")}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
