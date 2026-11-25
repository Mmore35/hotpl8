"""Offline tests of scripts/check-plans.py: fixture pages only, no network."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("check_plans", Path(__file__).resolve().parents[1] / "scripts/check-plans.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

SENTENCE = "five times the Pro plan's usage every five hours and every week"
PAGE = "<html><head><style>p{}</style><script>var x='five times';</script></head><body><h1>Max</h1><p>Max gives you <b>five times</b> the Pro plan&rsquo;s\n  usage every five hours and   every week.</p></body></html>"
CATALOGUE = dict(verifiedAt="2026-11-13", profiles={
    "fictional-small": dict(source="https://plans.example.invalid/max", published=SENTENCE),
    "fictional-large": dict(source="https://plans.example.invalid/max", published=SENTENCE),
    "fictional-unconfirmed": dict(source="https://plans.example.invalid/pricing", published=None),
})


def pages(**served):
    asked = []

    def read(url):
        asked.append(url)
        return served.get(url.rsplit("/", 1)[-1])
    read.asked = asked
    return read


def run(catalogue, read, *flags):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / "catalogue.json"
        path.write_text(json.dumps(catalogue), encoding="utf-8")
        out = io.StringIO()
        code = checker.main(["--catalogue", str(path), *flags], read, out)
        return code, out.getvalue()


class CheckPlans(unittest.TestCase):
    def outcomes(self, read):
        return {row["profile"]: row["outcome"] for row in checker.check(CATALOGUE, read)}

    def test_a_page_that_still_says_the_sentence_is_unchanged(self):
        read = pages(max=PAGE, pricing=PAGE)
        self.assertEqual(self.outcomes(read), {"fictional-small": "unchanged", "fictional-large": "unchanged", "fictional-unconfirmed": "unreadable"})
        # A page two profiles share is read once.
        self.assertEqual(read.asked.count("https://plans.example.invalid/max"), 1)
        self.assertEqual(run(CATALOGUE, pages(max=PAGE))[0], 0)

    def test_a_page_read_without_the_sentence_is_changed_and_fails(self):
        page = PAGE.replace("five times", "ten times")
        self.assertEqual(self.outcomes(pages(max=page))["fictional-small"], "CHANGED")
        code, out = run(CATALOGUE, pages(max=page))
        self.assertEqual(code, 1)
        self.assertIn("CHANGED", out)

    def test_a_page_blocked_or_cut_short_is_unreadable_and_does_not_fail(self):
        for page in (None, PAGE[:120]):
            self.assertEqual(self.outcomes(pages(max=page))["fictional-small"], "unreadable")
            self.assertEqual(run(CATALOGUE, pages(max=page))[0], 0)

    def test_json_names_every_profile_for_an_agent(self):
        code, out = run(CATALOGUE, pages(max=PAGE), "--json")
        result = json.loads(out)
        self.assertEqual((code, result["verifiedAt"]), (0, "2026-11-13"))
        self.assertEqual([row["profile"] for row in result["rows"]], list(CATALOGUE["profiles"]))
        self.assertEqual(result["rows"][2]["reason"], "no published sentence")

    def test_every_profile_in_the_catalogue_names_a_source(self):
        catalogue = json.loads(checker.CATALOGUE.read_text(encoding="utf-8"))
        for profile, entry in catalogue["profiles"].items():
            self.assertTrue(entry["source"].startswith("https://"), profile)
            self.assertIn("published", entry, profile)


if __name__ == "__main__":
    unittest.main()
