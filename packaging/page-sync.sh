#!/bin/bash
# The eleven hand steps of a public release, in the one order that cannot lie.
#
#   packaging/page-sync.sh --app <id> --accepted <sha256> --repo <owner/name> --feed-url <url>
#   packaging/page-sync.sh --all --accepted-file <app<TAB>sha256> ...        (same required options)
#
# The 1301 feed is the only source of truth: every version, name, size, digest and icon comes from
# it, and every name that reaches the page is then read back from GitHub, because GitHub stores an
# asset name with its spaces rewritten to dots and the mirror must carry the name that exists.
# `--accepted` is the sha256 the page checker passed, and it must equal the feed's, so a build the
# checker refused can never reach the page. Nothing is guessed and nothing is overwritten: a
# precondition that does not hold stops the run before the next step, and says exactly what differed.
#
# The steps: read the feed · require the acceptance · obtain and hash the artifact · upload it under
# the feed's own name and read the stored name back · verify the stored digest · carry the icon onto
# the tag that stays · keep the previous release · rebuild the signed mirror on the publisher host
# with the feed re-read either side · commit that exact release.json and read both public addresses
# back. Step 8 and step 9 run once for the whole page, after every app has its row.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
  cat >&2 <<'TXT'
usage: packaging/page-sync.sh --app <id> --accepted <sha256> --repo <owner/name> --feed-url <url>
       packaging/page-sync.sh --all --accepted-file <app<TAB>sha256> --repo <owner/name> --feed-url <url>
  --artifact <path>    use this file instead of dist/ or the feed (its sha256 must still match)
  --publisher <host>   the publisher host holding the signing key (env KHU_RELEASE_HOST)
  --key <file>         its ssh key (env KHU_RELEASE_KEY, default ~/.ssh/id_ed25519_gateway1301)
  --dry-run            read everything, perform nothing
Env: KHU_PUBLIC_REPO, KHU_FEED_URL, KHU_PAGES_URL, KHU_RAW_URL, KHU_PUBLIC_WAIT (seconds, 180)
Exit: 0 in step · 2 usage · 5 refused, nothing after that step changed · 6 committed, not yet served
TXT
  exit 2
}

APP=""; ACCEPTED=""; ACCEPTED_FILE=""; ARTIFACT=""; ALL=0; DRY=0
REPO="${KHU_PUBLIC_REPO:-}"; FEED_URL="${KHU_FEED_URL:-}"; PUB_HOST="${KHU_RELEASE_HOST:-}"
PUB_KEY="${KHU_RELEASE_KEY:-$HOME/.ssh/id_ed25519_gateway1301}"
while [ $# -gt 0 ]; do
  case "$1" in
    --app|--accepted|--accepted-file|--artifact|--repo|--feed-url|--publisher|--key)
      [ $# -ge 2 ] || usage
      case "$1" in
        --app) APP="$2";; --accepted) ACCEPTED="$2";; --accepted-file) ACCEPTED_FILE="$2";;
        --artifact) ARTIFACT="$2";; --repo) REPO="$2";; --feed-url) FEED_URL="$2";;
        --publisher) PUB_HOST="$2";; --key) PUB_KEY="$2";;
      esac
      shift 2 ;;
    --all) ALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "page-sync: unknown option $1" >&2; usage ;;
  esac
done

