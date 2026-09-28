"""Prove Python updater locks exclude actual PowerShell writers on macOS."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "delivery"))
import runner


@unittest.skipUnless(sys.platform == "darwin", "Native macOS lock interoperability")
class MacLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hotpl8-lock-test-")
        self.root = Path(self.tmp.name)
        self.path = self.root / "writer.lock"
        self.child = None
        self.pwsh = shutil.which("pwsh")
        self.assertIsNotNone(self.pwsh, "Native qualification requires PowerShell")

    def tearDown(self):
        if self.child is not None:
            (self.root / "release").touch()
            try:
                self.child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.communicate()
        self.tmp.cleanup()

    def start_writer(self, share):
        script = self.root / "writer.ps1"
        script.write_text("""param($LockPath, $ReadyPath, $ReleasePath, $Share)
$ErrorActionPreference='Stop'
$lease=[IO.File]::Open($LockPath,'OpenOrCreate','ReadWrite',$Share)
try {
    [IO.File]::WriteAllText($ReadyPath,'ready')
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(-not [IO.File]::Exists($ReleasePath)) {
        if([DateTime]::UtcNow -gt $deadline){throw 'Fixture timed out'}
        Start-Sleep -Milliseconds 25
    }
} finally {$lease.Dispose()}
""", encoding="utf-8")
        self.child = subprocess.Popen([self.pwsh, "-NoProfile", "-NonInteractive", "-File", str(script),
                                       str(self.path), str(self.root / "ready"),
                                       str(self.root / "release"), share],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        while not (self.root / "ready").exists():
            self.assertIsNone(self.child.poll(), "Fixture exited before acquiring its lease")
            self.assertLess(time.monotonic(), deadline, "Fixture did not acquire its lease")
            time.sleep(.025)

    def test_exclusive_powershell_writer_defers_python_updater(self):
        self.start_writer("None")
        with self.assertRaises(runner.Deferred):
            with runner.lock(self.path):
                self.fail("Updater entered during native writer")

    def test_shared_powershell_runtime_lease_defers_python_updater(self):
        self.start_writer("ReadWrite")
        with self.assertRaises(runner.Deferred):
            with runner.lock(self.path):
                self.fail("Updater entered during native runtime lease")

    def test_python_updater_excludes_powershell_writer(self):
        script = self.root / "probe.ps1"
        script.write_text("""param($LockPath)
try {
    $lease=[IO.File]::Open($LockPath,'OpenOrCreate','ReadWrite','None')
    $lease.Dispose()
    exit 2
} catch [IO.IOException] {
    $number=$_.Exception.HResult -band 0xffff
    if($number -eq 35){exit 0}
    exit 3
}
""", encoding="utf-8")
        with runner.lock(self.path):
            result = subprocess.run([self.pwsh, "-NoProfile", "-NonInteractive", "-File", str(script), str(self.path)],
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, "Expected native EWOULDBLOCK while updater holds lock")

    def test_native_exit_releases_lock_for_next_update(self):
        self.start_writer("None")
        (self.root / "release").touch()
        self.child.communicate(timeout=10)
        self.assertEqual(self.child.returncode, 0)
        with runner.lock(self.path):
            self.assertTrue(self.path.exists())


if __name__ == "__main__":
    unittest.main()
