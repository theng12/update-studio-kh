#!/usr/bin/env python3
"""Keep only the latest releases in a build folder, recoverably.

Owner rule (2026-11-15, RELEASE-POLICY.md §4): a project's build/ keeps the latest two versions per app
and retires the rest to _trash on every release. dist/ and the feed are the record; build output is not
an archive. This only touches files named `<App>-<version>.dmg`; binaries, kits, staging folders and
anything else are left alone. Moving is `mv`, so every retired file stays restorable under _trash.

  packaging/rotate-build.py [--dir build] [--keep 2] [--trash _trash]
"""
import argparse
import datetime as dt
import os
import re
import shutil
import sys

ARTIFACT = re.compile(r"^(?P<app>[A-Za-z0-9][A-Za-z0-9 ._-]*?)-(?P<version>\d+(?:\.\d+)*)\.dmg$")


def sort_key(version):
    return tuple(int(part) for part in version.split("."))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?", default=None, help="the build folder (same as --dir)")
    ap.add_argument("--dir", default=None)
    ap.add_argument("--keep", type=int, default=2)
    ap.add_argument("--trash", default="_trash")
    args = ap.parse_args()
    if args.keep < 1:
        raise SystemExit("--keep must be at least 1")
    folder = args.dir or args.folder or "build"
    root = os.path.abspath(folder)
    if not os.path.isdir(root):
        raise SystemExit(f"{root} is not a directory")
    groups = {}
    for name in os.listdir(root):
        path = os.path.join(root, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        match = ARTIFACT.match(name)
        if match:
            groups.setdefault(match.group("app"), []).append((sort_key(match.group("version")), name))
    if not groups:
        print(f"rotate-build: nothing to rotate in {folder}")
        return 0
    retired = []
    for app, entries in groups.items():
        entries.sort(key=lambda item: item[0], reverse=True)
        for _, name in entries[args.keep:]:
            retired.append(name)
    if not retired:
        print(f"rotate-build: {folder} already holds the latest {args.keep} per app")
        return 0
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = os.path.join(os.path.abspath(args.trash), f"build-history-{stamp}")
    os.makedirs(destination, exist_ok=True)
    for name in sorted(retired):
        shutil.move(os.path.join(root, name), os.path.join(destination, name))
        print(f"rotate-build: retired {name} -> {destination}")
    print(f"rotate-build: kept the latest {args.keep} per app; {len(retired)} file(s) in {destination}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - a release step must fail loudly and change nothing else
        print(f"rotate-build: ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
