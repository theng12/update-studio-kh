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

# The signed `file` name is <sha12>-<basename> (Publish.swift, `name`), so GitHub is given that name.
BASE=$(basename "$ART")
NAME="${SHA:0:12}-$BASE"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/kh-asset.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ln "$ART" "$STAGE/$NAME" 2>/dev/null || cp "$ART" "$STAGE/$NAME"

releases() { gh api "repos/$REPO/releases/tags/$TAG" 2>/dev/null; }

EXISTING=$(releases || true)
if [ -n "$EXISTING" ] && printf '%s' "$EXISTING" | grep -q '"draft":[[:space:]]*true'; then
  echo "github-asset: release $TAG in $REPO is a draft; clients cannot see it, so nothing was published — publish it and rerun" >&2
  exit 3
fi
if [ -n "$EXISTING" ]; then
  gh release upload "$TAG" "$STAGE/$NAME" -R "$REPO" --clobber >/dev/null \
    || { echo "github-asset: uploading $NAME to $TAG failed; nothing was published" >&2; exit 4; }
  echo "github-asset: uploaded $NAME to the existing release $TAG" >&2
else
  gh release create "$TAG" "$STAGE/$NAME" -R "$REPO" --title "$BASE" \
    --notes "Signed release from the KH Studio feed." >/dev/null \
    || { echo "github-asset: creating release $TAG failed; nothing was published" >&2; exit 4; }
  echo "github-asset: created $TAG in $REPO with $NAME" >&2
fi

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
    print("github-asset: GitHub reported no digest for %s; size and name matched, the digest was not proven" % name, file=sys.stderr)
elif digest != "sha256:" + want_sha:
    print("github-asset: GitHub stored %s with digest %s, not the signed sha256; nothing was published"
          % (name, digest), file=sys.stderr); raise SystemExit(3)
PY

# Fetch it back the way an installed client does — anonymously, from the address the row will carry.
# A release whose asset a stranger cannot download is a row that strands every Mac, so it is refused
# here rather than discovered on a client. Streaming, so a 1.5 GB artifact is never held in memory.
BASE_URL="${KHU_ASSET_BASE:-https://github.com}"
URL="$BASE_URL/$REPO/releases/download/$TAG/$NAME"
if [ "${KHU_ASSET_FETCH_CHECK:-1}" = "0" ]; then
  echo "github-asset: $URL was not fetched back (KHU_ASSET_FETCH_CHECK=0); only what GitHub reports is proven" >&2
else
  SERVED=$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}') \
    || { echo "github-asset: $URL could not be downloaded anonymously; a private or unpublished release strands every client, so nothing was published" >&2; exit 5; }
  [ "$SERVED" = "$SHA" ] || { echo "github-asset: $URL served $SERVED, not the signed $SHA; nothing was published" >&2; exit 5; }
  echo "github-asset: $URL downloaded anonymously and hashes to the signed sha256" >&2
fi

echo "$URL"
