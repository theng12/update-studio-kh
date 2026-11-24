#!/bin/bash
# Writes the DMG's `Read Me First.txt` (owner, 2026-11-23). Its first line is the exact command a
# person runs after dragging the app to Applications, and the same line is used in the release notes
# and on the download page. Plain text on purpose: a `.command` inside a quarantined DMG is itself
# quarantined, so macOS refuses to run the very thing meant to fix quarantine.
#
# The path is /Applications, never /Volumes/…: that one breaks the moment the image is ejected, and
# is wrong after the copy anyway.
# usage: read-me-first.sh "<App Name>.app" <directory the image is built from>
set -euo pipefail
APP_NAME="${1:?app name ending in .app}"
DIR="${2:?output directory}"
case "$APP_NAME" in
  *.app) ;;
  *) echo "read-me-first.sh needs an app name ending in .app, not $APP_NAME" >&2; exit 2 ;;
esac
mkdir -p "$DIR"
cat > "$DIR/Read Me First.txt" <<EOF
xattr -dr com.apple.quarantine "/Applications/$APP_NAME"
Drag $APP_NAME to Applications first, then run this in Terminal — it is only needed for a DMG or zip downloaded in a browser; an install the Launcher makes itself is not quarantined.
EOF
chmod 0644 "$DIR/Read Me First.txt"
