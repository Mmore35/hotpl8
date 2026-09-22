"""Stable entry installed outside releases; select a runner once per invocation."""
import json
from pathlib import Path
import re
import runpy
import sys
import hashlib
import subprocess

root = Path(__file__).resolve().parent
owner_file = root / "delivery-owner.json"
if owner_file.exists() and len(sys.argv) > 1 and sys.argv[1] in ("update", "preview"):
    owner = json.loads(owner_file.read_text(encoding="utf-8-sig"))
    entry = Path(owner.get("entry", ""))
    if (owner.get("protocol") != 1 or not entry.is_absolute() or not entry.is_file()
            or not re.fullmatch(r"[a-z][a-z0-9-]*", owner.get("service", ""))
            or hashlib.sha256(entry.read_bytes()).hexdigest() != owner.get("entrySha256")):
        raise SystemExit("Invalid central delivery owner; refusing local fallback")
    command = [sys.executable, str(entry), "--service", owner["service"],
               "--expected-install", str(root), sys.argv[1]]
    if sys.argv[1] == "preview" and len(sys.argv) == 3:
        command += ["--pr", sys.argv[2]]
    elif len(sys.argv) != 2:
        raise SystemExit("Invalid delivery arguments")
    raise SystemExit(subprocess.run(command).returncode)
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
