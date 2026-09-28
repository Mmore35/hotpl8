"""Native tests of stable dispatch, drain and handoff; all application code is fake."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "delivery"))
import runner

A, B = "a" * 40, "b" * 40


@unittest.skipUnless(sys.platform == "darwin", "Native macOS stable dispatch")
class MacLaunchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hotpl8-dispatch-")
        self.root = Path(self.tmp.name) / "install with spaces"
        self.root.mkdir()
        self.state = Path(self.tmp.name) / "state with spaces"
        self.state.mkdir()
        self.pwsh = shutil.which("pwsh")
        self.assertIsNotNone(self.pwsh)
        self.config = dict(stateDirectory=str(self.state), powershell=self.pwsh)
        runner.write(self.root / "delivery.json", self.config)
        shutil.copyfile(REPO / "delivery/launch.ps1", self.root / "launch.ps1")
        for sha in (A, B):
            release = self.root / "releases" / sha
            release.mkdir(parents=True)
            (release / "tick.ps1").write_text("""param([switch]$Scheduled)
@{scheduled=[bool]$Scheduled;state=$env:HOTPL8_STATE_DIRECTORY;install=$env:HOTPL8_INSTALL_DIRECTORY;release=$PSScriptRoot}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:HOTPL8_STATE_DIRECTORY 'observed.json')
exit 0
""", encoding="utf-8")
        runner.write(self.root / "current.json", dict(sha=A, release="releases/" + A))

    def tearDown(self):
        self.tmp.cleanup()

    def launch(self, *args):
        return subprocess.run([self.pwsh, "-NoProfile", "-NonInteractive", "-File", str(self.root / "launch.ps1"), *args],
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=15)

    def test_next_launch_adopts_pointer_and_preserves_arguments_and_state_binding(self):
        for sha in (A, B):
            runner.write(self.root / "current.json", dict(sha=sha, release="releases/" + sha))
            result = self.launch("-Entry", "tick", "-Scheduled")
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            observed = runner.read(self.state / "observed.json")
            self.assertTrue(observed["scheduled"])
            self.assertEqual(Path(observed["state"]), self.state)
            self.assertEqual(Path(observed["install"]), self.root)
            self.assertEqual(Path(observed["release"]).name, sha)

    def test_updater_lease_defers_tick_without_running_application(self):
        with runner.lock(self.root / "runtime.lock"):
            result = self.launch("-Entry", "tick", "-Scheduled")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse((self.state / "observed.json").exists())

    def test_positional_cli_command_is_forwarded_not_bound_as_install_directory(self):
        (self.root / 'releases' / A / 'hotpl8.ps1').write_text('''param([string]$Command)
@{command=$Command}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:HOTPL8_STATE_DIRECTORY 'observed.json')
''', encoding='utf-8')
        result = self.launch('-Entry', 'hotpl8', 'status')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(runner.read(self.state / 'observed.json')['command'], 'status')

    def test_relative_native_executable_is_rejected(self):
        self.config["powershell"] = "pwsh"
        runner.write(self.root / "delivery.json", self.config)
        self.assertNotEqual(self.launch("-Entry", "tick").returncode, 0)
        self.assertFalse((self.state / "observed.json").exists())

    def test_unsafe_pointer_is_rejected_before_dispatch(self):
        runner.write(self.root / "current.json", dict(sha=A, release="../outside"))
        self.assertNotEqual(self.launch("-Entry", "tick").returncode, 0)
        self.assertFalse((self.state / "observed.json").exists())

    def test_display_handoff_selects_new_release(self):
        script = self.root / "releases" / A / "hotpl8.ps1"
        script.write_text("""@{sha='""" + B + """';release='releases/""" + B + """'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:HOTPL8_INSTALL_DIRECTORY 'current.json')
exit 75
""", encoding="utf-8")
        shutil.copyfile(self.root / "releases" / B / "tick.ps1", self.root / "releases" / B / "hotpl8.ps1")
        result = self.launch("-Entry", "hotpl8")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(Path(runner.read(self.state / "observed.json")["release"]).name, B)


if __name__ == "__main__":
    unittest.main()
