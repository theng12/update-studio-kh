#!/usr/bin/env python3
"""Open the verified SSD Launcher in local update/repair mode, without a network request."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import shutil
import uuid


def launcher_image(root, index_bytes=None):
    index = json.loads(index_bytes if index_bytes is not None else (root / 'apps.json').read_bytes())
    if index.get('format') != 'kh.apps.v1':
        raise ValueError('This SSD has an unsupported apps list. Use a refreshed SSD.')
    rows = [row for row in index['apps'] if row.get('id') == 'updater']
    if len(rows) != 1 or rows[0].get('bundleID') != 'com.khupdater.launcher':
        raise ValueError('This SSD does not name exactly one Studio Launcher installer.')
    row = rows[0]
    image = (root / row['file']).resolve(strict=True)
    if root not in image.parents or not image.is_file():
        raise ValueError('The Launcher installer must be a file on this SSD.')
    expected = row.get('sha256', '')
    if len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        raise ValueError('The Launcher installer has no valid checksum.')
    digest = hashlib.sha256()
    with image.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError('The Launcher installer checksum does not match. Nothing was started.')
    return image, row['version'], expected


def verified_copy(image, expected, staging):
    staging.mkdir(parents=True, mode=0o700)
    local = staging / 'Launcher.dmg'
    shutil.copyfile(image, local)
    local.chmod(0o600)
    digest = hashlib.sha256()
    with local.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError('The Launcher installer changed while copying. Nothing was started.')
    return local


def main(root):
    root = root.resolve(strict=True)
    index_bytes = (root / 'apps.json').read_bytes()
    image, version, expected = launcher_image(root, index_bytes)
    index_sha256 = hashlib.sha256(index_bytes).hexdigest()
    state = Path.home() / 'Library/KHUpdater/state'
    staging = state / 'ssd-bootstrap' / str(uuid.uuid4())
    try:
        local = verified_copy(image, expected, staging)
        return run_launcher(root, local, version, index_sha256)
    finally:
        if staging.exists():
            trash = state / '_trash'
            trash.mkdir(parents=True, exist_ok=True)
            staging.rename(trash / ('ssd-bootstrap-' + staging.name))


def run_launcher(root, image, version, index_sha256):
    result = subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(image)],
                            capture_output=True, check=True, timeout=120)
    attached = plistlib.loads(result.stdout)
    entities = attached['system-entities']
    mounts = [Path(entity['mount-point']) for entity in entities if 'mount-point' in entity]
    devices = list(dict.fromkeys(entity['dev-entry'] for entity in entities
                                if isinstance(entity.get('dev-entry'), str)
                                and entity['dev-entry'].startswith('/dev/disk')
                                and entity['dev-entry'][len('/dev/disk'):].isdigit()))
    if len(mounts) != 1 or len(devices) != 1:
        for device in devices:
            subprocess.run(['/usr/bin/hdiutil', 'detach', device], capture_output=True, timeout=60)
        raise ValueError('The Launcher installer did not return one mounted volume and device.')
    mount, device = mounts[0], devices[0]
    try:
        apps = list(mount.glob('*.app'))
        if len(apps) != 1:
            raise ValueError('The Launcher installer must contain one app.')
        app = apps[0]
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != 'com.khupdater.launcher' or info.get('CFBundleShortVersionString') != version:
            raise ValueError('The Launcher installer identity or version does not match the SSD list.')
        executable = (app / 'Contents/MacOS' / info['CFBundleExecutable']).resolve(strict=True)
        if app.resolve() not in executable.parents:
            raise ValueError('The Launcher executable is outside its app.')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                       capture_output=True, check=True, timeout=60)
        return subprocess.run([str(executable), 'ssd-update', '--volume', str(root), '--index-sha256', index_sha256], check=False).returncode
    finally:
        result = subprocess.run(['/usr/bin/hdiutil', 'detach', device], capture_output=True, timeout=60)
        if result.returncode:
            print('The installer volume is still mounted. No force-eject was attempted.', file=sys.stderr)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Open Update installed apps.command from the SSD root.')
        raise SystemExit(main(Path(sys.argv[1])))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        reason = str(exc) if isinstance(exc, ValueError) else 'The SSD installer could not be opened. Use a refreshed SSD and try again.'
        print('Update installed apps: ' + reason, file=sys.stderr)
        raise SystemExit(1)
