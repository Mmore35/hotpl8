"""Local Delivery protocol 1. Standard library only; no application imports.

An installed bootstrap invokes the runner from its immutable release. A candidate
cannot replace this process's source. Production selection is one atomic JSON
pointer; persistent application state is never copied or restored by this runner.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import datetime, timezone

PROTOCOL = 1
SHA = re.compile(r"[0-9a-f]{40}")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


class DeliveryError(Exception):
    pass


class Deferred(DeliveryError):
    pass


def now():
    return datetime.now(timezone.utc).isoformat()


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return default


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + "." + os.urandom(8).hex() + ".tmp")
    try:
        with tmp.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_root(path):
    p = Path(path).absolute()
    if not p.is_absolute() or p == Path(p.anchor):
        raise DeliveryError("An absolute non-root installation path is required")
    for node in (p, *p.parents):
        if node.exists() and (node.is_symlink() or getattr(node.lstat(), "st_file_attributes", 0) & 1024):
            raise DeliveryError("Installation paths cannot traverse links")
    return p


@contextlib.contextmanager
def lock(path, wait=0):
    """Windows sharing exclusion also interoperates with .NET File.Open."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + wait
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                                      ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        while True:
            handle = kernel.CreateFileW(str(path), 0xC0000000, 0, None, 4, 0x80, None)
            if handle != ctypes.c_void_p(-1).value:
                break
            error = ctypes.get_last_error()
            if error not in (32, 33):
                raise DeliveryError("Cannot acquire installation lock (Windows error %d)" % error)
            if time.monotonic() >= deadline:
                raise Deferred("Application is busy; update will retry")
            time.sleep(.2)
        try:
            yield
        finally:
            kernel.CloseHandle(handle)
    else:
        import fcntl
        with path.open("a+b") as stream:
            while True:
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise Deferred("Application is busy; update will retry")
                    time.sleep(.2)
            try:
                yield
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)


def run(args, timeout=120):
    try:
        result = subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout,
                                creationflags=NO_WINDOW)
    except subprocess.TimeoutExpired:
        raise Deferred("Command timed out; update will retry") from None
    if result.returncode:
        # Subprocess output may include private paths/account data. Keep it out of
        # the status feed. Operators can run their own diagnostics explicitly.
        raise DeliveryError("Command failed: " + Path(str(args[0])).name)
    return result.stdout


class GitHub:
    def __init__(self, repo, executable="gh"):
        if not REPO.fullmatch(repo):
            raise DeliveryError("Invalid repository")
        self.repo, self.executable = repo, executable

    def api(self, endpoint):
        return json.loads(run([self.executable, "api", "repos/" + self.repo + "/" + endpoint], 45))

    def main(self):
        sha = self.api("commits/main")["sha"]
        if not SHA.fullmatch(sha):
            raise DeliveryError("Invalid main revision")
        return sha

    def candidate(self, sha, config):
        try:
            release = self.api("releases/tags/main-" + sha)
        except DeliveryError:
            raise Deferred("Main has no available passing release (or GitHub is unavailable)") from None
        if release.get("draft") or release.get("tag_name") != "main-" + sha:
            raise DeliveryError("Invalid main release identity")
        if self.api("commits/main-" + sha).get("sha") != sha:
            raise DeliveryError("Release tag does not identify the selected commit")
        runs = self.api("actions/workflows/" + config["workflow"] + "/runs?head_sha=" + sha + "&event=push&per_page=30")
        eligible = [r for r in runs.get("workflow_runs", [])
                    if r.get("head_sha") == sha and r.get("head_branch") == "main"
                    and r.get("event") == "push" and r.get("status") == "completed"
                    and r.get("conclusion") == "success"
                    and r.get("head_repository", {}).get("full_name", "").lower() == self.repo.lower()]
        if not eligible:
            raise Deferred("Main release workflow has not completed successfully")
        assets = [a for a in release.get("assets", []) if a.get("name") == config["asset"]]
        if len(assets) != 1 or not re.fullmatch(r"sha256:[a-f0-9]{64}", assets[0].get("digest") or ""):
            raise DeliveryError("Release must contain one asset with an authenticated SHA256 digest")
        if assets[0].get("size", 0) > 250_000_000:
            raise DeliveryError("Release download exceeds size limit")
        return {"sha": sha, "assetId": assets[0]["id"], "digest": assets[0]["digest"][7:],
                "runId": eligible[0]["id"], "releaseId": release["id"]}

    def is_forward(self, previous, candidate):
        return self.api("compare/" + previous + "..." + candidate).get("status") in ("ahead", "identical")

    def download(self, candidate, path):
        # gh handles the authenticated asset redirect without putting tokens in
        # command lines or forwarding our own Authorization header to a CDN.
        with Path(path).open("wb") as stream:
            result = subprocess.run([self.executable, "api", "repos/" + self.repo + "/releases/assets/" + str(candidate["assetId"]),
                                     "-H", "Accept: application/octet-stream"], stdout=stream,
                                    stderr=subprocess.PIPE, timeout=180, creationflags=NO_WINDOW)
        if result.returncode:
            raise Deferred("Package download failed")
        if digest(path) != candidate["digest"]:
            raise DeliveryError("Package SHA256 mismatch")

    def attest(self, archive, sha, workflow):
        run([self.executable, "attestation", "verify", archive, "--repo", self.repo,
             "--signer-workflow", self.repo + "/.github/workflows/" + workflow,
             "--source-digest", sha, "--source-ref", "refs/heads/main", "--deny-self-hosted-runners"], 120)


