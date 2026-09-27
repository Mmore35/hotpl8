"""Offline release transactions; no GitHub calls or credentials."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
