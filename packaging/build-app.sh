#!/usr/bin/env bash
# Builds the signed publisher app and build/Update-Studio-KH-<version>.dmg.
# Usage: packaging/build-app.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: packaging/build-app.sh <version>}"
IDENTITY="${KHU_SIGN_IDENTITY:-KH Studio Local Signing}"
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || { echo 'A stable signing identity is required' >&2; exit 1; }
APP="build/Update Studio KH.app"; DMG="build/Update-Studio-KH-$VERSION.dmg"
TMP="$(mktemp -d)"
mkdir -p build
[ -e "$APP" ] && { mkdir -p _trash; mv "$APP" "_trash/Update Studio KH.app.$(date +%s)"; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 -B -I packaging/generate-ui.py
cp build/whats-new.json "$APP/Contents/Resources/whats-new.json"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" -o "$TMP/KHUpdater-$arch" App/main.swift -framework AppKit -framework WebKit
done
lipo -create "$TMP/KHUpdater-arm64" "$TMP/KHUpdater-x86_64" -output "$APP/Contents/MacOS/KHUpdater"

packaging/build-icon.sh >/dev/null
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSExceptionDomains</key><dict><key>ts.net</key><dict><key>NSIncludesSubdomains</key><true/><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict></dict></dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

mkdir "$TMP/dmg"; ditto "$APP" "$TMP/dmg/Update Studio KH.app"; ln -s /Applications "$TMP/dmg/Applications"
[ -e "$DMG" ] && { mkdir -p _trash; mv "$DMG" "_trash/$(basename "$DMG").$(date +%s)"; }
hdiutil create -volname "Update Studio KH" -srcfolder "$TMP/dmg" -ov -format UDZO "$DMG" >/dev/null
echo "built $APP and $DMG"
packaging/record-dist.sh copy "Update Studio KH" "$VERSION" "$DMG"
