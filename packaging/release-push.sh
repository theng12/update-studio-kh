#!/bin/bash
# The release path: this Mac builds, the app's own GitHub repo holds the artifact.
#
#   packaging/release-push.sh <feed-app-id> <version> <dmg> <changelog> [kind]
#
# 1301 is an operational Mac, not a release host (owner, 2026-11-23: "no one should publish to
# 1301"). This wrapper used to scp the artifact there and run `khu publish`; that half is deleted
# rather than switched off, because a retired host does not need a switch. The artifact now goes to
# the app's own repo through packaging/github-asset.sh, which proves the bytes by fetching them back
# anonymously, and the feed is generated from that release.
set -euo pipefail
SELF=$(cd -- "$(dirname -- "$0")" && pwd)
[ $# -ge 4 ] || { echo "usage: $0 <feed-app-id> <version> <dmg> <changelog> [kind] --scan-receipt <file>" >&2; exit 2; }
APP="$1"; VERSION="$2"; DMG="$3"; LOG="$4"; shift 4
KIND=""; RECEIPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scan-receipt) [ $# -ge 2 ] && [ -n "$2" ] || { echo "release-push: --scan-receipt needs a file" >&2; exit 2; }
                    RECEIPT="$2"; shift 2 ;;
    -*) echo "release-push: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$KIND" ] || { echo "release-push: unexpected argument $1" >&2; exit 2; }
       KIND="$1"; shift ;;
  esac
done
[ -f "$DMG" ] || { echo "no such DMG: $DMG" >&2; exit 2; }
[ -f "$LOG" ] || { echo "no such changelog: $LOG" >&2; exit 2; }
# A scan receipt in a message is not a receipt (row 20261123-131: library 0.7.34's verdict was
# pasted into chat and written nowhere). The publish names the file, so a receipt that exists
# nowhere is a refusal rather than a fact someone remembers reading.
[ -n "$RECEIPT" ] || {
  echo "release-push: no scan receipt named — pass --scan-receipt <file>; without one this publish cannot be told apart from an unscanned artifact" >&2
  exit 2
}
[ -f "$RECEIPT" ] || {
  echo "release-push: no such scan receipt: $RECEIPT — write the file with the artifact's sha256 and its verdict before publishing" >&2
  exit 2
}
# The `updater` entry is the raw helper, and a stale build/khu is not it: publish the bytes sealed
# inside the Launcher that this version ships. Refusing beats publishing an unbuilt binary.
ORIG_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
if [ "$KIND" = "updater" ]; then
  SEALED=$("$SELF"/sealed-helper.sh "$VERSION") || exit 2
  if ! cmp -s "$DMG" "$SEALED"; then
    echo "release-push: $DMG is not the helper sealed in the Launcher; publishing $SEALED instead"
    DMG="$SEALED"
  fi
fi
# There is one place a release goes: the app's own repo. No repo named is a refusal, not a fallback.
[ -n "${KHU_PUBLIC_REPO:-}" ] || {
  echo "release-push: no public repo named for $APP — set KHU_PUBLIC_REPO=<owner/repo>; there is no other release host (1301 runs apps, it does not publish them)." >&2
  exit 2
}
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
# The receipt has to be about this artifact. A sealed helper is covered by the DMG it was taken from
# (the `cmp` above proves it is that helper), so either sha binds an honest receipt.
BOUND=""
for s in "$SHA" "$ORIG_SHA"; do
  if [ -n "$s" ] && grep -qi "$s" "$RECEIPT"; then BOUND=1; break; fi
done
[ -n "$BOUND" ] || {
  echo "release-push: $RECEIPT names neither $SHA nor the DMG it was scanned from ($ORIG_SHA) — that receipt is about a different artifact" >&2
  exit 2
}
grep -Eqi 'clean|SCAN_EXIT=0|"exit": *0|SCAN PASS|no findings' "$RECEIPT" || {
  echo "release-push: $RECEIPT carries no verdict; a receipt without one is a file, not a pass" >&2
  exit 2
}
URL=$("$SELF"/github-asset.sh "$KHU_PUBLIC_REPO" "${KHU_GITHUB_TAG:-$APP-$VERSION}" \
        "$DMG" "$SHA" "$(stat -f %z "$DMG")" "$LOG") || exit $?
echo "release-push: $KHU_PUBLIC_REPO holds the artifact at $URL"
