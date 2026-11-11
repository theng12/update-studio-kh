#!/bin/bash
# Builds build/AppIcon.icns from App/icon.swift. The app, helper and publisher bundles share it:
# one product icon, so a named background process looks like it belongs to the app.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swiftc -o "$TMP/icon" App/icon.swift -framework AppKit
"$TMP/icon" "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p build _trash
iconutil -c icns "$TMP/AppIcon.iconset" -o build/AppIcon.icns
mv "$TMP" "_trash/icon-staging.$(date +%s)"
echo "built build/AppIcon.icns"
