"""Publish both attested platform assets together; interrupted uploads stay drafts.

Invoked only by CI after tests and attestation. Never replace a published asset.
An identical rerun may finish a partially uploaded draft without exposing an
incomplete release to installed updaters.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ASSETS = ("hotpl8-main.zip", "hotpl8-macos-main.zip")


class PublicationError(Exception):
    pass


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise PublicationError("Invalid repository")
        self.repository = repository

    def run(self, *args):
        result = subprocess.run(["gh", *map(str, args)], capture_output=True, timeout=180)
        if result.returncode:
            raise PublicationError("GitHub publication operation failed; retain the draft and retry")
        return result.stdout

    def find(self, tag):
        pages = json.loads(self.run("api", "--paginate", "--slurp",
                                    f"repos/{self.repository}/releases?per_page=100"))
        found = [r for page in pages for r in page if r["tag_name"] == tag]
        if len(found) > 1:
            raise PublicationError("Ambiguous release identity")
        return found[0] if found else None

    def create(self, tag, sha):
        self.run("release", "create", tag, "--repo", self.repository, "--draft",
                 "--prerelease", "--target", sha, "--title", "Tested main " + sha[:12],
                 "--notes", "Automatic main-channel packages for commit " + sha +
                 ". Ordinary stable installations are unchanged.")

    def upload(self, tag, path):
        # No --clobber: a rerun must never replace bytes under an existing name.
        self.run("release", "upload", tag, path, "--repo", self.repository)

    def publish(self, tag):
        self.run("release", "edit", tag, "--repo", self.repository, "--draft=false")


def check(release, tag, sha, hashes):
    if (not release or release.get("tag_name") != tag
            or release.get("target_commitish") != sha or not release.get("prerelease")):
        raise PublicationError("Existing release has a different identity; refusing replacement")
    missing = []
    for name, expected in hashes.items():
        assets = [a for a in release.get("assets", []) if a.get("name") == name]
        if not assets:
            missing.append(name)
        elif len(assets) != 1 or assets[0].get("digest") != expected:
            raise PublicationError("Existing asset differs; refusing replacement")
    return missing


def readback(github, tag, sha, hashes, *, complete=False, published=False):
    # GitHub's release list can lag a successful create/upload/edit. Retry only
    # reads: never repeat writes or relax identity and immutable-asset checks.
    for attempt in range(6):
        release = github.find(tag)
        if release is not None:
            missing = check(release, tag, sha, hashes)
            if (not complete or not missing) and (not published or not release.get("draft")):
                return release
        if attempt < 5:
            time.sleep(2)
    raise PublicationError("Release write not yet visible; retain the release and rerun")


def publish(github, directory, sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise PublicationError("An exact source SHA is required")
    directory = Path(directory)
    hashes = {}
    # Resolve every local artifact before making any external change.
    for name in ASSETS:
        with (directory / name).open("rb") as stream:
            hashes[name] = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
    tag = "main-" + sha
    release = github.find(tag)
    if release is None:
        github.create(tag, sha)
        release = readback(github, tag, sha, hashes)
    missing = check(release, tag, sha, hashes)
    if not release.get("draft"):
        if missing:
            raise PublicationError("Published release is incomplete; refusing modification")
        return "Identical immutable release already published"
    for name in missing:
        github.upload(tag, directory / name)
    release = readback(github, tag, sha, hashes, complete=True)
    if release.get("draft"):
        github.publish(tag)
    readback(github, tag, sha, hashes, complete=True, published=True)
    return "Both immutable platform packages published"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--directory", default=".")
    args = parser.parse_args()
    try:
        print(publish(GitHub(args.repository), args.directory, args.sha))
    except (PublicationError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
