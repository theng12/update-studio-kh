#!/bin/bash
# Builds build/Studio Launcher KH.app and build/Studio-Launcher-KH-<version>.dmg: the helper as an
# app, with a universal agent kit (and this publisher's publisher.json) inside for the front door.
# usage: packaging/build-launcher.sh <version> <publisher.json>   (run ./build.sh build first)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"; PUB="${2:-}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && -f "$PUB" && -x build/khu ]] || { echo "usage: $0 <version> <publisher.json> (after ./build.sh build)" >&2; exit 2; }
APP="build/Studio Launcher KH.app"; DMG="build/Studio-Launcher-KH-$VERSION.dmg"; KIT="build/launcher-kit"
mkdir -p _trash
for old in "$APP" "$DMG" "$KIT"; do if [ -e "$old" ]; then mv "$old" "_trash/$(basename "$old").$(date +%s)"; fi; done
CORE=(Sources/KHUStub/*.swift Sources/KHUpdaterCore/*.swift build/Changelog.swift)
swiftc -parse-as-library -O -target x86_64-apple-macos13 -o build/khu-x86 "${CORE[@]}" Sources/khu/*.swift 2>/dev/null
swiftc -parse-as-library -O -target x86_64-apple-macos13 -o build/khu-stub-x86 Sources/KHUStub/*.swift Sources/khu-stub/*.swift 2>/dev/null
lipo -create build/khu build/khu-x86 -output build/khu-universal
lipo -create build/khu-stub build/khu-stub-x86 -output build/khu-stub-universal
mv build/khu-x86 build/khu-stub-x86 _trash/
packaging/build-agent-kit.sh "$VERSION" "$KIT" >/dev/null
cp build/khu-universal "$KIT/bin/khu"; cp build/khu-stub-universal "$KIT/bin/khu-stub"; cp "$PUB" "$KIT/publisher.json"
/usr/bin/python3 -I -c '
import hashlib, json, pathlib, sys
kit = pathlib.Path(sys.argv[1])
names = ["VERSION", "agent-config.example.json", "bin/khu", "bin/khu-stub", "com.khupdater.agent.plist", "install-agent.sh", "publisher.json"]
files = {n: {"bytes": len((kit / n).read_bytes()), "sha256": hashlib.sha256((kit / n).read_bytes()).hexdigest()} for n in names}
(kit / "MANIFEST.json").write_text(json.dumps({"agent_version": sys.argv[2], "files": files,
    "format": "studiohub.khu-agent.v1", "stage": "bootstrap-only"}, indent=2) + "\n")
' "$KIT" "$VERSION"
build/khu-universal launcher-bundle --out "$APP" --version "$VERSION" --kit "$KIT" >/dev/null
codesign --force --deep -s - "$APP" >/dev/null 2>&1
TMP="$(mktemp -d)"; mkdir "$TMP/dmg"; ditto "$APP" "$TMP/dmg/Studio Launcher KH.app"; ln -s /Applications "$TMP/dmg/Applications"
hdiutil create -volname "Studio Launcher KH" -srcfolder "$TMP/dmg" -ov -format UDZO "$DMG" >/dev/null 2>&1
mv "$TMP" "_trash/launcher-dmg-staging.$(date +%s)"
echo "built $APP and $DMG (agent $(lipo -archs "$KIT/bin/khu"))"
