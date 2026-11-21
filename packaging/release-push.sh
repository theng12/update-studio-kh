#!/bin/bash
# The release path: this Mac builds, 1301 publishes. Nothing here writes the feed.
#
#   packaging/release-push.sh <feed-app-id> <version> <dmg> <changelog>
#
# Copies the DMG and its changelog to the release host's staging folder and runs `khu publish`
# there, then reads the served feed back and prints the version it now offers. The feed, the
# retained pair and the retired artifacts all live on the release host.
set -euo pipefail
HOST="${KHU_RELEASE_HOST:-vengtheng@100.82.91.102}"
KEY="${KHU_RELEASE_KEY:-$HOME/.ssh/id_ed25519_gateway1301}"
STAGE="${KHU_RELEASE_STAGE:-Library/KHUpdater/feed-incoming-$(date +%Y%m%d)}"
[ $# -eq 4 ] || [ $# -eq 5 ] || { echo "usage: $0 <feed-app-id> <version> <dmg> <changelog> [kind]" >&2; exit 2; }
APP="$1"; VERSION="$2"; DMG="$3"; LOG="$4"; KIND="${5:-}"
# The publisher writes the feed's category label from this release id, never from UI inference.
# An explicit label wins; the two Launcher components are labelled even by older wrappers that
# do not set the variable. Every other app keeps its current unlabelled state.
TYPE="${KHU_APP_TYPE:-}"
if [ -n "$TYPE" ]; then
  case "$TYPE" in
    business|entertainment|media|system|utility) ;;
    *) echo "release-push: KHU_APP_TYPE must be business, entertainment, media, system or utility, not $TYPE" >&2; exit 2 ;;
  esac
elif [ "$APP" = "launcher" ] || [ "$APP" = "updater" ]; then
  TYPE="system"
fi
[ -f "$DMG" ] || { echo "no such DMG: $DMG" >&2; exit 2; }
[ -f "$LOG" ] || { echo "no such changelog: $LOG" >&2; exit 2; }
# The `updater` entry is the raw helper, and a stale build/khu is not it: publish the bytes sealed
# inside the Launcher that this version ships. Refusing beats publishing an unbuilt binary.
if [ "$KIND" = "updater" ]; then
  SEALED=$(packaging/sealed-helper.sh "$VERSION") || exit 2
  if ! cmp -s "$DMG" "$SEALED"; then
    echo "release-push: $DMG is not the helper sealed in the Launcher; publishing $SEALED instead"
    DMG="$SEALED"
  fi
fi
BASE=$(basename "$DMG")
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 "$HOST")

"${SSH[@]}" "mkdir -p ~/$STAGE/changelogs"
scp -i "$KEY" -o BatchMode=yes "$DMG" "$HOST:$STAGE/$BASE"
scp -i "$KEY" -o BatchMode=yes "$LOG" "$HOST:$STAGE/changelogs/$APP.md"
# base/current moves with the agent's own updates; bin/khu is a copy that can fall behind.
# A genuinely new app says so once (`KHU_NEW_APP=1`); otherwise the host refuses an id it does not
# know, so a mistyped one cannot become a second app beside the real one.
"${SSH[@]}" "K=\$HOME/Library/KHUpdater; H=\"\$K/base/current\"; [ -x \"\$H\" ] || H=\"\$K/bin/khu\"; \"\$H\" publish --feed \"\$K/feed\" --key \"\$K/keys/private.key\" \
  --app '$APP' --version '$VERSION' --artifact \"\$HOME/$STAGE/$BASE\" --changelog \"\$HOME/$STAGE/changelogs/$APP.md\" \
  ${KIND:+--kind '$KIND'} ${TYPE:+--type '$TYPE'} ${KHU_NEW_APP:+--new-app}"

/usr/bin/python3 -I - "$HOST" "$APP" "$VERSION" <<'PY'
import base64, json, sys, urllib.request
host, app, want = sys.argv[1].split("@")[-1], sys.argv[2], sys.argv[3]
feed = json.loads(base64.b64decode(json.load(urllib.request.urlopen(f"http://{host}:8790/release.json", timeout=20))["feed"]))
got = feed["apps"].get(app, {}).get("version")
previous = (feed.get("previous") or {}).get(app, {}).get("version")
print(f"feed offers {app} {got} (previous {previous}); expected {want}")
raise SystemExit(0 if got == want else 1)
PY