[ -n "$REPO" ] || { echo "page-sync: name the public repo (--repo or KHU_PUBLIC_REPO); it is not built in" >&2; exit 2; }
[ -n "$FEED_URL" ] || { echo "page-sync: name the feed address (--feed-url or KHU_FEED_URL); it is not built in" >&2; exit 2; }
[ -n "$PUB_HOST" ] || { echo "page-sync: name the publisher host (--publisher or KHU_RELEASE_HOST); it is not built in" >&2; exit 2; }
case "$REPO" in */*) ;; *) echo "page-sync: --repo is owner/name, not $REPO" >&2; exit 2 ;; esac
case "$FEED_URL" in *"/release.json") ;; *) echo "page-sync: the feed address must end in /release.json: $FEED_URL" >&2; exit 2 ;; esac
FEED_BASE=${FEED_URL%/release.json}
OWNER=${REPO%%/*}; REPONAME=${REPO#*/}
PUBLIC_CANONICAL=${KHU_PAGES_URL:-https://$OWNER.github.io/$REPONAME/release.json}
PUBLIC_RAW=${KHU_RAW_URL:-https://raw.githubusercontent.com/$REPO/main/release.json}
WAIT=${KHU_PUBLIC_WAIT:-180}
EVIDENCE_EMAIL="112568204+theng12@users.noreply.github.com"
MIRROR_BASE="https://github.com/$REPO/releases/download"

# ---------- the task list: which apps, each with the sha256 its checker passed ----------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/khu-page-sync.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/apps.txt"; : > "$WORK/accepted.tsv"
if [ "$ALL" = 1 ]; then
  [ -n "$ACCEPTED_FILE" ] || { echo "page-sync: --all needs --accepted-file (one app<TAB>sha256 per line)" >&2; exit 2; }
  [ -f "$ACCEPTED_FILE" ] || { echo "page-sync: no such acceptance file: $ACCEPTED_FILE" >&2; exit 2; }
  awk -F'\t' 'NF>=2 && $2 ~ /^[0-9a-fA-F]{64}$/ {print tolower($1)}' "$ACCEPTED_FILE" | sort -u > "$WORK/apps.txt"
  awk -F'\t' 'NF>=2 && $2 ~ /^[0-9a-fA-F]{64}$/ {print tolower($1)"\t"tolower($2)}' "$ACCEPTED_FILE" > "$WORK/accepted.tsv"
else
  [ -n "$APP" ] || usage
  [ -n "$ACCEPTED" ] || { echo "page-sync: name the sha256 the page checker passed (--accepted)" >&2; exit 2; }
  printf '%s\n' "$APP" > "$WORK/apps.txt"
  printf '%s\t%s\n' "$APP" "$(printf %s "$ACCEPTED" | tr 'A-F' 'a-f')" > "$WORK/accepted.tsv"
fi
[ -s "$WORK/apps.txt" ] || { echo "page-sync: no app to sync" >&2; exit 2; }
# A line that is not "app<TAB>sha256" is said out loud, never dropped in silence.
if [ "$ALL" = 1 ]; then
  awk -F'\t' 'NF<2 || $2 !~ /^[0-9a-fA-F]{64}$/ {print "page-sync: ignoring line " NR " of the acceptance file (it is not app<TAB>sha256): " $0}' "$ACCEPTED_FILE" >&2
fi
while IFS= read -r a; do
  case "$a" in ""|*[!a-z0-9-]*) echo "page-sync: not an app id: $a" >&2; exit 2 ;; esac
done < "$WORK/apps.txt"

# ---------- the report: one line per step, and a reason on every line that is not a step ----------
STEP=0; LABEL=feed; SUBJ=-
CHANGED=0; SKIPPED=0; DONE=0
begin() { STEP=$((STEP+1)); LABEL=$1; DONE=$((DONE+1)); }
ok()    { printf '%-14s %d %-8s %s\n' "$SUBJ" "$STEP" "$LABEL" "$*"; }
skip()  { SKIPPED=$((SKIPPED+1)); printf '%-14s %d %-8s skipped: %s\n' "$SUBJ" "$STEP" "$LABEL" "$*"; }
would() { printf '%-14s %d %-8s would %s\n' "$SUBJ" "$STEP" "$LABEL" "$*"; }
did()   { CHANGED=$((CHANGED+1)); ok "$*"; }
refuse() {
  printf '%-14s %d %-8s REFUSED: %s\n' "$SUBJ" "$STEP" "$LABEL" "$*"
  printf 'page-sync: %s stopped at step %d — nothing after it was changed%s\n' "$SUBJ" "$STEP" \
    "$([ "$CHANGED" -gt 0 ] && echo "; $CHANGED earlier action(s) stand and the mirror was not rebuilt, so the feed is unchanged")"
  exit 5
}
not_served() {
  printf '%-14s %d %-8s NOT YET SERVED: %s\n' "$SUBJ" "$STEP" "$LABEL" "$*"
  printf 'page-sync: %s committed but not yet accepted — see step %d\n' "$SUBJ" "$STEP"
  exit 6
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
bytes_of() { stat -f %z "$1"; }
url_quote() { python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
pub() { ssh -i "$PUB_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$PUB_HOST" "$1"; }

# The feed's own name for this app, and the feed's whole published_at line, as tab-separated rows:
#   published_at<TAB><when>      app<TAB>id<TAB>version<TAB>file<TAB>sha256<TAB>bytes<TAB>icon<TAB>iconSha<TAB>previous version
#                                <TAB>previous file<TAB>previous sha256<TAB>previous bytes<TAB>previous icon<TAB>previous iconSha
feed_tsv() {
  python3 -I - "$1" <<'PY'
import base64, json, sys
env = json.load(open(sys.argv[1]))
feed = json.loads(base64.b64decode(env["feed"]))
print("published_at\t" + feed["published_at"])
for app in sorted(feed["apps"]):
    e = feed["apps"][app]
    prev = (feed.get("previous") or {}).get(app) or {}
    print("\t".join([app, e["version"], e["file"], e["sha256"], str(e["bytes"]),
                     e.get("icon") or "", e.get("iconSha256") or "", prev.get("version") or "",
                     prev.get("file") or "", prev.get("sha256") or "", str(prev.get("bytes") or ""),
                     prev.get("icon") or "", prev.get("iconSha256") or ""]))
PY
}

feed_read() {
  curl -fsS --retry 3 --connect-timeout 10 --max-time 60 "$FEED_URL?t=$(date +%s%N)" -o "$1"
}

page_releases() {
  gh api "repos/$REPO/releases?per_page=100" > "$WORK/releases.json" || return 1
  python3 -I - "$WORK/releases.json" <<'PY' || return 1
import json, sys
rels = json.load(open(sys.argv[1]))
if len(rels) >= 100:
    print("the page answered with 100 releases, so the list may be truncated; refusing to read it as complete", file=sys.stderr)
    raise SystemExit(1)
PY
}

# The stored assets of one tag: name, digest, size — one line each, nothing when the tag is absent.
tag_assets() {
  gh api "repos/$REPO/releases/tags/$1" > "$WORK/tag.json" 2>/dev/null || { rm -f "$WORK/tag.json"; return 1; }
  python3 -I - "$WORK/tag.json" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1]))
for a in rel.get("assets", []):
    print("\t".join([a["name"], (a.get("digest") or "").replace("sha256:", ""), str(a["size"])]))
PY
}

