#!/usr/bin/env python3
"""Build one local Sparkle 2 appcast candidate from a sealed DMG.

Fields come from the DMG that is mounted read-only here; the checkout bundle is
never opened. The item is signed with the Launcher key (mode 0600) and verified
against the public key pinned in the app before output. Private key bytes are
never written to output.
"""
import argparse
import base64
import hashlib
import hmac
import json
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# PKCS#8 v2 Ed25519: prefix + 32-byte seed.
PRIVATE_KEY_DER_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
# SPKI Ed25519: prefix + 32-byte public key.
PUBLIC_KEY_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
EXPECTED_FINGERPRINT = "15574bae365a8c4a"
DEFAULT_KEY = Path.home() / ".kh-sparkle/com.khupdater.launcher/private.key"
DEFAULT_APP_SOURCE = Path(__file__).resolve().parents[1] / "Sources/khu/Launcher.swift"
CHUNK = 1024 * 1024


class AppcastError(RuntimeError):
    pass


def _run(cmd, *, input_bytes=None, what):
    proc = subprocess.run(cmd, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip()
        raise AppcastError(f"{what}: {detail or 'command failed'}")
    return proc.stdout


def _read_key_der(key_path):
    mode = stat.S_IMODE(key_path.stat().st_mode)
    if mode != 0o600:
        raise AppcastError(f"key {key_path} must be mode 0600, found {mode:o}")
    try:
        seed = base64.b64decode(key_path.read_bytes().strip(), validate=True)
    except Exception as exc:
        raise AppcastError(f"key {key_path} is not base64: {exc}") from exc
    if len(seed) != 32:
        raise AppcastError(f"key {key_path} must decode to 32 bytes, found {len(seed)}")
    return PRIVATE_KEY_DER_PREFIX + seed


def _derive_public_key(private_der):
    spki = _run(
        ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
        input_bytes=private_der,
        what="derive public key",
    )
    if len(spki) != 44:
        raise AppcastError(f"public key SPKI must be 44 bytes, found {len(spki)}")
    return spki[12:]


def _pinned_public_key(app_source):
    try:
        text = app_source.read_text()
    except OSError as exc:
        raise AppcastError(f"read app source {app_source}: {exc}") from exc
    match = re.search(r'publicEDKey\s*=\s*"([A-Za-z0-9+/=]+)"', text)
    if not match:
        raise AppcastError(f"no pinned publicEDKey in {app_source}")
    try:
        raw = base64.b64decode(match.group(1), validate=True)
    except Exception as exc:
        raise AppcastError(f"pinned publicEDKey is not base64: {exc}") from exc
    if len(raw) != 32:
        raise AppcastError(f"pinned publicEDKey must be 32 bytes, found {len(raw)}")
    return raw


def _fingerprint(raw_public_key):
    return hashlib.sha256(raw_public_key).hexdigest()[:16]


def _sign_dmg(dmg, private_der):
    return _run(
        [
            "openssl",
            "pkeyutl",
            "-sign",
            "-rawin",
            "-inkey",
            "/dev/stdin",
            "-keyform",
            "DER",
            "-in",
            str(dmg),
        ],
        input_bytes=private_der,
        what="sign DMG",
    )


def _verify_signature(dmg, signature, public_key, temp_dir):
    sig_path = Path(temp_dir) / "edsignature.bin"
    sig_path.write_bytes(signature)
    sig_path.chmod(0o600)
    public_der = PUBLIC_KEY_DER_PREFIX + public_key
    _run(
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
        input_bytes=public_der,
        what="verify DMG signature",
    )


def _hash_dmg(dmg):
    digest = hashlib.sha256()
    with dmg.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def _detach(mount_point):
    commands = (
        ["hdiutil", "detach", str(mount_point), "-quiet"],
        ["hdiutil", "detach", str(mount_point), "-force", "-quiet"],
    )
    for command in commands:
        proc = subprocess.run(command, capture_output=True)
        if proc.returncode == 0:
            return
    raise AppcastError(f"detach {mount_point} failed")


def _mount_bundle(dmg, temp_dir):
    mount_point = Path(temp_dir) / "mount"
    mount_point.mkdir()
    attached = False
    try:
        _run(
            [
                "diskutil",
                "image",
                "attach",
                "-readOnly",
                "-nobrowse",
                "-mountPoint",
                str(mount_point),
                str(dmg),
            ],
            what="mount DMG read-only",
        )
        attached = True
        apps = sorted(path for path in mount_point.glob("*.app") if path.is_dir())
        if len(apps) != 1:
            raise AppcastError(f"expected one app bundle in DMG, found {len(apps)}")
        info_path = apps[0] / "Contents/Info.plist"
        if not info_path.is_file():
            raise AppcastError(f"missing Info.plist in {apps[0].name}")
        try:
            info = plistlib.loads(info_path.read_bytes())
        except Exception as exc:
            raise AppcastError(f"read Info.plist: {exc}") from exc
        short_version = info.get("CFBundleShortVersionString")
        bundle_id = info.get("CFBundleIdentifier")
        if not isinstance(short_version, str) or not short_version:
            raise AppcastError("Info.plist has no CFBundleShortVersionString")
        if not isinstance(bundle_id, str) or not bundle_id:
            raise AppcastError("Info.plist has no CFBundleIdentifier")
        version = info.get("CFBundleVersion") or short_version
        if not isinstance(version, str) or not version:
            raise AppcastError("Info.plist has no usable CFBundleVersion")
        minimum_system_version = info.get("LSMinimumSystemVersion") or "13.0"
        if not isinstance(minimum_system_version, str) or not minimum_system_version:
            minimum_system_version = "13.0"
        title = info.get("CFBundleDisplayName") or info.get("CFBundleName") or apps[0].stem
        return {
            "bundleId": bundle_id,
            "shortVersion": short_version,
            "version": version,
            "minimumSystemVersion": minimum_system_version,
            "title": title,
        }
    finally:
        if attached:
            had_pending_error = sys.exc_info()[1] is not None
            try:
                _detach(mount_point)
            except AppcastError:
                if not had_pending_error:
                    raise


def _build_appcast(fields, dmg, url, signature):
    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = fields["title"]
    ET.SubElement(channel, "link").text = url
    ET.SubElement(channel, "description").text = f"{fields['title']} releases"
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"{fields['title']} {fields['shortVersion']}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = fields["version"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = fields["shortVersion"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = fields["minimumSystemVersion"]
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": url,
            "length": str(dmg.stat().st_size),
            "type": "application/octet-stream",
            f"{{{SPARKLE_NS}}}version": fields["version"],
            f"{{{SPARKLE_NS}}}shortVersionString": fields["shortVersion"],
            f"{{{SPARKLE_NS}}}edSignature": base64.b64encode(signature).decode("ascii"),
        },
    )
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def _parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", required=True, type=Path, help="sealed DMG to read and sign")
    parser.add_argument(
        "--url",
        help="enclosure URL (default: file:// URL of this DMG; local file/http URLs for fixtures)",
    )
    parser.add_argument("--out", type=Path, help="write appcast XML here instead of stdout")
    parser.add_argument("--key", type=Path, default=DEFAULT_KEY, help="Launcher private key (0600)")
    parser.add_argument(
        "--app-source",
        type=Path,
        default=DEFAULT_APP_SOURCE,
        help="app source holding the pinned publicEDKey",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    dmg = args.dmg.expanduser().resolve()
    if not dmg.is_file():
        raise AppcastError(f"DMG not found: {dmg}")
    if dmg.stat().st_size <= 0:
        raise AppcastError(f"DMG is empty: {dmg}")
    url = args.url or dmg.as_uri()

    private_der = _read_key_der(args.key.expanduser())
    derived_public = _derive_public_key(private_der)
    derived_fingerprint = _fingerprint(derived_public)
    if derived_fingerprint != EXPECTED_FINGERPRINT:
        raise AppcastError(
            f"signing key fingerprint {derived_fingerprint} != expected {EXPECTED_FINGERPRINT}"
        )
    pinned_public = _pinned_public_key(args.app_source.expanduser())
    pinned_fingerprint = _fingerprint(pinned_public)
    if pinned_fingerprint != EXPECTED_FINGERPRINT:
        raise AppcastError(
            f"pinned key fingerprint {pinned_fingerprint} != expected {EXPECTED_FINGERPRINT}"
        )
    if not hmac.compare_digest(derived_public, pinned_public):
        raise AppcastError("signing key does not match the public key pinned in the app")

    with tempfile.TemporaryDirectory(prefix="kh-appcast-") as temp_dir:
        fields = _mount_bundle(dmg, temp_dir)
        signature = _sign_dmg(dmg, private_der)
        _verify_signature(dmg, signature, pinned_public, temp_dir)
        xml_bytes = _build_appcast(fields, dmg, url, signature)
        summary = {
            "bundleId": fields["bundleId"],
            "bytes": dmg.stat().st_size,
            "filename": dmg.name,
            "fingerprint": derived_fingerprint,
            "minimumSystemVersion": fields["minimumSystemVersion"],
            "sha256": _hash_dmg(dmg),
            "shortVersion": fields["shortVersion"],
            "url": url,
            "version": fields["version"],
        }

    if args.out:
        out = args.out.expanduser().resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(xml_bytes)
    else:
        sys.stdout.buffer.write(xml_bytes)
    print(json.dumps(summary, sort_keys=True), file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AppcastError as exc:
        print(f"local-appcast: {exc}", file=sys.stderr)
        raise SystemExit(2)
