"""PR identity, explicit execution boundary, archive and lifecycle regressions."""
import io
import json
import os
from pathlib import Path
import stat
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "delivery"))
import live_preview as live
import runner as d

SHA = "a" * 40
OTHER = "b" * 40


def source_zip(extra=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as z:
        for name in ("hotpl8.ps1", "src/dashboard.ps1", "tests/fixtures/screenshots.ps1"):
            z.writestr("repo-head/" + name, "# fictional candidate")
        for name, value in (extra or {}).items():
            z.writestr(name, value)
    return output.getvalue()


class Preview(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = dict(repository="sample/hotpl8", previewWorkflow="ci.yml", powershell=sys.executable)
        d.write(self.root / "delivery.json", self.config)
        d.write(self.root / "current.json", dict(sha=OTHER, release="releases/" + OTHER))
        self.before = (self.root / "current.json").read_bytes()
        self.pr = dict(head=dict(sha=SHA, repo=dict(full_name="sample/hotpl8")))
        self.workflow = dict(id=11, conclusion="success", event="pull_request", status="completed",
                             head_sha=SHA, pull_requests=[dict(number=34)])
        self.gh = mock.Mock(repo="sample/hotpl8", executable="gh")
        self.gh.api.side_effect = lambda endpoint: self.pr if endpoint.startswith("pulls/") else dict(workflow_runs=[self.workflow])
        self.download = source_zip()
        self.children = []

    def run_child(self, argv, **kwargs):
        if argv[0] == "gh":
            self.assertEqual(argv[-1], "repos/sample/hotpl8/zipball/" + SHA)
            kwargs["stdout"].write(self.download)
        else:
            self.children.append((argv, kwargs))
            self.assertTrue(Path(argv[argv.index("-SourceDirectory") + 1], "src/dashboard.ps1").is_file())
            self.assertNotIn("HOTPL8_INSTALL_DIRECTORY", kwargs["env"])
            self.assertNotIn("GH_TOKEN", kwargs["env"])
            self.assertNotIn("stdout", kwargs)  # Native terminal is inherited, not piped.
        return subprocess.CompletedProcess(argv, 0)

    def invoke(self, sha=SHA):
        with mock.patch.object(live.subprocess, "run", side_effect=self.run_child):
            return live.launch(self.root, 34, sha, self.gh)

    def test_exact_head_runs_real_candidate_with_disposable_demo_state_and_no_activation(self):
        with mock.patch.dict(os.environ, HOTPL8_INSTALL_DIRECTORY="production", GH_TOKEN="fictional-token"):
            self.assertEqual(self.invoke(), 0)
        self.assertEqual(len(self.children), 1)
        argv = self.children[0][0]
        self.assertIn("https://github.com/sample/hotpl8/pull/34", argv)
        self.assertEqual(argv[-1], SHA)
        self.assertFalse(Path(argv[argv.index("-StateDirectory") + 1]).exists())
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)
        receipt = d.read(self.root / "previews/pr-34" / SHA / "live.json")
        self.assertEqual(receipt["mode"], "live fictional accounts")

    def test_repeated_launches_have_distinct_sessions(self):
        self.invoke(); self.invoke()
        self.assertNotEqual(self.children[0][0], self.children[1][0])
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)

    def test_changed_unpinned_or_fork_revision_never_downloads_or_executes(self):
        for invalid in ("", SHA[:7], OTHER, "../" + SHA):
            with self.subTest(invalid=invalid), mock.patch.object(live.subprocess, "run") as process:
                with self.assertRaises(d.DeliveryError):
                    live.launch(self.root, 34, invalid, self.gh)
                process.assert_not_called()
        self.pr["head"]["repo"]["full_name"] = "outsider/fork"
        with mock.patch.object(live.subprocess, "run") as process:
            with self.assertRaises(d.DeliveryError): self.invoke()
            process.assert_not_called()
        self.assertFalse(self.children)

    def test_failed_wrong_pr_wrong_sha_or_unfinished_ci_cannot_execute(self):
        for key, bad in (("conclusion", "failure"), ("head_sha", OTHER), ("pull_requests", [dict(number=35)]),
                         ("status", "in_progress"), ("event", "push")):
            original = self.workflow[key]
            with self.subTest(key=key), mock.patch.object(live.subprocess, "run") as process:
                self.workflow[key] = bad
                with self.assertRaises(d.Deferred): self.invoke()
                process.assert_not_called()
            self.workflow[key] = original

    def test_head_changed_during_download_is_rejected(self):
        self.gh.api.side_effect = [self.pr, dict(workflow_runs=[self.workflow]), dict(head=dict(sha=OTHER))]
        with self.assertRaises(d.Deferred): self.invoke()
        self.assertFalse(self.children)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_child_failure_propagates_and_cleans_up(self):
        original = self.run_child
        def fail(argv, **kwargs):
            result = original(argv, **kwargs)
            return result if argv[0] == "gh" else subprocess.CompletedProcess(argv, 7)
        self.run_child = fail
        self.assertEqual(self.invoke(), 7)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)

    def test_download_failure_never_executes_and_cleans_up(self):
        self.run_child = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 1)
        with self.assertRaises(d.Deferred): self.invoke()
        self.assertFalse(self.children)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_unsafe_archive_rejected_before_any_extraction(self):
        for name in ("repo-head/../outside", "/absolute", "repo-head/a\\b", "repo-head/C:drive", "repo-head/con",
                     "repo-head/file.", "repo-head/file ", "second-root/a", "repo-head/SRC/dashboard.ps1",
                     "repo-head/src", "repo-head/a/./b"):
            with self.subTest(name=name):
                self.download = source_zip({name: "unsafe"})
                with self.assertRaises(d.DeliveryError): self.invoke()
                self.assertFalse(self.children)
                self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_symlink_rejected(self):
        item = zipfile.ZipInfo("repo-head/link")
        item.create_system = 3
        item.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.download = source_zip({item: "../../private"})
        with self.assertRaises(d.DeliveryError): self.invoke()
        self.assertFalse(self.children)

    def test_real_demo_harness_runs_in_installed_powershell_without_account_state(self):
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if not powershell: self.skipTest("PowerShell unavailable")
        state = self.root / "fixture"
        state.mkdir()
        result = subprocess.run([powershell, "-NoProfile", "-File", str(REPO / "delivery/live-preview.ps1"),
                                 "-SourceDirectory", str(REPO), "-StateDirectory", str(state),
                                 "-PrUrl", "https://github.com/sample/hotpl8/pull/34", "-Revision", SHA],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        self.assertIn(b"Demo Everyday", result.stdout)
        self.assertIn(b"Demo Work", result.stdout)
        self.assertEqual(sorted(p.name for p in state.iterdir()), ["policy.json", "status.json"])
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)

    @unittest.skipUnless(sys.platform == "darwin", "Native controlling terminal")
    def test_live_harness_animation_freeze_resize_and_exit_on_native_terminal(self):
        import fcntl
        import pty
        import select
        import signal
        import struct
        import termios
        import time
        state = self.root / "fixture"
        state.mkdir()
        pid, master = pty.fork()
        if pid == 0:
            exe = shutil.which("pwsh")
            os.execve(exe, [exe, "-NoProfile", "-File", str(REPO / "delivery/live-preview.ps1"),
                           "-SourceDirectory", str(REPO), "-StateDirectory", str(state),
                           "-PrUrl", "https://github.com/sample/hotpl8/pull/34", "-Revision", SHA],
                      dict(os.environ, TERM="xterm-256color", TERM_PROGRAM="Apple_Terminal", NO_COLOR="",
                           HOTPL8_INSTALL_DIRECTORY="", HOTPL8_REDUCED_MOTION=""))
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 114, 0, 0))
        output = bytearray()
        def collect(seconds):
            start = len(output)
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    try: chunk = os.read(master, 65536)
                    except OSError: break
                    if not chunk: break
                    output.extend(chunk)
            return bytes(output[start:])
        status = None
        try:
            deadline = time.monotonic() + 20
            while b"Demo Everyday" not in output and time.monotonic() < deadline: collect(.1)
            self.assertIn(b"Demo Everyday", output)
            self.assertIn(b"\x1b[?1049h", output)
            self.assertIn(b"\x1b[48;5;", output)
            self.assertNotRegex(bytes(output), rb"\x1b\[(38|48);2;")
            self.assertGreater(len(collect(1)), 100)
            os.write(master, b" "); collect(2)
            self.assertEqual(collect(.5), b"")
            os.write(master, b" ")
            self.assertGreater(len(collect(1)), 100)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 80, 0, 0))
            os.kill(pid, signal.SIGWINCH)
            self.assertGreater(len(collect(2)), 100)
            os.write(master, b"q")
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                collect(.1)
                waited, value = os.waitpid(pid, os.WNOHANG)
                if waited: status = value; break
            self.assertIsNotNone(status)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0)
            self.assertIn(b"\x1b[?1049l", output)
        finally:
            if status is None:
                os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
            os.close(master)

    def test_public_powershell_command_forwards_live_pin_and_preserves_image_preview(self):
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if not powershell: self.skipTest("PowerShell unavailable")
        config = dict(self.config, python=sys.executable)
        d.write(self.root / "delivery.json", config)
        (self.root / "delivery.py").write_text("import json,sys; print(json.dumps(sys.argv[1:]))")
        command = [powershell, "-NoProfile", "-File", str(REPO / "hotpl8.ps1"), "preview", "pr", "34",
                   "-InstallDirectory", str(self.root)]
        for tail, expected in (([], ["preview", "34"]),
                               (["-Live", "-TrustRevision", SHA], ["preview", "34", "--trust-revision", SHA])):
            result = subprocess.run(command + tail, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
            self.assertEqual(json.loads(result.stdout), expected)
        result = subprocess.run(command + ["-Live"], capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)

    def test_existing_installed_bootstrap_loads_new_preview_from_selected_release(self):
        # This stable bootstrap predates live preview. Advancing only current.json
        # must select all new helpers, without adding a module to the install root.
        old = self.root / "releases" / OTHER / "delivery"
        old.mkdir(parents=True)
        (old / "runner.py").write_text("print('old-release')")
        shutil.copyfile(REPO / "delivery/bootstrap.py", self.root / "delivery.py")
        command = [sys.executable, str(self.root / "delivery.py"), "preview", "34", "--trust-revision", "short"]
        self.assertEqual(subprocess.check_output(command).strip(), b"old-release")
        new = self.root / "releases" / SHA / "delivery"
        new.mkdir(parents=True)
        for name in ("runner.py", "live_preview.py", "live-preview.ps1"):
            shutil.copyfile(REPO / "delivery" / name, new / name)
        d.write(self.root / "current.json", dict(sha=SHA, release="releases/" + SHA))
        result = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("full trusted PR revision", json.loads(result.stdout)["reason"])
        self.assertNotIn(b"Traceback", result.stderr)
        d.write(self.root / "current.json", dict(sha=OTHER, release="releases/" + OTHER))
        self.assertEqual(subprocess.check_output(command).strip(), b"old-release")

    def test_release_inventory_contains_live_preview_and_screenshot_dependencies(self):
        inventory = set(json.loads((REPO / "release-files.json").read_text())["files"])
        for name in ("delivery/live_preview.py", "delivery/live-preview.ps1", "tests/fixtures/screenshots.ps1",
                     "tests/fixtures/terminal.ps1"):
            self.assertIn(name, inventory)

    def test_script_entry_reports_invalid_pin_without_traceback(self):
        result = subprocess.run([sys.executable, str(REPO / "delivery/runner.py"), "--install", str(self.root),
                                 "preview", "34", "--trust-revision", "short"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["state"], "error")
        self.assertNotIn(b"Traceback", result.stderr)

    def test_size_limit_and_missing_surface_rejected(self):
        archive = self.root / "source.zip"
        archive.write_bytes(source_zip())
        with mock.patch.object(Path, "stat", return_value=mock.Mock(st_size=100_000_001)):
            with self.assertRaises(d.DeliveryError): live.extract_source(archive, self.root / "source")
        with zipfile.ZipFile(archive, "w") as z: z.writestr("repo/README.md", "no dashboard")
        with self.assertRaises(d.DeliveryError): live.extract_source(archive, self.root / "source")
        self.assertFalse((self.root / "source").exists())


if __name__ == "__main__":
    unittest.main()
