#!/usr/bin/env python3
"""CHANGELOG.md -> whats-new.json, the one What's New format every KH app reads.

Input convention (already used by all apps):  ## 1.2.3 — 2026-11-08   then  - bullet lines.
Output: [{"version": "1.2.3", "date": "2026-11-08" | null, "items": ["..."]}, ...] newest first.
Usage: python3 -I whats-new.py CHANGELOG.md [out.json]     (prints to stdout without out.json)
       python3 -I whats-new.py --self-test
"""
import json, re, sys

HEAD = re.compile(r"^##\s+v?(\d+(?:\.\d+)+(?:[-+][\w.]+)?)\s*(?:[—–-]\s*(\d{4}-\d{2}-\d{2}))?")


def parse(text):
    out, cur = [], None
    for line in text.splitlines():
        m = HEAD.match(line)
        if m:
            cur = {"version": m.group(1), "date": m.group(2), "items": []}
            out.append(cur)
        elif cur is not None and re.match(r"^\s*[-*]\s+\S", line) and not line.startswith(("  ", "\t")):
            cur["items"].append(re.sub(r"^\s*[-*]\s+", "", line).strip())
        elif line.startswith("## "):
            cur = None  # a non-version heading (e.g. "## Technical notes") ends the release
    return out


def self_test():
    sample = "# Changelog\n\n## 1.0.14 — 2026-11-09\n- One entry per printer\n  - nested detail skipped\n\n## v1.0.13\n* Signed\n## Technical notes\n- not a release\n"
    r = parse(sample)
    assert r == [
        {"version": "1.0.14", "date": "2026-11-09", "items": ["One entry per printer"]},
        {"version": "1.0.13", "date": None, "items": ["Signed"]},
    ], r
    print("self-test ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) in (2, 3):
        data = json.dumps(parse(open(sys.argv[1], encoding="utf-8").read()), ensure_ascii=False, indent=2)
        if len(sys.argv) == 3:
            open(sys.argv[2], "w", encoding="utf-8").write(data + "\n")
        else:
            print(data)
    else:
        sys.exit(__doc__)
