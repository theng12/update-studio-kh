"""The SSD entry checks bytes and containment before starting any executable.

It runs with the Mac's own tools only (2026-11-20): /usr/bin/python3 is absent on a fresh Mac and
asks for the Command Line Tools, so the entry is a shell script and these fakes stand in for
hdiutil and codesign on PATH.
"""
import hashlib
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENTRY = ROOT / 'packaging/update-from-ssd.sh'

HDIUTIL = """#!/bin/bash
case "$1" in
  attach) cat "$KHU_TEST_ATTACH"; exit 0 ;;
  detach) printf '%s\\n' "$2" >> "$KHU_TEST_DETACH"; exit 0 ;;
esac
exit 2
"""
CODESIGN = """#!/bin/bash
[[ -n "${KHU_TEST_BADSIG:-}" ]] && exit 1
exit 0
"""
LAUNCHER = """#!/bin/bash
printf '%s\\n' "$@" > "$KHU_TEST_LAUNCH"
printf 'changed on SSD' >> "$KHU_TEST_INDEX"
exit "${KHU_TEST_LAUNCH_EXIT:-0}"
"""


class SSDEntryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='khu-ssd-entry-')
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name).resolve()
        self.root = self.temp / 'ssd'
        self.root.mkdir()
        self.home = self.temp / 'home'
        self.home.mkdir()
        bin_dir = self.temp / 'bin'
        bin_dir.mkdir()
        for name, body in [('hdiutil', HDIUTIL), ('codesign', CODESIGN)]:
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.bin = bin_dir
        self.detach_log = self.temp / 'detach.log'
        self.launch_log = self.temp / 'launch.log'
        self.attach = self.temp / 'attach.plist'
        self.image = self.root / 'Launcher.dmg'
        self.image.write_bytes(b'verified installer fixture')
        self.row = dict(id='updater', bundleID='com.khupdater.launcher', version='0.1.11',
                        file=self.image.name, sha256=hashlib.sha256(self.image.read_bytes()).hexdigest())
        self.index()

    def index(self, rows=None):
        (self.root / 'apps.json').write_text(json.dumps(dict(format='kh.apps.v1', apps=rows or [self.row])))

    def mounted_app(self, entities=None, signature=True):
        """A volume carrying one Launcher app, and the hdiutil reply that describes it."""
        mount = self.temp / 'mounted'
        app = mount / 'Launcher.app'
        (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
        launcher = app / 'Contents/MacOS/Launcher'
        launcher.write_text(LAUNCHER)
        launcher.chmod(0o755)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier='com.khupdater.launcher', CFBundleShortVersionString='0.1.11',
            CFBundleExecutable='Launcher')))
        if entities is None:
            entities = [{'dev-entry': '/dev/disk987'}, {'dev-entry': '/dev/disk987s1'},
                        {'dev-entry': '/dev/disk987s1', 'mount-point': str(mount)}]
        self.attach.write_bytes(plistlib.dumps({'system-entities': entities}))
        return app

    def run_entry(self, extra=None):
        env = {'HOME': str(self.home), 'PATH': f'{self.bin}:/usr/bin:/bin',
               'KHU_TEST_ATTACH': str(self.attach), 'KHU_TEST_DETACH': str(self.detach_log),
               'KHU_TEST_LAUNCH': str(self.launch_log), 'KHU_TEST_INDEX': str(self.root / 'apps.json'),
               'TMPDIR': str(self.temp)}
        env.update(extra or {})
        return subprocess.run(['/bin/bash', str(ENTRY), str(self.root)],
                              capture_output=True, text=True, env=env, timeout=120)

    def detaches(self):
        return self.detach_log.read_text().split() if self.detach_log.exists() else []

    def test_verified_installer_runs_with_the_verified_index_hash(self):
        self.mounted_app()
        pin = hashlib.sha256((self.root / 'apps.json').read_bytes()).hexdigest()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.launch_log.read_text().split(),
                         ['ssd-update', '--volume', str(self.root), '--index-sha256', pin])
        self.assertEqual(self.detaches(), ['/dev/disk987s1'])
        copies = list((self.home / 'Library/KHUpdater/state/_trash').glob('ssd-bootstrap-*/Launcher.dmg'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_bytes(), self.image.read_bytes())

    def test_changed_bytes_refused(self):
        self.mounted_app()
        self.image.write_bytes(b'changed')
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        self.assertIn('checksum does not match', result.stderr)
        self.assertFalse(self.launch_log.exists())

    def test_duplicate_launcher_refused(self):
        self.index([self.row, self.row])
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        self.assertIn('exactly one', result.stderr)

    def test_symlink_escape_refused(self):
        outside = self.temp / 'outside.dmg'
        outside.write_bytes(self.image.read_bytes())
        (self.root / 'link.dmg').symlink_to(outside)
        self.row['file'] = 'link.dmg'
        self.index()
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        self.assertIn('on this SSD', result.stderr)

    def test_bad_mount_layout_detaches_only_its_device(self):
        self.attach.write_bytes(plistlib.dumps({'system-entities': [
            {'dev-entry': '/dev/disk987'}, {'mount-point': '/Volumes/first'}, {'mount-point': '/Volumes/second'}]}))
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        self.assertIn('one mounted volume and device', result.stderr)
        self.assertEqual(self.detaches(), ['/dev/disk987'])
        self.assertFalse(self.launch_log.exists())

    def test_mount_path_cannot_be_used_as_device(self):
        self.attach.write_bytes(plistlib.dumps({'system-entities': [
            {'dev-entry': '/dev/disk987'}, {'dev-entry': '/Volumes/KH-STUDIO-ATLAS', 'mount-point': '/Volumes/fixture'}]}))
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        self.assertIn('one mounted volume and device', result.stderr)
        self.assertEqual(self.detaches(), ['/dev/disk987'])

    def test_signature_failure_detaches_by_device(self):
        # A synthesized APFS whole disk must never be the thing that is detached.
        self.mounted_app()
        result = self.run_entry({'KHU_TEST_BADSIG': '1'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('not signed', result.stderr)
        self.assertEqual(self.detaches(), ['/dev/disk987s1'])
        self.assertFalse(self.launch_log.exists())

    def test_wrong_version_refused(self):
        self.mounted_app()
        self.row['version'] = '9.9'
        self.index()
        result = self.run_entry()
        self.assertEqual(result.returncode, 1)
        self.assertIn('identity or version', result.stderr)


if __name__ == '__main__':
    unittest.main()