# =====================================================================================
# Steps 1–7, one app at a time.
# =====================================================================================
sync_app() {
  APP="$1"
  ACCEPTED=$(awk -F'\t' -v a="$APP" '$1==a {print $2; exit}' "$WORK/accepted.tsv")
  SUBJ=$APP

  # 1 — the live feed is the only source of truth.
  begin feed
  feed_read "$WORK/feed-$APP.json" || refuse "cannot read the feed at $FEED_URL"
  feed_tsv "$WORK/feed-$APP.json" > "$WORK/feed-$APP.tsv"
  WHEN=$(awk -F'\t' '$1=="published_at" {print $2}' "$WORK/feed-$APP.tsv")
  ROW=$(awk -F'\t' -v a="$APP" '$1==a' "$WORK/feed-$APP.tsv")
  [ -n "$ROW" ] || refuse "the feed has no $APP"
  # Tab is IFS *whitespace*, so `read` collapses runs of it and empty fields vanish: a null-icon
  # row parsed the previous version into A_ICON ("cannot download the icon 0.1.70", issue
  # 20261120-192). Split on a non-whitespace unit separator instead, where empties survive.
  IFS=$'\x1f' read -r _ A_VER A_FILE A_SHA A_BYTES A_ICON A_ICONSHA A_PREV A_PREVFILE A_PREVSHA A_PREVBYTES A_PREVICON A_PREVICONSHA <<<"${ROW//$'\t'/$'\x1f'}"
  A_SHA=$(printf %s "$A_SHA" | tr 'A-F' 'a-f'); A_ICONSHA=$(printf %s "$A_ICONSHA" | tr 'A-F' 'a-f')
  A_PREVSHA=$(printf %s "$A_PREVSHA" | tr 'A-F' 'a-f'); A_PREVICONSHA=$(printf %s "$A_PREVICONSHA" | tr 'A-F' 'a-f')
  TAG="$APP-$A_VER"
  ok "$A_VER $A_FILE $A_BYTES bytes sha256 $A_SHA, published $WHEN"

  # 2 — the acceptance is the whole reason this exists.
  begin accepted
  [ "$ACCEPTED" = "$A_SHA" ] || refuse "the checker passed $ACCEPTED, the feed offers $A_SHA — this build is not the one that passed; nothing was touched"
  ok "$A_SHA"

  # 3 — the artifact, hashed against the feed before anything sees it.
  begin artifact
  if [ "$DRY" = 1 ]; then
    if [ -n "$ARTIFACT" ]; then would "use $ARTIFACT and verify it hashes to $A_SHA"
    elif [ -f "$ROOT/dist/$A_FILE" ]; then would "use $ROOT/dist/$A_FILE and verify it hashes to $A_SHA"
    else would "download $FEED_BASE/artifacts/$A_FILE and verify it hashes to $A_SHA"; fi
    begin upload; would "create release $TAG with $A_FILE and read the stored name back"
    begin digest; would "require the stored digest to be $A_SHA"
    begin icon
    if [ -z "$A_ICON" ]; then skip "the feed names no icon for $APP"; else would "put $A_ICON on $TAG and verify $A_ICONSHA"; fi
    begin previous
    if [ -z "$A_PREV" ]; then skip "the feed holds no previous version"; else would "keep the $APP-$A_PREV row, adding it when the page lacks it"; fi
    return 0
  fi
  A_SRC=""; A_HOW=""
  if [ -n "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] || refuse "no such file: $ARTIFACT"
    A_SRC=$ARTIFACT; A_HOW="local $ARTIFACT"
  elif [ -f "$ROOT/dist/$A_FILE" ]; then
    A_SRC="$ROOT/dist/$A_FILE"; A_HOW="local dist/$A_FILE"
  else
    A_SRC="$WORK/$A_FILE"; A_HOW="downloaded from $FEED_BASE/artifacts/$A_FILE"
    curl -fsL --retry 3 --connect-timeout 10 "$FEED_BASE/artifacts/$(url_quote "$A_FILE")" -o "$A_SRC" \
      || refuse "cannot download $A_FILE from $FEED_BASE/artifacts/"
  fi
  GOT_SHA=$(sha_of "$A_SRC"); GOT_BYTES=$(bytes_of "$A_SRC")
  [ "$GOT_SHA" = "$A_SHA" ] || refuse "$A_HOW hashes to $GOT_SHA, the feed says $A_SHA"
  [ "$GOT_BYTES" = "$A_BYTES" ] || refuse "$A_HOW is $GOT_BYTES bytes, the feed says $A_BYTES"
  # The page stores the file under its own basename, so the bytes must sit under the feed's name.
  if [ "$(basename "$A_SRC")" != "$A_FILE" ]; then
    cp "$A_SRC" "$WORK/$A_FILE"; A_SRC="$WORK/$A_FILE"
  fi
  ok "$A_HOW — sha256 and $A_BYTES bytes match the feed"

  # 4 — upload under the feed's own name; a row that is already right is left alone.
  begin upload
  rm -f "$WORK/tag.json"
  tag_assets "$TAG" >/dev/null || true
  EXISTING=""
  if [ -f "$WORK/tag.json" ]; then EXISTING=$(python3 -I - "$WORK/tag.json" "$A_FILE" "$A_SHA" <<'PY'
import json, sys
rel = json.load(open(sys.argv[1])); name, sha = sys.argv[2], sys.argv[3]
for a in rel.get("assets", []):
    d = (a.get("digest") or "").replace("sha256:", "")
    if d == sha: print("same"); break
    if a["name"] == name: print("differ\t" + a["name"] + "\t" + (d or "no digest")); break
PY
)
  fi
  case "$EXISTING" in
    same) ok "$TAG already carries the feed's bytes — nothing to upload" ;;
    differ*)
      IFS=$'\x1f' read -r _ dname ddg <<<"${EXISTING//$'\t'/$'\x1f'}"
      refuse "$TAG already holds $dname with digest $ddg, not $A_SHA; a published DMG is never overwritten" ;;
    *)
      if [ -f "$WORK/tag.json" ]; then
        gh release upload "$TAG" "$A_SRC" -R "$REPO" >/dev/null 2>"$WORK/gh.err" \
          || refuse "the upload of $A_FILE to $TAG failed: $(tail -1 "$WORK/gh.err")"
        did "uploaded $A_FILE to the existing release $TAG"
      else
        gh release create "$TAG" "$A_SRC" -R "$REPO" --title "$APP $A_VER" \
          --notes "Signed release from the KH Studio feed. The install guide is in the README." \
          >/dev/null 2>"$WORK/gh.err" \
          || refuse "creating release $TAG failed: $(tail -1 "$WORK/gh.err")"
        did "created $TAG with $A_FILE"
      fi ;;
  esac

  # 5 — the stored name and digest, read back. GitHub is the authority on what it stored.
  begin digest
  STORED=$(tag_assets "$TAG" | awk -F'\t' -v s="$A_SHA" '$2==s {print $1; exit}') \
    || refuse "the page has no release $TAG after the upload"
  [ -n "$STORED" ] || refuse "$TAG carries no asset with digest $A_SHA; the page does not hold this build"
  if [ "$STORED" = "$A_FILE" ]; then
    ok "$STORED, digest $A_SHA"
  else
    CHANGED=$((CHANGED+1)); ok "$STORED, digest $A_SHA (GitHub stored it under this name, and the mirror will carry it)"
  fi

  # 6 — the icon lives on the tag, so it is put on the tag that stays.
  begin icon
  if [ -z "$A_ICON" ]; then
    skip "the feed names no icon for $APP"
  elif tag_assets "$TAG" | awk -F'\t' -v s="$A_ICONSHA" '$2==s {found=1} END {exit !found}'; then
    ok "$A_ICON is already on $TAG and hashes to the feed's iconSha256"
  else
    ICON_LOCAL="$WORK/$A_ICON"
    curl -fsL --retry 3 --connect-timeout 10 "$FEED_BASE/artifacts/$(url_quote "$A_ICON")" -o "$ICON_LOCAL" \
      || refuse "cannot download the icon $A_ICON from $FEED_BASE/artifacts/"
    [ "$(sha_of "$ICON_LOCAL")" = "$A_ICONSHA" ] \
      || refuse "the downloaded $A_ICON hashes to $(sha_of "$ICON_LOCAL"), the feed says $A_ICONSHA"
    gh release upload "$TAG" "$ICON_LOCAL" -R "$REPO" >/dev/null 2>"$WORK/gh.err" \
      || refuse "putting $A_ICON on $TAG failed: $(tail -1 "$WORK/gh.err")"
    tag_assets "$TAG" | awk -F'\t' -v s="$A_ICONSHA" '$2==s {found=1} END {exit !found}' \
      || refuse "$A_ICON is not on $TAG with the feed's iconSha256 after the upload"
    did "put $A_ICON on $TAG, hash $A_ICONSHA"
  fi

  # 7 — the previous release stays on the page. Retention is current + previous everywhere else,
  # and a page that deletes the asset its own `previous` entry names breaks that rule, so this step
  # makes the previous row present and never deletes one.
  begin previous
  if [ -z "$A_PREV" ] || [ -z "$A_PREVFILE" ]; then
    skip "the feed holds no previous version of $APP"
  else
    PREV_TAG="$APP-$A_PREV"
    [ "$PREV_TAG" != "$TAG" ] || refuse "the feed names $TAG as its own previous version"
    if tag_assets "$PREV_TAG" | awk -F'\t' -v s="$A_PREVSHA" '$2==s {found=1} END {exit !found}'; then
      ok "$PREV_TAG is on the page with the feed's bytes — kept"
    else
      P_SRC="$WORK/$A_PREVFILE"
      curl -fsL --retry 3 --connect-timeout 10 "$FEED_BASE/artifacts/$(url_quote "$A_PREVFILE")" -o "$P_SRC" \
        || refuse "cannot download $A_PREVFILE from $FEED_BASE/artifacts/"
      [ "$(sha_of "$P_SRC")" = "$A_PREVSHA" ] || refuse "the downloaded $A_PREVFILE hashes to $(sha_of "$P_SRC"), the feed says $A_PREVSHA"
      if [ -f "$WORK/tag.json" ]; then
        gh release upload "$PREV_TAG" "$P_SRC" -R "$REPO" >/dev/null 2>"$WORK/gh.err" \
          || refuse "adding $A_PREVFILE to the existing release $PREV_TAG failed: $(tail -1 "$WORK/gh.err")"
        did "kept $PREV_TAG and put $A_PREVFILE on it"
      else
        gh release create "$PREV_TAG" "$P_SRC" -R "$REPO" --title "$APP $A_PREV" \
          --notes "Signed release from the KH Studio feed, kept as the previous version." \
          >/dev/null 2>"$WORK/gh.err" \
          || refuse "creating release $PREV_TAG failed: $(tail -1 "$WORK/gh.err")"
        did "created $PREV_TAG with $A_PREVFILE as the page's previous version"
      fi
      tag_assets "$PREV_TAG" | awk -F'\t' -v s="$A_PREVSHA" '$2==s {found=1} END {exit !found}' \
        || refuse "$PREV_TAG carries no asset with the feed's previous sha256 after the upload"
    fi
  fi
}

