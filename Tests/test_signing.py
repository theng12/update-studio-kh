#!/usr/bin/env python3
"""Packaging order and refusal checks with fake tools; no keys or installed apps."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="khu-signing-"))
        self.repo = self.work / "repo"
        self.repo.mkdir()
        for name in ("build.sh", "CHANGELOG.md", "CHANGELOG-launcher.md",
                     "packaging/build-launcher.sh", "packaging/build-agent-kit.sh",
                     "packaging/install-agent.sh", "packaging/rotate-build.py", "packaging/fleet-roster.json",
                     "packaging/read-me-first.sh",
                     "packaging/generate-ui.py", "packaging/shared-ui/whats-new.py",
                     "packaging/shared-ui/design-tokens.json", "packaging/shared-ui/UI-CONVENTIONS.md",
                     "packaging/com.khupdater.agent.plist", "examples/agent-config.json"):
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
            target.chmod(0o755)
        # The dist copy step is stubbed here: this fixture stubs hdiutil, so no DMG is written,
        # and signing is what this file is about. Packaging's own suite covers the real script.
        stub = self.repo / "packaging/record-dist.sh"
        stub.write_text("#!/bin/bash\nexit 0\n")
        stub.chmod(0o755)
        tools = self.work / "tools"
        tools.mkdir()
        self.calls = self.work / "calls"
        self.env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                    "SIGN_CALLS": str(self.calls), "KHU_SIGN_IDENTITY": "Fixture Identity"}
        scripts = {
            "swiftc": 'while [[ $# -gt 0 ]]; do if [[ "$1" == -o ]]; then shift; touch "$1"; fi; shift; done',
            "lipo": 'if [[ "$1" == -archs ]]; then printf "arm64 x86_64\\n"; else while [[ $# -gt 0 ]]; do if [[ "$1" == -output ]]; then shift; touch "$1"; fi; shift; done; fi',
            "codesign": 'printf "%s\\t" "$@" >> "$SIGN_CALLS"; printf "\\n" >> "$SIGN_CALLS"; if [[ "$1" == --force && -f "${!#}" ]]; then printf signed >> "${!#}"; fi; if [[ "$1" == --force && -n "${TAMPER_KIT:-}" && -d "${!#}" ]]; then printf changed >> "${!#}/Contents/Resources/khu-agent/bin/khu"; fi',
            "hdiutil": 'printf "hdiutil\\n" >> "$SIGN_CALLS"',
        }
        for name, body in scripts.items():
            script = tools / name
            script.write_text('#!/bin/bash\nset -e\n' + body + '\n')
            script.chmod(0o755)

    def tearDown(self):
        trash = Path(tempfile.gettempdir()) / "_trash"
        trash.mkdir(exist_ok=True)
        self.work.rename(trash / (self.work.name + "." + uuid.uuid4().hex))

    def run_script(self, script, *args, **env):
        return subprocess.run(["/bin/bash", str(self.repo / script), *args],
                              env={**self.env, **env}, capture_output=True, text=True)

    def launcher(self, publisher=None, *extra, **env):
        build = self.repo / "build"
        build.mkdir(exist_ok=True)
        helper = build / "khu"
        helper.write_text('''#!/bin/bash
set -e
[[ "$1" == launcher-bundle ]]
out="$3"; kit="$7"
mkdir -p "$out/Contents/Resources" "$out/Contents/MacOS"
cp -R "$kit" "$out/Contents/Resources/khu-agent"
cp "$0" "$out/Contents/MacOS/StudioLauncher"
''')
        helper.chmod(0o755)
        (build / "khu-stub").write_text("signed fixture stub")
        (build / "khu-stub").chmod(0o755)
        pub = self.work / "publisher.json"
        pub.write_text(json.dumps(publisher or {}))
        return self.run_script("packaging/build-launcher.sh", "0.1.99", str(pub), *extra, **env)

    def test_raw_binaries_signed_after_merge(self):
        result = self.run_script("build.sh", "build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.calls.exists(), "raw artifacts must be signed")
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 4)
        for name in ("khu", "khu-stub"):
            self.assertEqual((self.repo / "build" / name).read_text(), "signed")
        self.assertTrue(all("Fixture Identity" in c for c in calls if c.startswith("--force")))
        self.assertTrue(all("--deep" not in c for c in calls))

    def test_ad_hoc_refused_before_artifact_changes(self):
        for script in ("build.sh", "packaging/build-launcher.sh"):
            result = self.run_script(script, "0.1.99", KHU_SIGN_IDENTITY="-")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("stable signing identity", result.stderr)
            self.assertFalse((self.repo / "build").exists())
        self.assertFalse(self.calls.exists())

    def test_outer_seal_preserves_pinned_bytes(self):
        result = self.launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        signing = [c for c in calls if c.startswith("--force")]
        self.assertEqual(len(signing), 1)
        self.assertIn("Fixture Identity", signing[0])
        self.assertTrue(all("--deep" not in call for call in calls))
        self.assertEqual(calls[-1], "hdiutil")
        kit = self.repo / "build/Studio Launcher KH.app/Contents/Resources/khu-agent"
        self.assertEqual((kit / "bin/khu-stub").read_text(), "signed fixture stub")
        pins = json.loads((kit / "MANIFEST.json").read_text())["files"]
        self.assertIn("bin/khu", pins)
        roster = (ROOT / "packaging/fleet-roster.json").read_bytes()
        self.assertEqual((kit / "fleet-roster.json").read_bytes(), roster)
        self.assertEqual(pins["fleet-roster.json"], {"bytes": len(roster), "sha256": hashlib.sha256(roster).hexdigest()})

    def test_shipped_kit_keeps_the_key_but_not_the_address(self):
        # A DMG anyone can download must not hand out the publisher's machine name.
        publisher = {"feedURL": "http://100.64.0.7:8790/release.json",
                     "enrolURL": "http://100.64.0.7:8790/enrol",
                     "publicKey": "fixture-key", "testAuthority": False}
        result = self.launcher(publisher)
        self.assertEqual(result.returncode, 0, result.stderr)
        kit = self.repo / "build/Studio Launcher KH.app/Contents/Resources/khu-agent"
        record = json.loads((kit / "publisher.json").read_text())
        self.assertEqual(record, {"publicKey": "fixture-key", "testAuthority": False})
        self.assertNotIn("8790", (kit / "publisher.json").read_text())

    def test_kit_address_kept_only_when_asked(self):
        publisher = {"feedURL": "http://100.64.0.7:8790/release.json",
                     "enrolURL": "http://100.64.0.7:8790/enrol", "publicKey": "fixture-key"}
        result = self.launcher(publisher, "--kit-address")
        self.assertEqual(result.returncode, 0, result.stderr)
        kit = self.repo / "build/Studio Launcher KH.app/Contents/Resources/khu-agent"
        self.assertEqual(json.loads((kit / "publisher.json").read_text()), publisher)

    def test_changed_kit_refused_before_dmg(self):
        result = self.launcher(TAMPER_KIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signing changed a pinned kit file", result.stderr)
        self.assertNotIn("hdiutil", self.calls.read_text())

    def test_failed_create_names_the_image(self):
        fake = self.work / "tools" / "hdiutil"
        fake.write_text('#!/bin/bash\nprintf "hdiutil %s\\n" "$1" >> "$SIGN_CALLS"\n'
                        'if [[ "$1" == create ]]; then echo "hdiutil: create failed - Disk Full" >&2; exit 1; fi\n'
                        'exit 0\n')
        fake.chmod(0o755)
        result = self.launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hdiutil create failed", result.stderr)
        self.assertIn("Studio-Launcher-KH-0.1.99.dmg", result.stderr)
        self.assertIn("Disk Full", result.stderr)

    def test_truncated_image_refused_before_record(self):
        # create exits 0 but the image is not whole: the build must stop before it is recorded.
        fake = self.work / "tools" / "hdiutil"
        fake.write_text('#!/bin/bash\nprintf "hdiutil %s\\n" "$1" >> "$SIGN_CALLS"\n'
                        '[[ "$1" != verify ]]\n')
        fake.chmod(0o755)
        recorded = self.repo / "packaging/record-dist.sh"
        recorded.write_text('#!/bin/bash\nprintf "record-dist\\n" >> "$SIGN_CALLS"\n')
        recorded.chmod(0o755)
        result = self.launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hdiutil verify failed", result.stderr)
        self.assertIn("Studio-Launcher-KH-0.1.99.dmg", result.stderr)
        self.assertNotIn("record-dist", self.calls.read_text())


if __name__ == "__main__":
    unittest.main()
