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
        result = subprocess.run([ps, "-NoProfile", "-File", str(self.root / "app/hotpl8.ps1"), "status", "-AsJson"], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(json.loads(result.stdout), {"command": "status", "json": True, "state": str(self.state)})
        result = subprocess.run([ps, "-NoProfile", "-File", str(self.root / "app/tick.ps1"), "-Scheduled"], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
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
        result = subprocess.run([ps, "-NoProfile", "-File", str(self.root / "app/hotpl8.ps1"), "watch"], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout.strip(), b"new:watch")

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


if __name__ == "__main__":
    unittest.main()