def unpack(archive, destination, config, sha):
    """Validate the complete archive BEFORE extracting or executing any code."""
    with zipfile.ZipFile(archive) as z:
        infos = z.infolist()
        if len(infos) > 5000 or sum(i.file_size for i in infos) > 250_000_000:
            raise DeliveryError("Package exceeds extraction limits")
        seen = set()
        for item in infos:
            name = item.filename
            parts = PurePosixPath(name).parts
            if (not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", name)
                    or any(x in (".", "..") or x.endswith((".", " ")) for x in parts)
                    or any(re.fullmatch(r"(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\..*)?", x) for x in parts)
                    or name.lower() in seen or stat.S_ISLNK(item.external_attr >> 16)):
                raise DeliveryError("Unsafe or duplicate archive path")
            seen.add(name.lower())
        try:
            manifest = json.loads(z.read("delivery-manifest.json"))
        except (KeyError, ValueError):
            raise DeliveryError("Missing delivery manifest") from None
        if (manifest.get("protocol") != PROTOCOL or manifest.get("product") != config["product"]
                or manifest.get("repository") != config["repository"] or manifest.get("sha") != sha
                or manifest.get("platform") != "windows" or manifest.get("stateCompatibility") != config["stateCompatibility"]):
            raise DeliveryError("Incompatible or incorrectly identified release")
        hashes = manifest.get("files", {})
        if set(hashes) != {i.filename for i in infos} - {"delivery-manifest.json"}:
            raise DeliveryError("Release file inventory mismatch")
        for name, expected in hashes.items():
            if hashlib.sha256(z.read(name)).hexdigest() != expected:
                raise DeliveryError("Release file checksum mismatch")
        if config["adapter"] not in hashes:
            raise DeliveryError("Missing application adapter")
        z.extractall(destination)
    return manifest


def invoke_adapter(config, release, operation, root):
    ps = config.get("powershell") or str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
    return run([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
         Path(release) / config["adapter"], "-Operation", operation,
         "-InstallDirectory", root, "-ReleaseDirectory", release,
         "-StateDirectory", config["stateDirectory"]], config.get("adapterTimeout", 120))


@contextlib.contextmanager
def drained(root, config):
    with contextlib.ExitStack() as stack:
        stack.enter_context(lock(root / "runtime.lock", config.get("drainSeconds", 30)))
        for path in config.get("writerLocks", []):
            stack.enter_context(lock(path, config.get("drainSeconds", 30)))
        yield


def recover(root, config, adapter=invoke_adapter):
    txn = read(root / "transaction.json")
    if not txn:
        return
    # An interrupted activation is never silently declared healthy. Restore the
    # prior pointer, keeping all state written since deployment and both releases.
    previous = txn.get("previous")
    if previous:
        with drained(root, config):
            write(root / "current.json", previous)
            adapter(config, root / previous["release"], "recover", root)
    elif read(root / "current.json"):
        raise DeliveryError("Interrupted first activation requires operator recovery")
    write(root / "rejected.json", {"sha": txn["candidate"]["sha"], "at": now(), "reason": "Interrupted activation"})
    (root / "transaction.json").unlink()


