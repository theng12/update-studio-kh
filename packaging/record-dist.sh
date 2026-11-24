#!/bin/bash
# Keeps this repo's canonical dist/ in step with releases, so nobody has to remember.
#
#   packaging/record-dist.sh copy   <app> <version> <dmg>   after packaging: the DMG is always in dist/
#   packaging/record-dist.sh rotate <app> <version>         after the release is live: keep the latest two
#
# `copy` never removes anything: a build that has not passed its gate must not evict the installer
# people rely on. `rotate` is the accepted-release step and uses the shared retention tool, which
# retires older files to this repo's _trash rather than deleting them.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
MODE="${1:-}"; APP="${2:?usage: record-dist.sh copy|rotate <app> <version> [dmg]}"; VERSION="${3:?}"
DIST="$ROOT/dist"
mkdir -p "$DIST"
case "$MODE" in
  copy)
    DMG="${4:?copy needs the DMG path}"
    [[ -f "$DMG" ]] || { echo "no such DMG: $DMG" >&2; exit 2; }
    DEST="$DIST/$APP-$VERSION.dmg"
    if [ -f "$DEST" ] && cmp -s "$DMG" "$DEST"; then
      echo "dist already holds $APP-$VERSION.dmg"
    else
      cp "$DMG" "$DEST.tmp" && mv "$DEST.tmp" "$DEST"
      echo "copied $(basename "$DMG") to dist/$APP-$VERSION.dmg"
    fi
    # `copy` stops here on purpose: rotating is the accepted-release step, and a build that has not
    # passed its gate must not evict the installer people rely on (this file's own first paragraph).
    # It called rotate here until 0.1.82, so a second build of the same version refused with "was
    # placed with different bytes" — twice, one gate each time (row 20261125-12).
    ;;
  rotate)
    DRY=""
    if [ ! -f "$DIST/$APP-$VERSION.dmg" ]; then
      echo "dist has no $APP-$VERSION.dmg; run the copy step first" >&2; exit 2
    fi
    # The one trash is on the Desktop, resolved as a real path: no `_trash` link or folder lives in
    # the checkout. KHU_TRASH points a test at a temp dir.
    REAL_TRASH=$(/usr/bin/python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${KHU_TRASH:-$HOME/Desktop/_trash/update-studio-kh}")
    TRASH_DIR="$REAL_TRASH/$(date +%Y-%m-%d) dist"
mkdir -p "$TRASH_DIR"
    PIN=$(mktemp -t khu-dist-pins)
    /usr/bin/python3 -I - "$DIST" "$APP" "$VERSION" "$ROOT" "$PIN" "$REAL_TRASH" <<'PY'
import hashlib, json, os, re, sys
dist, app, version, root, out, real_trash = sys.argv[1:7]
def parts(v):
    return tuple(int(x) for x in v.split("."))
def fact(path):
    data = open(path, "rb").read()
    return hashlib.sha256(data).hexdigest(), len(data)
manifest = json.load(open(os.path.join(dist, ".release-dist.json")))
managed = manifest["apps"].get(app, {}).get("files", {})
name = f"{app}-{version}.dmg"
releases = []
sha, size = fact(os.path.join(dist, name))
releases.append({"version": version, "source": os.path.join(dist, name),
                 "sha256": sha, "bytes": size,
                 "evidence": "release recorded by packaging/record-dist.sh rotate on " + __import__("datetime").date.today().isoformat()})
# The retained pair is this release and the newest one below it, judged from what is actually in
# dist — a DMG placed by hand still counts, and the ledger is not the only record of it.
present = []
for entry in os.listdir(dist):
    if not entry.startswith(app + "-") or not entry.endswith(".dmg"):
        continue
    v = entry[len(app) + 1:-len(".dmg")]
    if v == version or not re.match(r"^\d+(\.\d+)+$", v):
        continue
    present.append((v, entry))
present.sort(key=lambda pair: parts(pair[0]), reverse=True)
if present:
    v, entry = present[0]
    path = os.path.join(dist, entry)
    sha2, size2 = fact(path)
    record = managed.get(entry, {})
    releases.append({"version": v, "source": path, "sha256": sha2, "bytes": size2,
                     "evidence": record.get("provenance") or "retained from the previous release"})
pin = {"schema": 1, "apps": [{"app": app, "project": root,
                              "retirement_trash": real_trash,
                              "releases": releases}]}
json.dump(pin, open(out, "w"), indent=2)
PY
    sh "$ROOT/packaging/retain-release.sh" "$PIN"
    ;;
  *) echo "usage: record-dist.sh copy|rotate <app> <version> [dmg]" >&2; exit 2 ;;
esac
