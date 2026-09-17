"""Enroll an existing HotPl8 installation in tested-main delivery, explicitly."""
import argparse
import os
from pathlib import Path
import shutil
import sys
import time

from runner import DeliveryError, lock, read, run, safe_root, update, write


def setup(root, register=True):
    root = safe_root(root)
    owned = read(root / "installation.json")
    if not owned or owned.get("product") != "hotpl8":
        raise DeliveryError("First install HotPl8 normally, then enroll that owned installation")
    gh = shutil.which("gh")
    if not gh:
        raise DeliveryError("GitHub CLI is required")
    state = safe_root(owned["stateDirectory"])
    config = {"protocol": 1, "product": "hotpl8", "repository": "Mmore35/hotpl8", "channel": "main",
              "workflow": "ci.yml", "previewWorkflow": "ci.yml", "asset": "hotpl8-main.zip", "attestation": True,
              "stateCompatibility": 1, "adapter": "delivery/hotpl8-adapter.ps1", "stateDirectory": str(state),
              "writerLocks": [str(state / "tick.lock")], "gh": gh, "python": sys.executable, "drainSeconds": 30}
    existing = read(root / "delivery.json")
    if existing and (existing.get("repository") != config["repository"] or existing.get("stateDirectory") != str(state)):
        raise DeliveryError("Existing delivery registration belongs to another instance")
    write(root / "delivery.json", config)
    result = update(root)
    if result["state"] != "current":
        raise DeliveryError("Enrollment waits for a verified main release: " + str(result.get("reason")))
    with lock(root / "update.lock", 30), lock(root / "runtime.lock", 30), lock(state / "tick.lock", 30):
        current = read(root / "current.json")
        release = root / current["release"]
        for src, dst in (("launch.ps1", "launch.ps1"), ("bootstrap.py", "delivery.py")):
            shutil.copyfile(release / "delivery" / src, root / dst)
        # Keep the entire pre-delivery app as a recovery copy. The app path then
        # becomes compatibility launchers for existing scheduled tasks/shortcuts.
        app = root / "app"
        marker = app / ".delivery-shims"
        if app.exists() and not marker.exists():
            app.rename(root / ("legacy-app-" + time.strftime("%Y%m%d-%H%M%S")))
        app.mkdir(exist_ok=True)
        for entry in ("hotpl8", "tick", "status-print", "audit-codex", "setup-codex"):
            (app / (entry + ".ps1")).write_text(
                "& (Join-Path (Split-Path $PSScriptRoot -Parent) 'launch.ps1') -Entry " + entry + " @args\nexit $LASTEXITCODE\n", encoding="utf-8")
        marker.write_text("Local Delivery compatibility entrypoints\n", encoding="utf-8")
        (root / "hotpl8.cmd").write_text('@echo off\npowershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" -Entry hotpl8 %*\nexit /b %errorlevel%\n')
        owned.update(sourceSha=current["sha"], channel="main", managedBy="local-delivery")
        write(root / "installation.json", owned)
    if register:
        ps = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        run([ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", release / "delivery/register.ps1",
             "-InstallDirectory", root, "-Python", sys.executable])
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--install", required=True)
    args = parser.parse_args()
    try:
        print(setup(Path(args.install)))
    except DeliveryError as error:
        raise SystemExit(str(error))
