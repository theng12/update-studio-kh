#!/usr/bin/env python3
"""Installer smoke checks; all destination files live in a temporary home. No launchctl."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="khu-packaging-"))
checks = 0


def check(condition, name):
    global checks
    assert condition, name
    checks += 1
    print("PASS", name)


def run(script, *args):
    result = subprocess.run(["/bin/bash", str(script), *map(str, args)], capture_output=True, text=True)
    assert "fixture-secret-token" not in result.stdout + result.stderr, "credential leaked"
    return result


try:
    kit = work / "Agent Kit"
    builder = ROOT / "packaging/build-agent-kit.sh"
    installer = kit / "install-agent.sh"
    check(run(builder, "1.0.0", kit).returncode == 0, "build a credential-free kit")
    check(run(builder, "1.0.0", kit).returncode != 0, "refuse overwriting a kit")
    check(run(builder, "../escape", work / "bad").returncode != 0, "refuse unsafe version")
    home = work / "Home with spaces & <xml>"
    home.mkdir()
    config = work / "input.json"
    cfg = {
        "feedURL": "http://127.0.0.1:8790/release.json", "publicKey": "fixture-public-key",
        "machine": "fixture-mac", "token": "fixture-secret-token", "once": True,
        "apps": {"updater": {"bundlePath": "", "recipe": "updater", "automatic": False},
                 "story": {"bundlePath": "/fixture/Story.app", "recipe": "story", "automatic": False},
                 "hub": {"bundlePath": "/fixture/Hub.app", "recipe": "hub", "automatic": False}},
    }
    config.write_text(json.dumps(cfg))
    result = run(installer, config, home)
    check(result.returncode == 0 and "NOT started" in result.stdout, "install without starting launchd or apps")
    base = home / "Library/KHUpdater/base"
    installed_config = base / "config.json"
    saved = json.loads(installed_config.read_text())
    check(saved["token"] == cfg["token"] and saved["apps"] == cfg["apps"] and not saved["once"]
          and saved["stateDir"] == str(home / "Library/KHUpdater/state") and saved["stubBase"] == str(base),
          "config retains app choices and token; paths point at destination")
    check(installed_config.stat().st_mode & 0o777 == 0o600
          and (home / "Library/KHUpdater").stat().st_mode & 0o777 == 0o700,
          "credentials and private layout have restricted permissions")
    check((base / "current").is_symlink() and (base / "current").resolve() == (base / "versions/1.0.0/khu").resolve()
          and os.access(base / "current", os.X_OK) and os.access(home / "Library/KHUpdater/bin/khu-stub", os.X_OK),
          "stub and current binary are executable and versioned")
    plist = home / "Library/LaunchAgents/com.khupdater.agent.plist"
    job = plistlib.loads(plist.read_bytes())
    check(job["ProgramArguments"] == [str(home / "Library/KHUpdater/bin/khu-stub"), "--base", str(base)]
          and str(home) in job["StandardOutPath"] and "__HOME__" not in str(job),
          "plist safely encodes paths with spaces and XML characters")
    before = installed_config.read_bytes(), plist.read_bytes()
    check(run(installer, config, home).returncode != 0 and before == (installed_config.read_bytes(), plist.read_bytes()),
          "repeat install refuses without overwriting existing state")
    badhome = work / "bad-home"
    badhome.mkdir()
    cfg["token"] = "__TOKEN_FROM_ENROL__"
    config.write_text(json.dumps(cfg))
    check(run(installer, config, badhome).returncode != 0 and not (badhome / "Library").exists(),
          "unfilled credentials refuse before writing destination")
    cfg["token"] = "fixture-secret-token"
    cfg["apps"] = []
    config.write_text(json.dumps(cfg))
    check(run(installer, config, badhome).returncode != 0, "wrong apps shape refuses before installation")
    cfg["apps"] = {}
    config.write_text(json.dumps(cfg))
    # Fail after staging began: the invalid template must be preserved, not deleted or installed.
    template = kit / "com.khupdater.agent.plist"
    template.rename(kit / "kept-template.plist")
    template.write_text("invalid plist")
    result = run(installer, config, badhome)
    trash = badhome / "Library/_trash"
    check(result.returncode != 0 and not (badhome / "Library/KHUpdater").exists()
          and any(trash.glob("*/staging/KHUpdater/base/config.json")),
          "failed staging moves partial install into destination trash")
    print(f"PACKAGING: {checks} passed, 0 failed")
finally:
    print(f"Temporary fixtures preserved at {work}")