def update(root, github=None, adapter=invoke_adapter):
    root = safe_root(root)
    config = read(root / "delivery.json")
    if not config or config.get("protocol") != PROTOCOL or config.get("channel") != "main":
        raise DeliveryError("Installation is not registered for main delivery")
    if not re.fullmatch(r"[a-z][a-z0-9-]*", config.get("product", "")):
        raise DeliveryError("Invalid product")
    github = github or GitHub(config["repository"], config.get("gh", "gh"))
    with lock(root / "update.lock"):
        status = read(root / "delivery-status.json", {})
        status.update(lastCheck=now(), channel="main")
        candidate = None
        try:
            recover(root, config, adapter)
            current = read(root / "current.json")
            sha = github.main()
            status.update(desiredSha=sha, installedSha=current.get("sha") if current else None)
            if current and current["sha"] == sha:
                # Existing enrollments can gain components without a new main
                # commit. Product readiness must still cover those components.
                if config.get("componentHealth"):
                    adapter(config, root / current["release"], "health", root)
                status.update(state="current", reason=None)
                return status
            if current and not github.is_forward(current["sha"], sha):
                raise Deferred("Main history was rewritten; automatic downgrade or divergence is not permitted")
            if read(root / "rejected.json", {}).get("sha") == sha:
                raise Deferred("This revision failed activation; awaiting a newer main revision")
            candidate = github.candidate(sha, config)
            releases = root / "releases"
            releases.mkdir(exist_ok=True)
            destination = safe_root(releases / sha)
            # Never trust an existing directory by name alone. A previous fully
            # verified extraction has a digest receipt outside its signed files.
            receipt = read(root / "receipts" / (sha + ".json"))
            if destination.exists():
                if not receipt or receipt.get("digest") != candidate["digest"]:
                    raise DeliveryError("Existing candidate has no matching verified receipt")
                if digest(destination / "delivery-manifest.json") != receipt.get("manifestDigest"):
                    raise DeliveryError("Previously staged manifest was modified")
                manifest = read(destination / "delivery-manifest.json")
                for name, expected in manifest["files"].items():
                    if digest(destination / name) != expected:
                        raise DeliveryError("Previously staged release was modified")
            else:
                with tempfile.TemporaryDirectory(prefix="download-", dir=root) as temporary:
                    temporary = Path(temporary)
                    archive = temporary / "package.zip"
                    github.download(candidate, archive)
                    if config.get("attestation"):
                        github.attest(archive, sha, config["workflow"])
                    stage = temporary / "release"
                    unpack(archive, stage, config, sha)
                    adapter(config, stage, "preflight", root)
                    os.replace(stage, destination)
                    candidate["manifestDigest"] = digest(destination / "delivery-manifest.json")
                    write(root / "receipts" / (sha + ".json"), candidate)
            adapter(config, destination, "preflight", root)
            if github.main() != sha:
                raise Deferred("Main advanced while staging; update will retry the newer revision")
            pointer = {"protocol": PROTOCOL, "sha": sha, "release": "releases/" + sha, "activatedAt": now()}
            with drained(root, config):
                write(root / "transaction.json", {"previous": current, "candidate": pointer, "at": now()})
                try:
                    adapter(config, destination, "drain", root)
                    write(root / "current.json", pointer)
                    adapter(config, destination, "activate", root)
                    adapter(config, destination, "health", root)
                except Exception:
                    if current:
                        write(root / "current.json", current)
                        adapter(config, root / current["release"], "recover", root)
                    write(root / "rejected.json", {"sha": sha, "at": now(), "reason": "Activation health check failed"})
                    if current:
                        (root / "transaction.json").unlink()
                    raise
                if current:
                    write(root / "previous.json", current)
                (root / "transaction.json").unlink()
            status.update(state="current", reason=None, installedSha=sha, lastUpdate=now())
            return status
        except Deferred as error:
            status.update(state="pending", reason=str(error))
            return status
        except Exception as error:
            status.update(state="error", reason=str(error) if isinstance(error, DeliveryError) else type(error).__name__)
            return status
        finally:
            # The pointer is the actual installed state, including after recovery.
            current = read(root / "current.json", {})
            status["installedSha"] = current.get("sha")
            write(root / "delivery-status.json", status)


