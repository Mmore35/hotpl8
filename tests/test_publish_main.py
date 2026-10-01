"""Offline release transactions; no GitHub calls or credentials."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publish_main", Path(__file__).resolve().parents[1] / "scripts/publish-main.py")
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
SHA = "a" * 40


class FakeGitHub:
    def __init__(self):
        self.release = None
        self.uploads = []
        self.published = 0
        self.fail_upload = None

    def find(self, tag):
        return copy.deepcopy(self.release)

    def create(self, tag, sha):
        self.release = dict(tag_name=tag, target_commitish=sha, draft=True, prerelease=True, assets=[])

    def upload(self, tag, path):
        if path.name == self.fail_upload:
            raise p.PublicationError("Upload interrupted")
        self.uploads.append(path.name)
        self.release["assets"].append(dict(name=path.name, digest="sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()))

    def publish(self, tag):
        self.published += 1
        self.release["draft"] = False


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.sleep = patch.object(p.time, "sleep").start()
        self.addCleanup(patch.stopall)
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name in p.ASSETS:
            (self.root / name).write_bytes(name.encode())
        self.github = FakeGitHub()

    def tearDown(self):
        self.tmp.cleanup()

    def test_complete_publication_and_idempotent_retry(self):
        p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, list(p.ASSETS))
        self.assertEqual(self.github.published, 1)
        p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, list(p.ASSETS))
        self.assertEqual(self.github.published, 1)

    def test_interrupted_second_upload_stays_draft_and_resumes_without_replacement(self):
        self.github.fail_upload = p.ASSETS[1]
        with self.assertRaises(p.PublicationError):
            p.publish(self.github, self.root, SHA)
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(self.github.published, 0)
        self.github.fail_upload = None
        p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, list(p.ASSETS))
        self.assertFalse(self.github.release["draft"])

    def test_missing_local_platform_prevents_release_creation(self):
        (self.root / p.ASSETS[1]).unlink()
        with self.assertRaises(FileNotFoundError):
            p.publish(self.github, self.root, SHA)
        self.assertIsNone(self.github.release)

    def test_changed_draft_asset_is_not_clobbered(self):
        self.github.fail_upload = p.ASSETS[1]
        with self.assertRaises(p.PublicationError):
            p.publish(self.github, self.root, SHA)
        (self.root / p.ASSETS[0]).write_bytes(b"changed")
        with self.assertRaisesRegex(p.PublicationError, "differs"):
            p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, [p.ASSETS[0]])
        self.assertEqual(self.github.published, 0)

    def test_published_incomplete_release_is_not_mutated(self):
        self.github.create("main-" + SHA, SHA)
        self.github.release["draft"] = False
        with self.assertRaisesRegex(p.PublicationError, "incomplete"):
            p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, [])

    def test_wrong_source_release_is_not_used(self):
        self.github.create("main-" + SHA, "b" * 40)
        with self.assertRaisesRegex(p.PublicationError, "identity"):
            p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, [])

    def test_ambiguous_asset_names_are_refused(self):
        p.publish(self.github, self.root, SHA)
        self.github.release["assets"].append(self.github.release["assets"][0])
        with self.assertRaisesRegex(p.PublicationError, "differs"):
            p.publish(self.github, self.root, SHA)

    def test_delayed_create_upload_and_publish_readbacks_do_not_repeat_writes(self):
        class DelayedGitHub(FakeGitHub):
            def __init__(self):
                super().__init__()
                self.stale = []
                self.created = 0

            def find(self, tag):
                return self.stale.pop(0) if self.stale else super().find(tag)

            def create(self, tag, sha):
                self.created += 1
                super().create(tag, sha)
                self.stale = [None, None]

            def upload(self, tag, path):
                self.stale.append(copy.deepcopy(self.release))
                super().upload(tag, path)

            def publish(self, tag):
                self.stale = [copy.deepcopy(self.release)]
                super().publish(tag)

        github = DelayedGitHub()
        p.publish(github, self.root, SHA)
        self.assertEqual(github.created, 1)
        self.assertEqual(github.uploads, list(p.ASSETS))
        self.assertEqual(github.published, 1)
        self.assertEqual(self.sleep.call_count, 5)

    def test_invisible_create_stops_after_bounded_reads_without_uploading(self):
        with patch.object(self.github, "find", return_value=None) as find:
            with self.assertRaisesRegex(p.PublicationError, "not yet visible"):
                p.publish(self.github, self.root, SHA)
        self.assertEqual(find.call_count, 7)
        self.assertEqual(self.sleep.call_count, 5)
        self.assertEqual(self.github.uploads, [])
        self.assertEqual(self.github.published, 0)
        self.assertTrue(self.github.release["draft"])

    def test_wrong_identity_after_create_is_refused_without_retry(self):
        create = self.github.create
        with patch.object(self.github, "create", side_effect=lambda tag, sha: create(tag, "b" * 40)):
            with self.assertRaisesRegex(p.PublicationError, "identity"):
                p.publish(self.github, self.root, SHA)
        self.sleep.assert_not_called()
        self.assertEqual(self.github.uploads, [])

    def test_changed_asset_after_upload_is_refused_without_retry(self):
        upload = self.github.upload

        def corrupted_upload(tag, path):
            upload(tag, path)
            self.github.release["assets"][-1]["digest"] = "sha256:wrong"

        with patch.object(self.github, "upload", side_effect=corrupted_upload):
            with self.assertRaisesRegex(p.PublicationError, "differs"):
                p.publish(self.github, self.root, SHA)
        self.sleep.assert_not_called()
        self.assertEqual(self.github.published, 0)

    def test_incomplete_upload_visibility_never_publishes(self):
        with patch.object(self.github, "upload") as upload:
            with self.assertRaisesRegex(p.PublicationError, "not yet visible"):
                p.publish(self.github, self.root, SHA)
        self.assertEqual(upload.call_count, 2)
        self.assertEqual(self.sleep.call_count, 5)
        self.assertEqual(self.github.published, 0)

    def test_delayed_publication_beyond_budget_can_be_rerun(self):
        with patch.object(self.github, "publish") as publish:
            with self.assertRaisesRegex(p.PublicationError, "not yet visible"):
                p.publish(self.github, self.root, SHA)
        publish.assert_called_once()
        self.assertEqual(self.sleep.call_count, 5)
        p.publish(self.github, self.root, SHA)
        self.assertEqual(self.github.uploads, list(p.ASSETS))
        self.assertFalse(self.github.release["draft"])


if __name__ == "__main__":
    unittest.main()
