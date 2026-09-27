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
        self.assertEqual(len(self.backend.jobs), 2)
        self.assertEqual(self.update()['state'], 'current')
        self.assertEqual(self.attested, 1)
        self.candidate(B)
        self.assertEqual(self.update()['state'], 'current')
        self.assertEqual(d.read(self.root / 'previous.json')['sha'], A)
        self.assertEqual({c['nextLaunchSha'] for c in m.components(self.root, self.backend)}, {B})
        self.assertEqual((self.state / 'policy.json').read_bytes(), policy)
        self.assertEqual((self.state / 'native-account-sentinel').read_bytes(), b'preserve account')

    def test_readiness_failure_rolls_back_without_reverting_state(self):
        self.assertEqual(self.update()['state'], 'current')
        self.candidate(B)
        self.assertEqual(self.update(fail_health=True)['state'], 'error')
        self.assertEqual(d.read(self.root / 'current.json')['sha'], A)
        self.assertEqual(d.read(self.root / 'installation.json')['sourceSha'], A)
        self.assertFalse((self.root / 'transaction.json').exists())

    def test_registration_prevalidates_all_and_preserves_disabled_jobs(self):
        owned, config = m.owned_config(self.root)
        spec = m.job_plist(self.root, 'updater', owned, config)
        path = self.backend.directory / (spec['Label'] + '.plist')
        path.write_bytes(b'foreign')
        with self.assertRaises(d.DeliveryError):
            m.register(self.root, self.backend)
        self.assertFalse(self.backend.jobs)
        path.unlink()
        m.register(self.root, self.backend)
        self.backend.disabled.add(spec['Label'])
        self.backend.remove(spec['Label'])
        self.assertEqual(m.components(self.root, self.backend)[1]['state'], 'disabled')
        m.uninstall(self.root, self.backend)
        m.uninstall(self.root, self.backend)
        self.assertFalse(self.backend.jobs)
        self.assertTrue((self.state / 'native-account-sentinel').exists())

    def test_legacy_adoption_checks_digest_and_retries_without_duplicates(self):
        legacy = dict(Label='io.hotpl8.legacy', ProgramArguments=['/bin/echo', 'hotpl8'], StartInterval=60)
        path = self.backend.directory / (legacy['Label'] + '.plist')
        path.write_bytes(plistlib.dumps(legacy))
        self.backend.install(path, legacy)
        with self.assertRaises(d.DeliveryError):
            m.collector_conflicts(self.backend, self.state, 'abcdef123456')
        with self.assertRaises(d.DeliveryError):
            m.adopt_collector(self.root, self.backend, path, 'wrong')
        self.assertTrue(self.backend.loaded(legacy['Label']))
        original = path.read_bytes()
        m.adopt_collector(self.root, self.backend, path, d.digest(path))
        m.adopt_collector(self.root, self.backend, path, None)
        m.register(self.root, self.backend)
        self.assertEqual(len(self.backend.jobs), 2)
        self.assertEqual((self.root / 'legacy-collector.plist').read_bytes(), original)

    def test_missing_owned_job_is_error_and_not_silently_recreated_by_update(self):
        self.assertEqual(self.update()['state'], 'current')
        m.register(self.root, self.backend)
        path = next(self.backend.directory.glob('*collector.plist'))
        path.unlink()
        self.assertEqual(m.components(self.root, self.backend)[0]['state'], 'error')
        self.assertEqual(self.update()['state'], 'error')
        self.assertFalse(path.exists())

    def test_t3_staging_activation_upgrade_and_removal_preserve_identity(self):
        self.assertEqual(self.update()['state'], 'current')
        settings = self.base / 'settings.json'
        shared = self.base / 'shared home'
        shared.mkdir()
        d.write(settings, dict(providers=dict(cursor={}), theme='dark'))
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
        self.assertEqual(t3.components(self.root)[0]['nextLaunchSha'], B)
        self.assertFalse((self.base / 'provider-invoked').exists())
        with patch.object(t3, 'closed'):
            t3.remove(self.root)
        self.assertEqual(d.read(settings)['theme'], 'dark')
        self.assertNotIn('codex', d.read(settings)['providerInstances'])
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
