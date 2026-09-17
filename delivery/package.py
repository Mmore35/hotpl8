"""Wrap the allowlisted product package with exact, reproducible build identity."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


def package(source, output, product, repository, sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("An exact source SHA is required")
    with zipfile.ZipFile(source) as archive:
        files = {item.filename: archive.read(item) for item in archive.infolist()}
    files["build-info.json"] = (json.dumps({"protocol": 1, "product": product, "repository": repository,
                                            "sha": sha, "channel": "main"}, indent=2) + "\n").encode()
    manifest = {"protocol": 1, "product": product, "repository": repository, "sha": sha,
                "platform": "windows", "stateCompatibility": 1,
                "files": {name: hashlib.sha256(value).hexdigest() for name, value in sorted(files.items())}}
    files["delivery-manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, value in sorted(files.items()):
            entry = zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, value)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("--product", default="hotpl8")
    parser.add_argument("--repository", default="Mmore35/hotpl8")
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    package(args.source, args.output, args.product, args.repository, args.sha)
