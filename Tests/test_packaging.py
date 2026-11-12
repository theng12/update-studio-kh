#!/usr/bin/env python3
"""Installer smoke checks; all destination files live in a temporary home.

launchd is a recording stub first on PATH, so no test reaches the real `gui` domain, the real
~/Library/LaunchAgents or the real agent."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
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
  print) [[ -f "$FAKE_LAUNCHCTL_LOADED" ]] && exit 0; exit "${FAKE_LAUNCHCTL_PRINT_EXIT:-1}" ;;
  bootstrap)
    if [[ -n "${FAKE_LAUNCHCTL_FAIL:-}" ]]; then
      echo 'Bootstrap failed: 5: Input/output error' >&2; exit 1
    fi
    : > "$FAKE_LAUNCHCTL_LOADED" ;;
  bootout)
    if [[ -n "${FAKE_LAUNCHCTL_BOOTOUT_FAIL:-}" ]]; then
      echo 'Bootout failed: 3: No such process' >&2; exit 1
    fi
    # The job is no longer loaded: the marker is moved aside, never deleted.
    [[ -f "$FAKE_LAUNCHCTL_LOADED" ]] && mv "$FAKE_LAUNCHCTL_LOADED" "$FAKE_LAUNCHCTL_LOADED.off" ;;
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
    for suite in ("test_release_proof.py", "test_signing.py", "test_launcher_progress.py", "test_app_services.py", "test_shared_ui.py"):
        check(subprocess.run([sys.executable, "-B", "-I", str(ROOT / "Tests" / suite)]).returncode == 0,
              f"{suite} isolated regression checks")
    check(subprocess.run(["node", str(ROOT / "Tests" / "test_launcher_render.js")]).returncode == 0,
          "Launcher render and dialog regression checks")
    # Inspect real binaries: the kit must run on the macOS version its app declares.
    for binary in ("khu", "khu-stub"):
        output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(ROOT / "build" / binary)], text=True)
        minimums = [line.split()[1] for line in output.splitlines() if line.strip().startswith("minos ")]
        check(bool(minimums) and all(tuple(map(int, (v.split(".") + ["0", "0"])[:2])) <= (13, 0) for v in minimums),
              f"{binary} supports the declared macOS 13 minimum")
    # Universal-build regression: mocked kits only, no compile. Thin build outputs are refused,
    # universal ones ship unchanged, and build.sh/build-launcher.sh keep the universal shape.
    import shutil
    fake_root = work / "universal-root"
    (fake_root / "packaging").mkdir(parents=True)
    (fake_root / "examples").mkdir()
    (fake_root / "build").mkdir()
    for rel in ("packaging/build-agent-kit.sh", "packaging/install-agent.sh",
                "packaging/com.khupdater.agent.plist", "examples/agent-config.json"):
        shutil.copy(ROOT / rel, fake_root / rel)
    # Stand-in lipo first on this block's PATH only (like the launchctl fake): the fixtures are
    # text, so the real lipo would reject them; real Mach-O inputs are exercised by the kit run
    # below against the actual ./build.sh build binaries.
    univ_bin = work / "lipo-bin"
    univ_bin.mkdir()
    (univ_bin / "lipo").write_text(
        '#!/bin/bash\n'
        '[[ "$1" == "-archs" ]] || exit 2\n'
        "archs=$(cat \"$2\")\n"
        '[[ "$archs" == *arm64* || "$archs" == *x86_64* ]] || { echo "lipo: not a mach-o" >&2; exit 1; }\n'
        "printf '%s\\n' \"$archs\"\n")
    (univ_bin / "lipo").chmod(0o755)
    univ_env = {**fake_env, "PATH": f"{univ_bin}:{fake_env['PATH']}"}
    fake_builder = fake_root / "packaging/build-agent-kit.sh"
    universal_blob = "arm64 x86_64\n"
    (fake_root / "build/khu-stub").write_text(universal_blob)
    (fake_root / "build/khu-stub").chmod(0o755)
    (fake_root / "build/AppIcon.icns").write_text("fixture icon")
    thin = fake_root / "build/khu"
    thin.write_text("arm64\n")
    thin.chmod(0o755)
    out = fake_root / "kit-thin"
    result = run(fake_builder, "1.0.0", out, env=univ_env)
    check(result.returncode != 0 and "must be universal arm64+x86_64" in result.stderr and not out.exists(),
          "kit refuses a thin arm64-only khu before creating any output")
    thin.write_text(universal_blob)
    (fake_root / "build/khu-stub").write_text("x86_64\n")
    result = run(fake_builder, "1.0.0", out, env=univ_env)
    check(result.returncode != 0 and "must be universal arm64+x86_64" in result.stderr and not out.exists(),
          "kit refuses a thin x86_64-only khu-stub too, so both slices are asserted")
    (fake_root / "build/khu-stub").write_text("payload with no architectures\n")
    result = run(fake_builder, "1.0.0", out, env=univ_env)
    check(result.returncode != 0 and "must be universal arm64+x86_64" in result.stderr
          and "not a Mach-O" in result.stderr and not out.exists(),
          "an unrecognised build/khu-stub fails the same gate with a reason instead of crashing")
    (fake_root / "build/khu-stub").write_text(universal_blob)
    check(run(fake_builder, "1.0.0", out, env=univ_env).returncode == 0
          and (out / "bin/khu").read_text() == universal_blob
          and (out / "bin/khu-stub").read_text() == universal_blob,
          "kit ships universal inputs unchanged")
    check(run(fake_builder, "1.0.0", out, env=univ_env).returncode != 0
          and (out / "bin/khu").read_text() == universal_blob,
          "overwrite refusal still follows the universal check")

    # Static shape of build.sh/build-launcher.sh: per-arch compile, lipo merge at macos13.0,
    # native test runner intact, and the launcher no longer re-merges duplicate slices.
    build_sh = (ROOT / "build.sh").read_text()
    check("universal build/khu" in build_sh and "universal build/khu-stub" in build_sh
          and 'TARGET="$(uname -m)' not in build_sh,
          "build.sh produces both universal binaries instead of a uname-sized thin one")
    check("apple-macos13.0" in build_sh and '"${arch}-${FLOOR}"' in build_sh
          and "lipo -create" in build_sh,
          "each slice keeps its own macos13.0 target and is merged with lipo")
    check("build/khu-tests" in build_sh and "./build/khu-tests" in build_sh
          and '"$(uname -m)-${FLOOR}"' in build_sh,
          "test mode still compiles and runs the native test runner")
    launcher_sh = (ROOT / "packaging/build-launcher.sh").read_text()
    check("khu-universal" not in launcher_sh and "build/khu-x86" not in launcher_sh
          and "build/khu launcher-bundle" in launcher_sh,
          "launcher consumes the shared universal build/khu without re-merging slices")

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
    helper = home / "Library/KHUpdater/Update Studio KH Helper.app"
    helper_info = plistlib.loads((helper / "Contents/Info.plist").read_bytes())
    check(job["ProgramArguments"] == [str(helper / "Contents/MacOS/Update Studio KH Helper"), "--base", str(base)]
          and str(home) in job["StandardOutPath"] and "__HOME__" not in str(job),
          "plist safely encodes paths with spaces and XML characters")
    check(helper_info.get("LSUIElement") is True
          and helper_info.get("CFBundleDisplayName") == "Update Studio KH Helper"
          and helper_info.get("CFBundleIdentifier") == "com.khupdater.agent"
          and os.access(helper / "Contents/MacOS/Update Studio KH Helper", os.X_OK),
          "the launchd job runs from a named, icon-carrying helper bundle instead of a bare binary")
    check((helper / "Contents/MacOS/Update Studio KH Helper").read_bytes() == (home / "Library/KHUpdater/bin/khu-stub").read_bytes(),
          "the helper bundle wraps the supervisor stub, not the agent binary")
    ats = helper_info.get("NSAppTransportSecurity", {})
    domains = ats.get("NSExceptionDomains", {})
    check(domains.get("100.64.0.0/10", {}).get("NSExceptionAllowsInsecureHTTPLoads") is True
          and domains.get("ts.net", {}).get("NSIncludesSubdomains") is True
          and domains.get("ts.net", {}).get("NSExceptionAllowsInsecureHTTPLoads") is True
          and "NSAllowsArbitraryLoads" not in ats,
          "the helper reaches the feed by tailnet address and MagicDNS name, and nothing else")
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

    # Incomplete installations repair in place; launchctl remains a recording fake.
    def reset_launchd(tag, running=False):
        for file in [calls, loaded]:
            if file.exists():
                file.rename(work / (file.name + "-" + tag))
        if running:
            loaded.touch()

    def incomplete(tag, plist_only=False):
        h = work / tag
        h.mkdir()
        k = h / "Library/KHUpdater"
        p = h / "Library/LaunchAgents/com.khupdater.agent.plist"
        p.parent.mkdir(parents=True)
        p.write_bytes(plist.read_bytes())
        if not plist_only:
            (k / "state/downloads").mkdir(parents=True)
            (k / "state/downloads/keep").write_text("saved-app-data")
            (k / "base/versions/0.8.0").mkdir(parents=True)
            old = k / "base/versions/0.8.0/khu"
            old.write_text("old-version")
            old.chmod(0o755)
            (k / "base/current").symlink_to("versions/0.8.0/khu")
        return h, k, p

    cfg["apps"] = {"updater": {"bundlePath": "", "recipe": "updater", "automatic": False}}
    config.write_text(json.dumps(cfg))
    for tag, plist_only in [("repair-data", False), ("repair-plist", True)]:
        reset_launchd(tag, running=True)
        h, k, p = incomplete(tag, plist_only)
        old_plist = p.read_bytes()
        result = run(installer, config, h, "--repair")
        check(result.returncode == 0 and (k / "base/config.json").is_file(), tag + " finishes setup")
        check(recorded() == [["print", label], ["bootout", label], ["bootstrap", domain, str(p)]],
              tag + " stops the loaded job and starts exactly one replacement")
        check(any(x.read_bytes() == old_plist for x in (h / "Library/_trash").glob("repair-*/agent.plist")),
              tag + " preserves the replaced LaunchAgent")
        if not plist_only:
            check((k / "state/downloads/keep").read_text() == "saved-app-data"
                  and (k / "base/versions/0.8.0/khu").read_text() == "old-version"
                  and (k / "base/previous").resolve() == (k / "base/versions/0.8.0/khu").resolve(),
                  "repair preserves saved data, old version and rollback link")
        before = (k / "base/config.json").read_bytes()
        reset_launchd(tag + "-repeat")
        check(run(installer, config, h, "--repair").returncode != 0
              and (k / "base/config.json").read_bytes() == before and recorded() == [],
              "repair never overwrites an existing connection")

    reset_launchd("repair-stop-failed", running=True)
    h, k, p = incomplete("repair-stop-failed")
    before = p.read_bytes()
    result = run(installer, config, h, "--repair", env={**fake_env, "FAKE_LAUNCHCTL_BOOTOUT_FAIL": "1"})
    check(result.returncode != 0 and not (k / "base/config.json").exists() and p.read_bytes() == before
          and (k / "state/downloads/keep").read_text() == "saved-app-data"
          and recorded() == [["print", label], ["bootout", label]],
          "failed stop leaves all original files unchanged and starts no second job")

    reset_launchd("repair-start-failed")
    h, k, p = incomplete("repair-start-failed")
    result = run(installer, config, h, "--repair", env={**fake_env, "FAKE_LAUNCHCTL_FAIL": "1"})
    check(result.returncode != 0 and (k / "base/config.json").is_file()
          and "Open Studio Launcher again" in result.stderr
          and (k / "state/downloads/keep").read_text() == "saved-app-data",
          "failed repair start keeps completed setup and gives the reopen recovery step")

    for component in ["KHUpdater", "KHUpdater/base", "KHUpdater/bin", "KHUpdater/state"]:
        reset_launchd("symlink-" + component.replace("/", "-"))
        h = work / ("symlink-" + component.replace("/", "-")); h.mkdir()
        outside = h / "outside"; outside.mkdir(); (outside / "keep").write_text("untouched")
        link = h / "Library" / component; link.parent.mkdir(parents=True, exist_ok=True); link.symlink_to(outside)
        result = run(installer, config, h, "--repair")
        check(result.returncode != 0 and (outside / "keep").read_text() == "untouched" and recorded() == [],
              "repair refuses linked " + component + " before touching launchd")

    reset_launchd("repair-stage-failed", running=True)
    h, k, p = incomplete("repair-stage-failed")
    template = kit / "com.khupdater.agent.plist"
    template_bytes = template.read_bytes()
    template.write_text("invalid plist")
    result = run(installer, config, h, "--repair")
    template.write_bytes(template_bytes)
    check(result.returncode != 0 and not (k / "base/config.json").exists()
          and (k / "state/downloads/keep").read_text() == "saved-app-data" and recorded() == [],
          "invalid repair staging leaves data and the running job untouched")

    # A saved connection repairs its own helper files and start file, with no code: the config is
    # read from that Mac's own base and never rewritten.
    def saved_repair_home(tag):
        h, k, p = incomplete(tag)
        (k / "base").mkdir(parents=True, exist_ok=True)
        saved = json.loads(installed_config.read_text())
        saved["stateDir"] = str(k / "state")
        saved["stubBase"] = str(k / "base")
        bytes_ = json.dumps(saved).encode()
        (k / "base/config.json").write_bytes(bytes_)
        (k / "base/config.json").chmod(0o600)
        return h, k, p, bytes_

    reset_launchd("repair-saved", running=True)
    h, k, p, saved_bytes = saved_repair_home("repair-saved")
    result = run(installer, k / "base/config.json", h, "--repair-saved")
    check(result.returncode == 0 and (k / "base/config.json").read_bytes() == saved_bytes
          and (k / "base/versions/1.0.0/khu").is_file() and (k / "bin/khu-stub").is_file()
          and (k / "state/downloads/keep").read_text() == "saved-app-data",
          "saved repair finishes the helper files and keeps the saved connection and data byte for byte")
    check(recorded() == [["print", label], ["bootout", label], ["bootstrap", domain, str(p)]],
          "saved repair stops the loaded job and starts exactly one replacement")
    check((k / "base/config.json").stat().st_mode & 0o777 == 0o600, "saved repair keeps the connection private")

    reset_launchd("repair-saved-absent")
    h, k, p, saved_bytes = saved_repair_home("repair-saved-absent")
    result = run(installer, k / "base/config.json", h, "--repair-saved",
                 env={**fake_env, "FAKE_LAUNCHCTL_PRINT_EXIT": "113"})
    check(result.returncode == 0 and recorded() == [["print", label], ["bootstrap", domain, str(p)]]
          and (k / "base/config.json").read_bytes() == saved_bytes,
          "saved repair starts an explicitly absent job once and preserves its connection")

    reset_launchd("repair-saved-unknown")
    h, k, p, saved_bytes = saved_repair_home("repair-saved-unknown")
    old_current = os.readlink(k / "base/current")
    result = run(installer, k / "base/config.json", h, "--repair-saved")
    check(result.returncode != 0 and "startup status" in result.stderr and recorded() == [["print", label]]
          and os.readlink(k / "base/current") == old_current
          and (k / "base/config.json").read_bytes() == saved_bytes,
          "saved repair refuses unknown startup status before stopping or replacing anything")

    reset_launchd("repair-saved-other")
    h, k, p, saved_bytes = saved_repair_home("repair-saved-other")
    other = work / "other-config.json"
    other.write_bytes(saved_bytes)
    result = run(installer, other, h, "--repair-saved")
    check(result.returncode != 0 and recorded() == [] and (k / "base/config.json").read_bytes() == saved_bytes,
          "saved repair refuses a config that is not this Mac's own")

    reset_launchd("repair-copy-failed")
    h, k, p = incomplete("repair-copy-failed")
    old_current = os.readlink(k / "base/current")
    old_plist = p.read_bytes()
    broken_cp = fake_bin / "cp"
    broken_cp.write_text('#!/bin/bash\nlast="${!#}"\nif [[ "$last" == "$FAIL_COPY_TO" ]]; then printf partial > "$last"; exit 1; fi\nexec /bin/cp "$@"\n')
    broken_cp.chmod(0o755)
    result = run(installer, config, h, "--repair", env={**fake_env, "FAIL_COPY_TO": str(k / "base/config.json")})
    broken_cp.rename(work / "kept-failing-cp")
    check(result.returncode != 0 and not (k / "base/config.json").exists()
          and os.readlink(k / "base/current") == old_current and p.read_bytes() == old_plist
          and (k / "state/downloads/keep").read_text() == "saved-app-data",
          "failed config copy restores originals and retires the partial config")
    check(run(installer, config, h, "--repair").returncode == 0,
          "repair can retry successfully after a partial copy failure")

    reset_launchd("before-fresh-invalid")
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

    # Display/discovery naming: the kit finds the Hub's settings under either bundle name.
    import importlib.util
    spec = importlib.util.spec_from_file_location("khu_install", ROOT / "packaging/connect-kit/khu-install.py")
    khu = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(khu)
    hub_home = work / "hub-home"
    (hub_home / "Applications").mkdir(parents=True)
    check(khu.hub_data_dir(hub_home) is None, "no Hub bundle on this Mac means no Hub data dir")
    old_bundle = hub_home / "Applications" / "Studio Hub.app"
    old_bundle.mkdir()
    check(khu.hub_data_dir(hub_home) == old_bundle / "Contents" / "Resources" / "voice",
          "hub_data_dir still finds the old Studio Hub.app bundle")
    old_bundle.rmdir()
    new_bundle = hub_home / "Applications" / "Hub Studio KH.app"
    new_bundle.mkdir()
    check(khu.hub_data_dir(hub_home) == new_bundle / "Contents" / "Resources" / "voice",
          "hub_data_dir finds the Hub Studio KH.app bundle too")
    packaging = Path(__file__).resolve().parent.parent / "packaging"
    check('record-dist.sh copy "Update Studio KH"' in (packaging / "build-app.sh").read_text()
          and 'record-dist.sh copy "Studio Launcher KH"' in (packaging / "build-launcher.sh").read_text()
          and (packaging / "record-dist.sh").stat().st_mode & 0o111,
          "every packaged DMG is written into dist/ by the build itself, not by remembering")
    print(f"PACKAGING: {checks} passed, 0 failed")
finally:
    print(f"Temporary fixtures preserved at {work}")
