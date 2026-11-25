#!/usr/bin/env python3
"""Local signed-appcast candidate tests: sealed DMG fields, local URLs, signature checks."""
import base64
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "packaging/local-appcast.py"
KEY = Path.home() / ".kh-sparkle/com.khupdater.launcher/private.key"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PUBLIC_KEY_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
EXPECTED_FINGERPRINT = "15574bae365a8c4a"


def _find_sealed_dmg():
    candidates = [ROOT / "build/Studio-Launcher-KH-0.1.83.dmg"]
    if len(ROOT.parents) > 3:
        candidates.append(ROOT.parents[3] / "app/build/Studio-Launcher-KH-0.1.83.dmg")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _build_dmg(work_dir, *, filename, app_name, bundle_id, short_version, version, min_os):
    source = work_dir / f"src-{filename}"
    app = source / f"{app_name}.app" / "Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "MacOS" / app_name).write_text("#!/bin/sh\nexit 0\n")
    (app / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": bundle_id,
                "CFBundleShortVersionString": short_version,
                "CFBundleVersion": version,
                "CFBundleDisplayName": app_name,
                "LSMinimumSystemVersion": min_os,
            }
        )
    )
    dmg = work_dir / filename
    proc = subprocess.run(
        [
            "hdiutil",
            "create",
            "-quiet",
            "-srcfolder",
            str(source),
            "-volname",
            app_name,
            "-format",
            "UDZO",
            "-o",
            str(dmg),
        ],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"hdiutil create failed: {proc.stderr.decode(errors='replace')}")
    return dmg


def pinned_public_key():
    text = (ROOT / "Sources/khu/Launcher.swift").read_text()
    match = re.search(r'publicEDKey\s*=\s*"([A-Za-z0-9+/=]+)"', text)
    if not match:
        raise AssertionError("no pinned publicEDKey in Launcher.swift")
    return base64.b64decode(match.group(1), validate=True)


def openssl_verify(dmg, signature, public_key):
    with tempfile.TemporaryDirectory(prefix="kh-local-appcast-verify-") as temp:
        sig_path = Path(temp) / "signature.bin"
        sig_path.write_bytes(signature)
        sig_path.chmod(0o600)
        proc = subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-verify",
                "-rawin",
                "-inkey",
                "/dev/stdin",
                "-keyform",
                "DER",
                "-pubin",
                "-in",
                str(dmg),
                "-sigfile",
                str(sig_path),
            ],
            input=PUBLIC_KEY_DER_PREFIX + public_key,
            capture_output=True,
        )
    return proc.returncode == 0


class LocalAppcastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not KEY.is_file():
            raise unittest.SkipTest(f"Launcher key missing: {KEY}")
        cls._class_temp = None
        found = _find_sealed_dmg()
        if found is not None:
            cls.sealed_dmg = found
        else:
            cls._class_temp = tempfile.TemporaryDirectory(prefix="kh-local-appcast-cls-")
            cls.sealed_dmg = _build_dmg(
                Path(cls._class_temp.name),
                filename="Studio-Launcher-KH-0.1.83.dmg",
                app_name="Studio Launcher KH",
                bundle_id="com.khupdater.launcher",
                short_version="0.1.83",
                version="0.1.83",
                min_os="13.0",
            )
        cls.public_key = pinned_public_key()
        cls.public_fingerprint = hashlib.sha256(cls.public_key).hexdigest()[:16]

    @classmethod
    def tearDownClass(cls):
        if cls._class_temp is not None:
            cls._class_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kh-local-appcast-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def run_generator(self, *extra, dmg=None):
        if dmg is None:
            dmg = self.sealed_dmg
        out = self.work / "candidate.xml"
        proc = subprocess.run(
            [sys.executable, "-I", str(GENERATOR), "--dmg", str(dmg), "--out", str(out), *extra],
            capture_output=True,
        )
        summary = json.loads(proc.stderr) if proc.returncode == 0 and proc.stderr else None
        return proc, out, summary

    def make_fake_dmg(self):
        dmg = _build_dmg(
            self.work,
            filename="fake-0.9.9.dmg",
            app_name="Fake Launcher",
            bundle_id="com.fixture.appcast",
            short_version="0.9.9",
            version="0.9.9",
            min_os="14.0",
        )
        self.assertTrue(dmg.is_file(), f"fake DMG not created: {dmg}")
        return dmg

    def test_candidate_from_sealed_dmg_uses_file_url_and_pinned_key(self):
        proc, out, summary = self.run_generator()
        self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors="replace"))
        self.assertEqual(proc.stdout, b"")
        self.assertIsNotNone(summary, proc.stderr.decode(errors="replace"))
        self.assertEqual(summary["bundleId"], "com.khupdater.launcher")
        self.assertEqual(summary["shortVersion"], "0.1.83")
        self.assertEqual(summary["version"], "0.1.83")
        self.assertEqual(summary["minimumSystemVersion"], "13.0")
        self.assertEqual(summary["filename"], self.sealed_dmg.name)
        self.assertEqual(summary["bytes"], self.sealed_dmg.stat().st_size)
        self.assertEqual(summary["fingerprint"], EXPECTED_FINGERPRINT)
        self.assertEqual(summary["fingerprint"], self.public_fingerprint)
        digest = hashlib.sha256()
        with self.sealed_dmg.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
        self.assertEqual(summary["sha256"], digest.hexdigest())
        self.assertEqual(summary["url"], self.sealed_dmg.as_uri())
        self.assertEqual(stat.S_IMODE(KEY.stat().st_mode), 0o600)

        root = ET.parse(out).getroot()
        self.assertEqual(root.tag, "rss")
        self.assertEqual(root.get("version"), "2.0")
        enclosure = root.find(".//enclosure")
        self.assertIsNotNone(enclosure)
        self.assertEqual(enclosure.get("url"), self.sealed_dmg.as_uri())
        self.assertEqual(enclosure.get("length"), str(self.sealed_dmg.stat().st_size))
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(f"{{{SPARKLE_NS}}}version"), "0.1.83")
        self.assertEqual(enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString"), "0.1.83")
        signature = base64.b64decode(enclosure.get(f"{{{SPARKLE_NS}}}edSignature"), validate=True)
        self.assertEqual(len(signature), 64)
        self.assertTrue(openssl_verify(self.sealed_dmg, signature, self.public_key))

        item = root.find(".//item")
        self.assertIsNotNone(item)
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}version"), "0.1.83")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}shortVersionString"), "0.1.83")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion"), "13.0")

    def test_local_http_url_is_used_for_enclosure(self):
        local_url = "http://127.0.0.1:18080/Studio-Launcher-KH-0.1.83.dmg"
        proc, out, summary = self.run_generator("--url", local_url)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors="replace"))
        self.assertEqual(summary["url"], local_url)
        enclosure = ET.parse(out).getroot().find(".//enclosure")
        self.assertEqual(enclosure.get("url"), local_url)

    def test_fields_come_from_dmg_not_checkout(self):
        fake_dmg = self.make_fake_dmg()
        local_url = "http://127.0.0.1:18080/fake-0.9.9.dmg"
        proc, out, summary = self.run_generator("--url", local_url, dmg=fake_dmg)
        self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors="replace"))
        self.assertEqual(summary["bundleId"], "com.fixture.appcast")
        self.assertEqual(summary["shortVersion"], "0.9.9")
        self.assertEqual(summary["version"], "0.9.9")
        self.assertEqual(summary["minimumSystemVersion"], "14.0")
        self.assertEqual(summary["filename"], fake_dmg.name)
        self.assertEqual(summary["url"], local_url)
        enclosure = ET.parse(out).getroot().find(".//enclosure")
        self.assertEqual(enclosure.get(f"{{{SPARKLE_NS}}}version"), "0.9.9")
        self.assertEqual(enclosure.get(f"{{{SPARKLE_NS}}}shortVersionString"), "0.9.9")
        signature = base64.b64decode(enclosure.get(f"{{{SPARKLE_NS}}}edSignature"), validate=True)
        self.assertTrue(openssl_verify(fake_dmg, signature, self.public_key))

    def test_tampered_signature_is_rejected(self):
        proc, out, _ = self.run_generator()
        self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors="replace"))
        enclosure = ET.parse(out).getroot().find(".//enclosure")
        signature = bytearray(base64.b64decode(enclosure.get(f"{{{SPARKLE_NS}}}edSignature")))
        signature[-1] ^= 1
        self.assertFalse(openssl_verify(self.sealed_dmg, bytes(signature), self.public_key))

    def test_key_must_be_mode_0600(self):
        bad_key = self.work / "bad.key"
        seed = base64.b64encode(bytes(range(32))).decode("ascii")
        bad_key.write_text(seed)
        bad_key.chmod(0o644)
        proc, out, summary = self.run_generator("--key", str(bad_key))
        self.assertEqual(proc.returncode, 2)
        self.assertIsNone(summary)
        self.assertFalse(out.exists())
        text = (proc.stdout + proc.stderr).decode(errors="replace")
        self.assertIn("must be mode 0600", text)
        self.assertNotIn(seed, text)

    def test_wrong_key_fingerprint_is_refused(self):
        wrong_key = self.work / "wrong.key"
        seed = base64.b64encode(bytes(range(32))).decode("ascii")
        wrong_key.write_text(seed)
        wrong_key.chmod(0o600)
        proc, out, summary = self.run_generator("--key", str(wrong_key))
        self.assertEqual(proc.returncode, 2)
        self.assertIsNone(summary)
        self.assertFalse(out.exists())
        text = (proc.stdout + proc.stderr).decode(errors="replace")
        self.assertIn(EXPECTED_FINGERPRINT, text)
        self.assertNotIn(seed, text)


if __name__ == "__main__":
    unittest.main()
