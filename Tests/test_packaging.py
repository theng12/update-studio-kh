#!/usr/bin/env python3
"""Installer smoke checks; all destination files live in a temporary home.

launchd is a recording stub first on PATH, so no test reaches the real `gui` domain, the real
~/Library/LaunchAgents or the real agent."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
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
  list)
    # A loaded job with a pid: the installer reads the pid rather than trusting bootstrap's exit code.
    [[ -f "$FAKE_LAUNCHCTL_LOADED" ]] && printf '4242\t0\tcom.khupdater.agent\n'; exit 0 ;;
esac
""")
(fake_bin / "launchctl").chmod(0o755)
calls = work / "launchctl-calls"
loaded = work / "launchd-loaded"
fake_env = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "FAKE_LAUNCHCTL_CALLS": str(calls), "FAKE_LAUNCHCTL_LOADED": str(loaded)}


def recorded():
    return [line.split("\t")[:-1] for line in calls.read_text().splitlines()] if calls.exists() else []


def activation(prefix):
    """The activation calls in order. The installer reads the job's pid back after bootstrap — once,
    or twice when it also prints it — so any number of read-only `list` calls may follow."""
    made = recorded()
    return made[:len(prefix)] == prefix and all(call == ["list"] for call in made[len(prefix):])


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
                "packaging/com.khupdater.agent.plist", "packaging/fleet-roster.json", "examples/agent-config.json"):
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
    check(not (out / "fleet-roster.json").exists(),
          "the kit ships no build-time roster: Hub refuses an unexpected entry in a kit")
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
    check("if [ -L _trash ]" not in launcher_sh and "KHU_TRASH:-$HOME/Desktop/_trash/update-studio-kh" in launcher_sh
          and "KHU_TRASH:-$HOME/Desktop/_trash/update-studio-kh" in (ROOT / "packaging/record-dist.sh").read_text()
          and "/_trash" in (ROOT / ".gitignore").read_text(),
          "packaging uses the Desktop trash path directly instead of a checkout _trash symlink")

    # The publisher key inside the build is the one input a rewritten trust file cannot change.
    pin_src = (ROOT / "Sources/KHUpdaterCore/PinnedKey.swift").read_text()
    match = re.search(r'public static let base64: String\? = "([^"]+)"', pin_src)
    try:
        pin_bytes = base64.b64decode(match.group(1), validate=True) if match else b""
    except (ValueError, TypeError):
        pin_bytes = b""
    check(len(pin_bytes) == 32 and pin_src.count("public static let base64") == 1,
          "the app pins one real 32-byte publisher key (never a placeholder)")
    release_branch = pin_src.split("#else", 1)[-1]
    check(pin_src.count('environment["KHU_TEST_KEY"]') == 1
          and "KHU_TEST_KEY" not in release_branch
          and "ProcessInfo.processInfo.environment" not in release_branch,
          "a fixture key can override the pin only inside #if KHU_TESTS")

    # Trash path guard: build-launcher.sh creates a missing KHU_TRASH dir and refuses a non-directory.
    trash_repo = work / "trash-repo"
    (trash_repo / "packaging").mkdir(parents=True)
    (trash_repo / "build").mkdir()
    shutil.copyfile(ROOT / "packaging/build-launcher.sh", trash_repo / "packaging/build-launcher.sh")
    (trash_repo / "packaging/build-launcher.sh").chmod(0o755)
    (trash_repo / "packaging/build-agent-kit.sh").write_text("#!/bin/bash\nexit 99\n")
    (trash_repo / "packaging/build-agent-kit.sh").chmod(0o755)
    (trash_repo / "build/khu").write_text("#!/bin/sh\nexit 0\n")
    (trash_repo / "build/khu").chmod(0o755)
    trash_pub = work / "trash-pub.json"
    trash_pub.write_text("{}\n")
    trash_file = work / "not-a-dir"
    trash_file.write_text("file\n")
    bad_trash = run(trash_repo / "packaging/build-launcher.sh", "0.1.61", trash_pub,
                    env={**fake_env, "KHU_TRASH": str(trash_file)})
    check(bad_trash.returncode == 1 and "exists and is not a directory" in bad_trash.stderr
          and not (trash_repo / "_trash").exists(),
          "build-launcher stops with one plain sentence when the trash path is not a directory")
    new_trash = work / "created-trash/nested"
    mk_trash = run(trash_repo / "packaging/build-launcher.sh", "0.1.61", trash_pub,
                   env={**fake_env, "KHU_TRASH": str(new_trash)})
    check(mk_trash.returncode == 99 and new_trash.is_dir() and not (trash_repo / "_trash").exists(),
          "build-launcher creates a missing trash directory without creating a checkout _trash link")

    # Shared Tools paths: no retired Developer-root shortcut in release-proof.py or docs/INSTALL.md.
    proof_py = (ROOT / "packaging/release-proof.py").read_text()
    install_md = (ROOT / "docs/INSTALL.md").read_text()
    check("~/Developer/portfolio" not in proof_py
          and "Developer/Shared Tools/portfolio/test-policy/projects.json" in proof_py
          and "Developer/Shared Tools/portfolio/bin/testctl" in proof_py,
          "release-proof.py defaults point at Shared Tools/portfolio")
    check("~/Developer/kh-shared-ui" not in install_md and "~/Developer/portfolio" not in install_md
          and "~/Developer/Shared Tools/kh-shared-ui" in install_md
          and "~/Developer/Shared Tools/portfolio/bin/testctl" in install_md,
          "docs/INSTALL.md names Shared Tools folders only")

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
        # The kit's own address, which 0.1.69's installer refuses when it names a bare IP
        # (install-agent.sh:41): a fixture must be an address the installer would accept.
        "feedURL": "http://publisher.tailnet.ts.net:8790/release.json", "publicKey": "fixture-public-key",
        "machine": "fixture-mac", "token": "fixture-secret-token", "once": True,
        "apps": {"updater": {"bundlePath": "", "recipe": "updater", "automatic": False},
                 "story": {"bundlePath": "/fixture/Story.app", "recipe": "story", "automatic": False},
                 "hub": {"bundlePath": "/fixture/Hub.app", "recipe": "hub", "automatic": False}},
    }
    config.write_text(json.dumps(cfg))
    result = run(installer, config, home)
    plist = home / "Library/LaunchAgents/com.khupdater.agent.plist"
    check(result.returncode == 0 and "started" in result.stdout, "install starts the agent")
    check(activation([["print", label], ["bootstrap", domain, str(plist)]])
          and "pid 4242" in result.stdout,
          "activation probes the job, bootstraps this home's plist once, and reads the running pid back")
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
    helper = home / "Library/KHUpdater/Studio Launcher KH Helper.app"
    helper_info = plistlib.loads((helper / "Contents/Info.plist").read_bytes())
    check(job["ProgramArguments"] == [str(helper / "Contents/MacOS/Studio Launcher KH Helper"), "--base", str(base)]
          and str(home) in job["StandardOutPath"] and "__HOME__" not in str(job),
          "plist safely encodes paths with spaces and XML characters")
    check("LSUIElement" not in helper_info
          and helper_info.get("CFBundleDisplayName") == "Studio Launcher KH Helper"
          and helper_info.get("CFBundleIdentifier") == "com.khupdater.agent"
          and os.access(helper / "Contents/MacOS/Studio Launcher KH Helper", os.X_OK),
          "the launchd job runs from a named, icon-carrying helper bundle with a Dock icon, not a bare binary")
    check((helper / "Contents/MacOS/Studio Launcher KH Helper").read_bytes() == (home / "Library/KHUpdater/bin/khu-stub").read_bytes(),
          "the helper bundle wraps the supervisor stub, not the agent binary")
    ats = helper_info.get("NSAppTransportSecurity", {})
    domains = ats.get("NSExceptionDomains", {})
    check(ats.get("NSAllowsArbitraryLoads") is None and set(domains) == {"ts.net"}
          and domains["ts.net"].get("NSIncludesSubdomains") is True
          and domains["ts.net"].get("NSExceptionAllowsInsecureHTTPLoads") is True,
          "the helper allows plain HTTP to the tailnet's DNS suffix and nothing else")
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

    # A public https feed carries no token on purpose — Connect.usePublicFeed writes "" because it
    # reports to nobody. Requiring one refused every GitHub public-feed install (2026-11-20). A
    # publisher's feed still needs its token; both must be a real string, never a placeholder.
    public_home = work / "public-home"
    public_home.mkdir()
    # Exactly the file Connect.usePublicFeed writes (Connect.swift), field for field.
    public_cfg = {
        "feedURL": "https://raw.githubusercontent.com/theng12/kh-releases/main/release.json",
        "publicKey": cfg["publicKey"], "machine": "fixture-mac", "token": "",
        "stateDir": "set-by-installer", "intervalMinutes": 5, "once": False,
        "apps": {"updater": {"bundlePath": "", "recipe": "updater", "automatic": True}},
    }
    config.write_text(json.dumps(public_cfg))
    result = run(installer, config, public_home)
    public_config = public_home / "Library/KHUpdater/base/config.json"
    check(result.returncode == 0 and public_config.is_file()
          and json.loads(public_config.read_text())["token"] == "",
          "a public https feed installs with the empty token Connect writes for it")


    plain_home = work / "no-token-home"
    plain_home.mkdir()
    config.write_text(json.dumps(dict(cfg, feedURL="http://publisher.tailnet.ts.net:8790/release.json", token="")))
    result = run(installer, config, plain_home)
    check(result.returncode != 0 and "Fill in token" in result.stderr
          and not (plain_home / "Library/KHUpdater").exists(),
          "a publisher feed with no token is still refused before anything is installed")
    config.write_text(json.dumps(cfg))

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
        check(activation([["print", label], ["bootout", label], ["bootstrap", domain, str(p)]]),
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

    # A Mac installed by 0.1.35 carries the old-named client engine. A repair keeps it in its own
    # trash, installs the renamed bundle and points the job at it — no duplicate job, no hand step.
    reset_launchd("repair-legacy-name", running=True)
    h, k, p = incomplete("repair-legacy-name")
    legacy = k / "Update Studio KH Helper.app"
    (legacy / "Contents/MacOS").mkdir(parents=True)
    (legacy / "Contents/MacOS/Update Studio KH Helper").write_text("old-helper")
    legacy_versioned = k / "base/versions/1.0.0/Update Studio KH Helper.app"
    (legacy_versioned / "Contents/MacOS").mkdir(parents=True)
    (legacy_versioned / "Contents/MacOS/Update Studio KH Helper").write_text("old-versioned-helper")
    result = run(installer, config, h, "--repair")
    renamed = k / "Studio Launcher KH Helper.app"
    job = plistlib.loads(p.read_bytes())
    trash = h / "Library/_trash"
    check(result.returncode == 0 and (renamed / "Contents/MacOS/Studio Launcher KH Helper").is_file()
          and job["ProgramArguments"][0] == str(renamed / "Contents/MacOS/Studio Launcher KH Helper")
          and not legacy.exists() and not legacy_versioned.exists()
          and any(x.name.startswith("legacy-helper-app") for x in trash.glob("repair-*/*"))
          and any(x.name.startswith("legacy-versions-1.0.0-helper-app") for x in trash.glob("repair-*/*")),
          "repair migrates the old helper name to Studio Launcher KH Helper and keeps the old bundles")
    plists = sorted((h / "Library/LaunchAgents").glob("*.plist"))
    check([x.name for x in plists] == ["com.khupdater.agent.plist"],
          "the migration re-points the one existing job; no second launchd job is created")

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
    check(activation([["print", label], ["bootout", label], ["bootstrap", domain, str(p)]]),
          "saved repair stops the loaded job and starts exactly one replacement")
    check((k / "base/config.json").stat().st_mode & 0o777 == 0o600, "saved repair keeps the connection private")

    reset_launchd("repair-saved-absent")
    h, k, p, saved_bytes = saved_repair_home("repair-saved-absent")
    result = run(installer, k / "base/config.json", h, "--repair-saved",
                 env={**fake_env, "FAKE_LAUNCHCTL_PRINT_EXIT": "113"})
    check(result.returncode == 0 and activation([["print", label], ["bootstrap", domain, str(p)]])
          and (k / "base/config.json").read_bytes() == saved_bytes,
          "saved repair starts an explicitly absent job once, reads its pid back and preserves its connection")

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
    check('record-dist.sh copy "Studio Launcher KH"' in (packaging / "build-launcher.sh").read_text()
          and (packaging / "record-dist.sh").stat().st_mode & 0o111,
          "every packaged DMG is written into dist/ by the build itself, not by remembering")
    check(not (packaging / "build-app.sh").exists() and not (ROOT / "App/main.swift").exists(),
          "Update Studio KH.app stays retired into Studio Launcher KH: one GUI app, one DMG")
    # A copy is a build step, not the accepted-release step: two builds of one version both copy, and
    # a copy evicts nothing. It called rotate until 0.1.82, so the second build of a version refused
    # with "was placed with different bytes" — twice, one gate each time (row 20261125-12).
    rec = work / "dist-repo"
    (rec / "packaging").mkdir(parents=True)
    shutil.copyfile(packaging / "record-dist.sh", rec / "packaging/record-dist.sh")
    shutil.copyfile(packaging / "retain-release.sh", rec / "packaging/retain-release.sh")
    for script in ("record-dist.sh", "retain-release.sh"):
        (rec / "packaging" / script).chmod(0o755)
    (rec / "dist").mkdir()
    ledger = rec / "dist/.release-dist.json"
    ledger.write_text('{"schema": 1, "apps": {}}')
    (rec / "dist/Studio Launcher KH-0.1.79.dmg").write_text("older-79")
    (rec / "dist/Studio Launcher KH-0.1.81.dmg").write_text("older-81")
    env = {**os.environ, "KHU_TRASH": str(work / "dist-trash")}
    def rec_run(*args):
        return subprocess.run(["bash", str(rec / "packaging/record-dist.sh"), *args],
                              capture_output=True, text=True, env=env)
    def rec_copy(body):
        (work / "b.dmg").write_text(body)
        return rec_run("copy", "Studio Launcher KH", "0.1.82", str(work / "b.dmg"))
    seeded = rec_run("rotate", "Studio Launcher KH", "0.1.81")
    ledger_before_copy = ledger.read_text()
    first = rec_copy("first build")
    second = rec_copy("second build")
    check(seeded.returncode == 0 and first.returncode == 0 and second.returncode == 0
          and (rec / "dist/Studio Launcher KH-0.1.82.dmg").read_text() == "second build"
          and (rec / "dist/Studio Launcher KH-0.1.79.dmg").exists()
          and ledger.read_text() == ledger_before_copy,
          "two builds of one version both copy, evict nothing and never rotate (rc=%d/%d/%d %s)"
          % (seeded.returncode, first.returncode, second.returncode,
             (seeded.stderr + first.stderr + second.stderr).strip()[:90]))
    accepted = rec_run("rotate", "Studio Launcher KH", "0.1.82")
    ledger_after_rotate = ledger.read_text()
    third = rec_copy("third build after rotate")
    check(accepted.returncode == 0 and third.returncode == 0
          and not (rec / "dist/Studio Launcher KH-0.1.79.dmg").exists()
          and (rec / "dist/Studio Launcher KH-0.1.81.dmg").exists()
          and (rec / "dist/Studio Launcher KH-0.1.82.dmg").read_text() == "third build after rotate"
          and ledger.read_text() == ledger_after_rotate,
          "rotate keeps the latest two and a later copy with new bytes still succeeds (rc=%d/%d %s)"
          % (accepted.returncode, third.returncode, (accepted.stderr + third.stderr).strip()[:90]))
    rotation = work / "rotation"
    rotation.mkdir()
    for name in ["Studio-Launcher-KH-0.1.18.dmg", "Studio-Launcher-KH-0.1.39.dmg", "Studio-Launcher-KH-0.1.40.dmg",
                 "Update-Studio-KH-1.0.21.dmg", "Update-Studio-KH-1.0.39.dmg", "Update-Studio-KH-1.0.41.dmg"]:
        (rotation / name).write_text("dmg")
    (rotation / "khu").write_text("binary")
    (rotation / "launcher-kit").mkdir()
    rotate = packaging / "rotate-build.py"
    result = subprocess.run([sys.executable, "-I", str(rotate), "--dir", str(rotation),
                             "--trash", str(work / "rotation-trash")], capture_output=True, text=True)
    check(result.returncode == 0, "rotate-build runs on a build folder")
    left = sorted(p.name for p in rotation.iterdir())
    check(left == ["Studio-Launcher-KH-0.1.39.dmg", "Studio-Launcher-KH-0.1.40.dmg",
                   "Update-Studio-KH-1.0.39.dmg", "Update-Studio-KH-1.0.41.dmg", "khu", "launcher-kit"],
          "build keeps the latest two DMGs per app and nothing else is touched")
    trash = sorted(p.name for p in (work / "rotation-trash").glob("build-history-*/*"))
    check(trash == ["Studio-Launcher-KH-0.1.18.dmg", "Update-Studio-KH-1.0.21.dmg"],
          "older installers are retired recoverably to _trash")
    again = subprocess.run([sys.executable, "-I", str(rotate), "--dir", str(rotation),
                            "--trash", str(work / "rotation-trash")], capture_output=True, text=True)
    check(again.returncode == 0 and len(list((work / "rotation-trash").glob("build-history-*"))) == 1,
          "a second rotation moves nothing and adds no folder")
    check("rotate-build.py build" in (packaging / "build-launcher.sh").read_text(),
          "every release build rotates its own build folder")

    # The `updater` feed entry is the helper sealed in the Launcher: publishing a path someone built
    # at another time once offered a binary no build produced (2026-11-17), so the path is resolved.
    sealed_tool = packaging / "sealed-helper.sh"
    check(sealed_tool.stat().st_mode & 0o111
          and 'sealed-helper.sh "$VERSION"' in (packaging / "release-push.sh").read_text(),
          "release-push resolves the updater helper from the sealed launcher instead of trusting a path")
    sealed_repo = work / "sealed-repo"
    (sealed_repo / "packaging").mkdir(parents=True)
    shutil.copyfile(sealed_tool, sealed_repo / "packaging/sealed-helper.sh")
    (sealed_repo / "packaging/sealed-helper.sh").chmod(0o755)
    missing = subprocess.run(["bash", str(sealed_repo / "packaging/sealed-helper.sh"), "0.1.54"],
                             capture_output=True, text=True)
    check(missing.returncode == 2 and "no sealed helper" in missing.stderr,
          "with no built bundle and no DMG it refuses instead of guessing (rc=%d)" % missing.returncode)
    helper = sealed_repo / "build/Studio Launcher KH.app/Contents/Resources/khu-agent/bin/khu"
    helper.parent.mkdir(parents=True)
    helper.write_text("sealed helper")
    helper.chmod(0o755)
    found = subprocess.run(["bash", str(sealed_repo / "packaging/sealed-helper.sh"), "0.1.54"],
                           capture_output=True, text=True)
    check(found.returncode == 0 and found.stdout.strip() == "build/Studio Launcher KH.app/Contents/Resources/khu-agent/bin/khu",
          "inside a built tree it names the helper the DMG ships (%s)" % (found.stdout.strip() or found.stderr.strip()))
    # 1301 is not a release host (owner 2026-11-23): release-push publishes nowhere. It resolves
    # the sealed helper and puts the artifact in the app's own repo, which is what these fixtures
    # exercise — a fake gh that stores what it is given and reports it the way GitHub does.
    import hashlib
    import http.server
    import threading
    dmg, changelog = work / "push.dmg", work / "push.md"
    dmg.write_text("dmg")
    changelog.write_text("changes")
    # The body is a two-or-three-sentence summary the releaser writes, not the changelog
    # (RELEASE-POLICY; owner 2026-11-24). 0.1.82 shipped the whole file and put 70,801
    # characters on the Launcher card (measured 2026-11-25).
    summary = work / "push-SUMMARY.txt"
    summary.write_text("This version stops the queue remembering finished rows.\n")
    gh_state = work / "push-gh-state"
    gh_state.mkdir()
    push_gh_calls, push_order = work / "push-gh-calls", work / "push-order"
    push_gh = fake_bin / "gh"
    push_gh.write_text(r'''#!/usr/bin/env python3
import hashlib, json, os, sys
STATE = os.environ["FAKE_GH_STATE"]
args = sys.argv[1:]
open(os.environ["FAKE_GH_CALLS"], "a").write("\t".join(args) + "\n")
def rels():
    p = os.path.join(STATE, "releases.json")
    return json.load(open(p)) if os.path.exists(p) else []
def save(r): json.dump(r, open(os.path.join(STATE, "releases.json"), "w"))
def asset(path):
    data = open(path, "rb").read()
    digest = hashlib.sha256(b"corrupt" if os.environ.get("FAKE_GH_CORRUPT") else data).hexdigest()
    return {"name": os.path.basename(path), "size": len(data),
            "digest": "" if os.environ.get("FAKE_GH_NO_DIGEST") else "sha256:" + digest}
if args[0] == "api":
    tag = args[1].rsplit("/", 1)[-1]
    found = [r for r in rels() if r["tag"] == tag]
    if not found:
        # Real gh prints the API error body on stdout and still exits non-zero.
        print(json.dumps({"message": "Not Found", "status": "404"})); sys.exit(1)
    print(json.dumps({"tag": tag, "draft": found[0]["draft"], "assets": found[0]["assets"]}))
elif args[0] == "release" and args[1] in ("create", "upload"):
    tag = args[2]
    # A flag's value is not an artifact: `--notes-file <path>` carries the body, and reading it as
    # one more asset would hide whatever the wrapper actually wrote there.
    files, notes, i = [], None, 3
    while i < len(args):
        a = args[i]
        if a == "--notes-file":
            notes = open(args[i + 1]).read(); i += 2; continue
        if a == "--notes":
            notes = args[i + 1]; i += 2; continue
        if a == "--title":
            i += 2; continue
        if not a.startswith("-") and os.path.exists(a):
            files.append(a)
        i += 1
    open(os.environ["FAKE_GH_ORDER"], "a").write(args[1] + "\n")
    releases = rels()
    found = [r for r in releases if r["tag"] == tag]
    if found:
        found[0]["assets"] += [asset(f) for f in files]
    else:
        releases.append({"tag": tag, "draft": bool(os.environ.get("FAKE_GH_DRAFT")),
                         "assets": [asset(f) for f in files], "notes": notes})
    save(releases)
elif args[0] == "repo" and args[1] == "view":
    # `--jq .visibility` prints the bare value, which is what the check reads.
    print(os.environ.get("FAKE_GH_VISIBILITY", "PUBLIC"))
elif args[0] == "release" and args[1] == "view":
    tag = args[2]
    found = [r for r in rels() if r["tag"] == tag]
    if not found:
        sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
    print(json.dumps({"isDraft": found[0]["draft"], "assets": found[0]["assets"]}))
else:
    sys.stderr.write("fake gh: unsupported " + " ".join(args) + "\n"); sys.exit(2)
''')
    push_gh.chmod(0o755)
    # The helper fetches the asset back the way a client does, so the fixture serves the release
    # path over loopback: the download check is the one that proves a stranger can install it.
    gh_serve = work / "push-gh-serve"
    sha = hashlib.sha256(b"dmg").hexdigest()
    asset_name = sha[:12] + "-push.dmg"
    asset_path = gh_serve / "theng12/push-app/releases/download/gateway-9.9.9" / asset_name
    asset_path.parent.mkdir(parents=True)
    asset_path.write_text("dmg")
    # A scan receipt is a file carrying the artifact's sha and a verdict, never a sentence in a
    # message (row 20261123-131).
    receipt = work / "push-SCAN.txt"
    receipt.write_text('scan-receipt {"sha256": "%s", "exit": 0}\nSCAN_EXIT=0\n' % sha)

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), lambda *a, **k: Quiet(*a, directory=str(gh_serve), **k))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    asset_url = ("http://127.0.0.1:%d/theng12/push-app/releases/download/gateway-9.9.9/%s"
                 % (server.server_address[1], asset_name))
    push_env = {**fake_env, "KHU_PUBLIC_REPO": "theng12/push-app",
                "KHU_ASSET_BASE": "http://127.0.0.1:%d" % server.server_address[1],
                "FAKE_GH_STATE": str(gh_state), "FAKE_GH_CALLS": str(push_gh_calls),
                "FAKE_GH_ORDER": str(push_order)}
    push = packaging / "release-push.sh"
    gh_asset = packaging / "github-asset.sh"

    def push_run(extra_args=(), **extra):
        for path in (push_gh_calls, push_order):
            if path.exists():
                path.unlink()
        (gh_state / "releases.json").write_text("[]")
        env = {**push_env, **extra}
        env = {k: v for k, v in env.items() if v is not None}
        return run(push, "gateway", "9.9.9", dmg, changelog, "--scan-receipt", receipt,
                   "--summary", summary, *extra_args, env=env)

    result = push_run()
    check(result.returncode == 0 and asset_url in result.stdout,
          "release-push uploads to the app's own repo and prints the address (rc=%d)" % result.returncode)
    check(push_order.exists() and push_order.read_text().split() == ["create"],
          "the release is created, and nothing else is written (%r)"
          % (push_order.read_text().split() if push_order.exists() else []))
    check(push_gh_calls.exists() and "--notes-file" in push_gh_calls.read_text(),
          "the release body comes from a file, not a placeholder line the card would show")

    # The body is the summary, never the changelog: the feed row is composed from it, so a copy of
    # the file lands on the owner's card.
    changelog.write_text("# Title\n\n## 9.9.9 — 2026-11-25\n- this release\n- another row\n")
    result = push_run()
    notes = json.loads((gh_state / "releases.json").read_text())[0]["notes"]
    check(result.returncode == 0 and "another row" not in notes
          and notes.strip() == summary.read_text().strip(),
          "the body is the summary, not the changelog entry (%d chars)" % len(notes))
    changelog.write_text("changes")  # the runs below are about the gate line, not the body source

    result = push_run(("--summary", str(work / "no-summary-given")))
    check(result.returncode == 2 and "no such summary" in result.stderr,
          "a summary path that names no file is refused (rc=%d)" % result.returncode)

    result = push_run(KHU_PUBLIC_REPO=None)
    check(result.returncode == 2 and "no public repo named" in result.stderr and not push_gh_calls.exists(),
          "with no repo named it refuses instead of publishing anywhere (rc=%d)" % result.returncode)

    # A receipt nobody can open is not a receipt, and one about another artifact is worse: it reads
    # as a pass. Both are refused before the release host is touched.
    result = run(push, "gateway", "9.9.9", dmg, changelog, env=push_env)
    check(result.returncode == 2 and "no scan receipt named" in result.stderr and not push_gh_calls.exists(),
          "a publish with no receipt named is refused, not assumed scanned (rc=%d)" % result.returncode)
    result = run(push, "gateway", "9.9.9", dmg, changelog, "--scan-receipt", work / "nowhere.txt", env=push_env)
    check(result.returncode == 2 and "no such scan receipt" in result.stderr and not push_gh_calls.exists(),
          "a receipt that exists only in a message is refused and named (rc=%d)" % result.returncode)
    stranger = work / "stranger-SCAN.txt"
    stranger.write_text("%s\nclean\n" % ("a" * 64))
    result = run(push, "gateway", "9.9.9", dmg, changelog, "--scan-receipt", stranger,
                 "--summary", summary, env=push_env)
    check(result.returncode == 2 and "different artifact" in result.stderr and not push_gh_calls.exists(),
          "a receipt scanned for another artifact is refused (rc=%d)" % result.returncode)
    receipt.write_text("%s\nSCAN_EXIT=0\n" % sha)

    # A private repo is the other way a publish strands every client: the release is real and the
    # anonymous fetch 404s. Refused before the upload, not after.
    result = push_run(FAKE_GH_VISIBILITY="PRIVATE")
    check(result.returncode == 2 and "not PUBLIC" in result.stderr
          and not (push_order.exists() and push_order.read_text().strip()),
          "a private repo is refused before anything is uploaded (rc=%d)" % result.returncode)

    # The gate line travels with the body, copied verbatim from the file the gate wrote. A line for
    # another app is the one way a verbatim copy still goes wrong, so it is refused.
    gate = work / "push-GATE-PASS.txt"
    gate.write_text("GATE PASS gateway f95fff15f1200f42622c751457e3104501296f21 2026-11-23T12:45:04Z\n")
    result = push_run(("--gate-line", str(gate)))
    recorded = json.loads((gh_state / "releases.json").read_text() or "[]")
    body = (recorded[0].get("notes") or "") if recorded else ""
    check(result.returncode == 0
          and body.startswith("GATE PASS gateway f95fff15f1200f42622c751457e3104501296f21 2026-11-23T12:45:04Z\n\n")
          and body.strip().endswith(summary.read_text().strip()),
          "the gate line is copied verbatim above the summary (%r)" % body[:70])

    result = push_run()
    recorded = json.loads((gh_state / "releases.json").read_text() or "[]")
    body = (recorded[0].get("notes") or "") if recorded else ""
    check(result.returncode == 0 and "GATE PASS" not in body
          and body.strip() == summary.read_text().strip(),
          "with no gate line named the body is the summary alone (%r)" % body[:70])

    wrong = work / "wrong-app-GATE-PASS.txt"
    wrong.write_text("GATE PASS storage deadbeef 2026-11-23T12:45:04Z\n")
    result = push_run(("--gate-line", str(wrong)))
    check(result.returncode == 2 and "not gateway" in result.stderr
          and not (push_order.exists() and push_order.read_text().strip()),
          "a gate line naming another app is refused, not copied (rc=%d)" % result.returncode)

    result = push_run(("--gate-line", str(work / "no-gate.txt")))
    check(result.returncode == 2 and "no such gate line" in result.stderr,
          "a gate line file that does not exist is refused (rc=%d)" % result.returncode)

    result = push_run(FAKE_GH_DRAFT="1")
    check(result.returncode != 0 and "draft" in result.stderr,
          "a draft release stops the release step (rc=%d)" % result.returncode)

    result = push_run(FAKE_GH_CORRUPT="1")
    check(result.returncode != 0 and "digest" in result.stderr,
          "bytes GitHub did not store are refused (rc=%d)" % result.returncode)

    asset_path.write_text("a different build")
    result = push_run()
    check(result.returncode != 0 and "served" in result.stderr,
          "bytes the public address does not serve are refused (rc=%d)" % result.returncode)
    asset_path.write_text("dmg")

    result = push_run(FAKE_GH_NO_DIGEST="1")
    check(result.returncode == 0 and "reported no digest" in result.stderr,
          "without a GitHub digest the fetched bytes are the proof")

    # Releases are added, never withdrawn: a rerun reuses what is there, and a release holding a
    # different artifact for the same version is left alone rather than overwritten.
    (gh_state / "releases.json").write_text(json.dumps([{"tag": "gateway-9.9.9", "draft": False,
        "assets": [{"name": asset_name, "size": 3, "digest": "sha256:" + sha}]}]))
    result = run(gh_asset, "theng12/push-app", "gateway-9.9.9", dmg, sha, "3", env=push_env)
    check(result.returncode == 0 and "nothing was re-uploaded" in result.stderr,
          "a rerun with the same bytes reuses the stored asset instead of uploading again")
    (gh_state / "releases.json").write_text(json.dumps([{"tag": "gateway-9.9.9", "draft": False,
        "assets": [{"name": "ffffffffffff-other.dmg", "size": 9, "digest": "sha256:" + "f" * 64}]}]))
    result = run(gh_asset, "theng12/push-app", "gateway-9.9.9", dmg, sha, "3", env=push_env)
    check(result.returncode == 5 and "keeps its bytes" in result.stderr,
          "a version already published with a different artifact is refused, not overwritten (rc=%d)"
          % result.returncode)

    # One release carries the Launcher DMG and the helper binary the updater row names: a second
    # asset of a different kind attaches instead of reading as a second artifact for one version.
    helper_sha = hashlib.sha256(b"khu").hexdigest()
    helper_name = helper_sha[:12] + "-khu"
    helper_path = gh_serve / "theng12/push-app/releases/download/gateway-9.9.9" / helper_name
    helper_path.write_text("khu")
    (work / "khu").write_text("khu")
    (gh_state / "releases.json").write_text(json.dumps([{"tag": "gateway-9.9.9", "draft": False,
        "assets": [{"name": asset_name, "size": 3, "digest": "sha256:" + sha}]}]))
    result = run(gh_asset, "theng12/push-app", "gateway-9.9.9", work / "khu", helper_sha, "3", env=push_env)
    check(result.returncode == 0 and helper_name in result.stdout,
          "a second asset of another kind joins the same release instead of being refused (rc=%d, %s)"
          % (result.returncode, (result.stderr or "").strip().splitlines()[-1:]))
    (gh_state / "releases.json").write_text("[]")

    if push_gh_calls.exists():
        push_gh_calls.unlink()
    result = run(gh_asset, "theng12/push-app", "gateway-9.9.9", dmg, "a" * 64, "2147483648", env=push_env)
    check(result.returncode != 0 and "2 GiB" in result.stderr and not push_gh_calls.exists(),
          "at GitHub's 2 GiB cap the upload is refused before anything moves")
    result = run(gh_asset, "theng12/push-app", "gateway-9.9.9", dmg, "b" * 64, "3", env=push_env)
    check(result.returncode != 0 and "not the signed" in result.stderr and not push_gh_calls.exists(),
          "an artifact that is not the signed one is refused before any upload")
    result = run(gh_asset, "theng12/push-app'; rm -rf /", "gateway-9.9.9", dmg, sha, "3", env=push_env)
    check(result.returncode != 0 and "may hold only" in result.stderr and not push_gh_calls.exists(),
          "a repo name a shell would read as syntax is refused, not escaped into the release host")
    result = run(gh_asset, "theng12/push-app", "gateway-9.9.9", dmg, sha, "3",
                 env={**push_env, "KHU_ASSET_BASE": "http://example.com"})
    check(result.returncode != 0 and "must be an https address" in result.stderr,
          "a cleartext address clients would refuse is refused here instead")

    # Closing the listener matters: a socket left listening with nobody accepting hangs a client.
    server.shutdown()
    server.server_close()
    # The DMG's Read Me First.txt (owner, 2026-11-23): one plain-text file at the image root whose
    # first line is the exact command, the same line the release notes and download page use.
    staging = work / "read-me-staging"
    result = subprocess.run([str(ROOT / "packaging/read-me-first.sh"), "Studio Launcher KH.app", str(staging)],
                            capture_output=True, text=True)
    read_me = staging / "Read Me First.txt"
    check(result.returncode == 0 and read_me.is_file(), "read-me-first.sh writes the file into the staging folder")
    lines = read_me.read_text().splitlines() if read_me.is_file() else []
    check(lines and lines[0] == 'xattr -dr com.apple.quarantine "/Applications/Studio Launcher KH.app"',
          "the first line is the verbatim command with the /Applications path (%r)" % (lines[0] if lines else None))
    check(len(lines) == 2 and "browser" in lines[1] and "Terminal" in lines[1],
          "one sentence follows: drag to Applications, run it in Terminal, only for a browser download")
    check(not (read_me.stat().st_mode & 0o111), "the file is not executable")
    check(not list(staging.glob("*.command")), "no double-clickable .command is shipped")
    builder = (ROOT / "packaging/build-launcher.sh").read_text()
    check(builder.index("read-me-first.sh") < builder.index("hdiutil create"),
          "the launcher's build writes it before the image is made, so every release carries it")
    result = subprocess.run([str(ROOT / "packaging/read-me-first.sh"), "NotAnApp", str(work / "x")],
                            capture_output=True, text=True)
    check(result.returncode != 0 and "ending in .app" in result.stderr,
          "a name that is not an app is refused rather than written")

    print(f"PACKAGING: {checks} passed, 0 failed")
finally:
    print(f"Temporary fixtures preserved at {work}")
