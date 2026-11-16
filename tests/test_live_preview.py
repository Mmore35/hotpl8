"""PR identity, explicit execution boundary, archive and lifecycle regressions."""
import hashlib
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
PLATFORM = "windows" if os.name == "nt" else "macos"
READER = "bin/" + PLATFORM + "/hotpl8-native" + (".exe" if PLATFORM == "windows" else "")
PACKAGE = "hotpl8-0.0.0-" + PLATFORM + ".zip"


def source_zip(extra=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as z:
        for name in ("hotpl8.ps1", "src/common.ps1", "tests/fixtures/screenshots.ps1"):
            z.writestr("repo-head/" + name, "# fictional candidate")
        for name, value in (extra or {}).items():
            if isinstance(name, zipfile.ZipInfo):
                info = name
            else:
                info = zipfile.ZipInfo(name)
                # The writer otherwise sanitizes backslashes on Windows before
                # the malicious fixture ever reaches the production validator.
                info.filename = info.orig_filename = name
            z.writestr(info, value)
    return output.getvalue()


def candidate_zip(reader=b"fictional reader", recorded=None, sums=None, name=PACKAGE, extra=None, package=None):
    """The artifact CI stores for a candidate: its package and the package's checksum."""
    if package is None:
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as z:
            z.writestr("hotpl8.ps1", "# fictional candidate")
            if reader is not None:
                z.writestr(READER, reader)
            if recorded is not False:
                z.writestr("checksums.json", json.dumps({READER: recorded or hashlib.sha256(reader or b"").hexdigest()}))
        package = inner.getvalue()
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as z:
        z.writestr(name, package)
        z.writestr("SHA256SUMS", hashlib.sha256(package).hexdigest() + "  " + name + "\n" if sums is None else sums)
        for key, value in (extra or {}).items():
            z.writestr(key, value)
    return output.getvalue()


class Fixture(unittest.TestCase):
    """A trusted same-repository PR whose run passed, with every download faked."""

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
        self.candidate = None
        self.children = []
        self.readers = []

    def compiled(self, inventory=None, **changes):
        """Make the fixture a candidate that ships a compiled reader for this platform."""
        inventory = inventory or json.dumps(dict(files=["hotpl8.ps1"], platformFiles={PLATFORM: [READER]}))
        self.download = source_zip({"repo-head/release-files.json": inventory})
        self.candidate = candidate_zip(**changes)
        self.artifacts = [dict(id=77, name="hotpl8-" + PLATFORM + "-candidate", expired=False)]
        self.heads = []
        def api(endpoint):
            if endpoint.startswith("pulls/"):
                return self.heads.pop(0) if self.heads else self.pr
            if endpoint == "actions/runs/11/artifacts":
                return dict(artifacts=self.artifacts)
            return dict(workflow_runs=[self.workflow])
        self.gh.api.side_effect = api

    def run_child(self, argv, **kwargs):
        if argv[0] == "gh" and argv[-1].endswith("/zip"):
            self.assertEqual(argv[-1], "repos/sample/hotpl8/actions/artifacts/77/zip")
            kwargs["stdout"].write(self.candidate)
        elif argv[0] == "gh":
            self.assertEqual(argv[-1], "repos/sample/hotpl8/zipball/" + SHA)
            kwargs["stdout"].write(self.download)
        else:
            self.children.append((argv, kwargs))
            reader = Path(argv[argv.index("-SourceDirectory") + 1], READER)
            self.readers.append((reader.read_bytes(), os.access(reader, os.X_OK)) if reader.is_file() else None)
            self.assertTrue(Path(argv[argv.index("-SourceDirectory") + 1], "src/common.ps1").is_file())
            self.assertTrue("HOTPL8_INSTALL_DIRECTORY" not in kwargs["env"])
            self.assertTrue("GH_TOKEN" not in kwargs["env"])
            self.assertNotIn("stdout", kwargs)  # Native terminal is inherited, not piped.
        return subprocess.CompletedProcess(argv, 0)

    def invoke(self, sha=SHA):
        with mock.patch.object(live.subprocess, "run", side_effect=self.run_child):
            return live.launch(self.root, 34, sha, self.gh)


class Preview(Fixture):
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
        self.assertEqual(len(self.children), 0)

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
        self.assertEqual(len(self.children), 0)
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
        self.assertEqual(len(self.children), 0)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_unsafe_archive_rejected_before_any_extraction(self):
        for name in ("repo-head/../outside", "/absolute", "repo-head/a\\b", "repo-head/C:drive", "repo-head/con",
                     "repo-head/file.", "repo-head/file ", "second-root/a", "repo-head/SRC/common.ps1",
                     "repo-head/src", "repo-head/a/./b"):
            with self.subTest(name=name):
                self.children.clear()
                self.download = source_zip({name: "unsafe"})
                with self.assertRaises(d.DeliveryError): self.invoke()
                self.assertEqual(len(self.children), 0)
                self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_raw_backslash_is_rejected_even_when_zipinfo_normalizes_it(self):
        self.download = source_zip({"repo-head/a\\b": "unsafe"})
        # Exercise Windows ZipInfo normalization on either test host.
        with mock.patch.object(zipfile.os, "sep", "\\"):
            with zipfile.ZipFile(io.BytesIO(self.download)) as z:
                item = z.infolist()[-1]
                self.assertEqual(item.filename, "repo-head/a/b")
                self.assertEqual(item.orig_filename, "repo-head/a\\b")
            with self.assertRaises(d.DeliveryError): self.invoke()
        self.assertEqual(len(self.children), 0)

    def test_symlink_rejected(self):
        item = zipfile.ZipInfo("repo-head/link")
        item.create_system = 3
        item.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.download = source_zip({item: "../../private"})
        with self.assertRaises(d.DeliveryError): self.invoke()
        self.assertEqual(len(self.children), 0)

    def test_compiled_candidate_runs_with_the_reader_its_trusted_run_built(self):
        self.compiled()
        self.assertEqual(self.invoke(), 0)
        self.assertEqual(self.readers, [(b"fictional reader", True)])
        self.assertIn(mock.call("actions/runs/11/artifacts"), self.gh.api.mock_calls)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)

    def test_candidate_without_a_reader_for_this_platform_downloads_no_package(self):
        other = "macos" if PLATFORM == "windows" else "windows"
        for inventory in (None, json.dumps(dict(files=[READER])), json.dumps(dict(platformFiles={other: [READER]})),
                          json.dumps(dict(platformFiles={PLATFORM: ["bin/" + PLATFORM + "/another"]}))):
            with self.subTest(inventory=inventory):
                self.children.clear(); self.readers.clear(); self.gh.api.reset_mock()
                if inventory:
                    self.compiled(inventory=inventory)
                self.assertEqual(self.invoke(), 0)
                self.assertEqual(self.readers, [None])
                self.assertNotIn(mock.call("actions/runs/11/artifacts"), self.gh.api.mock_calls)

    def test_missing_expired_or_ambiguous_candidate_package_defers_without_executing(self):
        mine = dict(id=77, name="hotpl8-" + PLATFORM + "-candidate", expired=False)
        other = "macos" if PLATFORM == "windows" else "windows"
        for artifacts in ([], [dict(mine, expired=True)], [mine, dict(mine, id=78)],
                          [dict(mine, name="hotpl8-" + other + "-candidate")], [dict(mine, name="preview-images")]):
            with self.subTest(artifacts=artifacts):
                self.compiled()
                self.artifacts = artifacts
                with self.assertRaises(d.Deferred): self.invoke()
                self.assertEqual(len(self.children), 0)
                self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_candidate_package_download_failure_defers_without_executing(self):
        self.compiled()
        original = self.run_child
        def fail(argv, **kwargs):
            if argv[-1].endswith("/zip"):
                return subprocess.CompletedProcess(argv, 1)
            return original(argv, **kwargs)
        self.run_child = fail
        with self.assertRaises(d.Deferred): self.invoke()
        self.assertEqual(len(self.children), 0)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))

    def test_damaged_or_unexpected_candidate_package_never_executes(self):
        other = "macos" if PLATFORM == "windows" else "windows"
        cases = dict(
            wrong_package_checksum=dict(sums="0" * 64 + "  " + PACKAGE + "\n"),
            checksum_names_another_file=dict(package=b"x", sums=hashlib.sha256(b"x").hexdigest() + "  other.zip\n"),
            two_checksum_lines=dict(package=b"x", sums=(hashlib.sha256(b"x").hexdigest() + "  " + PACKAGE + "\n") * 2),
            empty_checksums=dict(sums=""),
            extra_file=dict(extra={"run.cmd": "unsafe"}),
            other_platform=dict(name="hotpl8-0.0.0-" + other + ".zip"),
            unsafe_name=dict(name="../hotpl8-0.0.0-" + PLATFORM + ".zip"),
            no_reader=dict(reader=None),
            reader_differs_from_its_checksum=dict(recorded="0" * 64),
            no_file_checksums=dict(recorded=False),
            package_is_not_an_archive=dict(package=b"not an archive"),
        )
        for label, changes in cases.items():
            with self.subTest(label=label):
                self.compiled(**changes)
                with self.assertRaises(d.DeliveryError): self.invoke()
                self.assertEqual(len(self.children), 0)
                self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))
        for label, candidate in (("not_an_archive", b"not an archive"), ("empty", b"")):
            with self.subTest(label=label):
                self.compiled()
                self.candidate = candidate
                with self.assertRaises(d.DeliveryError): self.invoke()
                self.assertEqual(len(self.children), 0)
        self.compiled(inventory="{")
        with self.assertRaises(d.DeliveryError): self.invoke()
        self.assertEqual(len(self.children), 0)

    def test_compiled_candidate_refuses_fork_failed_ci_and_changed_head(self):
        self.compiled()
        self.pr["head"]["repo"]["full_name"] = "outsider/fork"
        with mock.patch.object(live.subprocess, "run") as process:
            with self.assertRaises(d.DeliveryError): self.invoke()
            process.assert_not_called()
        self.pr["head"]["repo"]["full_name"] = "sample/hotpl8"
        self.workflow["conclusion"] = "failure"
        with mock.patch.object(live.subprocess, "run") as process:
            with self.assertRaises(d.Deferred): self.invoke()
            process.assert_not_called()
        self.workflow["conclusion"] = "success"
        # The head moves after both downloads: neither the source nor the reader runs.
        self.heads = [self.pr, dict(head=dict(sha=OTHER))]
        with self.assertRaises(d.Deferred): self.invoke()
        self.assertEqual(len(self.children), 0)
        self.assertFalse(list(self.root.glob("previews/pr-34/*/live-*")))
        self.assertEqual(self.invoke(), 0)
        self.assertEqual(self.readers, [(b"fictional reader", True)])

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

    def test_public_powershell_observe_forwards_pin_and_absolute_scenario(self):
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if not powershell: self.skipTest("PowerShell unavailable")
        d.write(self.root / "delivery.json", dict(self.config, python=sys.executable))
        (self.root / "delivery.py").write_text("import json,sys; print(json.dumps(sys.argv[1:]))")
        d.write(self.root / "claim.json", dict(claim="fictional"))
        command = [powershell, "-NoProfile", "-File", str(REPO / "hotpl8.ps1"), "observe", "pr", "34",
                   "-InstallDirectory", str(self.root), "-TrustRevision", SHA, "-Scenario", "claim.json"]
        scenario = str((self.root / "claim.json").resolve())
        for tail, expected in (([], []), (["-Baseline", OTHER], ["--baseline", OTHER])):
            result = subprocess.run(command + tail, capture_output=True, timeout=30, cwd=self.root)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
            self.assertEqual(json.loads(result.stdout),
                             ["preview", "34", "--trust-revision", SHA, "--observe", scenario] + expected)
        for tail in (["-Live"], ["-Baseline", "short"]):
            result = subprocess.run(command + tail, capture_output=True, timeout=30, cwd=self.root)
            self.assertNotEqual(result.returncode, 0, tail)
        for bad in (command[:-2], command[:-4] + command[-2:], command[:-2] + ["-Scenario", "missing.json"]):
            result = subprocess.run(bad, capture_output=True, timeout=30, cwd=self.root)
            self.assertNotEqual(result.returncode, 0, bad)
        result = subprocess.run(command[:4] + ["preview", "pr", "34", "-Scenario", "claim.json"],
                                capture_output=True, timeout=30, cwd=self.root)
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
        for name in ("runner.py", "live_preview.py", "live-preview.ps1", "observe.ps1"):
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
        for name in ("delivery/live_preview.py", "delivery/live-preview.ps1", "delivery/observe.ps1",
                     "tests/fixtures/screenshots.ps1", "tests/fixtures/terminal.ps1"):
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


