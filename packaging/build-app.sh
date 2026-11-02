#!/usr/bin/env bash
# Builds build/KH Updater.app (ad-hoc signed, like gateway-kh) and build/KH-Updater-<version>.dmg.
# Usage: packaging/build-app.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: packaging/build-app.sh <version>}"
APP="build/KH Updater.app"; DMG="build/KH-Updater-$VERSION.dmg"
TMP="$(mktemp -d)"
mkdir -p build
[ -e "$APP" ] && { mkdir -p _trash; mv "$APP" "_trash/KH Updater.app.$(date +%s)"; }
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
<key>CFBundleName</key><string>KH Updater</string>
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

mkdir "$TMP/dmg"; ditto "$APP" "$TMP/dmg/KH Updater.app"; ln -s /Applications "$TMP/dmg/Applications"
[ -e "$DMG" ] && { mkdir -p _trash; mv "$DMG" "_trash/$(basename "$DMG").$(date +%s)"; }
hdiutil create -volname "KH Updater" -srcfolder "$TMP/dmg" -ov -format UDZO "$DMG" >/dev/null
echo "built $APP and $DMG"
