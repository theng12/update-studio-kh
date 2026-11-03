#!/usr/bin/env python3
"""Real AppKit bundle/URLSession regression. Fixture server is launched through preview_start.
prepare <khu> <new-empty-root> <tailnet-ip> <port>
run <candidate.app> <old-no-ATS.app> <fixture-root>
No real profile, LaunchAgent, publisher key or application is changed. All fixtures are retained.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def call(*args):
    return subprocess.check_output([str(a) for a in args], text=True)


def make_kit(root, name, public, feed):
    kit = root / name
    kit.mkdir()
    (kit / 'publisher.json').write_text(json.dumps({'feedURL': feed, 'enrolURL': feed.rsplit('/', 1)[0] + '/enrol', 'publicKey': public}))
    (kit / 'install-agent.sh').write_text('#!/bin/bash\nset -e\nmkdir -p "$2/Library/KHUpdater/base"\ncp "$1" "$2/Library/KHUpdater/base/config.json"\necho "Fixture installed; no LaunchAgent touched."\n')
    files = {}
    for name in ['publisher.json', 'install-agent.sh']:
        data = (kit / name).read_bytes()
        files[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    (kit / 'MANIFEST.json').write_text(json.dumps({'files': files}))
    return kit


if sys.argv[1] == 'prepare':
    binary, root, host, port = Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), sys.argv[4], int(sys.argv[5])
    assert not root.exists(), 'Use a new empty fixture root'
    root.mkdir(parents=True)
    (root / 'feed').mkdir()
    result = call(binary, 'keygen', root / 'test-only-key')
    public = next(line.split(': ', 1)[1] for line in result.splitlines() if line.startswith('public key: '))
    feed = f'http://{host}:{port}/release.json'
    make_kit(root, 'kit-default', public, feed)
    make_kit(root, 'kit-edited', public, f'http://100.64.0.8:{port}/release.json')
    (root / 'fixture.json').write_text(json.dumps({'binary': str(binary), 'host': host, 'port': port, 'feed': feed, 'publicKey': public}))
    print('Prepared isolated fixture:', root)
    print('Preview server arguments:', json.dumps(['serve', '--feed', str(root / 'feed'), '--state', str(root / 'state'), '--key', str(root / 'test-only-key/private.key'), '--bind', '127.0.0.1', '--bind', host, '--port', str(port)]))
else:
    candidate, baseline, root = Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), Path(sys.argv[4]).resolve()
    fixture = json.loads((root / 'fixture.json').read_text())
    cases = sys.argv[5:] or ['ats-control', 'wrong-code', 'public-address', 'success']
    if cases == ['public-address']:
        code = '123456'  # Fixture only: validation must refuse before any request.
    else:
        code = json.loads((root / 'state/state.json').read_text())['pairing']['code']
    driver = root / 'driver.dylib'
    source = Path(__file__).with_name('LauncherConnectDriver.m')
    subprocess.run(['clang', '-fobjc-arc', '-dynamiclib', '-framework', 'Cocoa', str(source), '-o', str(driver)], check=True)
    subprocess.run(['codesign', '--force', '-s', '-', str(driver)], check=True)
    results = []
    for mode in cases:
        app = baseline if mode == 'ats-control' else candidate
        plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        executable = app / 'Contents/MacOS' / plist['CFBundleExecutable']
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        home = root / ('home-' + mode)
        assert not home.exists(), 'Each run requires a clean profile'
        home.mkdir()
        proof = root / (mode + '.json')
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(driver), KHU_CONNECT_HOME=str(home),
                   KHU_CONNECT_KIT=str(root / ('kit-default' if mode == 'ats-control' else 'kit-edited')),
                   KHU_TEST_PROOF=str(proof), KHU_TEST_CASE=mode, KHU_TEST_MACHINE='ats-native-' + mode,
                   KHU_TEST_CODE=(('000000' if code != '000000' else '111111') if mode == 'wrong-code' else code),
                   KHU_TEST_ADDRESS=('8.8.8.8:8790' if mode == 'public-address' else f"{fixture['host']}:{fixture['port']}"))
        # The injected UI driver has its own 30-second watchdog; no timeout wrapper kills a child.
        command = ['/usr/bin/open', '-n', '-W', '--stdout', str(root / (mode + '.log')), '--stderr', str(root / (mode + '.log'))]
        for key, value in env.items():
            if key.startswith('KHU_') or key == 'DYLD_INSERT_LIBRARIES':
                command.extend(['--env', key + '=' + value])
        result = subprocess.run(command + [str(app)], check=False)
        assert proof.exists(), f'{mode}: no UI driver result; see {root / (mode + ".log")}'
        data = json.loads(proof.read_text())
        assert result.returncode == 0 and data['passed'], (mode, result.returncode, data)
        if mode == 'success':
            saved = json.loads((home / 'Library/KHUpdater/base/config.json').read_text())
            assert saved['feedURL'] == fixture['feed'] and saved['publicKey'] == fixture['publicKey']
            assert saved['machine'] == 'ats-native-success' and len(saved['token']) >= 32
            assert data['editable'] and data['addressEnabled']
        results.append({'case': mode, 'passed': True, 'app': str(app), 'proof': str(proof)})
        print(mode + (': baseline permits HTTP on this OS' if mode == 'ats-control' and data['installed'] else ': passed'), flush=True)
    if cases != ['ats-control', 'wrong-code', 'public-address', 'success']:
        (root / 'partial-result.json').write_text(json.dumps({'partial': True, 'results': results}, indent=2) + '\n')
        print('BUNDLED-CONNECT: selected cases only; not a full connection pass')
        sys.exit(0)
    machines = json.loads((root / 'state/state.json').read_text())['machines']
    expected_machines = {'ats-native-success'}
    baseline_proof = json.loads((root / 'ats-control.json').read_text())
    if baseline_proof['installed']:
        expected_machines.add('ats-native-ats-control')
    assert set(machines) == expected_machines, machines.keys()
    output = {'passed': True, 'profile': 'new temporary home per case', 'transport': 'real URLSession over this Mac Tailscale IP',
              'application': 'LaunchServices opens unchanged signed app and Info.plist; injected test-only AppKit UI driver',
              'baselineATSReproduced': not baseline_proof['installed'],
              'installer': 'manifest-verified fixture writes only the temporary profile config; no LaunchAgent', 'results': results}
    (root / 'result.json').write_text(json.dumps(output, indent=2) + '\n')
    print('BUNDLED-CONNECT: 4 cases passed; clean profile, edited route, original pin, no real enrolments')
