"""Offline behavioral tests. All GitHub and product actions are fake."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import os
import subprocess
import time
import uuid
import ctypes
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "delivery"))
import runner as d
from package import package

A, B, C = "a" * 40, "b" * 40, "c" * 40


class FakeGitHub:
    def __init__(self, archive):
        self.archive = archive
        self.sha = B
        self.fail = False
        self.downloads = 0

    def main(self):
        return self.sha

    def candidate(self, sha, config):
        if self.fail:
            raise d.Deferred("CI has not passed")
        return {"sha": sha, "digest": d.digest(self.archive)}

    def is_forward(self, previous, candidate):
        return True

    def download(self, candidate, destination):
        self.downloads += 1
        shutil.copyfile(self.archive, destination)

    def attest(self, *args):
        pass


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "install with spaces"
        self.root.mkdir()
        self.state = Path(self.tmp.name) / "state"
        self.state.mkdir()
        (self.state / "ledger.json").write_text('{"request":42}')
        self.config = {"protocol": 1, "channel": "main", "product": "hotpl8", "repository": "example/hotpl8",
                       "workflow": "ci.yml", "asset": "hotpl8-main.zip", "stateCompatibility": 1,
                       "adapter": "adapter.ps1", "stateDirectory": str(self.state), "drainSeconds": 0,
                       "writerLocks": [str(self.state / "tick.lock")]}
        d.write(self.root / "delivery.json", self.config)
        self.previous = {"sha": A, "release": "releases/" + A}
        d.write(self.root / "current.json", self.previous)
        self.source = Path(self.tmp.name) / "source.zip"
        with zipfile.ZipFile(self.source, "w") as z:
            z.writestr("adapter.ps1", "# fake adapter")
            z.writestr("data.json", "{}")
        self.archive = Path(self.tmp.name) / "package.zip"
        package(self.source, self.archive, "hotpl8", "example/hotpl8", B)
        self.github = FakeGitHub(self.archive)
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def adapter(self, config, release, operation, root):
        self.calls.append(operation)

    def update(self):
        return d.update(self.root, self.github, self.adapter)

    def test_success_preserves_state_and_previous(self):
        result = self.update()
        self.assertEqual(result["state"], "current")
        self.assertEqual(d.read(self.root / "current.json")["sha"], B)
        self.assertEqual(d.read(self.root / "previous.json"), self.previous)
        self.assertEqual((self.state / "ledger.json").read_text(), '{"request":42}')
        self.assertIn("health", self.calls)
        self.assertFalse((self.root / "transaction.json").exists())

    def test_noop_does_not_download_or_restart(self):
        self.github.sha = A
        self.assertEqual(self.update()["state"], "current")
        self.assertEqual(self.calls, [])
        self.assertEqual(self.github.downloads, 0)

    def test_current_release_rechecks_enrolled_component_health(self):
        self.github.sha = A
        d.write(self.root / "delivery.json", {**self.config, "componentHealth": True})
        self.assertEqual(self.update()["state"], "current")
        self.assertEqual(self.calls, ["health"])
        def unhealthy(*args):
            raise d.DeliveryError("Missing component")
        self.assertEqual(d.update(self.root, self.github, unhealthy)["state"], "error")
        self.assertEqual(self.github.downloads, 0)

    def t3_fixture(self):
        """Real adapter/launcher/bootstrap; fake bridge does no provider work."""
        # Hosted Windows runners often expose TEMP through an 8.3 alias. The
        # PowerShell directory provider expands it; persisted paths may not.
        short_path = ctypes.windll.kernel32.GetShortPathNameW
        short_path.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
        short_path.restype = ctypes.c_uint32
        buffer = ctypes.create_unicode_buffer(32768)
        if short_path(str(self.root), buffer, len(buffer)):
            self.root = Path(buffer.value)
        source = Path(__file__).resolve().parents[1]
        self.config["adapter"] = "delivery/hotpl8-adapter.ps1"
        d.write(self.root / "delivery.json", self.config)
        self.previous["protocol"] = 1
        d.write(self.root / "current.json", self.previous)
        shutil.copyfile(source / "policy.example.json", self.state / "policy.json")
        self.t3 = self.root / "integrations" / "t3-codex"
        self.t3.mkdir(parents=True)
        self.launcher = self.t3 / "hotpl8-codex.exe"
        self.ps = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        # Input paths are fixture-owned; the PowerShell script uses parameters.
        compile_script = Path(self.tmp.name) / "compile.ps1"
        compile_script.write_text("param($Source,$Target)\nAdd-Type -TypeDefinition ([IO.File]::ReadAllText($Source)) -ReferencedAssemblies System.Web.Extensions -OutputAssembly $Target -OutputType ConsoleApplication\n")
        d.run([self.ps, "-NoProfile", "-File", compile_script, source / "src/t3-launcher.cs", self.launcher])
        self.bridge = """import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
