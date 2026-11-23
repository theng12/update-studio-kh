#!/usr/bin/env python3
"""Check a folder of Launcher page captures against RELEASE-POLICY §5d and the owner's tab numbers.

    python3 -I Tests/check-snapshots.py <folder>

Fails on: a PNG over 400 KB, a PNG carrying a tEXt/iTXt/eXIf/tIME chunk (an author or a path can
travel there while the pixels are perfect), a tab gap under 6px, a tab target under 32px, a selected
tab whose ink and fill are under 4.5:1, a wrapped tab label, or a missing measurement.
"""
import glob
import json
import os
import struct
import sys

CAP = 400 * 1024
FORBIDDEN = {b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"tIME"}


def png_problem(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) > CAP:
        return f"{os.path.basename(path)} is {len(data)} bytes (cap {CAP})"
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return f"{os.path.basename(path)} is not a PNG"
    at, found = 8, []
    while at + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        if kind in FORBIDDEN:
            found.append(kind.decode())
        at += 12 + length
        if kind == b"IEND":
            break
    if found:
        return f"{os.path.basename(path)} carries {', '.join(sorted(set(found)))} metadata"
    return None


def main(folder):
    problems = []
    pngs = sorted(glob.glob(os.path.join(folder, "*.png")))
    measures = sorted(glob.glob(os.path.join(folder, "measure-*.json")))
    # Images are optional in the gate: they are taken from the served artifact at publish time.
    # When present, every one is held to the size and metadata rules.
    if not measures:
        problems.append("no measurement was written")
    for png in pngs:
        problem = png_problem(png)
        if problem:
            problems.append(problem)
    for path in measures:
        m = json.load(open(path))
        name = os.path.basename(path)
        gap = m.get("minGap")
        height = m.get("minHeight")
        contrast = (m.get("selected") or {}).get("contrast")
        if m.get("gapCSS") != "6px":
            problems.append(f"{name}: the bar's gap is {m.get('gapCSS')!r}, not 6px")
        if gap is None or gap < 5.9:
            problems.append(f"{name}: measured gap {gap} is under 6px")
        if height is None or height < 32:
            problems.append(f"{name}: a tab is {height}px tall, under 32px")
        if contrast is None or contrast < 4.5:
            problems.append(f"{name}: selected tab contrast {contrast}:1 is under 4.5:1")
        if m.get("labelWrapped"):
            problems.append(f"{name}: a tab label wrapped at {m.get('width')}px")
        fill = (m.get("selected") or {}).get("background", "")
        if fill in ("rgba(0, 0, 0, 0)", "transparent", ""):
            problems.append(f"{name}: the selected tab has no fill ({fill!r})")
    for p in problems:
        print("FAIL " + p)
    if not problems:
        images = (f", each of {len(pngs)} image(s) under {CAP // 1024} KB with no author or path metadata"
                  if pngs else " (no images in this folder)")
        print(f"OK {len(measures)} measurement(s){images}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))