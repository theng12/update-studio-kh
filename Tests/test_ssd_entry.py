"""The SSD entry checks bytes and containment before starting any executable."""
import hashlib
import importlib.util
import json
import plistlib
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ssd_entry', Path(__file__).resolve().parents[1] / 'packaging/update-from-ssd.py')
ENTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENTRY)


class SSDEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='khu-ssd-entry-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.image = self.root / 'Launcher.dmg'
        self.image.write_bytes(b'verified installer fixture')
        self.row = dict(id='updater', bundleID='com.khupdater.launcher', version='0.1.11', file=self.image.name,
                        sha256=hashlib.sha256(self.image.read_bytes()).hexdigest())
        self.index()

    def index(self, rows=None):
        (self.root / 'apps.json').write_text(json.dumps(dict(format='kh.apps.v1', apps=rows or [self.row])))

    def test_mounted_installer_detaches_by_device_after_signature_failure(self):
        mount = self.root / 'mounted'
        app = mount / 'Launcher.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/Launcher').write_bytes(b'fixture executable')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.khupdater.launcher', CFBundleShortVersionString='0.1.11', CFBundleExecutable='Launcher')))
        attachment = plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk987'}, {'dev-entry': '/dev/disk987s1', 'mount-point': str(mount)}]})
        for signature_ok in [True, False]:
            def run(command, **kwargs):
                if command[1] == 'attach':
                    return subprocess.CompletedProcess(command, 0, stdout=attachment)
                if command[0] == '/usr/bin/codesign' and not signature_ok:
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0)
            with patch.object(ENTRY.subprocess, 'run', side_effect=run) as calls:
                if signature_ok:
                    self.assertEqual(ENTRY.run_launcher(self.root, self.image, '0.1.11', 'fixture-index-pin'), 0)
                else:
                    with self.assertRaises(subprocess.CalledProcessError):
                        ENTRY.run_launcher(self.root, self.image, '0.1.11', 'fixture-index-pin')
                detaches = [call.args[0] for call in calls.call_args_list if call.args[0][:2] == ['/usr/bin/hdiutil', 'detach']]
                self.assertEqual(detaches, [['/usr/bin/hdiutil', 'detach', '/dev/disk987']])

    def test_bad_mount_layout_detaches_only_its_device(self):
        attachment = plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk987'}, {'mount-point': '/Volumes/first'}, {'mount-point': '/Volumes/second'}]})
        with patch.object(ENTRY.subprocess, 'run', side_effect=[subprocess.CompletedProcess([], 0, stdout=attachment), subprocess.CompletedProcess([], 0)]) as calls:
            with self.assertRaisesRegex(ValueError, 'one mounted volume and device'):
                ENTRY.run_launcher(self.root, self.image, '0.1.11', 'fixture-index-pin')
            self.assertEqual(calls.call_args_list[-1].args[0], ['/usr/bin/hdiutil', 'detach', '/dev/disk987'])

    def test_verified_installer(self):
        self.assertEqual(ENTRY.launcher_image(self.root), (self.image, '0.1.11', self.row['sha256']))

    def test_copy_rejects_changed_source_after_initial_check(self):
        image, _, pin = ENTRY.launcher_image(self.root)
        image.write_bytes(b'changed after checksum')
        with self.assertRaisesRegex(ValueError, 'changed while copying'):
            ENTRY.verified_copy(image, pin, self.root / 'private-copy')

    def test_private_copy_survives_later_ssd_change(self):
        image, _, pin = ENTRY.launcher_image(self.root)
        local = ENTRY.verified_copy(image, pin, self.root / 'private-copy')
        image.write_bytes(b'changed on SSD')
        self.assertEqual(hashlib.sha256(local.read_bytes()).hexdigest(), pin)
        self.assertEqual(local.parent.stat().st_mode & 0o777, 0o700)

    def test_bootstrap_passes_the_original_index_hash(self):
        pin = hashlib.sha256((self.root / 'apps.json').read_bytes()).hexdigest()
        def launch(root, image, version, index_pin):
            self.index([dict(self.row, version='9.9')])
            self.assertEqual(index_pin, pin)
            self.assertNotEqual(hashlib.sha256((root / 'apps.json').read_bytes()).hexdigest(), index_pin)
            return 0
        with patch.object(ENTRY.Path, 'home', return_value=self.root / 'home'), patch.object(ENTRY, 'run_launcher', side_effect=launch):
            self.assertEqual(ENTRY.main(self.root), 0)
        self.assertTrue(list((self.root / 'home/Library/KHUpdater/state/_trash').glob('ssd-bootstrap-*')))

    def test_changed_bytes_refused(self):
        self.image.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum does not match'):
            ENTRY.launcher_image(self.root)

    def test_duplicate_launcher_refused(self):
        self.index([self.row, self.row])
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            ENTRY.launcher_image(self.root)

    def test_symlink_escape_refused(self):
        with tempfile.TemporaryDirectory(prefix='khu-ssd-outside-') as other:
            outside = Path(other) / 'outside.dmg'
            outside.write_bytes(self.image.read_bytes())
            link = self.root / 'link.dmg'
            link.symlink_to(outside)
            self.row['file'] = link.name
            self.index()
            with self.assertRaisesRegex(ValueError, 'on this SSD'):
                ENTRY.launcher_image(self.root)


if __name__ == '__main__':
    unittest.main()