while IFS= read -r app; do sync_app "$app"; done < "$WORK/apps.txt"

# =====================================================================================
# Step 8 — the signed mirror, built on the publisher host, with the feed read either side.
# =====================================================================================
SUBJ=page
begin mirror
if [ "$DRY" = 1 ]; then
  would "rebuild the signed mirror on $PUB_HOST from the feed's current rows and re-read the feed either side"
  begin commit
  would "commit that exact release.json to $REPO and read $PUBLIC_CANONICAL and $PUBLIC_RAW back"
  printf 'page-sync: dry run — %d steps printed, nothing performed\n' "$DONE"
  exit 0
fi
feed_read "$WORK/feed-before.json" || refuse "cannot read the feed at $FEED_URL"
feed_tsv "$WORK/feed-before.json" > "$WORK/feed-before.tsv"
WHEN_BEFORE=$(awk -F'\t' '$1=="published_at" {print $2}' "$WORK/feed-before.tsv")
page_releases || refuse "cannot list the page's releases"

MIRROR_APPS=$(python3 -I - "$WORK/feed-before.tsv" "$WORK/releases.json" "$WORK/names.tsv" 2>&1 <<'PY'
import json, re, sys
feed_tsv, releases_json, names_out = sys.argv[1:4]
rows = [l.rstrip("\n").split("\t") for l in open(feed_tsv) if l.strip()]
apps = {r[0]: r for r in rows if r[0] != "published_at"}
rels = json.load(open(releases_json))
version = re.compile(r"^\d+(\.\d+)+$")
owner = {}
for rel in rels:
    tag = rel.get("tag_name", "")
    best = None
    for app in apps:
        if tag.startswith(app + "-") and version.match(tag[len(app) + 1:]):
            if best is None or len(app) > len(best): best = app
    if best: owner.setdefault(best, []).append(rel)
out, carrying, gaps = [], [], []
for app in sorted(owner):
    r = apps[app]
    ver, file, sha, icon, iconsha = r[1], r[2], r[3], r[5], r[6]
    prev_ver = r[7] if len(r) > 7 else ""
    prev_file = r[8] if len(r) > 8 else ""
    prev_sha = r[9] if len(r) > 9 else ""
    prev_icon = r[11] if len(r) > 11 else ""
    prev_iconsha = r[12] if len(r) > 12 else ""

    def release_for(version):
        return next((x for x in owner[app] if x.get("tag_name") == app + "-" + version), None)

    def stored(rel, want):
        return next((a["name"] for a in (rel or {}).get("assets", [])
                     if (a.get("digest") or "").replace("sha256:", "") == want), None)

    rel = release_for(ver)
    behind = rel is None or not stored(rel, sha)
    if behind:
        # This app's page row is behind the feed. Keep the newest version the page does carry, so one
        # behind app cannot fail every other row; the caller names it and decides its own exit code.
        rel = release_for(prev_ver) if prev_ver else None
        if rel is None or not stored(rel, prev_sha):
            print("the page has no %s row and no %s row either (%s); run page-sync for %s first"
                  % (app + "-" + ver, app + "-" + prev_ver, ", ".join(sorted(x.get("tag_name", "") for x in owner[app])), app))
            raise SystemExit(3)
        out.append("\t".join([app, app + "-" + prev_ver, prev_file, stored(rel, prev_sha), prev_sha]))
        if prev_icon:
            if not prev_iconsha or not stored(rel, prev_iconsha):
                print("the page's %s carries no %s with the feed's iconSha256" % (app + "-" + prev_ver, prev_icon))
                raise SystemExit(3)
            out.append("\t".join([app, app + "-" + prev_ver, prev_icon, stored(rel, prev_iconsha), prev_iconsha]))
        gaps.append(app)
        carrying.append(app)
        continue
    tag = app + "-" + ver
    out.append("\t".join([app, tag, file, stored(rel, sha), sha]))
    if icon:
        if not iconsha or not stored(rel, iconsha):
            print("the page's %s carries no %s with the feed's iconSha256; run page-sync for %s first" % (tag, icon, app))
            raise SystemExit(3)
        out.append("\t".join([app, tag, icon, stored(rel, iconsha), iconsha]))
    # The previous release rides in the mirror too, so a public Mac keeps current + previous.
    if prev_ver and prev_file:
        prev_rel = release_for(prev_ver)
        if prev_rel is None or not stored(prev_rel, prev_sha):
            print("the page has no %s row for the feed's previous version; run page-sync for %s first" % (app + "-" + prev_ver, app))
            raise SystemExit(3)
        out.append("\t".join([app, app + "-" + prev_ver, prev_file, stored(prev_rel, prev_sha), prev_sha]))
        if prev_icon and prev_iconsha:
            prev_icon_name = stored(prev_rel, prev_iconsha)
            if prev_icon_name:
                out.append("\t".join([app, app + "-" + prev_ver, prev_icon, prev_icon_name, prev_iconsha]))
    carrying.append(app)
if not carrying:
    print("no app on the page is in the feed, so there is nothing to mirror"); raise SystemExit(3)
open(names_out, "w").write("\n".join(out) + "\n")
open(names_out + ".behind", "w").write(",".join(gaps))
print(",".join(carrying))
PY
) || refuse "$MIRROR_APPS"
BEHIND=$(cat "$WORK/names.tsv.behind" 2>/dev/null || true)

