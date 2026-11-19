#!/usr/bin/env python3
"""Focused checks for the release-time SHA256SUMS generator, stdlib only."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "packaging/release-checksums.py"
spec = importlib.util.spec_from_file_location("release_checksums", SCRIPT)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fixture():
    root = Path(tempfile.mkdtemp(prefix="khu-release-checksums-"))
    data = {"Zeta.dmg": b"zeta bytes", "Alpha.dmg": b"alpha bytes"}
    for name, content in data.items():
        (root / name).write_bytes(content)
    feed = {"schema": 1, "published_at": "2026-11-19T00:00:00Z",
            "apps": {name: {"version": "1.0.0", "file": name, "sha256": digest(content),
                            "bytes": len(content), "kind": "app-dmg"} for name, content in data.items()}}
    release = root / "release.json"
    release.write_text(json.dumps({"feed": base64.b64encode(json.dumps(feed).encode()).decode(),
                                   "signature": "ZmFrZQ=="}))
    return root, release, [root / "Zeta.dmg", root / "Alpha.dmg"], root / "SHA256SUMS.txt"


def discard(root):
    trash = Path(tempfile.gettempdir()) / "_trash"
    trash.mkdir(exist_ok=True)
    shutil.move(str(root), str(trash / (root.name + "-" + uuid.uuid4().hex)))


def generate(feed, assets, out):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), "--feed", str(feed), "--out", str(out)]
                          + [str(asset) for asset in assets], capture_output=True, text=True)


def expect_refusal(result, out):
    assert result.returncode != 0, "a bad asset was accepted"
    message = result.stderr.strip()
    assert len(message.splitlines()) == 1 and message.endswith("."), f"not one sentence: {message!r}"
    assert "Traceback" not in message and not result.stdout, f"not a plain refusal: {message!r}"
    assert not out.exists(), "a checksum file was written for a refused release"


def test_two_space_format(root, feed, assets, out):
    result = generate(feed, assets, out)
    assert result.returncode == 0, result.stderr
    lines = out.read_text().splitlines()
    assert len(lines) == 2, lines
    for line in lines:
        assert re.fullmatch(r"[0-9a-f]{64}  \S+", line), f"bad line: {line!r}"


def test_sorted_by_asset_name(root, feed, assets, out):
    assert generate(feed, assets, out).returncode == 0
    names = [line.split("  ", 1)[1] for line in out.read_text().splitlines()]
    assert names == sorted(names) == ["Alpha.dmg", "Zeta.dmg"], names


def test_never_lists_itself(root, feed, assets, out):
    out.write_bytes(b"stale checksums")
    result = generate(feed, assets + [out], out)
    assert result.returncode == 0, result.stderr
    assert "SHA256SUMS.txt" not in out.read_text()


def test_mismatch_refused(root, feed, assets, out):
    assets[0].write_bytes(b"tampered bytes")
    expect_refusal(generate(feed, assets, out), out)


def test_missing_feed_entry_refused(root, feed, assets, out):
    extra = root / "Extra.dmg"
    extra.write_bytes(b"unlisted asset")
    expect_refusal(generate(feed, assets + [extra], out), out)


def test_duplicate_asset_name_refused(root, feed, assets, out):
    other = root / "other"
    other.mkdir()
    (other / "Alpha.dmg").write_bytes(b"alpha bytes")
    expect_refusal(generate(feed, assets + [other / "Alpha.dmg"], out), out)


def test_shasum_accepts_output(root, feed, assets, out):
    assert generate(feed, assets, out).returncode == 0
    checked = subprocess.run(["shasum", "-a", "256", "-c", out.name], cwd=root,
                             capture_output=True, text=True)
    assert checked.returncode == 0, checked.stdout + checked.stderr
    assert checked.stdout.count(": OK") == 2, checked.stdout


def test_caveat_is_in_the_code(root, feed, assets, out):
    comment = "\n".join(SCRIPT.read_text().splitlines()[:8])
    assert "pinned key" in comment and "tampered" in comment, comment


def main():
    tests = [(name, body) for name, body in sorted(globals().items())
             if name.startswith("test_") and callable(body)]
    passed = 0
    for name, body in tests:
        root = None
        try:
            root, feed, assets, out = fixture()
            body(root, feed, assets, out)
            print(f"PASS {name}")
            passed += 1
        except Exception as error:
            print(f"FAIL {name}: {error}")
        finally:
            if root is not None:
                discard(root)
    print(f"{'PASS' if passed == len(tests) else 'FAIL'} {passed}/{len(tests)}")
    return 0 if passed == len(tests) else 1


if __name__ == "__main__":
    sys.exit(main())
