#!/usr/bin/env python3
"""Install an immutable published Windows baseline on an ephemeral CI runner.

No source is built. Both the GitHub asset digest and the previously verified
release hash must match before the installer is executed. Each workflow matrix
job installs only one release because NSIS shares the application registration.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "jason840709/RcloneBrowserNext"
# Public release receipts, independently downloaded and verified at release.
BASELINES = {
    "0.8.0": {
        "releaseID": 418697196,
        "assetID": 660047360,
        "bytes": 16921145,
        "sha256": "4b71936b341c7030f12fbadafd5f74246fc7eaf1ad0c5fa6e69fe102bc4d7a63",
    },
    "0.9.0": {
        "releaseID": 419070823,
        "assetID": 661099568,
        "bytes": 17043504,
        "sha256": "d943ee8a30e5bb8e16ad8a2c1edd20645c3cef733378ea8a1a7890de0f886780",
    },
}


class ReleaseRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if parsed.scheme != "https" or parsed.hostname not in {
            "api.github.com", "github.com", "release-assets.githubusercontent.com",
            "objects.githubusercontent.com", "github-releases.githubusercontent.com",
        }:
            raise RuntimeError("Unexpected GitHub release download redirect host")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and parsed.hostname != "api.github.com":
            # urllib otherwise forwards request headers across redirects.
            redirected.remove_header("Authorization")
        return redirected


def request(url, *, binary=False):
    headers = {
        "User-Agent": "RcloneBrowserNext-Windows-Baseline-Diagnostics",
        "Accept": "application/octet-stream" if binary else "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if urllib.parse.urlsplit(url).hostname == "api.github.com":
        token = os.environ.get("GH_TOKEN")
        if token:
            headers["Authorization"] = "Bearer " + token
    return urllib.request.build_opener(ReleaseRedirect()).open(
        urllib.request.Request(url, headers=headers), timeout=120
    )


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_release(release, version):
    expected = BASELINES[version]
    filename = f"Rclone_Browser_Next_{version}_Windows_x64_Setup.exe"
    if (release.get("id") != expected["releaseID"]
            or release.get("tag_name") != "v" + version
            or release.get("draft") is not False
            or release.get("prerelease") is not False
            or not release.get("published_at")):
        raise RuntimeError("The published baseline release identity changed")
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == filename]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one published Windows installer")
    asset = matches[0]
    api_url = f"https://api.github.com/repos/{REPOSITORY}/releases/assets/{expected['assetID']}"
    download_url = f"https://github.com/{REPOSITORY}/releases/download/v{version}/{filename}"
    if (asset.get("id") != expected["assetID"]
            or asset.get("state") != "uploaded"
            or asset.get("size") != expected["bytes"]
            or asset.get("digest") != "sha256:" + expected["sha256"]
            or asset.get("url") != api_url
            or asset.get("browser_download_url") != download_url):
        raise RuntimeError("The published installer differs from the pinned release receipt")
    return asset


def download_installer(asset, destination, expected):
    temporary = destination.with_suffix(".download")
    for attempt in range(3):
        try:
            # The API's octet-stream route follows a short-lived public asset
            # redirect; no token is forwarded to that download host.
            with request(asset["url"], binary=True) as source, temporary.open("wb") as out:
                count = 0
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    count += len(chunk)
                    if count > expected["bytes"]:
                        raise RuntimeError("The downloaded installer exceeds the pinned size")
                    out.write(chunk)
            if count != expected["bytes"] or digest_file(temporary) != expected["sha256"]:
                raise RuntimeError("The downloaded installer fails the pinned SHA-256 or size check")
            temporary.replace(destination)
            return
        except (OSError, urllib.error.URLError):
            temporary.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))
        except Exception:
            temporary.unlink(missing_ok=True)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=sorted(BASELINES), required=True)
    parser.add_argument("--rclone", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (os.name != "nt" or platform.machine().lower() not in {"amd64", "x86_64"}
            or os.environ.get("GITHUB_ACTIONS", "").lower() != "true"):
        raise SystemExit("This installer preparation runs only on ephemeral Windows x64 Actions runners")
    evidence = args.output.resolve()
    if not evidence.is_relative_to((ROOT / ".build-cache" / "windows-diagnostics").resolve()):
        raise SystemExit("Evidence must remain inside this checkout's Windows diagnostics cache")
    evidence.mkdir(parents=True, exist_ok=True)
    receipt = {
        "schemaVersion": 1, "version": args.version, "prepared": False,
        "repository": REPOSITORY, "diagnosticCommit": os.environ.get("GITHUB_SHA"),
        "runID": os.environ.get("GITHUB_RUN_ID"), "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "system": platform.platform(), "expectedInstaller": BASELINES[args.version],
    }
    try:
        rclone = args.rclone.resolve(strict=True)
        if not rclone.is_file():
            raise RuntimeError("The pinned rclone fixture is unavailable")
        receipt["rclone"] = {"bytes": rclone.stat().st_size, "sha256": digest_file(rclone)}
        api_url = f"https://api.github.com/repos/{REPOSITORY}/releases/tags/v{args.version}"
        with request(api_url) as response:
            raw = response.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise RuntimeError("Unexpectedly large release metadata")
        release = json.loads(raw)
        asset = validate_release(release, args.version)
        # Public API response only; request headers and download redirect URLs
        # are deliberately absent from retained evidence.
        write_json(evidence / "release-metadata.json", release)
        receipt["releaseMetadataSHA256"] = digest_file(evidence / "release-metadata.json")
        cache = ROOT / ".build-cache" / "windows-baselines" / args.version
        if cache.is_symlink():
            raise RuntimeError("The baseline cache cannot be a symlink")
        cache.mkdir(parents=True, exist_ok=True)
        installer = cache / asset["name"]
        download_installer(asset, installer, BASELINES[args.version])
        receipt["installer"] = {
            "name": asset["name"], "assetID": asset["id"], "bytes": installer.stat().st_size,
            "sha256": digest_file(installer), "apiDigest": asset["digest"],
            "knownReleaseHashVerified": True, "apiDigestVerified": True,
        }
        installed = cache / "installed"
        # Refuse a prior installation instead of silently reusing or removing it.
        installed.mkdir(exist_ok=False)
        with (evidence / "installer.log").open("w", encoding="utf-8") as log:
            result = subprocess.run([str(installer), "/S", f"/D={installed}"],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=240)
        receipt["installerExitCode"] = result.returncode
        if result.returncode != 0:
            raise RuntimeError(f"The baseline installer failed with exit code {result.returncode}")
        applications = [installed / name for name in ("rclone-browser-next.exe", "Rclone Browser Next.exe")]
        applications = [path for path in applications if path.is_file()]
        engines = list(installed.rglob("rbn-engine.exe"))
        if len(applications) != 1 or len(engines) != 1:
            raise RuntimeError("Expected one installed application and one bundled engine")
        app, engine = applications[0], engines[0]
        receipt["installedExecutables"] = {
            label: {"relativePath": path.relative_to(installed).as_posix(),
                    "bytes": path.stat().st_size, "sha256": digest_file(path)}
            for label, path in (("app", app), ("engine", engine))
        }
        receipt["prepared"] = True
        write_json(evidence / "preparation.json", receipt)
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                for key, value in (("app", app), ("engine", engine), ("evidence", evidence)):
                    print(f"{key}={value}", file=output)
        print(json.dumps(receipt, indent=2))
        return 0
    except Exception as error:
        receipt["error"] = {"type": type(error).__name__, "message": str(error)}
        write_json(evidence / "preparation.json", receipt)
        print(json.dumps(receipt, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