# The names table carries the name GitHub actually stored, so it is written from the readback above.
pub 'K="$HOME/Library/KHUpdater"; mkdir -p "$K/page-sync" && cat > "$K/page-sync/names.tsv"' < "$WORK/names.tsv" \
  || refuse "cannot write the names table on $PUB_HOST"
# No --current-only: the page keeps current + previous, like the rest of the estate.
MIRROR_OUT=$(pub "K=\"\$HOME/Library/KHUpdater\"; H=\"\$K/base/current\"; [ -f \"\$H\" ] && [ -x \"\$H\" ] || { echo \"page-sync: \$H is missing or not executable; refusing to fall back to \$K/bin/khu, a copy that can lag the installed version. Repair base/current on this host.\" >&2; exit 1; }
\"\$H\" mirror --feed \"\$K/feed\" --key \"\$K/keys/private.key\" --out \"\$K/page-sync/release.json\" \
  --base '$MIRROR_BASE' --names \"\$K/page-sync/names.tsv\" --apps '$MIRROR_APPS'" 2>&1) \
  || refuse "the mirror build on $PUB_HOST failed: $(printf '%s' "$MIRROR_OUT" | tail -1)"
# A page row behind is named once and does not fail the run — unless it is this run's own app, in
# which case the operator asked for something the page cannot carry yet.
if [ -n "$BEHIND" ]; then
  for app in ${BEHIND//,/ }; do
    if [ "$ALL" = 1 ] || [ "$app" = "$APP" ]; then
      refuse "$app's page row is behind the feed ($BEHIND); run page-sync for $app once its release is on the page"
    fi
  done
  ok "page rows behind the feed, kept as they are: $BEHIND"
fi
pub 'cat "$HOME/Library/KHUpdater/page-sync/release.json"' > "$WORK/release.json" \
  || refuse "cannot read the mirror file back from $PUB_HOST"
[ -s "$WORK/release.json" ] || refuse "the mirror file read back from $PUB_HOST is empty"

feed_read "$WORK/feed-after.json" || refuse "cannot re-read the feed after the mirror build"
feed_tsv "$WORK/feed-after.json" > "$WORK/feed-after.tsv"
WHEN_AFTER=$(awk -F'\t' '$1=="published_at" {print $2}' "$WORK/feed-after.tsv")

MIRROR_WHEN=$(python3 -I - "$WORK/release.json" "$WORK/feed-before.json" "$WORK/feed-after.json" 2>&1 <<'PY'
import base64, json, re, sys
mirror_file, before_file, after_file = sys.argv[1:4]
def feed_of(path): return json.loads(base64.b64decode(json.load(open(path))["feed"]))
mine, before, after = feed_of(mirror_file), feed_of(before_file), feed_of(after_file)
if before["published_at"] != after["published_at"]:
    print("the feed moved while the mirror was being built (%s then %s; re-run against the new one)"
          % (before["published_at"], after["published_at"])); raise SystemExit(3)
if mine["published_at"] != before["published_at"]:
    print("the mirror is dated %s and the feed %s, so the mirror was not built from this feed"
          % (mine["published_at"], before["published_at"])); raise SystemExit(3)
def identity(entries):
    # tagline is in the comparison on purpose: the page card reads it, a dropped one is invisible
    # (the card keeps old words), and version/sha/bytes cannot see it. Default keeps tagless apps valid.
    return sorted("%s|%s|%s|%s|%s" % (k, v["version"], v["sha256"], v["bytes"], v.get("tagline", ""))
                  for k, v in entries.items())
# The feed carries apps the page has no row for (Hub, the updater helper); the mirror cannot name
# them, so only the apps it carries are compared. A row the page is behind on is compared against
# the feed's previous entry, which is the version the mirror carries for it.
for app, entry in mine["apps"].items():
    if app not in after["apps"]:
        continue
    want = after["apps"][app]
    if want.get("version") != entry.get("version"):
        want = (after.get("previous") or {}).get(app) or {}
    if want.get("version") != entry.get("version") or identity({app: want}) != identity({app: entry}):
        print("the mirror does not name the feed's artifacts for %s" % app); raise SystemExit(3)
# The page carries the same shape as the feed: previous entries ride in the same envelope, and the
# network block keeps its public addresses. A dropped key is invisible in version/sha/bytes — the
# same reason `tagline` is in the identity comparison — so each is checked by name.
fed_prev, mine_prev = after.get("previous") or {}, mine.get("previous") or {}
for app, entry in mine["apps"].items():
    p = fed_prev.get(app)
    if not p or app in mine_prev:
        continue
    if entry.get("version") != p.get("version"):   # a behind app keeps its newest page row instead
        print("the mirror dropped the feed's previous entry for %s" % app); raise SystemExit(3)
fed_urls = (after.get("network") or {}).get("feedURLs") or []
if fed_urls and ((mine.get("network") or {}).get("feedURLs") or []) != fed_urls:
    print("the mirror dropped the feed's network addresses"); raise SystemExit(3)
if after.get("previousExtensions") and not mine.get("previousExtensions"):
    print("the mirror dropped the feed's previous extensions"); raise SystemExit(3)
# `com.terranash.<app>` is the reserved bundle-id domain: it sits in every copy's Info.plist and is
# public wherever it appears, so it is allowed in every field — not only in `bundleID`, which made
# the same string a leak in a changelog sentence and no leak in a plist. Everything else is still
# scanned: a tailnet host, a ts.net URL, an address or the machine-name form `terranash-<host>`
# does not match this prefix and still fails.
text = re.sub(r"(?i)com\.terranash\.[a-z0-9._-]+", "", json.dumps(mine))
# What is caught is a real identifier, never a name the owner chose to ship: an absolute home path, a
# private key, an email address, a tailnet host or address, or the machine-name form (owner, 2026-11-21:
# exempt `com.terranash.` and "keep catching /Users paths, tailnet hosts, emails and keys").
for pattern in (r"[A-Za-z0-9][A-Za-z0-9.-]*\.ts\.net", r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b",
                r"(?i)terranash", r"(?i)macmini",
                r"/Users/[A-Za-z0-9._-]+", r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}",
                r"BEGIN [A-Z ]*PRIVATE KEY"):
    if re.search(pattern, text):
        print("the public copy matches %s" % pattern); raise SystemExit(3)
print(mine["published_at"])
PY
) || refuse "$MIRROR_WHEN"
[ "$MIRROR_WHEN" = "$WHEN_BEFORE" ] && [ "$MIRROR_WHEN" = "$WHEN_AFTER" ] \
  || refuse "the mirror is dated $MIRROR_WHEN, the feed $WHEN_BEFORE then $WHEN_AFTER"
