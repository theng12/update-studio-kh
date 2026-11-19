#!/usr/bin/env python3
"""Write SHA256SUMS.txt for release assets, using the signed feed's checksums.

Trust is the signed feed and the pinned key, not this generated file: a tampered
release page could carry a tampered checksum beside a tampered asset.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys


class ChecksumError(Exception):
    pass


def feed_checksums(path):
    try:
        envelope = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(envelope, dict) or not isinstance(envelope.get("feed"), str):
            raise ValueError("no signed feed")
        feed = json.loads(base64.b64decode(envelope["feed"], validate=True))
        if not isinstance(feed, dict):
            raise ValueError("no feed object")
    except (OSError, ValueError, UnicodeError, TypeError):
        raise ChecksumError("The signed release feed could not be read.") from None

    entries = {}
    for group in ("apps", "previous"):
        feed_group = feed.get(group) or {}
        if not isinstance(feed_group, dict):
            continue
        for entry in feed_group.values():
            if not isinstance(entry, dict):
                continue
            name, digest = entry.get("file"), entry.get("sha256")
            if isinstance(name, str) and isinstance(digest, str):
                entries[name] = digest.lower()
    return entries


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_sums(feed_path, assets, out_path):
    expected = feed_checksums(feed_path)
    rows = {}
    for asset in assets:
        if asset.name == out_path.name or asset.resolve() == out_path.resolve():
            continue
        if asset.name in rows:
            raise ChecksumError(f"Two assets share the name {asset.name!r}.")
        digest = expected.get(asset.name)
        if digest is None:
            raise ChecksumError(f"No feed entry matches asset {asset.name!r}.")
        actual = digest_file(asset)
        if actual != digest:
            raise ChecksumError(f"Asset {asset.name!r} does not match the feed's sha256.")
        rows[asset.name] = actual
    out_path.write_text("".join(f"{rows[name]}  {name}\n" for name in sorted(rows)), encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate SHA256SUMS.txt from a signed release feed.")
    parser.add_argument("--feed", type=Path, required=True, help="signed release.json for this release")
    parser.add_argument("--out", type=Path, required=True, help="path of SHA256SUMS.txt to write")
    parser.add_argument("assets", nargs="+", type=Path, help="release asset files")
    args = parser.parse_args(argv)
    try:
        write_sums(args.feed, args.assets, args.out)
    except ChecksumError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
