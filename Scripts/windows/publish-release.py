#!/usr/bin/env python3
"""Publish only the exact Windows candidate already verified by Windows CI.

This runs on the explicit release branch. It never builds an application,
replaces an existing release, or changes a Mac asset or the stable latest tag.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess


ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".build-cache/windows-release"
REPOSITORY = "jason840709/RcloneBrowserNext"
TAG = "windows-v0.9.0-r1"
VERSION = "0.9.0+1"
MAC_TAG = "v0.9.0"
MAC_COMMIT = "ed76a5c269660fe919b7ffe664820baadff6790f"
MAC_ASSETS = {
    "Rclone_Browser_Next_0.9.0_macOS_arm64.zip":
        (661099566, 2831853, "941d9eabc75d3693cea1f6cff864ff44318806c555bf743f759779cac764aad1"),
    "Rclone_Browser_Next_0.9.0_macOS_x86_64.zip":
        (661099570, 2876017, "9fa21d2adaf32c79fb68df91d60818f150b3a199a1e460a57fce69b0339cdf91"),
}


def run(*arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True, encoding="utf-8")


def api(endpoint):
    return json.loads(run("gh", "api", f"repos/{REPOSITORY}/{endpoint}"))


def release_by_tag(tag):
    # REST /releases/tags only looks up published releases. GraphQL also
    # resolves a draft's pending tag; fetch its full asset data by release ID.
    owner, name = REPOSITORY.split("/", 1)
    query = """query($owner: String!, $name: String!, $tag: String!) {
      repository(owner: $owner, name: $name) {
        release(tagName: $tag) { databaseId tagName }
      }
    }"""
    result = json.loads(run("gh", "api", "graphql", "-f", "query=" + query,
                            "-f", "owner=" + owner, "-f", "name=" + name, "-f", "tag=" + tag))
    assert not result.get("errors"), "Release lookup returned GraphQL errors"
    repository = result["data"]["repository"]
    assert isinstance(repository, dict), "Release repository could not be read"
    found = repository["release"]
    if found is None:
        return None
    ident = found["databaseId"]
    assert type(ident) is int and ident > 0 and found["tagName"] == tag, "Release lookup returned a different identity"
    release = api(f"releases/{ident}")
    assert release["id"] == ident and release["tag_name"] == tag, "Release identity changed during lookup"
    return release


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def original_release():
    latest = api("releases/latest")
    release = api(f"releases/tags/{MAC_TAG}")
    tag = api(f"git/ref/tags/{MAC_TAG}")
    assert latest["id"] == release["id"] == 419070823, "The stable latest release changed"
    assert latest["tag_name"] == MAC_TAG and not release["draft"] and not release["prerelease"]
    assert tag["object"]["type"] == "commit" and tag["object"]["sha"] == MAC_COMMIT
    assets = {item["name"]: item for item in release["assets"]}
    for name, (ident, size, digest) in MAC_ASSETS.items():
        value = assets[name]
        assert (value["id"], value["size"], value["digest"]) == (ident, size, "sha256:" + digest)
    fields = ["id", "tag_name", "target_commitish", "name", "draft", "prerelease", "created_at", "updated_at", "published_at", "body"]
    asset_fields = ["id", "name", "size", "digest", "state", "created_at", "updated_at", "browser_download_url"]
    return {"release": {key: release.get(key) for key in fields},
            "tagCommit": tag["object"]["sha"], "latestReleaseID": latest["id"],
            "assets": [{key: item.get(key) for key in asset_fields}
                       for item in sorted(release["assets"], key=lambda item: item["id"])]}


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    receipt = {"passed": False, "tag": TAG, "version": VERSION}
    before = None
    try:
        assert os.environ.get("GITHUB_ACTIONS") == "true"
        assert os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
        assert os.environ.get("GITHUB_EVENT_NAME") == "push"
        assert os.environ.get("GITHUB_REF") == "refs/heads/release/" + TAG
        head = run("git", "rev-parse", "HEAD").strip()
        assert head == os.environ["GITHUB_SHA"]
        receipt["sourceCommit"] = head
        run("python3", "Scripts/windows/verify-mac-unchanged.py", "--output", str(CACHE / "mac-inputs.json"))
        before = original_release()
        save(CACHE / "original-release-before.json", before)

        # Refuse replacement, including an interrupted earlier draft. A partial
        # publication must be inspected before it is deliberately resumed.
        assert release_by_tag(TAG) is None, "A published release or draft already exists"
        existing_tag = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/git/ref/tags/{TAG}"],
                                      cwd=ROOT, text=True, capture_output=True)
        assert existing_tag.returncode != 0 and "HTTP 404" in existing_tag.stderr, "Tag already exists or its absence could not be confirmed"
        runs = api("actions/workflows/windows-candidate.yml/runs?branch=work%2Fwindows-fix&status=success&per_page=100")["workflow_runs"]
        candidates = [item for item in runs if item["head_sha"] == head
                      and item["head_branch"] == "work/windows-fix" and item["event"] == "push"
                      and item["status"] == "completed" and item["conclusion"] == "success"]
        assert candidates, "No successful Windows candidate exists for this exact commit"
        candidate = max(candidates, key=lambda item: item["id"])
        run_id = candidate["id"]
        jobs = api(f"actions/runs/{run_id}/jobs?per_page=100")["jobs"]
        assert len(jobs) >= 2 and all(job["status"] == "completed" and job["conclusion"] == "success" for job in jobs)
        receipt["candidateRunID"] = run_id
        receipt["candidateRunURL"] = candidate["html_url"]
        for kind in ("package", "verification"):
            destination = CACHE / "artifacts" / kind
            assert not destination.exists(), "Use a clean publication directory"
            run("gh", "run", "download", str(run_id), "--repo", REPOSITORY,
                "--name", "RcloneBrowserNext-Windows-r1-" + kind, "--dir", str(destination))
        package_root = CACHE / "artifacts/package"
        package_path = package_root / ".build-cache/compat/package-windows.json"
        package = json.loads(package_path.read_text(encoding="utf-8"))
        verification_path = CACHE / "artifacts/verification/candidate-verification.json"
        verification = json.loads(verification_path.read_text(encoding="utf-8"))
        assert package["sourceCommit"] == head and package["version"] == VERSION and package["releaseTag"] == TAG
        assert package["windowsRevision"] == 1 and package["baseVersion"] == "0.9.0"
        assert verification["passed"] is True and verification["sourceCommit"] == head
        assert str(verification["runID"]) == str(run_id)
        assert verification["packageReceiptSHA256"] == sha256(package_path)
        installer = package_root / "Distribution/Rclone_Browser_Next_0.9.0_Windows_r1_x64_Setup.exe"
        assert installer.stat().st_size == package["bytes"]
        assert sha256(installer) == package["sha256"] == verification["installerSha256"]
        receipt["installer"] = {"name": installer.name, "bytes": installer.stat().st_size, "sha256": sha256(installer)}
        receipt["verificationReceiptSHA256"] = sha256(verification_path)

        assets = CACHE / "release-assets"
        assets.mkdir()
        source = assets / "Rclone_Browser_Next_0.9.0_Windows_r1_Source.zip"
        run("git", "archive", "--format=zip", "--prefix=Rclone_Browser_Next_0.9.0_Windows_r1_Source/", "--output", str(source), head)
        public_evidence = assets / "Rclone_Browser_Next_0.9.0_Windows_r1_Verification.json"
        save(public_evidence, {"version": VERSION, "tag": TAG, "sourceCommit": head,
                               "candidateRunID": run_id, "candidateRunURL": candidate["html_url"],
                               "candidatePassed": True, "installer": receipt["installer"],
                               "verificationReceiptSHA256": receipt["verificationReceiptSHA256"],
                               "macInputsUnchanged": verification["macInputsUnchanged"],
                               "macInputsUnchangedMeaning": verification["macInputsUnchangedMeaning"],
                               "nonWindowsActiveSourceUnchanged": verification["nonWindowsActiveSourceUnchanged"],
                               "windowsOnlyCoreInsertions": verification["windowsOnlyCoreInsertions"],
                               "stableLatestRemains": MAC_TAG})
        published = [installer, source, public_evidence]
        checksums = assets / "SHA256SUMS.txt"
        checksums.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in published), encoding="utf-8")
        published.append(checksums)
        expected_assets = {path.name: (path.stat().st_size, "sha256:" + sha256(path)) for path in published}
        notes = ROOT / "docs/RELEASE_0.9.0_WINDOWS_R1.md"
        assert notes.is_file(), "Release notes must be reviewed before publication"
        created_tag = json.loads(run("gh", "api", "--method", "POST", f"repos/{REPOSITORY}/git/refs",
                                     "-f", "ref=refs/tags/" + TAG, "-f", "sha=" + head))
        assert created_tag["object"]["type"] == "commit" and created_tag["object"]["sha"] == head
        run("gh", "release", "create", TAG, *(str(path) for path in published), "--repo", REPOSITORY,
            "--verify-tag", "--target", head, "--title", "Rclone Browser Next 0.9.0 — Windows revision 1",
            "--notes-file", str(notes), "--draft", "--prerelease", "--latest=false")
        draft = release_by_tag(TAG)
        assert draft is not None and draft["draft"] and draft["prerelease"], "The new draft could not be verified"
        assert {item["name"]: (item["size"], item["digest"]) for item in draft["assets"]} == expected_assets
        draft_tag = api(f"git/ref/tags/{TAG}")
        assert draft_tag["object"]["type"] == "commit" and draft_tag["object"]["sha"] == head
        assert original_release() == before, "The stable release changed before publication"
        run("gh", "release", "edit", TAG, "--repo", REPOSITORY, "--draft=false", "--prerelease", "--latest=false")
        release = api(f"releases/tags/{TAG}")
        assert release["id"] == draft["id"] and not release["draft"] and release["prerelease"]
        assert {item["name"]: (item["size"], item["digest"]) for item in release["assets"]} == expected_assets
        assert api(f"git/ref/tags/{TAG}")["object"]["sha"] == head
        receipt["releaseID"] = release["id"]
        receipt["releaseURL"] = release["html_url"]
        receipt["assets"] = release["assets"]
        receipt["passed"] = True
    except Exception as error:
        receipt["error"] = str(error)
        raise
    finally:
        if before is not None:
            try:
                after = original_release()
                save(CACHE / "original-release-after.json", after)
                receipt["originalReleaseUnchanged"] = before == after
                if before != after:
                    receipt["passed"] = False
                    raise RuntimeError("The original release changed during publication")
            except Exception as error:
                receipt["passed"] = False
                receipt["originalReleaseError"] = str(error)
                save(CACHE / "publication.json", receipt)
                raise
        save(CACHE / "publication.json", receipt)
    print(json.dumps({key: receipt[key] for key in ("passed", "tag", "sourceCommit", "candidateRunID", "releaseURL", "originalReleaseUnchanged")}))


if __name__ == "__main__":
    main()