BASE = "c" * 40


class Observe(Fixture):
    """The unattended check: the candidate's reader beside main's, judged by observe.ps1."""

    def setUp(self):
        super().setUp()
        self.compiled()
        self.pr["base"] = dict(ref="main")
        self.compares = []
        fetch = self.gh.api.side_effect
        def api(endpoint):
            if endpoint.startswith("compare/"):
                self.compares.append(endpoint)
                return dict(merge_base_commit=dict(sha=BASE))
            return fetch(endpoint)
        self.gh.api.side_effect = api
        self.release(BASE)
        self.scenario = self.root / "claim.json"
        d.write(self.scenario, dict(claim="fictional claim", change="none", reason="fictional"))
        self.exit = 0

    def release(self, sha):
        (self.root / "releases" / sha).mkdir(parents=True)
        d.write(self.root / "releases" / sha / "delivery-manifest.json", dict(sha=sha))
        d.write(self.root / "receipts" / (sha + ".json"), dict(sha=sha))

    def run_child(self, argv, **kwargs):
        if argv[0] == "gh":
            return super().run_child(argv, **kwargs)
        self.children.append((argv, kwargs))
        value = lambda name: argv[argv.index(name) + 1]
        self.assertEqual(Path(value("-File")).name, "observe.ps1")
        self.assertTrue(Path(value("-Candidate"), "src/common.ps1").is_file())
        self.readers.append(Path(value("-Candidate"), READER).read_bytes())
        self.assertTrue(Path(value("-Scenario")).is_file())
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)  # Nobody is at a keyboard.
        for key in ("HOTPL8_INSTALL_DIRECTORY", "HOTPL8_STATE_DIRECTORY", "GH_TOKEN"):
            self.assertNotIn(key, kwargs["env"])
        return subprocess.CompletedProcess(argv, self.exit)

    def observed(self, sha=SHA, **options):
        with mock.patch.object(live.subprocess, "run", side_effect=self.run_child):
            return live.observe(self.root, 34, sha, self.scenario, gh=self.gh, **options)

    def test_runs_the_unattended_harness_against_the_merge_base_without_activation(self):
        with mock.patch.dict(os.environ, HOTPL8_INSTALL_DIRECTORY="production", GH_TOKEN="fictional-token"):
            self.assertEqual(self.observed(), live.PASS)
        argv = self.children[0][0]
        self.assertEqual(argv[argv.index("-Baseline") + 1], str(self.root / "releases" / BASE))
        self.assertEqual(argv[argv.index("-BaselineSha") + 1], BASE)
        self.assertEqual(argv[argv.index("-CandidateSha") + 1], SHA)
        self.assertEqual(self.compares, ["compare/main..." + SHA])
        self.assertEqual(self.readers, [b"fictional reader"])
        target = self.root / "previews/pr-34" / SHA
        report = Path(argv[argv.index("-Report") + 1])
        self.assertEqual(report.parent, target)
        self.assertTrue(report.name.startswith("observe-2"))
        receipt = d.read(target / "observed.json")
        self.assertEqual((receipt["verdict"], receipt["baseline"]), ("PASS", BASE))
        # The downloaded session is gone; only the report remains.
        self.assertEqual(sorted(p.name for p in target.iterdir()), sorted([report.name, "observed.json"]))
        self.assertEqual((self.root / "current.json").read_bytes(), self.before)

    def test_fail_is_a_verdict_and_any_other_exit_is_an_error(self):
        self.exit = live.FAIL
        self.assertEqual(self.observed(), live.FAIL)
        self.assertEqual(d.read(self.root / "previews/pr-34" / SHA / "observed.json")["verdict"], "FAIL")
        for code in (1, 75, -1):
            self.exit = code
            with self.subTest(code=code), self.assertRaises(d.DeliveryError) as raised:
                self.observed()
            self.assertNotIsInstance(raised.exception, d.Deferred)

    def test_explicit_baseline_and_report_are_used_as_given(self):
        self.release(OTHER)
        report = self.root / "chosen"
        self.assertEqual(self.observed(baseline=OTHER, report=report), live.PASS)
        argv = self.children[0][0]
        self.assertEqual(argv[argv.index("-Baseline") + 1], str(self.root / "releases" / OTHER))
        self.assertEqual(argv[argv.index("-Report") + 1], str(report.resolve()))
        self.assertEqual(self.compares, [])

    def test_unreleased_baseline_is_fetched_once_through_the_release_checks(self):
        shutil.rmtree(self.root / "releases" / BASE)
        self.gh.candidate.return_value = dict(sha=BASE, assetId=5, digest="d" * 64, runId=6, releaseId=7)
        self.config.update(attestation=True, workflow="ci.yml")
        d.write(self.root / "delivery.json", self.config)
        def unpack(archive, destination, config, sha):
            self.assertEqual(sha, BASE)
            (destination / "bin").mkdir(parents=True)
        with mock.patch.object(live, "unpack", side_effect=unpack) as unpacked:
            self.assertEqual(self.observed(), live.PASS)
            self.assertEqual(self.observed(), live.PASS)
        cached = self.root / "previews" / ("baseline-" + BASE)
        self.assertEqual([c[0][c[0].index("-Baseline") + 1] for c in self.children], [str(cached)] * 2)
        self.assertEqual(unpacked.call_count, 1)
        self.gh.download.assert_called_once()
        self.gh.attest.assert_called_once()
        self.assertEqual(self.gh.attest.call_args[0][1:], (BASE, "ci.yml"))
        self.assertFalse(list((self.root / "previews").glob(".baseline-*")))

    def test_unavailable_baseline_is_deferred_before_candidate_code_is_fetched(self):
        shutil.rmtree(self.root / "releases" / BASE)
        self.gh.candidate.side_effect = d.Deferred("Main has no available passing release")
        with mock.patch.object(live.subprocess, "run") as process:
            with self.assertRaises(d.Deferred): self.observed()
            process.assert_not_called()
        self.assertFalse((self.root / "previews/pr-34" / SHA / "observed.json").exists())

    def test_refusals_before_any_download_or_execution(self):
        for plan in ("not json", "[]", json.dumps(dict(change="none")), json.dumps(dict(claim=" "))):
            self.scenario.write_text(plan)
            with self.subTest(plan=plan), mock.patch.object(live.subprocess, "run") as process:
                with self.assertRaises(d.DeliveryError): self.observed()
                process.assert_not_called()
        d.write(self.scenario, dict(claim="fictional"))
        with mock.patch.object(live.subprocess, "run") as process:
            with self.assertRaises(d.DeliveryError): self.observed(baseline="main")
            with self.assertRaises(d.Deferred): self.observed(sha=OTHER)
            self.pr["head"]["repo"]["full_name"] = "outsider/fork"
            with self.assertRaises(d.DeliveryError): self.observed()
            process.assert_not_called()
        self.pr["head"]["repo"]["full_name"] = "sample/hotpl8"
        # The head moves after the downloads: the candidate's reader never runs.
        self.heads = [self.pr, dict(head=dict(sha=OTHER))]
        with self.assertRaises(d.Deferred): self.observed()
        self.assertEqual(self.children, [])


