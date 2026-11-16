"""Explicitly trusted PR execution with demo state; never a production activation.

This is not an OS sandbox. The caller must trust the exact revision before any
candidate code executes. The normal image-preview command remains inert.
"""
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

from runner import (DeliveryError, Deferred, GitHub, SHA, now, preview_revision, program, read, safe_root,
                    unpack, write)


def extract_source(archive, destination):
    """Validate the complete GitHub source ZIP before writing candidate files."""
    if archive.stat().st_size > 100_000_000:
        raise DeliveryError("Preview source exceeds download limit")
    with zipfile.ZipFile(archive) as z:
        entries = z.infolist()
        if not entries or len(entries) > 10_000 or sum(i.file_size for i in entries) > 100_000_000:
            raise DeliveryError("Preview source exceeds extraction limits")
        prefix = None
        files = {}
        seen = set()
        for item in entries:
            # ZipInfo.filename normalizes backslashes on Windows and truncates
            # NULs. Validate the raw header name before that platform-dependent
            # cleanup, so the same malformed archive is rejected on every OS.
            name = item.orig_filename.rstrip("/")
            parts = name.split("/")
            mode = stat.S_IFMT(item.external_attr >> 16)
            if (not name or any(ord(c) < 32 for c in name) or "\\" in name or ":" in name or name.startswith("/")
                    or any(p in ("", ".", "..") or p.endswith((".", " "))
                           or re.fullmatch(r"(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?", p)
                           for p in parts)
                    or mode not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise DeliveryError("Unsafe preview source path")
            prefix = prefix or parts[0]
            if parts[0] != prefix:
                raise DeliveryError("Preview source has multiple roots")
            if len(parts) == 1:
                if not item.is_dir():
                    raise DeliveryError("Invalid preview source root")
                continue
            relative = PurePosixPath(*parts[1:])
            key = str(relative).lower()
            if key in seen:
                raise DeliveryError("Duplicate preview source path")
            seen.add(key)
            if not item.is_dir():
                files[relative] = z.read(item)  # CRC checked before any extraction.
        for required in ("hotpl8.ps1", "src/common.ps1", "tests/fixtures/screenshots.ps1"):
            if PurePosixPath(required) not in files:
                raise DeliveryError("PR does not contain the dashboard preview surface")
        for relative in files:
            if any(parent in files for parent in relative.parents):
                raise DeliveryError("Conflicting preview source paths")
        for relative, content in files.items():
            path = destination.joinpath(*relative.parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)


def candidate_reader(source, platform):
    """Where this candidate ships a compiled reader for the platform, or None."""
    inventory = source / "release-files.json"
    if not inventory.is_file():
        return None
    try:
        listed = json.loads(inventory.read_text(encoding="utf-8-sig")).get("platformFiles", {}).get(platform, [])
    except (ValueError, AttributeError, UnicodeDecodeError):
        raise DeliveryError("Invalid candidate release inventory") from None
    name = "bin/" + platform + "/hotpl8-native" + (".exe" if platform == "windows" else "")
    return name if isinstance(listed, list) and name in listed else None


def read_member(archive, name, limit):
    item = archive.getinfo(name)
    if item.file_size > limit:
        raise DeliveryError("Candidate package exceeds extraction limits")
    return archive.read(item)  # CRC checked.


def fetch_reader(gh, workflow, platform, name, session, source):
    """Put the reader that the trusted run built and tested where a release has it.

    The run is the passing one for the pinned revision in the enrolled repository;
    that is what makes its package the candidate's. The checksums only show that
    the package arrived as CI wrote it.
    """
    wanted = "hotpl8-" + platform + "-candidate"
    artifacts = gh.api("actions/runs/" + str(workflow["id"]) + "/artifacts")
    artifacts = [a for a in artifacts.get("artifacts", []) if a.get("name") == wanted and not a.get("expired")]
    if len(artifacts) != 1:
        raise Deferred("Candidate package is missing or expired; rerun the PR workflow")
    download = session / "candidate.zip"
    try:
        with download.open("wb") as output:
            result = subprocess.run([gh.executable, "api", "repos/" + gh.repo + "/actions/artifacts/"
                                     + str(artifacts[0]["id"]) + "/zip"],
                                    stdout=output, stderr=subprocess.PIPE, timeout=120)
    except subprocess.TimeoutExpired:
        raise Deferred("Candidate package download timed out") from None
    if result.returncode:
        raise Deferred("Candidate package download failed")
    if download.stat().st_size > 100_000_000:
        raise DeliveryError("Candidate package exceeds download limit")
    try:
        with zipfile.ZipFile(download) as outer:
            names = sorted(i.orig_filename for i in outer.infolist())
            if (len(names) != 2 or names[0] != "SHA256SUMS"
                    or not re.fullmatch(r"hotpl8-[0-9A-Za-z.-]+-" + platform + r"\.zip", names[1])):
                raise DeliveryError("Candidate package has unexpected content")
            sums = read_member(outer, "SHA256SUMS", 1_000).decode("ascii", "replace")
            package = read_member(outer, names[1], 100_000_000)
        expected = re.fullmatch(r"([a-f0-9]{64})  (\S+)\r?\n?", sums)
        if (not expected or expected.group(2) != names[1]
                or hashlib.sha256(package).hexdigest() != expected.group(1)):
            raise DeliveryError("Candidate package does not match its checksum")
        with zipfile.ZipFile(io.BytesIO(package)) as inner:
            members = [i.orig_filename for i in inner.infolist()]
            if members.count(name) != 1 or members.count("checksums.json") != 1:
                raise DeliveryError("Candidate package has no reader for this platform")
            reader = read_member(inner, name, 50_000_000)
            checksums = json.loads(read_member(inner, "checksums.json", 1_000_000).decode("utf-8-sig"))
        if not isinstance(checksums, dict) or checksums.get(name) != hashlib.sha256(reader).hexdigest():
            raise DeliveryError("Candidate reader does not match its checksum")
    except (zipfile.BadZipFile, KeyError, ValueError):
        raise DeliveryError("Invalid candidate package") from None
    path = source.joinpath(*PurePosixPath(name).parts)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(reader)
    if platform != "windows":
        path.chmod(0o755)


def checked(root, number, trusted_sha, gh=None):
    """Every refusal that comes before anything is downloaded: the pinned head, the same
    repository, a passing run for exactly that revision, and the enrolled PowerShell."""
    root = safe_root(root)
    config = read(root / "delivery.json")
    if not SHA.fullmatch(trusted_sha):
        raise DeliveryError("Live preview requires a full trusted PR revision")
    gh = gh or GitHub(config["repository"], program(config.get("gh"), "gh"))
    pr = gh.api("pulls/" + str(number))
    if pr.get("head", {}).get("sha") != trusted_sha:
        raise Deferred("PR changed: review its new revision and use a new preview command")
    if pr.get("head", {}).get("repo", {}).get("full_name", "").lower() != config["repository"].lower():
        raise DeliveryError("Live preview supports trusted same-repository PRs; use image preview for forks")
    sha, workflow = preview_revision(config, number, gh, pr)
    powershell = config.get("powershell")
    if os.name == "nt":
        powershell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
    if not powershell or not Path(powershell).is_file():
        raise DeliveryError("Live preview needs the enrolled PowerShell executable")
    return dict(root=root, config=config, gh=gh, pr=pr, sha=sha, workflow=workflow, powershell=powershell,
                url="https://github.com/" + config["repository"] + "/pull/" + str(number),
                target=root / "previews" / ("pr-" + str(number)) / sha)


@contextlib.contextmanager
def fetched(trusted, number, prefix):
    """The candidate's source, with the reader its trusted run built, in a temporary
    session removed afterwards; yielded only once the head is confirmed unmoved."""
    gh, sha, target = trusted["gh"], trusted["sha"], trusted["target"]
    target.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=prefix, dir=target) as temporary:
        session = Path(temporary)
        archive = session / "source.zip"
        try:
            with archive.open("wb") as output:
                result = subprocess.run([gh.executable, "api", "repos/" + gh.repo + "/zipball/" + sha],
                                        stdout=output, stderr=subprocess.PIPE, timeout=120)
        except subprocess.TimeoutExpired:
            raise Deferred("PR source download timed out") from None
        if result.returncode:
            raise Deferred("PR source download failed")
        source = session / "source"
        try:
            extract_source(archive, source)
        except zipfile.BadZipFile:
            raise DeliveryError("Invalid preview source ZIP") from None
        # A compiled reader cannot be run from source: take the one CI built for this revision.
        platform = "windows" if os.name == "nt" else "macos"
        name = candidate_reader(source, platform)
        if name:
            fetch_reader(gh, trusted["workflow"], platform, name, session, source)
        # Do not silently execute an old head when review and download race a push.
        if gh.api("pulls/" + str(number))["head"]["sha"] != sha:
            raise Deferred("PR changed during preparation; use its new reviewed preview command")
        yield session, source


