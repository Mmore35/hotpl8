"""Owned macOS enrollment and lifecycle for the existing verified delivery runner."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runner import DeliveryError, Deferred, digest, drained, lock, now, read, run, safe_root, update, write


def native_only():
    if sys.platform != "darwin":
        raise DeliveryError("This operation requires macOS")


def executable(value):
    path = Path(value or "")
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise DeliveryError("An absolute executable binding is required")
    return str(path)


def atomic_bytes(path, data, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise DeliveryError("Refusing a linked output file")
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("xb") as stream:
            os.chmod(temporary, mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def selected(root):
    pointer = read(root / "current.json", {})
    sha = pointer.get("sha", "")
    if not re.fullmatch(r"[a-f0-9]{40}", sha) or pointer.get("release") != "releases/" + sha:
        raise DeliveryError("Invalid managed release pointer")
    return safe_root(root / pointer["release"])


def owned_config(root):
    safe_root(root)
    owned, config = read(root / "installation.json", {}), read(root / "delivery.json", {})
    if (owned.get("product") != "hotpl8" or not re.fullmatch(r"[a-f0-9]{12}", owned.get("id", ""))
            or config.get("product") != "hotpl8" or config.get("platform") != "macos"
            or config.get("protocol") != 1 or config.get("stateDirectory") != owned.get("stateDirectory")):
        raise DeliveryError("Mac installation ownership is invalid")
    safe_root(config["stateDirectory"])
    for key in ("python", "powershell", "gh"):
        executable(config.get(key))
    for key, value in config.get('macos', {}).get('runtimes', {}).items():
        if key not in ('codex', 'cswap'):
            raise DeliveryError('Unknown collector runtime binding')
        executable(value)
    return owned, config


def job_plist(root, role, owned, config):
    if role not in ("collector", "updater"):
        raise DeliveryError("Unknown native job")
    return {"Label": "io.hotpl8." + owned["id"] + "." + role,
            "ProgramArguments": [config["python"], str(root / "delivery.py"), "job", role],
            "RunAtLoad": True, "StartInterval": 60 if role == "collector" else 300,
            "ProcessType": "Background", "AbandonProcessGroup": False, "ExitTimeOut": 10,
            "EnvironmentVariables": {"PATH": config["macos"]["path"], "HOME": str(Path.home())},
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"}


class Launchd:
    def __init__(self, directory=None):
        native_only()
        self.directory = safe_root(directory or Path.home() / "Library/LaunchAgents")
        self.domain = "gui/" + str(os.getuid())

    def call(self, *args, missing_ok=False):
        result = subprocess.run(["/bin/launchctl", *args], capture_output=True,
                                stdin=subprocess.DEVNULL, timeout=20)
        # bootout uses ESRCH=3 for an absent owned job. Other failures are real.
        if result.returncode and not (missing_ok and result.returncode == 3):
            raise DeliveryError("launchd operation failed: " + args[0])
        return result.stdout.decode("utf-8", "replace")

    def loaded(self, label):
        result = subprocess.run(["/bin/launchctl", "print", self.domain + "/" + label],
                                capture_output=True, stdin=subprocess.DEVNULL, timeout=20)
        if result.returncode == 113:  # service not found in the requested domain
            return False
        if result.returncode:
            raise DeliveryError("Cannot inspect launchd service")
        return True

    def enabled(self, label):
        output = self.call("print-disabled", self.domain)
        return not re.search(r'"' + re.escape(label) + r'"\s*=>\s*true', output)

    def install(self, path, spec):
        if self.enabled(spec['Label']) and not self.loaded(spec["Label"]):
            self.call("bootstrap", self.domain, str(path))

    def remove(self, label):
        if self.loaded(label):
            self.call("bootout", self.domain + "/" + label)


def register(root, backend=None):
    owned, config = owned_config(root)
    backend = backend or Launchd()
    backend.directory.mkdir(parents=True, exist_ok=True)
    receipt = read(root / "macos-jobs.json", {"schemaVersion": 1, "jobs": {}})
    pending = []
    for role in ("collector", "updater"):
        spec = job_plist(root, role, owned, config)
        path = backend.directory / (spec["Label"] + ".plist")
        body = plistlib.dumps(spec, sort_keys=True)
        if path.exists() or path.is_symlink():
            if path.is_symlink() or path.read_bytes() != body:
                raise DeliveryError("Existing launchd registration differs; preserve and reconcile it explicitly")
        pending.append((role, spec, path, body))
    for role, spec, path, body in pending:
        if not path.exists():
            atomic_bytes(path, body)
        # Record ownership before native admission. Retry after interrupted
        # bootstrap can reconcile the exact same file without a duplicate job.
        receipt["jobs"][role] = dict(path=str(path), label=spec["Label"], digest=hashlib.sha256(body).hexdigest())
        write(root / "macos-jobs.json", receipt)
        backend.install(path, spec)
    config["macos"]["jobsEnrolled"] = True
    write(root / "delivery.json", config)


def components(root, backend=None):
    owned, config = owned_config(root)
    backend = backend or Launchd()
    current = read(root / "current.json", {})
    results = []
    receipt = read(root / "macos-jobs.json", {"jobs": {}})
    for role in ("collector", "updater"):
        expected = job_plist(root, role, owned, config)
        record = receipt["jobs"].get(role, {})
        path = backend.directory / (expected["Label"] + ".plist")
        valid = (record.get("path") == str(path) and record.get("label") == expected["Label"]
                 and path.is_file() and not path.is_symlink()
                 and digest(path) == record.get("digest")
                 and plistlib.loads(path.read_bytes()) == expected)
        state = "unmanaged"
        if config["macos"].get("jobsEnrolled"):
            state = ("error" if not valid else "disabled" if not backend.enabled(expected["Label"])
                     else "current" if backend.loaded(expected["Label"]) else "error")
        execution = read(root / "job-runs" / (role + ".json"), {})
        results.append(dict(component="scheduled-" + role, state=state,
                            nextLaunchSha=current.get("sha"), execution=execution))
    return results + t3_module().components(root)


def t3_module():
    spec = importlib.util.spec_from_file_location("hotpl8_macos_t3", Path(__file__).with_name("macos-t3.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_dispatch(root, release, config):
    # Only protocol-1 immutable selection lives outside releases. All changing
    # native launch/guardian/adapter code is loaded from the selected release.
    bootstrap = root / "delivery.py"
    expected = (release / "delivery/bootstrap.py").read_bytes()
    if bootstrap.is_symlink() or (bootstrap.exists() and bootstrap.read_bytes() != expected):
        raise DeliveryError("Existing delivery bootstrap needs explicit compatibility migration")
    if not bootstrap.exists():
        atomic_bytes(bootstrap, expected)
    shim = ("#!/bin/sh\nexec " + shlex.quote(config["python"]) + " " + shlex.quote(str(bootstrap))
            + ' run hotpl8 "$@"\n').encode()
    target = root / "hotpl8"
    if target.is_symlink() or (target.exists() and target.read_bytes() != shim):
        raise DeliveryError("Existing command is not owned by this Mac enrollment")
    if not target.exists():
        atomic_bytes(target, shim, 0o700)


def adapter(root, release, operation, backend=None):
    owned, config = owned_config(root)
    if operation == "components":
        return components(root, backend)
    build = read(release / "build-info.json", {})
    if not re.fullmatch(r"[a-f0-9]{40}", build.get("sha", "")):
        raise DeliveryError("Candidate has no exact source identity")
    command = [config["powershell"], "-NoProfile", "-NonInteractive", "-File",
               release / "delivery/macos-preflight.ps1", "-ReleaseDirectory", release,
               "-StateDirectory", config["stateDirectory"], "-InstallDirectory", root]
    if operation == "drain":
        command += ["-RecordOwner"]
    run(command, 30)
    t3_module().reconcile(root, release, operation)
    if operation in ("activate", "recover"):
        install_dispatch(root, release, config)
        owned.update(sourceSha=build["sha"], channel="main", managedBy="local-delivery")
        write(root / "installation.json", owned)
        config["componentHealth"] = True
        write(root / "delivery.json", config)
    if operation in ("health", "recover") and config["macos"].get("jobsEnrolled"):
        if any(c["state"] == "error" for c in components(root, backend)):
            raise DeliveryError("Native scheduler ownership or registration is unhealthy")
    return None


def collector_conflicts(backend, state, installation_id, adopted=None):
    # Inspect definitions, including unloaded jobs that could return at login.
    # An explicitly supplied definition is the only legacy job we may retire.
    directories = [backend.directory, Path('/Library/LaunchAgents'), Path('/Library/LaunchDaemons')]
    for directory in directories:
        if not directory.exists():
            continue
        for path in directory.glob('*.plist'):
            spec = plistlib.loads(path.read_bytes())
            if spec.get('Label', '').startswith('io.hotpl8.' + installation_id + '.'):
                continue
            text = json.dumps(spec).lower()
            if ('hotpl8' in text or str(state).lower() in text) and path != adopted:
                raise DeliveryError('Another HotPl8 job exists; explicitly reconcile its ownership before enrollment')


def adopt_collector(root, backend, path, expected_digest):
    _, config = owned_config(root)
    journal_path = root / 'collector-migration.json'
    journal = read(journal_path)
    if journal:
        path = Path(journal['path'])
        if expected_digest and expected_digest != journal['digest']:
            raise DeliveryError('Collector migration identity changed')
    else:
        path = Path(path)
        if path.parent != backend.directory or path.is_symlink() or not path.is_file() or digest(path) != expected_digest:
            raise DeliveryError('Legacy collector path/digest does not match the inspected user registration')
        body = path.read_bytes()
        spec = plistlib.loads(body)
        if (not re.fullmatch(r'[A-Za-z0-9_.-]+', spec.get('Label', ''))
                or path.name != spec['Label'] + '.plist'
                or not spec.get('ProgramArguments') or spec.get('KeepAlive')):
            raise DeliveryError('Legacy collector is not a finite user LaunchAgent')
        backup = root / 'legacy-collector.plist'
        atomic_bytes(backup, body)
        journal = dict(path=str(path), digest=expected_digest, label=spec['Label'], phase='prepared')
        write(journal_path, journal)
    backup = root / 'legacy-collector.plist'
    if digest(backup) != journal['digest'] or path.parent != backend.directory:
        raise DeliveryError('Collector recovery evidence is invalid')
    with drained(root, config):
        if path.exists() and (path.is_symlink() or digest(path) != journal['digest']):
            raise DeliveryError('Legacy collector changed after inspection')
        # The writer is idle before bootout. Preserve its exact definition; no
        # native account, policy or pinned source is removed or modified.
        backend.remove(journal['label'])
        path.unlink(missing_ok=True)
        journal['phase'] = 'retired'
        write(journal_path, journal)


def setup(root, state, powershell, github_cli, register_jobs=True, backend=None, github=None,
          adopt=None, adopt_digest=None, runtimes=None):
    native_only()
    root, state = safe_root(root), safe_root(state)
    if not (state / "policy.json").is_file():
        raise DeliveryError("Enroll an existing HotPl8 state directory with a valid policy")
    root.mkdir(parents=True, exist_ok=True)
    with lock(root / "enrollment.lock", 0):
        owned = read(root / "installation.json")
        if owned is None:
            if any(p.name != "enrollment.lock" for p in root.iterdir()):
                raise DeliveryError("Use an empty managed installation directory; existing source stays untouched")
            owned = dict(product="hotpl8", id=uuid.uuid4().hex[:12], stateDirectory=str(state), platform="macos")
            write(root / "installation.json", owned)
        if owned.get("product") != "hotpl8" or owned.get("stateDirectory") != str(state):
            raise DeliveryError("Installation belongs to another state directory")
        config = read(root / "delivery.json")
        if config is None:
            config = dict(protocol=1, product="hotpl8", repository="Mmore35/hotpl8", channel="main",
                          platform="macos", workflow="ci.yml", previewWorkflow="ci.yml",
                          asset="hotpl8-macos-main.zip", attestation=True, stateCompatibility=1,
                          adapter="delivery/macos.py", stateDirectory=str(state), writerLocks=[str(state / "tick.lock")],
                          gh=executable(github_cli), powershell=executable(powershell), python=executable(sys.executable),
                          drainSeconds=30, macos=dict(protocol=1, path=os.environ.get("PATH", "/usr/bin:/bin"), jobsEnrolled=False))
            write(root / "delivery.json", config)
        if runtimes:
            requested = {key: executable(value) for key, value in runtimes.items()}
            existing = config['macos'].get('runtimes', {})
            if existing and existing != requested:
                raise DeliveryError('Collector runtime bindings changed; explicitly reconcile before enrollment')
            config['macos']['runtimes'] = requested
            write(root / 'delivery.json', config)
        owned_config(root)
        backend = backend or Launchd()
        migration = read(root / 'collector-migration.json', {})
        adopted = Path(adopt or migration['path']) if adopt or migration else None
        collector_conflicts(backend, state, owned['id'], adopted)
        result = update(root, github=github)
        if result["state"] != "current":
            raise DeliveryError("Enrollment waits for a verified Mac main release: " + str(result.get("reason")))
        if register_jobs:
            if adopted:
                adopt_collector(root, backend, adopted, adopt_digest)
            register(root, backend)
            if adopted:
                migration = read(root / 'collector-migration.json')
                migration['phase'] = 'complete'
                write(root / 'collector-migration.json', migration)
        return result


def uninstall(root, backend=None):
    owned, config = owned_config(root)
    backend = backend or Launchd()
    with lock(root / "enrollment.lock"), lock(root / "update.lock"), drained(root, config):
        receipt = read(root / "macos-jobs.json", {"jobs": {}})
        # Validate all owned paths before stopping any job or removing a plist.
        for role, record in receipt["jobs"].items():
            spec = job_plist(root, role, owned, config)
            path = backend.directory / (spec["Label"] + ".plist")
            if (record.get("path") != str(path) or record.get('label') != spec['Label'] or path.is_symlink()
                    or (path.exists() and (digest(path) != record["digest"] or plistlib.loads(path.read_bytes()) != spec))):
                raise DeliveryError("Native job changed; refusing removal")
        for record in receipt["jobs"].values():
            backend.remove(record["label"])
            Path(record["path"]).unlink(missing_ok=True)
        config["macos"]["jobsEnrolled"] = False
        write(root / "delivery.json", config)
    # Retain immutable releases, CLI, state and native accounts for recovery.


def dispatch(root, command, arguments):
    native_only()
    _, config = owned_config(root)
    release = selected(root)
    if command == "run":
        if not arguments or arguments[0] not in ("hotpl8", "tick", "status-print", "audit-codex", "setup-codex"):
            raise DeliveryError("Specify a supported HotPl8 entrypoint")
        arguments = list(arguments)
        runtimes = config['macos'].get('runtimes', {})
        for key, flag, entries in [('codex', '-CodexExecutable', ('hotpl8', 'tick')),
                                   ('cswap', '-CswapExecutable', ('tick',))]:
            if key in runtimes and arguments[0] in entries and not any(x.lower().rstrip(':') == flag.lower() for x in arguments[1:]):
                arguments += [flag, runtimes[key]]
        return subprocess.call([config["powershell"], "-NoProfile", "-File", str(release / "delivery/launch.ps1"),
                                "-InstallDirectory", str(root), "-Entry", arguments[0], *arguments[1:]])
    if len(arguments) != 1 or arguments[0] not in ("collector", "updater"):
        raise DeliveryError("Specify collector or updater")
    role = arguments[0]
    try:
        with lock(root / (role + ".job.lock")):
            spec = importlib.util.spec_from_file_location("hotpl8_guardian", release / "delivery/macos-job.py")
            guardian = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(guardian)
            path = root / "job-runs" / (role + ".json")
            prior = read(path, {})
            if prior.get('state') == 'running':
                # Keep unfinished evidence independently of the next green wake.
                write(root / 'job-runs' / ('unfinished-' + prior['runId'] + '.json'), prior)
            record = dict(schemaVersion=1, runId=uuid.uuid4().hex, startedAt=now(), sha=read(release / "build-info.json")["sha"], state="running")
            write(path, record)
            tail = ["run", "tick", "-Scheduled", "-ObserveOnly"] if role == "collector" else ["update"]
            result = guardian.execute([config["python"], str(root / "delivery.py"), *tail], 225 if role == "collector" else 540)
            record.update(result, completedAt=now())
            outcome = read(root / 'delivery-status.json', {}) if role == 'updater' else read(Path(config['stateDirectory']) / 'collector.json', {})
            fields = ('state', 'lastCheck', 'installedSha', 'desiredSha', 'reason') if role == 'updater' else ('status', 'startedAt', 'completedAt', 'runningSha')
            record['outcome'] = {key: outcome.get(key) for key in fields}
            if result['state'] == 'complete':
                stamp = outcome.get('lastCheck' if role == 'updater' else 'startedAt')
                fresh = bool(stamp and datetime.fromisoformat(stamp) >= datetime.fromisoformat(record['startedAt']))
                record['completion'] = ('no-new-outcome' if not fresh else outcome.get('state') if role == 'updater' else outcome.get('status'))
            write(path, record)
            return 0 if result["state"] == "complete" else 1
    except Deferred:
        return 0  # One native wake is enough; never queue catch-up prompts.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("setup", "uninstall", "preflight", "drain", "activate", "health", "recover", "components"))
    parser.add_argument("--install", required=True)
    parser.add_argument("--release")
    parser.add_argument("--state")
    parser.add_argument("--powershell", default=shutil.which("pwsh"))
    parser.add_argument("--gh", default=shutil.which("gh"))
    parser.add_argument('--adopt-collector')
    parser.add_argument('--adopt-digest')
    parser.add_argument('--codex', help='Explicit collector/CLI native Codex executable; preserve isolated native packages')
    parser.add_argument('--cswap', help='Explicit collector cswap executable')
    args = parser.parse_args()
    root = safe_root(args.install)
    try:
        native_only()
        if args.operation == "setup":
            if not args.state:
                raise DeliveryError("Specify the existing state directory")
            result = setup(root, args.state, args.powershell, args.gh,
                           adopt=args.adopt_collector, adopt_digest=args.adopt_digest,
                           runtimes={key: value for key, value in [('codex', args.codex), ('cswap', args.cswap)] if value})
        elif args.operation == "uninstall":
            result = uninstall(root)
        else:
            result = adapter(root, safe_root(args.release) if args.release else selected(root), args.operation)
        print(json.dumps(result))
    except (DeliveryError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error) if isinstance(error, DeliveryError) else type(error).__name__)


if __name__ == "__main__":
    main()