class ObserveEntry(unittest.TestCase):
    """runner.py's preview verb: argument shape and the exit codes an agent acts on."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        stub = self.root / "release"
        stub.mkdir()
        (stub / "live_preview.py").write_text(
            "import json\nfrom runner import Deferred\nBLOCKED = 11\n"
            "def observe(root, number, sha, scenario, report, baseline):\n"
            "    print(json.dumps([number, sha, scenario, report, baseline]))\n"
            "    if scenario == 'later': raise Deferred('not yet')\n"
            "    return 10\n")
        self.runner = str(stub / "runner.py")

    def main(self, *arguments):
        import contextlib
        output = io.StringIO()
        argv = ["runner.py", "--install", str(self.root / "install"), "preview", "34", "--trust-revision", SHA]
        with mock.patch.object(d, "__file__", self.runner), mock.patch.object(sys, "argv", argv + list(arguments)), \
                contextlib.redirect_stdout(output):
            code = d.main()
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_verdicts_pass_through_and_not_ready_is_blocked(self):
        self.assertEqual(self.main("--observe", "plan.json"), (10, [[34, SHA, "plan.json", None, None]]))
        self.assertEqual(self.main("--observe", "plan.json", "--baseline", OTHER, "--report", "out")[1],
                         [[34, SHA, "plan.json", "out", OTHER]])
        code, lines = self.main("--observe", "later")
        self.assertEqual(code, 11)
        self.assertEqual(lines[-1], dict(state="blocked", reason="not yet"))

    def test_malformed_options_are_refused(self):
        for options in (["--observe"], ["--baseline", OTHER], ["--observe", "a", "--observe", "b"],
                        ["--observe", "a", "--live", "x"], ["--report", "r", "--observe", "a"]):
            with self.subTest(options=options):
                code, lines = self.main(*options)
                self.assertEqual(code, 1)
                self.assertEqual(lines[-1]["state"], "error")


if __name__ == "__main__":
    unittest.main()