const sha = JSON.parse(readFileSync(new URL('../build-info.json', import.meta.url))).sha;
export async function main(config, args) {
  if (args[0] === '--version') { process.stdout.write(sha+'\\n'); return; }
  process.stdout.write(sha+'\\n');
  const lines=createInterface({input:process.stdin});
  for await(const line of lines) { if(line==='quit') break; process.stdout.write(sha+'\\n'); }
  lines.close(); process.stdin.destroy();
}
"""
        self.make_t3_package(A)
        old = self.root / "releases" / A
        d.unpack(self.archive, old, self.config, A)
        d.write(self.root / "receipts" / (A + ".json"), {"manifestDigest": d.digest(old / "delivery-manifest.json")})
        self.make_t3_package(B)
        self.shared = Path(self.tmp.name) / "shared"
        self.shared.mkdir()
        (self.shared / "auth.json").write_text('synthetic-auth-sentinel')
        self.settings_path = Path(self.tmp.name) / "settings.json"
        instance = {"driver": "codex", "config": {"binaryPath": str(self.launcher)}}
        d.write(self.settings_path, {"providerInstances": {"hotpl8-codex": instance}})
        d.write(self.t3 / "receipt.json", {"settingsPath": str(self.settings_path), "targetProviderId": "hotpl8-codex", "installedInstance": instance, "sourceCommit": A})
        self.bridge_config = self.t3 / "bridge-config.json"
        d.write(self.bridge_config, {"schemaVersion": 1, "node": shutil.which("node"), "codex": sys.executable,
                                    "powershell": self.ps, "script": str(old / "src/t3-codex.mjs"),
                                    "stateDirectory": str(self.state), "sharedHome": str(self.shared)})

    def make_t3_package(self, sha, broken=False):
        source = Path(__file__).resolve().parents[1]
        with zipfile.ZipFile(self.source, "w") as z:
            for name in d.read(source / "release-files.json")["files"]:
                if name == "src/t3-codex.mjs":
                    z.writestr(name, "not valid javascript {" if broken else self.bridge)
                elif name == "src/t3-launcher.cs" and sha == A:
                    # Existing archive installation vs Windows checkout packaging.
                    z.writestr(name, (source / name).read_bytes().replace(b"\r\n", b"\n"))
                elif name == "delivery/hotpl8-adapter.ps1" and sha == A:
                    # Prove recovery by a predecessor that has NO T3 migration.
                    z.writestr(name, "param($Operation,$InstallDirectory,$ReleaseDirectory,$StateDirectory)\n")
                else:
                    z.write(source / name, name)
        package(self.source, self.archive, "hotpl8", "example/hotpl8", sha)

    def t3_probe(self):
        return d.run([self.launcher, "--version"]).decode().strip()

    @unittest.skipUnless(os.name == "nt", "Windows T3 delivery")
    def test_t3_real_upgrade_preserves_active_process_and_reports_versions(self):
        self.t3_fixture()
        # Convert A using the real migration so its live process has a receipt.
        source = Path(__file__).resolve().parents[1]
        d.invoke_adapter(self.config, source, "activate", self.root)
        settings_before = self.settings_path.read_bytes()
        launcher_before = d.digest(self.launcher)
        proc = subprocess.Popen([self.launcher, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(proc.stdout.readline().decode().strip(), A)
            self.assertEqual(d.update(self.root, self.github)["state"], "current")
            self.assertEqual(self.t3_probe(), B)
            proc.stdin.write(b"still working\n"); proc.stdin.flush()
            self.assertEqual(proc.stdout.readline().decode().strip(), A)
            components = json.loads(d.invoke_adapter(self.config, self.root / "releases" / B, "components", self.root))
            self.assertEqual(components[0]["state"], "restart-pending")
            self.assertEqual(components[0]["runningShas"], [A])
            self.assertEqual(components[0]["nextLaunchSha"], B)
            self.assertEqual(self.settings_path.read_bytes(), settings_before)
            self.assertEqual(d.digest(self.launcher), launcher_before)
            self.assertEqual((self.shared / "auth.json").read_text(), 'synthetic-auth-sentinel')
        finally:
            proc.communicate(b"quit\n", timeout=15)
        self.assertEqual(proc.returncode, 0)

    @unittest.skipUnless(os.name == "nt", "Windows T3 delivery")
    def test_t3_legacy_migration_and_failed_health_roll_back_with_old_adapter(self):
        self.t3_fixture()
        self.make_t3_package(B, broken=True)
        self.assertEqual(d.update(self.root, self.github)["state"], "error")
        self.assertEqual(d.read(self.root / "current.json")["sha"], A)
        # New bootstrap remains safe even though old recover cannot undo it.
        self.assertTrue(d.read(self.bridge_config).get("deliveryRoot"))
        self.assertEqual(self.t3_probe(), A)
        self.assertEqual(d.update(self.root, self.github)["state"], "pending")

    @unittest.skipUnless(os.name == "nt", "Windows T3 delivery")
    def test_t3_interrupted_activation_recovers_and_tamper_fails_closed(self):
        self.t3_fixture()
        self.assertEqual(d.update(self.root, self.github)["state"], "current")
        d.write(self.root / "transaction.json", {"previous": self.previous, "candidate": {"sha": B}})
        self.assertEqual(d.update(self.root, self.github)["state"], "pending")
        self.assertEqual(self.t3_probe(), A)
        (self.root / "releases" / A / "src/codex-route.ps1").write_text("tampered")
        with self.assertRaises(d.DeliveryError): self.t3_probe()

    @unittest.skipUnless(os.name == "nt", "Windows T3 delivery")
    def test_t3_unreadable_receipt_blocks_false_readiness(self):
        self.t3_fixture()
        (self.t3 / "receipt.json").write_text("{broken")
        self.assertEqual(d.update(self.root, self.github)["state"], "error")
        self.assertEqual(d.read(self.root / "current.json")["sha"], A)

    @unittest.skipUnless(os.name == "nt", "Windows T3 delivery")
    def test_t3_missing_registered_component_is_not_current(self):
        self.t3_fixture()
        self.assertEqual(d.update(self.root, self.github)["state"], "current")
        self.assertTrue(self.t3.resolve().is_relative_to(Path(self.tmp.name).resolve()))
        shutil.rmtree(self.t3)
        self.assertEqual(d.update(self.root, self.github)["state"], "error")
        self.assertEqual(d.read(self.root / "current.json")["sha"], B)

    @unittest.skipUnless(os.name == "nt", "Windows T3 delivery")
    def test_t3_removed_provider_does_not_get_reinstalled(self):
        self.t3_fixture()
        settings = d.read(self.settings_path)
        settings["providerInstances"] = {}
        d.write(self.settings_path, settings)
        before = self.bridge_config.read_bytes()
        self.assertEqual(d.update(self.root, self.github)["state"], "current")
        self.assertEqual(self.bridge_config.read_bytes(), before)
        self.assertEqual(json.loads(d.invoke_adapter(self.config, self.root / "releases" / B, "components", self.root)), [])

    def test_failed_ci_never_changes_pointer(self):
        self.github.fail = True
        self.assertEqual(self.update()["state"], "pending")
        self.assertEqual(d.read(self.root / "current.json"), self.previous)
        self.assertEqual(self.calls, [])

    def test_rewritten_main_never_automatically_downgrades(self):
        self.github.is_forward = lambda previous, candidate: False
        self.assertEqual(self.update()["state"], "pending")
        self.assertEqual(d.read(self.root / "current.json"), self.previous)
        self.assertEqual(self.github.downloads, 0)

    def test_busy_writer_defers_without_activation(self):
        with d.lock(self.state / "tick.lock"):
            self.assertEqual(self.update()["state"], "pending")
        self.assertNotIn("activate", self.calls)
        self.assertEqual(d.read(self.root / "current.json"), self.previous)

    def test_concurrent_updater_cannot_enter(self):
        with d.lock(self.root / "update.lock"):
            with self.assertRaises(d.Deferred):
                self.update()

    def test_health_failure_restores_code_not_new_state(self):
        def adapter(config, release, operation, root):
            if operation == "health":
                (self.state / "ledger.json").write_text('{"request":43}')
                raise d.DeliveryError("bad health")
        result = d.update(self.root, self.github, adapter)
        self.assertEqual(result["state"], "error")
        self.assertEqual(d.read(self.root / "current.json"), self.previous)
        self.assertEqual(d.read(self.state / "ledger.json"), {"request": 43})
        self.assertEqual(self.update()["state"], "pending")
        self.assertEqual(self.github.downloads, 1)

    def test_interrupted_activation_restores_previous(self):
        d.write(self.root / "transaction.json", {"previous": self.previous, "candidate": {"sha": B}})
        d.write(self.root / "current.json", {"sha": B, "release": "releases/" + B})
        result = self.update()
        self.assertEqual(result["state"], "pending")
        self.assertEqual(d.read(self.root / "current.json"), self.previous)
        self.assertIn("recover", self.calls)

    def test_superseded_candidate_never_activates(self):
        def adapter(config, release, operation, root):
            if operation == "preflight":
                self.github.sha = C
        self.assertEqual(d.update(self.root, self.github, adapter)["state"], "pending")
        self.assertEqual(d.read(self.root / "current.json"), self.previous)

    def test_staged_tamper_is_detected_on_retry(self):
        with d.lock(self.state / "tick.lock"):
            self.update()
        (self.root / "releases" / B / "data.json").write_text("tampered")
        self.assertEqual(self.update()["state"], "error")
        self.assertEqual(d.read(self.root / "current.json"), self.previous)

    def test_wrong_source_and_state_version_rejected(self):
        for key, value in (("product", "other"), ("repository", "other/repo"), ("stateCompatibility", 9)):
            with self.subTest(key=key):
                config = {**self.config, key: value}
                with self.assertRaises(d.DeliveryError):
                    d.unpack(self.archive, self.root / "bad", config, B)
        with self.assertRaises(d.DeliveryError):
            d.unpack(self.archive, self.root / "bad", self.config, A)

    def test_paths_and_hashes_are_checked_before_extraction(self):
        for name in ("../escape", "C:/escape", "a/../../b", "x\\b", "CON", "foo.", "DATA.json"):
            with self.subTest(name=name):
                archive = Path(self.tmp.name) / "bad.zip"
                shutil.copyfile(self.archive, archive)
                with zipfile.ZipFile(archive, "a") as z:
                    z.writestr(name, "bad")
                destination = self.root / "bad"
                with self.assertRaises(d.DeliveryError):
                    d.unpack(archive, destination, self.config, B)
                self.assertFalse(destination.exists())

    def test_reproducible_package(self):
        other = Path(self.tmp.name) / "other.zip"
        package(self.source, other, "hotpl8", "example/hotpl8", B)
        self.assertEqual(d.digest(other), d.digest(self.archive))

    @unittest.skipUnless(os.name == "nt", "Windows launcher qualification")
    def test_real_launcher_enrollment_and_argument_forwarding(self):
        def launch(arguments):
            # This bounds hangs, not product latency. The hosted run exceeded
            # the original 20-second bound for the nested PowerShell fixture.
            # Record elapsed time to distinguish slow startup from a real hang.
            # Keep the exit/output/state assertions and record the startup time.
            # Raised again once the suites began running concurrently: the same
            # nested cold start measured 1.5-2.4s on a 16-CPU machine and 75s on
            # a 4-vCPU hosted runner sharing it with every other suite.
            started = time.monotonic()
            try:
                return subprocess.run(arguments, capture_output=True, timeout=180)
            finally:
                print("fixture launcher elapsed: %.1fs" % (time.monotonic() - started), flush=True)
        import setup
        source = Path(__file__).resolve().parents[1]
        release = self.root / "releases" / B
        release.mkdir(parents=True)
        shutil.copytree(source / "delivery", release / "delivery", ignore=shutil.ignore_patterns("__pycache__"))
        # A fixture executable entry records the actual arguments and state
        # routing without contacting providers or touching the real scheduler.
        (release / "hotpl8.ps1").write_text("param([string]$Command,[switch]$AsJson)\n@{command=$Command;json=[bool]$AsJson;state=$env:HOTPL8_STATE_DIRECTORY}|ConvertTo-Json\n")
        (release / "tick.ps1").write_text("param([switch]$Scheduled)\nif(-not $Scheduled){exit 9}\nexit 0\n")
        d.write(self.root / "current.json", {"sha": B, "release": "releases/" + B})
        d.write(self.root / "installation.json", {"product": "hotpl8", "stateDirectory": str(self.state)})
        (self.root / "app").mkdir()
        (self.root / "app" / "original.txt").write_text("retained")
        (self.root / "delivery.json").unlink()
        with patch.object(setup, "update", return_value={"state": "current"}), patch.object(setup.shutil, "which", return_value="gh"):
            setup.setup(self.root, register=False)
            setup.setup(self.root, register=False)
        ps = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        result = launch([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(self.root / "app/hotpl8.ps1"), "status", "-AsJson"])
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(json.loads(result.stdout), {"command": "status", "json": True, "state": str(self.state)})
        result = launch([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(self.root / "app/tick.ps1"), "-Scheduled"])
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        legacy = self.root / "legacy.ps1"
        legacy.write_text("$parameters=@{Scheduled=$true}\n& (Join-Path $PSScriptRoot 'app/tick.ps1') @parameters\nexit $LASTEXITCODE\n")
        result = launch([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(legacy)])
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        legacy.write_text("$parameters=@{Command='status';AsJson=$true}\n& (Join-Path $PSScriptRoot 'app/hotpl8.ps1') @parameters\nexit $LASTEXITCODE\n")
        result = launch([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(legacy)])
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(json.loads(result.stdout)["command"], "status")
        backups = list(self.root.glob("legacy-app-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "original.txt").read_text(), "retained")
        self.assertEqual(d.read(self.state / "ledger.json"), {"request": 42})
        # A display exits with 75 after a generation change. The stable launcher
        # must hand off in the same console, retaining the requested command.
        next_release = self.root / "releases" / C
        next_release.mkdir()
        (next_release / "hotpl8.ps1").write_text("param([string]$Command)\nWrite-Output ('new:'+ $Command)\n")
        (release / "hotpl8.ps1").write_text(
            "@{sha='" + C + "';release='releases/" + C + "'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:HOTPL8_INSTALL_DIRECTORY 'current.json')\nexit 75\n")
        result = launch([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(self.root / "app/hotpl8.ps1"), "watch"])
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout.strip(), b"new:watch")

    @unittest.skipUnless(os.name == "nt", "Windows updater launcher qualification")
    def test_updater_launcher_survives_quoting_and_reaches_the_updater(self):
        # Nothing else executes the VBS the updater task launches, and its Python path
        # is quoted by hand. Plan the registration -- which writes the launcher and
        # creates no task -- then run that launcher and check what it invoked.
        source = Path(__file__).resolve().parents[1]
        # A unique product cannot collide with a real LocalDelivery task on this machine.
        product = "hotpl8-fixture-" + uuid.uuid4().hex
        d.write(self.root / "delivery.json", dict(self.config, product=product))
        # A space in the interpreter path is the case the hand-written quoting exists for.
        stub = Path(sys.executable)
        (self.root / 'delivery.py').write_text(
            'import json, sys\nfrom pathlib import Path\n'
            'Path(__file__).with_name("invoked.txt").write_text(json.dumps(sys.argv))\n'
            'raise SystemExit(7)\n')
        ps = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        result = subprocess.run([ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                                 str(source / "delivery/register.ps1"), "-InstallDirectory", str(self.root),
                                 "-Python", str(stub), "-PlanOnly"], capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        plan = json.loads(result.stdout)
        self.assertEqual(plan["name"], "LocalDelivery-" + product)
        self.assertEqual(plan["description"], "Local Delivery owned installation " + str(self.root))
        self.assertTrue(Path(plan['execute']).is_file())
        result = subprocess.run('"' + plan['execute'] + '" ' + plan['arguments'], capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 7, result.stderr.decode(errors="replace"))
        invoked = json.loads((self.root / "invoked.txt").read_text())
        # A dropped quote would truncate either path at its first space.
        self.assertEqual(invoked[0].strip().strip('"'), str(self.root / "delivery.py"))
        self.assertEqual(invoked[1].strip(), "update")
        receipts = list((self.root / 'job-runs/updater').glob('*/run.json'))
        self.assertEqual(len(receipts), 1)
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(receipt['exitCode'], 7)
        self.assertEqual(receipt['status'], 'failed')

    @unittest.skipUnless(os.name == "nt", "Windows product adapter")
    def test_real_product_package_preflight_and_readiness(self):
        source = Path(__file__).resolve().parents[1]
        inventory = d.read(source / "release-files.json")["files"]
        with zipfile.ZipFile(self.source, "w") as z:
            for name in inventory:
                z.write(source / name, name)
        package(self.source, self.archive, "hotpl8", "example/hotpl8", B)
        config = {**self.config, "adapter": "delivery/hotpl8-adapter.ps1"}
        destination = self.root / "candidate"
        d.unpack(self.archive, destination, config, B)
        shutil.copyfile(source / "policy.example.json", self.state / "policy.json")
        before = d.digest(self.state / "policy.json")
        d.invoke_adapter(config, destination, "preflight", self.root)
        d.invoke_adapter(config, destination, "health", self.root)
        self.assertEqual(d.digest(self.state / "policy.json"), before)
        self.assertEqual(d.read(self.state / "ledger.json"), {"request": 42})

    def test_preview_is_repeatable_and_never_selects_production(self):
        self.config["previewWorkflow"] = "ci.yml"
        d.write(self.root / "delivery.json", self.config)
        gh = d.GitHub("example/hotpl8", "fixture-gh")
        def api(endpoint):
            if endpoint.startswith("pulls/"):
                return {"head": {"sha": B}}
            if endpoint.startswith("actions/workflows/"):
                return {"workflow_runs": [{"id": 12, "head_sha": B, "event": "pull_request", "status": "completed", "conclusion": "success", "pull_requests": [{"number": 7}]}]}
            return {"artifacts": [{"id": 13, "name": "preview-images", "expired": False}]}
        gh.api = api
        def download(arguments, **kwargs):
            self.assertEqual(arguments[-1], "repos/example/hotpl8/actions/artifacts/13/zip")
            with zipfile.ZipFile(kwargs["stdout"], "w") as archive:
                archive.writestr("dashboard.png", b"\x89PNG\r\n\x1a\nfixture")
            return subprocess.CompletedProcess(arguments, 0)
        with patch.object(d.subprocess, "run", side_effect=download):
            first = d.preview(self.root, 7, gh)
            second = d.preview(self.root, 7, gh)
        self.assertEqual(first, second)
        self.assertEqual(first["sha"], B)
        self.assertEqual(first["mode"], "CI-rendered fictional data")
        self.assertEqual(len(first["images"]), 1)
        self.assertTrue(Path(first["images"][0]).is_file())
        self.assertEqual(d.read(self.root / "current.json"), self.previous)
        self.assertEqual(d.read(self.state / "ledger.json"), {"request": 42})

    def test_preview_rejects_entire_unsafe_archive_before_writing_images(self):
        self.config["previewWorkflow"] = "ci.yml"
        d.write(self.root / "delivery.json", self.config)
        gh = d.GitHub("example/hotpl8", "fixture-gh")
        def api(endpoint):
            if endpoint.startswith("pulls/"):
                return {"head": {"sha": B}}
            if endpoint.startswith("actions/workflows/"):
                return {"workflow_runs": [{"id": 12, "head_sha": B, "event": "pull_request", "status": "completed", "conclusion": "success", "pull_requests": [{"number": 7}]}]}
            return {"artifacts": [{"id": 13, "name": "preview-images", "expired": False}]}
        gh.api = api
        for unsafe in ("../escape.png", "script.ps1", "DASHBOARD.png"):
            with self.subTest(name=unsafe):
                def download(arguments, **kwargs):
                    with zipfile.ZipFile(kwargs["stdout"], "w") as archive:
                        archive.writestr("dashboard.png", b"\x89PNG\r\n\x1a\nfixture")
                        archive.writestr(unsafe, b"\x89PNG\r\n\x1a\nfixture")
                    return subprocess.CompletedProcess(arguments, 0)
                with patch.object(d.subprocess, "run", side_effect=download):
                    with self.assertRaises(d.DeliveryError):
                        d.preview(self.root, 7, gh)
                self.assertFalse((self.root / "previews").exists())
                self.assertEqual(d.read(self.root / "current.json"), self.previous)
                self.assertEqual(d.read(self.state / "ledger.json"), {"request": 42})

    def test_merged_preview_retains_exact_source_binding_without_pr_association(self):
        self.config["previewWorkflow"] = "ci.yml"
        d.write(self.root / "delivery.json", self.config)
        gh = d.GitHub("example/hotpl8", "fixture-gh")
        pr = {"merged": True, "head": {"sha": B, "ref": "feature", "repo": {"id": 9}}}
        workflow = {"id": 12, "head_sha": B, "head_branch": "feature", "head_repository": {"id": 9},
                    "event": "pull_request", "status": "completed", "conclusion": "success", "pull_requests": []}
        def api(endpoint):
            if endpoint.startswith("pulls/"): return pr
            if endpoint.startswith("actions/workflows/"): return {"workflow_runs": [workflow]}
            return {"artifacts": [{"id": 13, "name": "preview-images", "expired": False}]}
        gh.api = api
        def download(arguments, **kwargs):
            with zipfile.ZipFile(kwargs["stdout"], "w") as archive:
                archive.writestr("dashboard.png", b"\x89PNG\r\n\x1a\nfixture")
            return subprocess.CompletedProcess(arguments, 0)
        with patch.object(d.subprocess, "run", side_effect=download) as command:
            self.assertEqual(d.preview(self.root, 7, gh)["sha"], B)
            for key, value in (("head_sha", A), ("head_branch", "other"), ("head_repository", {"id": 99}), ("event", "push"), ("status", "in_progress")):
                with self.subTest(key=key):
                    previous = workflow[key]
                    workflow[key] = value
                    with self.assertRaises(d.Deferred): d.preview(self.root, 7, gh)
                    workflow[key] = previous
            pr["merged"] = False
            with self.assertRaises(d.Deferred): d.preview(self.root, 7, gh)
            self.assertEqual(command.call_count, 1)
        self.assertEqual(d.read(self.root / "current.json"), self.previous)

    def test_github_checks_exact_main_workflow_and_digest(self):
        gh = d.GitHub("example/hotpl8")
        release = {"tag_name": "main-" + B, "id": 2, "draft": False,
                   "assets": [{"id": 3, "name": "hotpl8-main.zip", "digest": "sha256:" + "d" * 64}]}
        workflow = {"id": 4, "head_sha": B, "head_branch": "main", "event": "push", "status": "completed",
                    "conclusion": "success", "head_repository": {"full_name": "example/hotpl8"}}
        def api(endpoint):
            if endpoint.startswith("releases/"): return release
            if endpoint.startswith("commits/"): return {"sha": B}
            return {"workflow_runs": [workflow]}
        gh.api = api
        self.assertEqual(gh.candidate(B, self.config)["sha"], B)
        for key, value in (("head_sha", A), ("head_branch", "feature"), ("event", "pull_request"), ("conclusion", "failure")):
            with self.subTest(key=key):
                old = workflow[key]
                workflow[key] = value
                with self.assertRaises(d.Deferred): gh.candidate(B, self.config)
                workflow[key] = old
        release["assets"][0]["digest"] = None
        with self.assertRaises(d.DeliveryError): gh.candidate(B, self.config)


    def test_central_owner_blocks_direct_runner_without_writes(self):
        d.write(self.root / "delivery-owner.json", {"protocol": 1})
        before = (self.root / "current.json").read_bytes()
        with self.assertRaises(d.DeliveryError):
            self.update()
        self.assertEqual((self.root / "current.json").read_bytes(), before)
        self.assertEqual(self.github.downloads, 0)

    def test_bootstrap_delegates_update_and_preview_but_refuses_broken_owner(self):
        import runpy
        source = Path(__file__).resolve().parents[1] / "delivery/bootstrap.py"
        bootstrap = self.root / "delivery.py"
        shutil.copyfile(source, bootstrap)
        entry = self.root / "manager.py"
        entry.write_text("# fixture dispatcher")
        owner = {"protocol": 1, "entry": str(entry), "entrySha256": d.digest(entry), "service": "sample"}
        d.write(self.root / "delivery-owner.json", owner)
        for args in (["update"], ["preview", "7"]):
            with self.subTest(args=args), patch.object(sys, "argv", [str(bootstrap), *args]), patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as invoke:
                with self.assertRaises(SystemExit) as exited:
                    runpy.run_path(str(bootstrap), run_name="__main__")
                self.assertEqual(exited.exception.code, 0)
                command = invoke.call_args.args[0]
                self.assertEqual(command[:6], [sys.executable, str(entry), "--service", "sample", "--expected-install", str(self.root)])
                self.assertEqual(command[6:], ["update"] if args[0] == "update" else ["preview", "--pr", "7"])
        entry.write_text("changed")
        with patch.object(sys, "argv", [str(bootstrap), "update"]), patch.object(subprocess, "run") as invoke:
            with self.assertRaises(SystemExit): runpy.run_path(str(bootstrap), run_name="__main__")
            invoke.assert_not_called()

if __name__ == "__main__":
    unittest.main()
