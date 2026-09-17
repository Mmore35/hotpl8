"""Stable entry installed outside releases; select a runner once per invocation."""
import json
from pathlib import Path
import re
import runpy
import sys

root = Path(__file__).resolve().parent
pointer = json.loads((root / "current.json").read_text(encoding="utf-8-sig"))
transaction = root / "transaction.json"
if transaction.exists():
    previous = json.loads(transaction.read_text(encoding="utf-8-sig")).get("previous")
    if previous:
        pointer = previous  # Run the known-good recovery implementation first.
if not re.fullmatch(r"[0-9a-f]{40}", pointer["sha"]) or pointer["release"] != "releases/" + pointer["sha"]:
    raise SystemExit("Invalid installed release pointer")
runner = root / pointer["release"] / "delivery/runner.py"
sys.argv = [str(runner), "--install", str(root), *sys.argv[1:]]
runpy.run_path(str(runner), run_name="__main__")
