#!/bin/bash
# The release path: this Mac builds, 1301 publishes. Nothing here writes the feed.
#
#   packaging/release-push.sh <feed-app-id> <version> <dmg> <changelog>
#
# Copies the DMG and its changelog to the release host's staging folder and runs `khu publish`
# there, then reads the served feed back and prints the version it now offers. The feed, the
# retained pair and the retired artifacts all live on the release host.
set -euo pipefail
SELF=$(cd -- "$(dirname -- "$0")" && pwd)
HOST="${KHU_RELEASE_HOST:-vengtheng@100.82.91.102}"
KEY="${KHU_RELEASE_KEY:-$HOME/.ssh/id_ed25519_gateway1301}"
STAGE="${KHU_RELEASE_STAGE:-Library/KHUpdater/feed-incoming-$(date +%Y%m%d)}"
[ $# -eq 4 ] || [ $# -eq 5 ] || { echo "usage: $0 <feed-app-id> <version> <dmg> <changelog> [kind]" >&2; exit 2; }
APP="$1"; VERSION="$2"; DMG="$3"; LOG="$4"; KIND="${5:-}"
# The publisher writes the feed's category label from this release id, never from UI inference.
# An explicit label wins; the two Launcher components are labelled even by older wrappers that
# do not set the variable. Every other app keeps its current unlabelled state.
# `KHU_APP_TYPE=` set but empty means "no label on this one": needed to publish the helper onto a
# host whose own tool predates `--type`, and it can never label anything by accident.
TYPE=""
if [ -n "${KHU_APP_TYPE+set}" ]; then
  TYPE="${KHU_APP_TYPE}"
elif [ "$APP" = "launcher" ] || [ "$APP" = "updater" ]; then
  TYPE="system"
fi
if [ -n "$TYPE" ]; then
  case "$TYPE" in
    business|entertainment|extension|media|plugin|system|utility) ;;
    *) echo "release-push: KHU_APP_TYPE must be business, entertainment, extension, media, plugin, system or utility, not $TYPE" >&2; exit 2 ;;
  esac
fi
[ -f "$DMG" ] || { echo "no such DMG: $DMG" >&2; exit 2; }
[ -f "$LOG" ] || { echo "no such changelog: $LOG" >&2; exit 2; }
# 1301 is an operational Mac, not a release host (owner, 2026-11-23: "no one should publish to
# 1301"). There is no flag that re-enables it: the escape hatch this used to carry is how gateway
# 0.2.305 reached that host at 12:45Z on 2026-11-23 (issue 20261123-103). An artifact goes to its
# own app's repo and the feed is generated from there.
echo "release-push: $HOST is retired as a release host — 1301 runs apps, it does not publish them (owner, 2026-11-23). Put the artifact in its app's own repo instead: packaging/github-asset.sh <owner/repo> <tag> <dmg> <sha256> <bytes>." >&2
exit 2
# The `updater` entry is the raw helper, and a stale build/khu is not it: publish the bytes sealed
# inside the Launcher that this version ships. Refusing beats publishing an unbuilt binary.
if [ "$KIND" = "updater" ]; then
  SEALED=$("$SELF"/sealed-helper.sh "$VERSION") || exit 2
  if ! cmp -s "$DMG" "$SEALED"; then
    echo "release-push: $DMG is not the helper sealed in the Launcher; publishing $SEALED instead"
    DMG="$SEALED"
  fi
fi
BASE=$(basename "$DMG")
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$HOST")

# GitHub-first (§2a/§2b): when the app's own repo is named, its release holds the artifact and the
# row carries that absolute address. A repo that is private or not yet migrated is simply not named,
# and the row stays base-relative with 1301 serving it — nothing strands, and an offline Mac joins
# later instead of holding a release back. The upload happens before the publish, because a row
# naming an address that does not exist yet is a publish undone by a missing release.
URL=""
if [ -n "${KHU_PUBLIC_REPO:-}" ]; then
  # The host's own helper must understand `publish --url` before anything is uploaded; an upload
  # nothing points at is wasted, and a publish that refuses on an unknown flag breaks a release.
  if "${SSH[@]}" 'H="$HOME/Library/KHUpdater/base/current"; [ -x "$H" ] && "$H" publish --help 2>&1 | grep -q -- "--url"'; then
    SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
    URL=$("$SELF"/github-asset.sh "$KHU_PUBLIC_REPO" "${KHU_GITHUB_TAG:-$APP-$VERSION}" \
            "$DMG" "$SHA" "$(stat -f %z "$DMG")") || exit $?
    echo "release-push: $KHU_PUBLIC_REPO holds the artifact; the row will name $URL"
  else
    echo "release-push: skipped the GitHub upload — the host helper does not understand publish --url yet, so $APP's row stays base-relative and 1301 serves it"
  fi
else
  echo "release-push: no public repo named for $APP — the row stays base-relative and 1301 serves the artifact"
fi

"${SSH[@]}" "mkdir -p ~/$STAGE/changelogs"
scp -i "$KEY" -o BatchMode=yes "$DMG" "$HOST:$STAGE/$BASE"
scp -i "$KEY" -o BatchMode=yes "$LOG" "$HOST:$STAGE/changelogs/$APP.md"
# base/current moves with the agent's own updates; bin/khu is a copy that can fall behind, so it is
# never used instead: a missing base/current is refused by name, both paths, and the host is fixed.
# A genuinely new app says so once (`KHU_NEW_APP=1`); otherwise the host refuses an id it does not
# know, so a mistyped one cannot become a second app beside the real one.
"${SSH[@]}" "K=\$HOME/Library/KHUpdater; H=\"\$K/base/current\"; [ -f \"\$H\" ] && [ -x \"\$H\" ] || { echo \"release-push: \$H is missing or not executable; refusing to fall back to \$K/bin/khu, a copy that can lag the installed version. Repair base/current on this host.\" >&2; exit 1; }; \"\$H\" publish --feed \"\$K/feed\" --key \"\$K/keys/private.key\" \
  --app '$APP' --version '$VERSION' --artifact \"\$HOME/$STAGE/$BASE\" --changelog \"\$HOME/$STAGE/changelogs/$APP.md\" \
  ${KIND:+--kind '$KIND'} ${TYPE:+--type '$TYPE'} ${KHU_NEW_APP:+--new-app} ${URL:+--url '$URL'}"

/usr/bin/python3 -I - "http://${HOST#*@}:${KHU_RELEASE_PORT:-8790}/release.json" "$APP" "$VERSION" "$URL" <<'PY'
import base64, json, sys, urllib.request
feed_url, app, want, url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
feed = json.loads(base64.b64decode(json.load(urllib.request.urlopen(feed_url, timeout=20))["feed"]))
got = feed["apps"].get(app, {}).get("version")
previous = (feed.get("previous") or {}).get(app, {}).get("version")
print(f"feed offers {app} {got} (previous {previous}); expected {want}")
if url and feed["apps"].get(app, {}).get("url") != url:
    print(f"the served row does not name {url}; the download address did not survive the publish")
    raise SystemExit(1)
raise SystemExit(0 if got == want else 1)
PY
