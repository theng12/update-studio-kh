#!/bin/bash
# Builds build/Studio Launcher KH.app and build/Studio-Launcher-KH-<version>.dmg: the helper as an
# app, with a universal agent kit inside for the front door. The kit's publisher record keeps the
# pinned key but, by default, no address: a DMG anyone can download must not hand out this
# publisher's machine name. `--kit-address` keeps the address too, for a copy whose front door
# starts with it filled in (the SSD copy).
# usage: packaging/build-launcher.sh <version> <publisher.json> [--kit-address]   (run ./build.sh build first)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"; PUB="${2:-}"; shift $(( $# > 2 ? 2 : $# ))
KIT_ADDRESS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kit-address) KIT_ADDRESS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
IDENTITY="${KHU_SIGN_IDENTITY:-KH Studio Local Signing}"
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || { echo 'A stable signing identity is required' >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && -f "$PUB" && -x build/khu ]] || { echo "usage: $0 <version> <publisher.json> [--kit-address] (after ./build.sh build)" >&2; exit 2; }
APP="build/Studio Launcher KH.app"; DMG="build/Studio-Launcher-KH-$VERSION.dmg"; KIT="build/launcher-kit"
# Retired build output goes to the one trash, on the Desktop, as a real path. A `_trash` symlink in
# the checkout made `mkdir -p` fail ENOTDIR once the owner emptied the trash (Story 1.4.410's gate,
# 2026-11-18). KHU_TRASH points a test at a temp dir, so a run never writes the owner's trash.
TRASH="${KHU_TRASH:-$HOME/Desktop/_trash/update-studio-kh}"
if { [ -e "$TRASH" ] || [ -L "$TRASH" ]; } && [ ! -d "$TRASH" ]; then
  echo "The trash path $TRASH exists and is not a directory; move it out of the way and build again." >&2
  exit 1
fi
mkdir -p "$TRASH"
for old in "$APP" "$DMG" "$KIT"; do if [ -e "$old" ]; then mv "$old" "$TRASH/$(basename "$old").$(date +%s)"; fi; done
# build/khu and build/khu-stub are already universal (./build.sh build); merging a duplicate
# slice again would only re-derive them, so the kit takes them as built.
packaging/build-agent-kit.sh "$VERSION" "$KIT" >/dev/null
# The kit keeps the pinned key (and any other field the publisher file carries); the address is
# dropped unless this build is explicitly for a copy that should arrive pointed at a publisher.
/usr/bin/python3 -I - "$PUB" "$KIT/publisher.json" "$KIT_ADDRESS" <<'PY'
import json, sys
source, kit_file, keep_address = sys.argv[1:]
record = json.loads(open(source).read())
if not keep_address:
    record.pop("feedURL", None)
    record.pop("enrolURL", None)
open(kit_file, "w").write(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
/usr/bin/python3 -I -c '
import hashlib, json, pathlib, sys
kit = pathlib.Path(sys.argv[1])
names = [n for n in ["VERSION", "agent-config.example.json", "AppIcon.icns", "bin/khu", "bin/khu-stub", "com.khupdater.agent.plist", "install-agent.sh", "publisher.json"] if (kit / n).exists()]
files = {n: {"bytes": len((kit / n).read_bytes()), "sha256": hashlib.sha256((kit / n).read_bytes()).hexdigest()} for n in names}
(kit / "MANIFEST.json").write_text(json.dumps({"agent_version": sys.argv[2], "files": files,
    "format": "studiohub.khu-agent.v1", "stage": "bootstrap-only"}, indent=2) + "\n")
' "$KIT" "$VERSION"
build/khu launcher-bundle --out "$APP" --version "$VERSION" --kit "$KIT" >/dev/null
# Sparkle 2 ships beside the app executable, not inside the kit: build/khu weak-links it, so the
# agent's own copies (base/versions/<v>, base/bin/khu) launch without it and only this bundle loads
# it (docs/SPARKLE-INTEGRATION.md). Versions/Current, never an added Versions/A alias, which makes
# codesign --verify --deep --strict fail with "unsealed contents present in the root directory".
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto vendor/khsparkle/Sparkle.framework "$FW"
# Nested first: Sparkle's own helpers cannot be signed after the framework that contains them.
for inner in "$FW"/Versions/Current/XPCServices/*.xpc "$FW"/Versions/Current/Autoupdate "$FW"/Versions/Current/Updater.app; do
  [ -e "$inner" ] || continue
  codesign --force --sign "$IDENTITY" --timestamp=none "$inner"
done
codesign --force --sign "$IDENTITY" --timestamp=none "$FW"
# The raw helpers were signed before their kit hashes; seal only the outer app here.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"
# A framework that is present but unsealed reads as shipped and fails on a Mac: prove the bundle.
codesign --verify --deep --strict "$APP"
[[ -d "$FW" ]] || { echo "Sparkle.framework is missing from $APP; a weak-linked app still launches, so nothing else would say so" >&2; exit 1; }
/usr/bin/python3 -I -c '
import hashlib, json, pathlib, sys
kit = pathlib.Path(sys.argv[1]) / "Contents/Resources/khu-agent"
manifest = json.loads((kit / "MANIFEST.json").read_text())
for name, pin in manifest["files"].items():
    data = (kit / name).read_bytes()
    if len(data) != pin["bytes"] or hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise SystemExit("Signing changed a pinned kit file: " + name)
' "$APP"
TMP="$(mktemp -d)"; mkdir "$TMP/dmg"; ditto "$APP" "$TMP/dmg/Studio Launcher KH.app"; ln -s /Applications "$TMP/dmg/Applications"
# The quarantine line travels with the image as plain text (owner, 2026-11-23). Generated here, in
# the folder the image is built from, so every later release has it without being remembered.
packaging/read-me-first.sh "Studio Launcher KH.app" "$TMP/dmg"
# Loud on purpose: a failed DMG step once exited 1 with its output discarded, so the build
# looked like it had produced nothing for no stated reason (2026-11-17).
if ! out=$(hdiutil create -volname "Studio Launcher KH" -srcfolder "$TMP/dmg" -ov -format UDZO "$DMG" 2>&1); then
  echo "hdiutil create failed for $DMG: ${out##*$'\n'}" >&2
  exit 1
fi
# Exit 0 from `create` is not proof the image is whole: a truncated one would be recorded and
# published as if it were good. The image itself is verified before anything records it.
if ! out=$(hdiutil verify "$DMG" 2>&1); then
  echo "hdiutil verify failed for $DMG: ${out##*$'\n'}" >&2
  exit 1
fi
mv "$TMP" "$TRASH/launcher-dmg-staging.$(date +%s)"
echo "built $APP and $DMG (agent $(lipo -archs "$KIT/bin/khu"))"
packaging/record-dist.sh copy "Studio Launcher KH" "$VERSION" "$DMG"
# Build output is not an archive: keep the latest two per app, retire the rest recoverably.
python3 -B -I packaging/rotate-build.py build --trash "$TRASH"
