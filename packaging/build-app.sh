#!/usr/bin/env bash
# Builds build/Update Studio KH.app (ad-hoc signed, like gateway-kh) and build/Update-Studio-KH-<version>.dmg.
# Usage: packaging/build-app.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: packaging/build-app.sh <version>}"
APP="build/Update Studio KH.app"; DMG="build/Update-Studio-KH-$VERSION.dmg"
TMP="$(mktemp -d)"
mkdir -p build
[ -e "$APP" ] && { mkdir -p _trash; mv "$APP" "_trash/Update Studio KH.app.$(date +%s)"; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/KHUpdater" App/main.swift -framework AppKit -framework WebKit

swiftc -o "$TMP/icon" App/icon.swift -framework AppKit
"$TMP/icon" "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleExecutable</key><string>KHUpdater</string>
<key>CFBundleIdentifier</key><string>com.khupdater.app</string>
<key>CFBundleName</key><string>Update Studio KH</string><key>CFBundleDisplayName</key><string>Update Studio KH</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir "$TMP/dmg"; ditto "$APP" "$TMP/dmg/Update Studio KH.app"; ln -s /Applications "$TMP/dmg/Applications"
[ -e "$DMG" ] && { mkdir -p _trash; mv "$DMG" "_trash/$(basename "$DMG").$(date +%s)"; }
hdiutil create -volname "Update Studio KH" -srcfolder "$TMP/dmg" -ov -format UDZO "$DMG" >/dev/null
echo "built $APP and $DMG"
