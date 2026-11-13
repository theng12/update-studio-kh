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
    # Rotate straight away: keeping the latest two is never a hand step. Anything older goes to the
    # repo's _trash, and the shared tool never moves a file its ledger or a pin still names.
    # A first build in a fresh checkout has no ledger yet; that is not a failed copy.
    if [ -f "$DIST/.release-dist.json" ]; then "$0" rotate "$APP" "$VERSION"; fi
    ;;
  rotate)
    DRY=""
    if [ ! -f "$DIST/$APP-$VERSION.dmg" ]; then
      echo "dist has no $APP-$VERSION.dmg; run the copy step first" >&2; exit 2
    fi
    TRASH_DIR="$ROOT/_trash/$(date +%Y-%m-%d) dist"
mkdir -p "$TRASH_DIR"
    PIN=$(mktemp -t khu-dist-pins)
    /usr/bin/python3 -I - "$DIST" "$APP" "$VERSION" "$ROOT" "$PIN" <<'PY'
import hashlib, json, os, re, sys
dist, app, version, root, out = sys.argv[1:6]
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
                              "retirement_trash": os.path.join(root, "_trash", __import__("datetime").date.today().isoformat() + " dist"),
                              "releases": releases}]}
json.dump(pin, open(out, "w"), indent=2)
PY
    sh "$ROOT/packaging/retain-release.sh" "$PIN"
    ;;
  *) echo "usage: record-dist.sh copy|rotate <app> <version> [dmg]" >&2; exit 2 ;;
esac
