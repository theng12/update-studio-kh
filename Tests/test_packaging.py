#!/usr/bin/env python3
"""Installer smoke checks; all destination files live in a temporary home.

launchd is a recording stub first on PATH, so no test reaches the real `gui` domain, the real
~/Library/LaunchAgents or the real agent."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
work = Path(tempfile.mkdtemp(prefix="khu-packaging-"))
checks = 0
domain = f"gui/{os.getuid()}"
label = f"{domain}/com.khupdater.agent"

# One tab between arguments, so a home with spaces stays unambiguous.
fake_bin = work / "fake-bin"
fake_bin.mkdir()
(fake_bin / "launchctl").write_text("""#!/bin/bash
printf '%s\\t' "$@" >> "$FAKE_LAUNCHCTL_CALLS"; printf '\\n' >> "$FAKE_LAUNCHCTL_CALLS"
case "$1" in
  print) [[ -f "$FAKE_LAUNCHCTL_LOADED" ]] && exit 0; exit 1 ;;
  bootstrap)
    if [[ -n "${FAKE_LAUNCHCTL_FAIL:-}" ]]; then
      echo 'Bootstrap failed: 5: Input/output error' >&2; exit 1
    fi
    : > "$FAKE_LAUNCHCTL_LOADED" ;;
esac
""")
(fake_bin / "launchctl").chmod(0o755)
calls = work / "launchctl-calls"
loaded = work / "launchd-loaded"
fake_env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FAKE_LAUNCHCTL_CALLS": str(calls), "FAKE_LAUNCHCTL_LOADED": str(loaded)}


def recorded():
    return [line.split("\t")[:-1] for line in calls.read_text().splitlines()] if calls.exists() else []


def check(condition, name):
    global checks
    assert condition, name
    checks += 1
    print("PASS", name)


def run(script, *args, env=fake_env):
    result = subprocess.run(["/bin/bash", str(script), *map(str, args)], capture_output=True, text=True, env=env)
    assert "fixture-secret-token" not in result.stdout + result.stderr, "credential leaked"
    return result


try:
    # Inspect real binaries: the kit must run on the macOS version its app declares.
    for binary in ("khu", "khu-stub"):
        output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(ROOT / "build" / binary)], text=True)
        minimums = [line.split()[1] for line in output.splitlines() if line.strip().startswith("minos ")]
        check(bool(minimums) and all(tuple(map(int, (v.split(".") + ["0", "0"])[:2])) <= (13, 0) for v in minimums),
              f"{binary} supports the declared macOS 13 minimum")
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
    plist = home / "Library/LaunchAgents/com.khupdater.agent.plist"
    check(result.returncode == 0 and "started" in result.stdout, "install starts the agent")
    check(recorded() == [["print", label], ["bootstrap", domain, str(plist)]],
          "activation probes the job, then bootstraps this home's plist exactly once")
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
    job = plistlib.loads(plist.read_bytes())
    check(job["ProgramArguments"] == [str(home / "Library/KHUpdater/bin/khu-stub"), "--base", str(base)]
          and str(home) in job["StandardOutPath"] and "__HOME__" not in str(job),
          "plist safely encodes paths with spaces and XML characters")
    before = installed_config.read_bytes(), plist.read_bytes()
    calls.unlink()
    loaded.unlink()
    check(run(installer, config, home).returncode != 0 and before == (installed_config.read_bytes(), plist.read_bytes())
          and recorded() == [],
          "repeat install refuses without overwriting existing state or touching launchd")

    # A job launchd already has is left alone: no second copy, and the files still install.
    loaded_home = work / "loaded-home"
    loaded_home.mkdir()
    loaded.touch()
    cfg["token"] = "fixture-secret-token"
    cfg["apps"] = {"updater": {"bundlePath": "", "recipe": "updater", "automatic": False}}
    config.write_text(json.dumps(cfg))
    result = run(installer, config, loaded_home)
    check(result.returncode == 0 and "left alone" in result.stdout
          and recorded() == [["print", label]]
          and (loaded_home / "Library/KHUpdater/base/config.json").is_file(),
          "an already-loaded job is left alone and the install still completes")

    # A refused start keeps the finished install, says why, and names the one command that retries it.
    fail_home = work / "fail-home"
    fail_home.mkdir()
    loaded.unlink()
    calls.unlink()
    result = run(installer, config, fail_home, env={**fake_env, "FAKE_LAUNCHCTL_FAIL": "1"})
    keep = fail_home / "Library/KHUpdater"
    check(result.returncode != 0 and "did not start it" in result.stderr
          and "Input/output error" in result.stderr
          and f"launchctl bootstrap {domain}" in result.stderr
          and "Incomplete install preserved" not in result.stderr,
          "a failed start reports launchctl's own reason and how to retry it")
    check((keep / "base/config.json").is_file()
          and (keep / "base/current").is_symlink()
          and (fail_home / "Library/LaunchAgents/com.khupdater.agent.plist").is_file()
          and not list((fail_home / "Library/_trash").glob("*/KHUpdater"))
          and recorded() == [["print", label], ["bootstrap", domain, str(fail_home / "Library/LaunchAgents/com.khupdater.agent.plist")]],
          "a failed start keeps the whole install in place and trashes nothing")

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
