#!/bin/bash
# One-time migration for a publisher installed before the named bundle: wraps the existing
# ~/Library/KHUpdater/bin/khu in Update Studio KH Publisher.app and points the LaunchAgent at it.
# It changes no other file, starts nothing and is safe to re-run.
# usage: packaging/relabel-publisher.sh [--home <dir>]   (after ./build.sh build)
set -euo pipefail
umask 077
HOME_DIR="$HOME"
[[ "${1:-}" == "--home" && -n "${2:-}" ]] && HOME_DIR="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="$HOME_DIR/Library/KHUpdater"
PLIST="$HOME_DIR/Library/LaunchAgents/com.khupdater.publisher.plist"
BUNDLE="$K/Update Studio KH Publisher.app"
fail() { echo "$1" >&2; exit 1; }
[[ -x "$ROOT/build/khu" ]] || fail 'build/khu missing; run ./build.sh build first'
[[ -x "$K/bin/khu" ]] || fail 'no installed publisher binary at ~/Library/KHUpdater/bin/khu'
[[ -f "$PLIST" ]] || fail 'no publisher LaunchAgent plist to relabel'
"$ROOT/build/khu" helper-bundle --out "$BUNDLE" --name "Update Studio KH Publisher" \
  --id com.khupdater.publisher --exec "$K/bin/khu" --executable "Update Studio KH Publisher" \
  --icon "$ROOT/build/AppIcon.icns" >/dev/null
# Before the bundle, the plist named the binary as its program; the bundle executable already is
# that program, so everything before `serve` is dropped and the bundle path becomes argument 0.
# Running this again changes nothing.
INDEX=0
while [[ "$(/usr/bin/plutil -extract "ProgramArguments.$INDEX" raw -o - "$PLIST" 2>/dev/null)" != "serve" ]]; do
    [[ -n "$(/usr/bin/plutil -extract "ProgramArguments.$INDEX" raw -o - "$PLIST" 2>/dev/null)" ]] || fail "no serve command in $PLIST; nothing was changed"
    INDEX=$((INDEX + 1))
done
while (( INDEX > 0 )); do
    /usr/bin/plutil -remove ProgramArguments.0 "$PLIST"
    INDEX=$((INDEX - 1))
done
/usr/bin/plutil -insert ProgramArguments.0 -string "$BUNDLE/Contents/MacOS/Update Studio KH Publisher" "$PLIST"
/usr/bin/plutil -lint "$PLIST" >/dev/null
echo "publisher relabelled: $BUNDLE"
echo "restart it with: launchctl bootout gui/$(id -u)/com.khupdater.publisher; launchctl bootstrap gui/$(id -u) $PLIST"