def scrubbed():
    env = dict(os.environ)
    for key in ("HOTPL8_INSTALL_DIRECTORY", "HOTPL8_STATE_DIRECTORY", "GH_TOKEN", "GITHUB_TOKEN",
                "OPENAI_API_KEY", "ANTHROPIC_API_KEY"):
        env.pop(key, None)
    return env


def launch(root, number, trusted_sha, gh=None):
    trusted = checked(root, number, trusted_sha, gh)
    url, sha = trusted["url"], trusted["sha"]
    info = dict(pr=number, url=url, sha=sha, workflow=trusted["workflow"]["id"], mode="live fictional accounts")
    print("Live preview: " + url + "\nRevision: " + sha
          + "\nData: fictional accounts. Executing this explicitly trusted PR locally."
          + "\nSpace: freeze/resume; arrows: scroll; Q: quit.", flush=True)
    with fetched(trusted, number, "live-") as (session, source):
        state = session / "state"
        state.mkdir()
        # Run the stable harness with the candidate's fixture and its compiled
        # reader, which draws the dashboard. Neither the candidate's installer
        # nor its collector is part of the preview path.
        harness = Path(__file__).with_name("live-preview.ps1")
        write(trusted["target"] / "live.json", info)
        result = subprocess.run([trusted["powershell"], "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                 "-File", str(harness), "-SourceDirectory", str(source),
                                 "-StateDirectory", str(state), "-PrUrl", url, "-Revision", sha],
                                env=scrubbed())
        return result.returncode


