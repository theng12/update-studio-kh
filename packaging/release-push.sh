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
[ $# -eq 4 ] || [ $# -eq 5 ] || { echo "usage: $0 <feed-app-id> <version> <dmg> <changelog> [kind]" >&2; exit 2; }
APP="$1"; VERSION="$2"; DMG="$3"; LOG="$4"; KIND="${5:-}"
[ -f "$DMG" ] || { echo "no such DMG: $DMG" >&2; exit 2; }
[ -f "$LOG" ] || { echo "no such changelog: $LOG" >&2; exit 2; }
# The `updater` entry is the raw helper, and a stale build/khu is not it: publish the bytes sealed
# inside the Launcher that this version ships. Refusing beats publishing an unbuilt binary.
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
URL=$("$SELF"/github-asset.sh "$KHU_PUBLIC_REPO" "${KHU_GITHUB_TAG:-$APP-$VERSION}" \
        "$DMG" "$SHA" "$(stat -f %z "$DMG")" "$LOG") || exit $?
echo "release-push: $KHU_PUBLIC_REPO holds the artifact at $URL"
