#!/bin/bash
# Put one released artifact on its app's GitHub release and prove GitHub stored those exact bytes.
#
#   packaging/github-asset.sh <owner/repo> <tag> <artifact> <sha256> <bytes>
#
# Prints the asset's absolute download URL on success. The release is created non-draft, and the
# publish that follows names it: a draft is invisible to clients, so a draft is a refusal, not a
# publish. Idempotent — re-running with the same bytes reuses the asset it finds.
set -euo pipefail
[ $# -eq 5 ] || { echo "usage: $0 <owner/repo> <tag> <artifact> <sha256> <bytes>" >&2; exit 2; }
REPO="$1"; TAG="$2"; ART="$3"; SHA="$4"; BYTES="$5"
command -v gh >/dev/null || { echo "github-asset: no gh on PATH; nothing was uploaded" >&2; exit 2; }
[ -f "$ART" ] || { echo "github-asset: no such artifact: $ART" >&2; exit 2; }
case "$REPO" in */*) ;; *) echo "github-asset: repo must be owner/name, not $REPO" >&2; exit 2 ;; esac
# These reach the release host inside a quoted command, so anything a shell would read as syntax
# (a quote, a space, a `;`) is refused by name here rather than escaped later.
case "$REPO" in *[!A-Za-z0-9._/-]*) echo "github-asset: repo may hold only letters, digits, dot, dash, slash: not $REPO" >&2; exit 2 ;; esac
case "$TAG" in ''|*[!A-Za-z0-9._-]*) echo "github-asset: tag may hold only letters, digits, dot and dash: not $TAG" >&2; exit 2 ;; esac
case "$SHA" in [0-9a-f]*) [ ${#SHA} -eq 64 ] || { echo "github-asset: sha256 must be 64 hex characters" >&2; exit 2; } ;; *) echo "github-asset: sha256 must be 64 hex characters" >&2; exit 2 ;; esac
case "$BYTES" in ''|*[!0-9]*) echo "github-asset: bytes must be a whole number, not $BYTES" >&2; exit 2 ;; esac

# GitHub refuses a single asset of 2 GiB or more; say so here, before a 1.5 GB upload, not after.
if [ "$BYTES" -ge 2147483648 ]; then
  echo "github-asset: $BYTES bytes is at or over GitHub's 2 GiB per-asset limit; $ART keeps a non-GitHub path" >&2
  exit 2
fi
# The bytes about to be uploaded are the bytes the feed will name, or nothing is uploaded.
REAL_BYTES=$(stat -f %z "$ART")
[ "$REAL_BYTES" = "$BYTES" ] || { echo "github-asset: $ART is $REAL_BYTES bytes, not the signed $BYTES; nothing was uploaded" >&2; exit 2; }
REAL_SHA=$(shasum -a 256 "$ART" | awk '{print $1}')
[ "$REAL_SHA" = "$SHA" ] || { echo "github-asset: $ART hashes to $REAL_SHA, not the signed $SHA; nothing was uploaded" >&2; exit 2; }

# The signed `file` name is <sha12>-<basename>, and an artifact already carrying that prefix keeps
# it (Publish.swift's `name`), so GitHub is given exactly the row's own name and never a second one.
BASE=$(basename "$ART")
# A space in a download address has to be encoded, and an encoded address is one more thing to get
# wrong, so the asset name uses dots where the artifact's own name has spaces (what the public page
# did). The row is generated from this release, so its `file` and this name agree by construction.
BASE="${BASE// /.}"
PRE=${SHA:0:12}
NAME="$BASE"
case "$BASE" in "$PRE"-*) ;; *) NAME="$PRE-$BASE" ;; esac
case "$NAME" in *[!A-Za-z0-9._-]*) echo "github-asset: $BASE cannot be an asset name (letters, digits, dot, dash only)" >&2; exit 2 ;; esac
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/kh-asset.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ln "$ART" "$STAGE/$NAME" 2>/dev/null || cp "$ART" "$STAGE/$NAME"

releases() { gh api "repos/$REPO/releases/tags/$TAG" 2>/dev/null; }

# gh prints an API error body on stdout with a non-zero status: that is "no such release",
# never a release that happens to hold no assets.
EXISTING=""
if ! EXISTING=$(releases); then EXISTING=""; fi
# Releases are added, never withdrawn (RELEASE-POLICY §2c): this decides "reuse the asset already
# there", "add the one asset a half-finished run left off", or "refuse" — never delete, never
# overwrite a different artifact, never touch the previous tag. A refusal leaves the repo's newest
# published release exactly as it was, which is what clients keep installing.
DECISION=create
if [ -n "$EXISTING" ]; then
  # One release legitimately carries more than one asset (the Launcher DMG and the helper binary
  # the updater row names), so a conflict is only another asset of the same kind as this one.
  KIND="${NAME##*.}"
  case "$NAME" in *.*) ;; *) KIND="" ;; esac
  DECISION=$(/usr/bin/python3 -I - "$NAME" "$BYTES" "$SHA" "$EXISTING" "$KIND" <<'PY' 
import json, sys
name, want_bytes, want_sha, raw = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
rel = json.loads(raw)
if rel.get("draft"):
    print("github-asset: release %s is a draft; clients cannot see it, so nothing was published — publish it and rerun" % rel.get("tag", ""), file=sys.stderr)
    print("draft"); raise SystemExit(0)
assets = rel.get("assets") or []
mine = [a for a in assets if a.get("name") == name]
if mine and mine[0].get("size") == want_bytes and (not mine[0].get("digest") or mine[0].get("digest") == "sha256:" + want_sha):
    print("reuse"); raise SystemExit(0)
kind, others = sys.argv[5], []
if kind:
    others = [a for a in assets if str(a.get("name", "")).endswith("." + kind) and a.get("name") != name]
if others:
    print("github-asset: this version's release already holds %s, not the artifact being published (%s); a published version keeps its bytes, so nothing was changed"
          % (", ".join(sorted(a.get("name", "?") for a in others)), name), file=sys.stderr)
    print("conflict"); raise SystemExit(0)
print("attach")
PY
) || { echo "github-asset: could not read release $TAG; nothing was published" >&2; exit 4; }
fi
case "$DECISION" in
  draft) exit 3 ;;
  conflict) exit 5 ;;
  reuse) echo "github-asset: $TAG already holds $NAME with these bytes; nothing was re-uploaded" >&2 ;;
  attach)
    gh release upload "$TAG" "$STAGE/$NAME" -R "$REPO" >/dev/null \
      || { echo "github-asset: uploading $NAME to $TAG failed; the release and everything already on it are unchanged" >&2; exit 4; }
    echo "github-asset: uploaded $NAME to the existing release $TAG" >&2 ;;
  create)
    gh release create "$TAG" "$STAGE/$NAME" -R "$REPO" --title "$BASE" \
      --notes "Signed release from the KH Studio feed." >/dev/null \
      || { echo "github-asset: creating release $TAG failed; nothing was published" >&2; exit 4; }
    echo "github-asset: created $TAG in $REPO with $NAME" >&2 ;;
esac

# Read back what GitHub actually stored. A name and a size is not the artifact; the digest is.
STORED=$(gh release view "$TAG" -R "$REPO" --json isDraft,assets)
/usr/bin/python3 -I - "$NAME" "$BYTES" "$SHA" "$STORED" <<'PY'
import json, sys
name, want_bytes, want_sha, raw = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
rel = json.loads(raw)
if rel.get("isDraft"):
    print("github-asset: %s is still a draft after the upload; nothing was published" % name, file=sys.stderr); raise SystemExit(3)
found = [a for a in rel.get("assets", []) if a.get("name") == name]
if not found:
    print("github-asset: the release does not carry %s after the upload; nothing was published" % name, file=sys.stderr); raise SystemExit(3)
a = found[0]
if a.get("size") != want_bytes:
    print("github-asset: GitHub stored %s bytes of %s, not the signed %d; nothing was published"
          % (a.get("size"), name, want_bytes), file=sys.stderr); raise SystemExit(3)
digest = a.get("digest") or ""
if not digest:
    # Nothing to compare, so the fetch below is the proof: it hashes the bytes a client receives.
    print("github-asset: GitHub reported no digest for %s; size matched and the fetched bytes are the proof" % name, file=sys.stderr)
elif digest != "sha256:" + want_sha:
    print("github-asset: GitHub stored %s with digest %s, not the signed sha256; nothing was published"
          % (name, digest), file=sys.stderr); raise SystemExit(3)
PY

# Fetch it back the way an installed client does — anonymously, from the address the row will carry.
# A release whose asset a stranger cannot download is a row that strands every Mac, so it is refused
# here rather than discovered on a client. Streaming, so a 1.5 GB artifact is never held in memory.
# Anonymous https only: a cleartext address is refused by every client's `Feed.artifactURL`, so a
# row naming one would be a row nobody can install. Loopback is allowed so the fixtures can serve.
BASE_URL="${KHU_ASSET_BASE:-https://github.com}"
case "$BASE_URL" in
  https://*) ;;
  http://127.0.0.1|http://127.0.0.1:*|http://localhost|http://localhost:*) ;;
  *) echo "github-asset: KHU_ASSET_BASE must be an https address, not $BASE_URL; nothing was published" >&2; exit 2 ;;
esac
URL="$BASE_URL/$REPO/releases/download/$TAG/$NAME"
case "$URL" in *[!A-Za-z0-9._:/@+-]*) echo "github-asset: $URL holds a character an address cannot carry; nothing was published" >&2; exit 2 ;; esac
# A server that accepts and then says nothing must not hold a release open: bound the connect and
# the stall, never the whole transfer (a 1.5 GB artifact legitimately takes minutes).
SERVED=$(curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 120 "$URL" | shasum -a 256 | awk '{print $1}') \
  || { echo "github-asset: $URL could not be downloaded anonymously; a private or unpublished release strands every client, so nothing was published" >&2; exit 5; }
[ "$SERVED" = "$SHA" ] || { echo "github-asset: $URL served $SERVED, not the signed $SHA; nothing was published" >&2; exit 5; }
echo "github-asset: $URL downloaded anonymously and hashes to the signed sha256" >&2

echo "$URL"
