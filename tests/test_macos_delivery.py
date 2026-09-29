"""Native lifecycle, scheduler and containment tests. Fictional local state only."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'delivery'))
import runner as d
import macos as m
from package import package


def module(name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'delivery' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


guardian = module('macos-job')
t3 = module('macos-t3')
A, B = 'a' * 40, 'b' * 40


class Scheduler:
    def __init__(self, directory):
        self.directory = directory
        self.jobs = {}
        self.disabled = set()

    def loaded(self, label):
        return label in self.jobs

    def enabled(self, label):
        return label not in self.disabled

    def install(self, path, spec):
        self.jobs[spec['Label']] = spec

    def remove(self, label):
        self.jobs.pop(label, None)


class EnrollmentContract(unittest.TestCase):
    """Portable interface checks; native lifecycle qualification stays separate."""

    def test_runtime_binding_preserves_default_and_explicit_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = dict(powershell=sys.executable, macos=dict(runtimes=dict(codex=sys.executable)))
            for arguments, expected in [(['hotpl8'], 'watch'), (['hotpl8', 'status'], 'status')]:
                with patch.object(m, 'native_only'), patch.object(m, 'owned_config', return_value=({}, config)), \
                        patch.object(m, 'selected', return_value=root), patch.object(m.subprocess, 'call', return_value=0) as call:
                    self.assertEqual(m.dispatch(root, 'run', arguments), 0)
                    argv = call.call_args.args[0]
                    self.assertEqual(argv[argv.index('-Entry') + 1:],
                                     ['hotpl8', expected, '-CodexExecutable', sys.executable])

    def test_cli_default_and_explicit_collector_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            argv = ['macos.py', 'setup', '--install', temporary, '--state', temporary]
            for flags, scheduled, observe in [([], False, None),
                                              (['--schedule-collector', '--observe-only'], True, True)]:
                with patch.object(sys, 'argv', argv + flags), patch.object(m, 'native_only'), \
                        patch.object(m, 'setup', return_value={}) as setup:
                    m.main()
                    self.assertEqual(setup.call_args.kwargs['register_jobs'], scheduled)
                    self.assertEqual(setup.call_args.kwargs['observe_only'], observe)

    def test_no_updater_definition_and_external_schedule_is_not_a_collector(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            owned = dict(id='abcdef123456')
            config = dict(python=sys.executable, macos=dict(path='fixture'))
            with self.assertRaises(d.DeliveryError):
                m.job_plist(root, 'updater', owned, config)
            backend = Scheduler(root)
            external = dict(Label='example.external', ProgramArguments=[sys.executable,
                            str(root / 'hotpl8/delivery.py'), 'job', 'updater'])
            (root / 'external.plist').write_bytes(plistlib.dumps(external))
            m.collector_conflicts(backend, root / 'state', owned['id'])
            legacy = dict(external, Label='io.hotpl8.' + owned['id'] + '.updater')
            (root / 'legacy.plist').write_bytes(plistlib.dumps(legacy))
            with self.assertRaises(d.DeliveryError):
                m.collector_conflicts(backend, root / 'state', owned['id'])

    def test_adoption_without_schedule_refuses_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'untouched'
            with patch.object(m, 'native_only'), self.assertRaises(d.DeliveryError):
                m.setup(root, root, sys.executable, sys.executable, adopt='fixture')
            self.assertFalse(root.exists())


@unittest.skipUnless(sys.platform == 'darwin', 'Native Mac qualification required')
class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hotpl8-native-')
        self.base = Path(self.tmp.name).resolve()
        self.root, self.state = self.base / 'managed install', self.base / 'state'
        self.root.mkdir()
        self.state.mkdir()
        self.pwsh = shutil.which('pwsh')
        self.gh = shutil.which('gh')
        self.backend = Scheduler(self.base / 'LaunchAgents')
        self.backend.directory.mkdir()
        self.config = dict(protocol=1, product='hotpl8', repository='Mmore35/hotpl8', platform='macos',
                           channel='main', workflow='ci.yml', asset='hotpl8-macos-main.zip', attestation=True,
                           stateCompatibility=1, stateDirectory=str(self.state), python=sys.executable,
                           powershell=self.pwsh, gh=self.gh, adapter='delivery/macos.py', drainSeconds=0,
                           writerLocks=[str(self.state / 'tick.lock')], macos=dict(path=os.environ['PATH'], jobsEnrolled=False))
        d.write(self.root / 'installation.json', dict(product='hotpl8', id='abcdef123456', stateDirectory=str(self.state)))
        d.write(self.root / 'delivery.json', self.config)
        shutil.copyfile(REPO / 'examples/claude-only.json', self.state / 'policy.json')
        (self.state / 'native-account-sentinel').write_bytes(b'preserve account')
        self.archive = self.base / 'candidate.zip'
        self.source = self.base / 'source.zip'
        with zipfile.ZipFile(self.source, 'w') as archive:
            for name in d.read(REPO / 'release-files.json')['files']:
                archive.write(REPO / name, name)
        self.candidate(A)

    def tearDown(self):
        self.tmp.cleanup()

    def candidate(self, sha):
        package(self.source, self.archive, 'hotpl8', 'Mmore35/hotpl8', sha, 'macos')
        self.sha = sha
        self.attested = 0

    def main(self):
        return self.sha

    def candidate_metadata(self, sha, config):
        return dict(sha=sha, digest=d.digest(self.archive))

    def download(self, candidate, path):
        shutil.copyfile(self.archive, path)

    def attest(self, *args):
        self.attested += 1

    def is_forward(self, *args):
        return True

    def update(self, fail_health=False):
        class GitHub:
            main, download, attest, is_forward = self.main, self.download, self.attest, self.is_forward
            candidate = self.candidate_metadata
        def adapter(config, release, operation, root):
            if fail_health and operation == 'health' and d.read(release / 'build-info.json')['sha'] == B:
                raise d.DeliveryError('fixture readiness failure')
            return m.adapter(root, release, operation, self.backend)
        return d.update(self.root, GitHub(), adapter)

    def test_first_update_no_change_and_new_release_preserve_state(self):
        policy = (self.state / 'policy.json').read_bytes()
        self.assertEqual(self.update()['state'], 'current')
        self.assertEqual(self.attested, 1)
        m.register(self.root, self.backend)
        m.register(self.root, self.backend)
        self.assertEqual(len(self.backend.jobs), 1)
        self.assertEqual(self.update()['state'], 'current')
        self.assertEqual(self.attested, 1)
        self.candidate(B)
        self.assertEqual(self.update()['state'], 'current')
        self.assertEqual(d.read(self.root / 'previous.json')['sha'], A)
        inventory = m.components(self.root, self.backend)
        self.assertEqual(inventory[0]['nextLaunchSha'], B)
        self.assertEqual(inventory[1]['state'], 'unmanaged')
        self.assertIsNone(inventory[1]['nextLaunchSha'])
        self.assertEqual(inventory[-1]['state'], 'unmanaged')
        self.assertIsNone(inventory[-1]['nextLaunchSha'])
        self.assertEqual((self.state / 'policy.json').read_bytes(), policy)
        self.assertEqual((self.state / 'native-account-sentinel').read_bytes(), b'preserve account')

    def test_setup_entrypoint_first_and_repeated_without_native_registration(self):
        (self.root / 'delivery.json').unlink()
        (self.root / 'installation.json').unlink()
        class GitHub:
            main, download, attest, is_forward = self.main, self.download, self.attest, self.is_forward
            candidate = self.candidate_metadata
        for _ in range(2):
            result = m.setup(self.root, self.state, self.pwsh, self.gh,
                             backend=self.backend, github=GitHub())
            self.assertEqual(result['state'], 'current')
        self.assertFalse(self.backend.jobs)
        self.assertFalse((self.root / 'macos-jobs.json').exists())
        self.assertFalse(d.read(self.root / 'delivery.json')['macos']['collectorObserveOnly'])
        command = [sys.executable, str(self.root / 'delivery.py'), 'status']
        result = subprocess.run(command, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['installed']['sha'], A)
        self.assertTrue(os.access(self.root / 'hotpl8', os.X_OK))

    def test_observation_override_is_explicit_and_survives_repeat_setup(self):
        (self.root / 'delivery.json').unlink()
        (self.root / 'installation.json').unlink()
        class GitHub:
            main, download, attest, is_forward = self.main, self.download, self.attest, self.is_forward
            candidate = self.candidate_metadata
        for override in (True, None):
            result = m.setup(self.root, self.state, self.pwsh, self.gh, observe_only=override,
                             backend=self.backend, github=GitHub())
            self.assertEqual(result['state'], 'current')
            self.assertTrue(d.read(self.root / 'delivery.json')['macos']['collectorObserveOnly'])
        with self.assertRaises(d.DeliveryError):
            m.setup(self.root, self.state, self.pwsh, self.gh, observe_only=False,
                    backend=self.backend, github=GitHub())
        self.assertTrue(d.read(self.root / 'delivery.json')['macos']['collectorObserveOnly'])
        self.assertFalse(self.backend.jobs)

    def test_readiness_failure_rolls_back_without_reverting_state(self):
        self.assertEqual(self.update()['state'], 'current')
        self.candidate(B)
        self.assertEqual(self.update(fail_health=True)['state'], 'error')
        self.assertEqual(d.read(self.root / 'current.json')['sha'], A)
        self.assertEqual(d.read(self.root / 'installation.json')['sourceSha'], A)
        self.assertFalse((self.root / 'transaction.json').exists())

    def test_registration_prevalidates_all_and_preserves_disabled_jobs(self):
        owned, config = m.owned_config(self.root)
        spec = m.job_plist(self.root, 'collector', owned, config)
        path = self.backend.directory / (spec['Label'] + '.plist')
        path.write_bytes(b'foreign')
        with self.assertRaises(d.DeliveryError):
            m.register(self.root, self.backend)
        self.assertFalse(self.backend.jobs)
        path.unlink()
        m.register(self.root, self.backend)
        self.backend.disabled.add(spec['Label'])
        self.backend.remove(spec['Label'])
        self.assertEqual(m.components(self.root, self.backend)[0]['state'], 'disabled')
        m.uninstall(self.root, self.backend)
        m.uninstall(self.root, self.backend)
        self.assertFalse(self.backend.jobs)
        self.assertTrue((self.state / 'native-account-sentinel').exists())

    def test_legacy_adoption_checks_digest_and_retries_without_duplicates(self):
        legacy = dict(Label='io.hotpl8.legacy', ProgramArguments=['/bin/echo', 'hotpl8', '-ObserveOnly'], StartInterval=60)
        path = self.backend.directory / (legacy['Label'] + '.plist')
        path.write_bytes(plistlib.dumps(legacy))
        self.backend.install(path, legacy)
        with self.assertRaises(d.DeliveryError):
            m.collector_conflicts(self.backend, self.state, 'abcdef123456')
        with self.assertRaises(d.DeliveryError):
            m.adopt_collector(self.root, self.backend, path, 'wrong')
        self.assertTrue(self.backend.loaded(legacy['Label']))
        original = path.read_bytes()
        with self.assertRaises(d.DeliveryError):
            m.adopt_collector(self.root, self.backend, path, d.digest(path))
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((self.root / 'collector-migration.json').exists())
        self.config['macos']['collectorObserveOnly'] = True
        d.write(self.root / 'delivery.json', self.config)
        m.adopt_collector(self.root, self.backend, path, d.digest(path))
        m.adopt_collector(self.root, self.backend, path, None)
        journal = d.read(self.root / 'collector-migration.json')
        journal['label'] = 'unrelated.job'
        d.write(self.root / 'collector-migration.json', journal)
        with self.assertRaises(d.DeliveryError):
            m.adopt_collector(self.root, self.backend, path, None)
        m.register(self.root, self.backend)
        self.assertEqual(len(self.backend.jobs), 1)
        self.assertEqual((self.root / 'legacy-collector.plist').read_bytes(), original)

    def test_missing_owned_job_is_error_and_not_silently_recreated_by_update(self):
        self.assertEqual(self.update()['state'], 'current')
        m.register(self.root, self.backend)
        path = next(self.backend.directory.glob('*collector.plist'))
        path.unlink()
        self.assertEqual(m.components(self.root, self.backend)[0]['state'], 'error')
        self.assertEqual(self.update()['state'], 'error')
        self.assertFalse(path.exists())

    def test_installed_bootstrap_job_dispatch_and_overlap(self):
        # Build a checksummed fixture collector: native scheduling never reads
        # credentials or invokes a real provider during qualification.
        with zipfile.ZipFile(self.source) as source:
            files = {name: source.read(name) for name in source.namelist()}
        self.config['macos']['runtimes'] = dict(codex=sys.executable, cswap=sys.executable)
        d.write(self.root / 'delivery.json', self.config)
        files['tick.ps1'] = b'''param([switch]$Scheduled,[switch]$ObserveOnly,[string]$CodexExecutable,[string]$CswapExecutable)
if(-not $Scheduled){exit 9}
if(-not $CodexExecutable -or $CswapExecutable -ne $CodexExecutable){exit 10}
@{startedAt=[datetimeoffset]::UtcNow.ToString('o');completedAt=[datetimeoffset]::UtcNow.ToString('o');status='ok';runningSha=('a'*40);observeOnly=[bool]$ObserveOnly}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:HOTPL8_STATE_DIRECTORY 'collector.json')
'''
        with zipfile.ZipFile(self.source, 'w') as source:
            for name, body in files.items():
                source.writestr(name, body)
        self.candidate(A)
        self.assertEqual(self.update()['state'], 'current')
        command = [sys.executable, str(self.root / 'delivery.py'), 'job', 'collector']
        with d.lock(self.root / 'collector.job.lock'):
            self.assertEqual(subprocess.run(command, timeout=15).returncode, 0)
        self.assertFalse((self.root / 'job-runs/collector.json').exists())
        self.assertEqual(subprocess.run(command, timeout=20).returncode, 0)
        record = d.read(self.root / 'job-runs/collector.json')
        self.assertEqual(record['state'], 'complete')
        self.assertEqual(record['completion'], 'ok')
        self.assertEqual(record['outcome']['runningSha'], A)
        self.assertFalse(d.read(self.state / 'collector.json')['observeOnly'])
        config = d.read(self.root / 'delivery.json')
        config['macos']['collectorObserveOnly'] = True
        d.write(self.root / 'delivery.json', config)
        self.assertEqual(subprocess.run(command, timeout=20).returncode, 0)
        self.assertTrue(d.read(self.state / 'collector.json')['observeOnly'])
        unfinished = dict(record, state='running', runId='c' * 32)
        d.write(self.root / 'job-runs/collector.json', unfinished)
        self.assertEqual(subprocess.run(command, timeout=20).returncode, 0)
        self.assertEqual(d.read(self.root / 'job-runs' / ('unfinished-' + 'c' * 32 + '.json')), unfinished)
        invalid = dict(unfinished, runId='../../outside')
        d.write(self.root / 'job-runs/collector.json', invalid)
        self.assertNotEqual(subprocess.run(command, timeout=20).returncode, 0)
        self.assertEqual(d.read(self.root / 'job-runs/collector.json'), invalid)

    def test_default_dashboard_with_native_binding_does_not_hold_update_lease(self):
        with zipfile.ZipFile(self.source) as source:
            files = {name: source.read(name) for name in source.namelist()}
        self.config['macos']['runtimes'] = dict(codex=sys.executable)
        d.write(self.root / 'delivery.json', self.config)
        files['hotpl8.ps1'] = b'''param([string]$Command='watch',[string]$CodexExecutable)
$ErrorActionPreference='Stop'
if($Command -ne 'watch' -or -not $CodexExecutable){exit 9}
$lease=[IO.File]::Open((Join-Path $env:HOTPL8_INSTALL_DIRECTORY 'runtime.lock'),'OpenOrCreate','ReadWrite','None')
$lease.Dispose()
@{command=$Command;leaseFree=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:HOTPL8_STATE_DIRECTORY 'display.json')
'''
        with zipfile.ZipFile(self.source, 'w') as source:
            for name, body in files.items():
                source.writestr(name, body)
        self.candidate(A)
        self.assertEqual(self.update()['state'], 'current')
        result = subprocess.run([str(self.root / 'hotpl8')], capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(d.read(self.state / 'display.json'), dict(command='watch', leaseFree=True))

    def test_t3_modified_binding_refuses_update_and_missing_receipt_stays_visible(self):
        self.assertEqual(self.update()['state'], 'current')
        settings = self.base / 'settings.json'
        shared = self.base / 'shared'
        shared.mkdir()
        d.write(settings, {})
        with patch.object(t3, 'closed'):
            t3.enroll(self.root, settings, shutil.which('node'), '/usr/bin/true', shared, True)
        document = d.read(settings)
        document['providerInstances']['codex']['config']['homePath'] = str(self.base)
        d.write(settings, document)
        self.candidate(B)
        self.assertEqual(self.update()['state'], 'error')
        self.assertEqual(d.read(self.root / 'current.json')['sha'], A)
        (self.root / 'integrations/t3-codex/receipt.json').unlink()
        with self.assertRaises(d.DeliveryError):
            t3.components(self.root)

    def test_t3_host_closed_guard_includes_standalone_runtime(self):
        settings = self.base / 'settings.json'
        d.write(settings, {})
        for process in (b' 42 /Applications/T3 Code.app/Contents/MacOS/T3 Code\n',
                        b' 42 /usr/bin/node /workspace/apps/server/dist/bin.mjs\n'):
            with patch.object(t3, 'run', return_value=process), self.assertRaises(d.DeliveryError):
                t3.closed(settings)
        d.write(self.base / 'server-runtime.json', dict(pid=42))
        with patch.object(t3, 'run', return_value=b' 42 /usr/bin/node /custom/server.mjs\n'), self.assertRaises(d.DeliveryError):
            t3.closed(settings)
        with patch.object(t3, 'run', return_value=b' 51 /usr/bin/unrelated\n'):
            t3.closed(settings)

    def test_t3_staging_activation_upgrade_and_removal_preserve_identity(self):
        self.assertEqual(self.update()['state'], 'current')
        settings = self.base / 'settings.json'
        shared = self.base / 'shared home'
        shared.mkdir()
        d.write(settings, dict(providers=dict(cursor={}), theme='dark'))
        settings.chmod(0o600)
        node = shutil.which('node')
        # The native Codex binding is a harmless executable: probes must not invoke it.
        native = self.base / 'native-codex'
        native.write_text('#!/bin/sh\necho forbidden > ' + str(self.base / 'provider-invoked') + '\nexit 99\n')
        native.chmod(0o700)
        self.assertEqual(t3.enroll(self.root, settings, node, str(native), shared)['state'], 'staged')
        self.assertNotIn('providerInstances', d.read(settings))
        with patch.object(t3, 'closed'):
            self.assertEqual(t3.enroll(self.root, settings, node, str(native), shared, True)['state'], 'active')
        before = settings.read_bytes()
        self.candidate(B)
        self.assertEqual(self.update()['state'], 'current')
        self.assertEqual(settings.read_bytes(), before)
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
        self.assertEqual(t3.components(self.root)[0]['nextLaunchSha'], B)
        self.assertFalse((self.base / 'provider-invoked').exists())
        with patch.object(t3, 'closed'):
            t3.remove(self.root)
        self.assertEqual(d.read(settings)['theme'], 'dark')
        self.assertNotIn('codex', d.read(settings)['providerInstances'])
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)
        self.assertEqual(t3.components(self.root)[0]['state'], 'unmanaged')

    def test_real_launchd_wake_and_removal(self):
        # Isolated native registration, not the owner's collector or updater.
        backend = m.Launchd(self.backend.directory)
        label = 'io.hotpl8.test.' + self.base.name
        path = backend.directory / (label + '.plist')
        receipt = self.base / 'launchd-proof'
        spec = dict(Label=label, ProgramArguments=[sys.executable, '-c',
                    'from pathlib import Path; Path(' + repr(str(receipt)) + ').write_text("completed")'], RunAtLoad=True)
        path.write_bytes(plistlib.dumps(spec))
        try:
            backend.install(path, spec)
            until = time.monotonic() + 15
            while not receipt.exists() and time.monotonic() < until:
                time.sleep(.1)
            self.assertEqual(receipt.read_text(), 'completed')
            self.assertTrue(backend.loaded(label))
        finally:
            backend.remove(label)
            path.unlink(missing_ok=True)
        self.assertFalse(backend.loaded(label))


@unittest.skipUnless(sys.platform == 'darwin', 'Native Mac process containment')
class Guardian(unittest.TestCase):
    def test_interactive_dashboard_renders_and_quits_on_native_pty(self):
        for mode, terminal, no_color in [('watch', 'iTerm.app', ''), ('nyan', 'Apple_Terminal', ''),
                                         ('nyan', 'Apple_Terminal', '1')]:
            with self.subTest(mode=mode, terminal=terminal, no_color=no_color):
                self.assert_interactive_dashboard_colors(mode, terminal, no_color)

    def assert_interactive_dashboard_colors(self, mode, terminal, no_color):
        import fcntl
        import pty
        import select
        import struct
        import termios
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            d.write(state / 'policy.json', dict(schemaVersion=2, mode='monitor', prefer=[], codex=dict(slots=[])))
            # forkpty supplies the controlling terminal used by .NET ReadKey.
            # Merely redirecting three descriptors to a PTY can render output
            # while /dev/tty still points at the CI runner's unrelated terminal.
            pid, master = pty.fork()
            if pid == 0:
                os.execve(shutil.which('pwsh'), [shutil.which('pwsh'), '-NoProfile', '-File', str(REPO / 'hotpl8.ps1'),
                          mode, '-StateDirectory', str(state), '-ReducedMotion'],
                          dict(os.environ, TERM='xterm-256color', TERM_PROGRAM=terminal, NO_COLOR=no_color))
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 100, 0, 0))
            output = b''
            status = None
            sent = False
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    waited, value = os.waitpid(pid, os.WNOHANG)
                    if waited:
                        status = value
                        break
                    if select.select([master], [], [], .1)[0]:
                        try:
                            output += os.read(master, 65536)
                        except OSError:
                            pass
                    if b'hotpl8 enroll' in output and not sent:
                        os.write(master, b'q')
                        sent = True
                self.assertIn(b'hotpl8 enroll', output)
                self.assertIsNotNone(status, output.decode('utf-8', 'replace'))
                self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode('utf-8', 'replace'))
                if no_color:
                    self.assertNotRegex(output, rb'\x1b\[(?:38|48);')
                    return
                self.assertIn(b'\x1b[?1049h', output)
                # Include the initial clear, asynchronous frame and exit sequence.
                if terminal == 'Apple_Terminal':
                    self.assertIn(b'\x1b[48;5;234m', output)
                    self.assertNotRegex(output, rb'\x1b\[(?:38|48);2;')
                else:
                    self.assertIn(b'\x1b[48;2;18;23;35m', output)
                    self.assertNotRegex(output, rb'\x1b\[(?:38|48);5;')
            finally:
                if status is None:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                os.close(master)

    def test_success_failure_timeout_and_output_limit(self):
        for code, expected in [('pass', 'complete'), ('raise SystemExit(7)', 'failed'),
                               ('import time; time.sleep(60)', 'timeout'),
                               ('import os\nwhile True: os.write(1,b"x"*65536)', 'output-limit')]:
            with self.subTest(expected=expected):
                result = guardian.execute([sys.executable, '-c', code], .5, 100000)
                self.assertEqual(result['state'], expected)

    def test_normal_exit_kills_lingering_descendant(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'child'
            code = ('import subprocess,sys; from pathlib import Path; '
                    'p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); '
                    'Path(' + repr(str(path)) + ').write_text(str(p.pid))')
            self.assertEqual(guardian.execute([sys.executable, '-c', code], 3)['state'], 'complete')
            pid = int(path.read_text())
            self.assert_dead(pid)

    def assert_dead(self, pid):
        until = time.monotonic() + 5
        while time.monotonic() < until:
            result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True)
            if result.returncode or result.stdout.strip().startswith(b'Z'):
                return
            time.sleep(.05)
        self.fail('Owned descendant survived guardian cleanup')

    def test_abrupt_parent_death_cleans_descendants(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'child'
            code = 'import os,time; from pathlib import Path; Path(' + repr(str(path)) + ').write_text(str(os.getpid())); time.sleep(60)'
            parent_code = ('import runpy; m=runpy.run_path(' + repr(str(REPO / 'delivery/macos-job.py'))
                           + '); m["execute"](' + repr([sys.executable, '-c', code]) + ',60)')
            parent = subprocess.Popen([sys.executable, '-c', parent_code], stdin=subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                until = time.monotonic() + 5
                while not path.exists() and time.monotonic() < until:
                    time.sleep(.05)
                pid = int(path.read_text())
                parent.kill()
                parent.wait(timeout=5)
                self.assert_dead(pid)
            finally:
                if parent.poll() is None:
                    parent.kill()
                parent.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
