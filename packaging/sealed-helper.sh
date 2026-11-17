#!/bin/bash
# Prints the path of the `khu` helper sealed inside Studio Launcher KH — the exact bytes a release
# DMG ships — so publishing the `updater` entry never trusts a stale path such as build/khu.
#
#   packaging/sealed-helper.sh <version> [dmg]
#
# The built bundle is read when it is there; otherwise the DMG is mounted read-only and the helper
# copied out before it is detached. Nothing is rebuilt or resigned here: a published helper is the
# one that was signed for the release, never a fresh compile that happens to share its version.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: sealed-helper.sh <version> [dmg]}"
DMG="${2:-build/Studio-Launcher-KH-$VERSION.dmg}"
SEALED="build/Studio Launcher KH.app/Contents/Resources/khu-agent/bin/khu"

if [ -x "$SEALED" ]; then printf '%s\n' "$SEALED"; exit 0; fi
[ -f "$DMG" ] || { echo "no built Launcher bundle and no $DMG: there is no sealed helper to publish" >&2; exit 2; }

MNT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/kh-sealed.XXXXXX")
OUT=$(/usr/bin/mktemp -t sealed-khu)
cleanup() { /usr/bin/hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1; /bin/rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
/usr/bin/hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -noautoopen -readonly >/dev/null 2>&1 \
  || { echo "$DMG did not mount: no sealed helper can be read from it" >&2; exit 2; }
IN="$MNT/Studio Launcher KH.app/Contents/Resources/khu-agent/bin/khu"
[ -x "$IN" ] || { echo "$DMG has no khu helper inside Studio Launcher KH.app" >&2; exit 2; }
/bin/cp "$IN" "$OUT" && /bin/chmod 755 "$OUT"
printf '%s\n' "$OUT"