def preview(root, number, gh=None):
    root = safe_root(root)
    config = read(root / "delivery.json")
    gh = gh or GitHub(config["repository"], config.get("gh", "gh"))
    pr = gh.api("pulls/" + str(number))
    sha = pr["head"]["sha"]
    if not SHA.fullmatch(sha):
        raise DeliveryError("Invalid PR revision")
    # These are inert CI renderings. No candidate scripts, HTML or native code
    # are launched on the host, even for a PR from a fork.
    runs = gh.api("actions/workflows/" + config["previewWorkflow"] + "/runs?event=pull_request&per_page=100")
    def belongs_to_pr(run):
        if any(p.get("number") == number for p in run.get("pull_requests", [])):
            return True
        # GitHub can clear the run's PR association after merge. Retained inert
        # renders remain attributable through the exact head repository, branch
        # and SHA from the merged PR. Never infer this from branch name alone.
        head = pr.get("head", {})
        repository_id = head.get("repo", {}).get("id")
        return (pr.get("merged") is True and not run.get("pull_requests")
                and repository_id is not None
                and run.get("head_repository", {}).get("id") == repository_id
                and run.get("head_branch") == head.get("ref"))
    matches = [r for r in runs.get("workflow_runs", []) if r.get("conclusion") == "success"
               and r.get("event") == "pull_request" and r.get("status") == "completed"
               and r.get("head_sha") == sha and belongs_to_pr(r)]
    if not matches:
        raise Deferred("No completed preview for this PR revision yet")
    target = root / "previews" / ("pr-" + str(number)) / sha
    artifacts = gh.api("actions/runs/" + str(matches[0]["id"]) + "/artifacts")
    artifacts = [a for a in artifacts.get("artifacts", []) if a.get("name") == "preview-images" and not a.get("expired")]
    if len(artifacts) != 1:
        raise Deferred("Preview images are missing or expired; rerun the PR workflow")
    images = []
    with tempfile.TemporaryDirectory(prefix="preview-", dir=root) as temporary:
        archive = Path(temporary) / "images.zip"
        with archive.open("wb") as output:
            result = subprocess.run([gh.executable, "api", "repos/" + gh.repo + "/actions/artifacts/" + str(artifacts[0]["id"]) + "/zip"],
                                    stdout=output, stderr=subprocess.PIPE, timeout=120, creationflags=NO_WINDOW)
        if result.returncode:
            raise Deferred("Preview download failed")
        with zipfile.ZipFile(archive) as z:
            infos = z.infolist()
            if len(infos) > 100 or sum(i.file_size for i in infos) > 50_000_000:
                raise DeliveryError("Preview exceeds extraction limits")
            seen = set()
            for item in infos:
                if (not re.fullmatch(r"[A-Za-z0-9_-]+\.png", item.filename)
                        or item.filename.lower() in seen or stat.S_ISLNK(item.external_attr >> 16)
                        or z.read(item)[:8] != b"\x89PNG\r\n\x1a\n"):
                    raise DeliveryError("Preview artifact contains unsafe or non-image content")
                seen.add(item.filename.lower())
            target.mkdir(parents=True, exist_ok=True)
            for item in infos:
                path = target / item.filename
                path.write_bytes(z.read(item))
                images.append(str(path))
    info = {"pr": number, "sha": sha, "mode": "CI-rendered fictional data", "images": images}
    write(target / "preview.json", info)
    return info


def main():
    parser = argparse.ArgumentParser(description="Local Delivery: tested main updates and inert PR previews")
    parser.add_argument("--install", required=True)
    parser.add_argument("command", choices=["update", "status", "preview"])
    parser.add_argument("pr", nargs="?", type=int)
    args = parser.parse_args()
    root = safe_root(args.install)
    try:
        if args.command == "update":
            result = update(root)
        elif args.command == "status":
            result = {"delivery": read(root / "delivery-status.json", {}), "installed": read(root / "current.json", {}),
                      "previous": read(root / "previous.json", {})}
            config = read(root / "delivery.json", {})
            if config.get("product") == "hotpl8":
                collector = read(Path(config["stateDirectory"]) / "collector.json", {})
                result["running"] = {"collectorSha": collector.get("runningSha"), "completedAt": collector.get("completedAt"),
                                     "collectorStatus": collector.get("status")}
                current = result["installed"]
                if current and (root / current["release"] / "src/t3-delivery.ps1").is_file():
                    result["components"] = json.loads(invoke_adapter(config, root / current["release"], "components", root))
        else:
            if not args.pr or args.pr < 1:
                raise DeliveryError("Specify a positive PR number")
            result = preview(root, args.pr)
        print(json.dumps(result, indent=2))
        return 1 if result.get("state") == "error" else 0
    except (DeliveryError, OSError, ValueError) as error:
        print(json.dumps({"state": "error", "reason": str(error) if isinstance(error, DeliveryError) else type(error).__name__}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