PASS, FAIL, BLOCKED = 0, 10, 11


def merge_base(trusted):
    """The main revision the PR's change is measured against: where its branch left main."""
    base = trusted["pr"].get("base", {}).get("ref") or "main"
    sha = trusted["gh"].api("compare/" + base + "..." + trusted["sha"]).get("merge_base_commit", {}).get("sha", "")
    if not SHA.fullmatch(sha or ""):
        raise Deferred("GitHub did not name the PR's merge base")
    return sha


def baseline_release(trusted, sha):
    """Main at sha as a release directory: the installed one, else its attested package,
    unpacked once into previews/baseline-<sha>. Not yet released is Deferred."""
    root, config, gh = trusted["root"], trusted["config"], trusted["gh"]
    installed = root / "releases" / sha
    if (root / "receipts" / (sha + ".json")).is_file() and (installed / "delivery-manifest.json").is_file():
        return installed
    cached = root / "previews" / ("baseline-" + sha)
    if (cached / "baseline.json").is_file():
        os.utime(cached)  # In use: not old enough for the update's preview pruning.
        return cached
    candidate = gh.candidate(sha, config)
    (root / "previews").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".baseline-", dir=root / "previews") as temporary:
        temporary = Path(temporary)
        archive = temporary / "package.zip"
        gh.download(candidate, archive)
        if config.get("attestation"):
            gh.attest(archive, sha, config["workflow"])
        stage = temporary / "release"
        try:
            unpack(archive, stage, config, sha)
        except zipfile.BadZipFile:
            raise DeliveryError("Invalid baseline package") from None
        write(stage / "baseline.json", dict(candidate, unpackedAt=now()))
        # Another observe may have unpacked the same baseline meanwhile and be running its
        # reader: keep its copy. Only a folder without baseline.json is a half-finished one.
        if (cached / "baseline.json").is_file():
            os.utime(cached)
            return cached
        if cached.exists():
            shutil.rmtree(cached)
        try:
            os.replace(stage, cached)
        except OSError:
            if not (cached / "baseline.json").is_file():
                raise
    return cached


def observe(root, number, trusted_sha, scenario, report=None, baseline=None, gh=None):
    """Run the trusted candidate's reader beside its baseline's through a scenario, with no
    terminal and no owner: PASS 0, FAIL 10. Nothing is activated; the report stays in previews/."""
    scenario = Path(scenario)
    try:
        plan = json.loads(scenario.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError, UnicodeDecodeError):
        raise DeliveryError("Observe scenario is not a readable JSON file") from None
    if not isinstance(plan, dict) or not isinstance(plan.get("claim"), str) or not plan["claim"].strip():
        raise DeliveryError("Observe scenario needs a claim; see docs/observe-scenarios.md")
    if baseline is not None and not SHA.fullmatch(baseline):
        raise DeliveryError("Observe baseline must be a full main revision")
    trusted = checked(root, number, trusted_sha, gh)
    sha = trusted["sha"]
    base = baseline or merge_base(trusted)
    release = baseline_release(trusted, base)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = Path(report).resolve() if report else trusted["target"] / ("observe-" + stamp)
    report.mkdir(parents=True, exist_ok=True)
    print("Observe: " + trusted["url"] + "\nRevision: " + sha + "\nBaseline: main " + base
          + "\nData: fictional accounts. Executing this explicitly trusted PR's reader locally.", flush=True)
    with fetched(trusted, number, "observe-") as (session, source):
        harness = Path(__file__).with_name("observe.ps1")
        try:
            result = subprocess.run([trusted["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive",
                                     "-ExecutionPolicy", "Bypass", "-File", str(harness),
                                     "-Candidate", str(source), "-Baseline", str(release),
                                     "-Scenario", str(scenario.resolve()), "-Report", str(report),
                                     "-CandidateSha", sha, "-BaselineSha", base, "-Pr", str(number)],
                                    env=scrubbed(), stdin=subprocess.DEVNULL, timeout=1800)
        except subprocess.TimeoutExpired:
            raise DeliveryError("The observation did not finish in 30 minutes") from None
    if result.returncode not in (PASS, FAIL):
        raise DeliveryError("The observation could not be made (exit " + str(result.returncode) + ")")
    verdict = "PASS" if result.returncode == PASS else "FAIL"
    write(trusted["target"] / "observed.json", dict(pr=number, sha=sha, baseline=base, verdict=verdict,
                                                    report=str(report), at=now()))
    print(json.dumps(dict(state="observed", verdict=verdict, pr=number, sha=sha, baseline=base,
                          report=str(report / "report.md"))), flush=True)
    return result.returncode