did "built on $PUB_HOST for $MIRROR_APPS from the feed published $WHEN_BEFORE; the feed did not move; controller withheld from the public copy by policy (a page-only Mac cannot follow a handoff)"

# =====================================================================================
# Step 9 — commit that exact file, then read both public addresses back.
# =====================================================================================
begin commit
REL_SHA=$(sha_of "$WORK/release.json")
python3 -I - "$WORK/release.json" "$WORK/release.b64" <<'PY'
import base64, sys
open(sys.argv[2], "w").write(base64.b64encode(open(sys.argv[1], "rb").read()).decode())
PY
if gh api "repos/$REPO/contents/release.json" > "$WORK/contents.json" 2>/dev/null; then
  BLOB=$(python3 -I - "$WORK/contents.json" "$WORK/release.json" <<'PY'
import base64, hashlib, json, sys
held = json.load(open(sys.argv[1]))
mine = open(sys.argv[2], "rb").read()
same = base64.b64decode(held.get("content", "")) == mine
print((held.get("sha", "") if not same else "") + ("\tsame" if same else "\tdiffer"))
PY
)
  BLOB_SHA=${BLOB%%$'\t'*}; SAME=${BLOB##*$'\t'}
else
  BLOB_SHA=""; SAME="differ"
fi
if [ "$SAME" = "same" ]; then
  ok "release.json already holds these exact bytes (sha256 $REL_SHA) — no commit made"
else
  gh api -X PUT "repos/$REPO/contents/release.json" \
    -f message="release.json: $(printf '%s' "$MIRROR_APPS" | tr ',' ' ') from the KH Studio feed" \
    -f content="$(cat "$WORK/release.b64")" ${BLOB_SHA:+-f sha="$BLOB_SHA"} -f branch=main \
    -f "committer[name]=KH Studio" -f "committer[email]=$EVIDENCE_EMAIL" \
    -f "author[name]=KH Studio" -f "author[email]=$EVIDENCE_EMAIL" \
    > "$WORK/put.json" 2>"$WORK/gh.err" \
    || refuse "committing release.json failed: $(tail -1 "$WORK/gh.err")"
  gh api "repos/$REPO/contents/release.json" > "$WORK/contents.json" 2>/dev/null \
    || refuse "cannot read release.json back from $REPO after the commit"
  python3 -I - "$WORK/contents.json" "$WORK/release.json" <<'PY' || refuse "the committed release.json is not the file that passed verification"
import base64, json, sys
held = json.load(open(sys.argv[1]))
raise SystemExit(0 if base64.b64decode(held.get("content", "")) == open(sys.argv[2], "rb").read() else 1)
PY
  did "committed release.json (sha256 $REL_SHA) as $EVIDENCE_EMAIL"
fi

# Both addresses must serve the bytes that just passed. Pages builds after the commit and raw caches,
# so each is polled to a bounded deadline and the answer is reported, never assumed.
served() { # served <url> <out>
  local tries=$((WAIT / 5)) n=0
  while [ "$n" -lt "$tries" ]; do
    n=$((n+1))
    if curl -fsS --connect-timeout 10 --max-time 60 "$1?t=$(date +%s%N)" -o "$2" 2>/dev/null; then
      cmp -s "$2" "$WORK/release.json" && return 0
    fi
    sleep 5
  done
  return 1
}
served "$PUBLIC_CANONICAL" "$WORK/canonical.json" || {
  SIDE="the canonical address served $([ -f "$WORK/canonical.json" ] && sha_of "$WORK/canonical.json" || echo nothing)"
  not_served "$SIDE within ${WAIT}s; the commit holds sha256 $REL_SHA — re-run when Pages has built" ; }
served "$PUBLIC_RAW" "$WORK/raw.json" || {
  SIDE="the raw address served $([ -f "$WORK/raw.json" ] && sha_of "$WORK/raw.json" || echo nothing)"
  not_served "$SIDE within ${WAIT}s; the commit holds sha256 $REL_SHA — re-run when the cache has turned over" ; }
ok "both public addresses serve sha256 $REL_SHA"

printf 'page-sync: %s — %d steps, %d changed, %d skipped, 0 refused\n' \
  "$(tr '\n' ' ' < "$WORK/apps.txt" | sed 's/ $//')" "$DONE" "$CHANGED" "$SKIPPED"
