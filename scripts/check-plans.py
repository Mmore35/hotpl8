"""Check that each plan in data/capacity-profiles.json still says what its size rests on.

For each profile, fetch its `source` page, strip the markup and whitespace, and look
for its `published` sentence. Report `unchanged` (the sentence is there), `CHANGED`
(the page was read and the sentence is gone) or `unreadable` (blocked, cut short, or
no `published` sentence to look for). Exit 1 only on CHANGED. Read-only: it sends no
credentials and writes nothing. docs/plan-catalogue.md says what to do with a result.
"""
import argparse
import html
import http.client
import json
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

CATALOGUE = Path(__file__).resolve().parents[1] / "data/capacity-profiles.json"
LIMIT = 8 * 1024 * 1024
QUOTES = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', " ": " "})


def fetch(url):
    """The page's text, or None when it cannot be read whole."""
    request = urllib.request.Request(url, headers={"User-Agent": "plan-catalogue-check", "Accept": "text/html"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read(LIMIT + 1)
            charset = response.headers.get_content_charset() or "utf-8"
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        return None
    if len(body) > LIMIT:
        return None
    return body.decode(charset, errors="replace")


def text(page):
    """What a reader sees: no scripts, styles or tags, entities decoded, one space between words."""
    page = re.sub(r"(?is)<(script|style|noscript)\b.*?</\1\s*>", " ", page)
    page = re.sub(r"(?s)<!--.*?-->", " ", page)
    page = re.sub(r"(?s)<[^>]*>", " ", page)
    return re.sub(r"\s+", " ", html.unescape(page).translate(QUOTES)).strip().casefold()


def outcome(page, published):
    if not published:
        return "unreadable", "no published sentence"
    if page is None:
        return "unreadable", "page not read"
    if "</html" not in page.lower() and "</body" not in page.lower():
        return "unreadable", "page cut short"
    if text(published) in text(page):
        return "unchanged", ""
    return "CHANGED", "published sentence not found"


def check(catalogue, read=fetch):
    pages = {}
    rows = []
    for profile, entry in catalogue["profiles"].items():
        source = entry.get("source") or ""
        if source not in pages:
            pages[source] = read(source) if source.startswith("https://") else None
        result, reason = outcome(pages[source], entry.get("published"))
        rows.append(dict(profile=profile, outcome=result, reason=reason, source=source))
    return rows


def main(argv=None, read=fetch, out=sys.stdout):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="print the rows as JSON")
    parser.add_argument("--catalogue", type=Path, default=CATALOGUE)
    args = parser.parse_args(argv)
    catalogue = json.loads(args.catalogue.read_text(encoding="utf-8"))
    rows = check(catalogue, read)
    if args.json:
        print(json.dumps(dict(verifiedAt=catalogue.get("verifiedAt"), rows=rows), indent=2), file=out)
    else:
        print("verifiedAt " + str(catalogue.get("verifiedAt")), file=out)
        for row in rows:
            print("{:<10} {:<15} {}{}".format(row["outcome"], row["profile"], row["source"], "  (" + row["reason"] + ")" if row["reason"] else ""), file=out)
    return 1 if any(row["outcome"] == "CHANGED" for row in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
