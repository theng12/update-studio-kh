#!/bin/bash
# Builds build/Studio Launcher KH.app and build/Studio-Launcher-KH-<version>.dmg: the helper as an
# app, with a universal agent kit (and this publisher's publisher.json) inside for the front door.
# usage: packaging/build-launcher.sh <version> <publisher.json>   (run ./build.sh build first)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"; PUB="${2:-}"
IDENTITY="${KHU_SIGN_IDENTITY:-KH Studio Local Signing}"
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || { echo 'A stable signing identity is required' >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && -f "$PUB" && -x build/khu ]] || { echo "usage: $0 <version> <publisher.json> (after ./build.sh build)" >&2; exit 2; }
APP="build/Studio Launcher KH.app"; DMG="build/Studio-Launcher-KH-$VERSION.dmg"; KIT="build/launcher-kit"
mkdir -p _trash
for old in "$APP" "$DMG" "$KIT"; do if [ -e "$old" ]; then mv "$old" "_trash/$(basename "$old").$(date +%s)"; fi; done
# build/khu and build/khu-stub are already universal (./build.sh build); merging a duplicate
# slice again would only re-derive them, so the kit takes them as built.
packaging/build-agent-kit.sh "$VERSION" "$KIT" >/dev/null
cp "$PUB" "$KIT/publisher.json"
/usr/bin/python3 -I -c '
import hashlib, json, pathlib, sys
kit = pathlib.Path(sys.argv[1])
names = ["VERSION", "agent-config.example.json", "bin/khu", "bin/khu-stub", "com.khupdater.agent.plist", "install-agent.sh", "publisher.json"]
files = {n: {"bytes": len((kit / n).read_bytes()), "sha256": hashlib.sha256((kit / n).read_bytes()).hexdigest()} for n in names}
(kit / "MANIFEST.json").write_text(json.dumps({"agent_version": sys.argv[2], "files": files,
    "format": "studiohub.khu-agent.v1", "stage": "bootstrap-only"}, indent=2) + "\n")
' "$KIT" "$VERSION"
build/khu launcher-bundle --out "$APP" --version "$VERSION" --kit "$KIT" >/dev/null
# The raw helpers were signed before their kit hashes; seal only the outer app here.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"
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
hdiutil create -volname "Studio Launcher KH" -srcfolder "$TMP/dmg" -ov -format UDZO "$DMG" >/dev/null 2>&1
mv "$TMP" "_trash/launcher-dmg-staging.$(date +%s)"
echo "built $APP and $DMG (agent $(lipo -archs "$KIT/bin/khu"))"
