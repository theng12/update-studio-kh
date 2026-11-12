#!/bin/bash
# Set up this Mac as the KH Updater publisher. Run once, on the Mac Studio:
#
#   ./build.sh build
#   packaging/publisher-init.sh --tailscale-ip "$(tailscale ip -4)" --backup-to /Volumes/<USB drive>
#
# publisher.json carries this Mac's Tailscale MagicDNS name (derived from `tailscale status`; pass
# --tailnet-host to name it, or --tailnet-host none to keep the numeric address), so a Mac that
# updates keeps reaching the publisher after its address changes. The launchd job binds "auto",
# which the server resolves to whatever tailnet address this Mac has when it starts.
#
# It installs build/khu to ~/Library/KHUpdater/bin/khu, creates the signing key with `khu keygen`
# (CryptoKit, mode 0600), copies that key once to the removable drive named by --backup-to and
# checks the copy, writes ~/Library/KHUpdater/publisher.json (feed + enrol URLs and the public key,
# no secret; this is the file the Studio Hub release ships), and writes the LaunchAgent from
# packaging/com.khupdater.publisher.plist. It starts nothing, ejects nothing and never replaces an
# existing key: a new key would orphan every enrolled Mac.
#
# --home exists for tests; the real run uses $HOME.
set -euo pipefail
umask 077
TAILSCALE_IP=""
TAILNET_HOST=""
BACKUP_TO=""
HOME_DIR="$HOME"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tailscale-ip) TAILSCALE_IP="${2:-}"; shift 2 ;;
    --tailnet-host) TAILNET_HOST="${2:-}"; shift 2 ;;
    --backup-to) BACKUP_TO="${2:-}"; shift 2 ;;
    --home) HOME_DIR="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
fail() { echo "$1" >&2; exit "${2:-1}"; }
[[ -n "$TAILSCALE_IP" ]] || fail "missing --tailscale-ip" 2
[[ -n "$BACKUP_TO" ]] || fail "missing --backup-to: the key must have an offline copy before any Mac trusts it" 2
[[ "$HOME_DIR" == /* && -d "$HOME_DIR" ]] || fail "--home must be an existing absolute directory" 2
# Studio Hub refuses a publisher outside Tailscale's range, so refuse it here, before a key exists.
python3 -I -c 'import ipaddress, sys; sys.exit(ipaddress.ip_address(sys.argv[1]) not in ipaddress.ip_network("100.64.0.0/10"))' \
  "$TAILSCALE_IP" 2>/dev/null || fail "not a Tailscale address (100.64.0.0/10): $TAILSCALE_IP" 2
[[ -d "$BACKUP_TO" && -w "$BACKUP_TO" ]] || fail "backup folder missing or not writable: $BACKUP_TO" 2
if [[ -z "${KHU_TEST_ALLOW_LOCAL_BACKUP:-}" ]]; then
  # The backup must leave this Mac's disk: a copy on the same drive is not an offline backup.
  [[ "$(/bin/df "$BACKUP_TO" | awk 'NR==2{print $1}')" != "$(/bin/df "$HOME_DIR" | awk 'NR==2{print $1}')" ]] \
    || fail "--backup-to is on this Mac's own disk; use a removable drive" 2
fi

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
[[ -x "$ROOT/build/khu" ]] || fail "build/khu missing; run ./build.sh build first" 2
K="$HOME_DIR/Library/KHUpdater"
KEY="$K/keys/private.key"
BACKUP_KEY="$BACKUP_TO/khupdater-publisher-private.key"
PLIST="$HOME_DIR/Library/LaunchAgents/com.khupdater.publisher.plist"
[[ ! -e "$KEY" ]] || fail "refusing: $KEY already exists; a new key would orphan every enrolled Mac"
[[ ! -e "$BACKUP_KEY" ]] || fail "refusing: $BACKUP_KEY already exists; keep it, and pick another folder"
[[ ! -e "$PLIST" ]] || fail "refusing: $PLIST already exists; boot it out and move it to _trash first"

mkdir -p "$K/bin" "$K/feed" "$K/state" "$HOME_DIR/Library/LaunchAgents" "$HOME_DIR/Library/Logs"
if [[ -e "$K/bin/khu" ]] && ! cmp -s "$ROOT/build/khu" "$K/bin/khu"; then
  TRASH="$K/_trash/bin-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$TRASH"
  mv "$K/bin/khu" "$TRASH/"
fi
cp "$ROOT/build/khu" "$K/bin/khu.tmp"
chmod 755 "$K/bin/khu.tmp"
mv "$K/bin/khu.tmp" "$K/bin/khu"
# The publisher runs from a named bundle so Activity Monitor shows the product, not a bare khu.
"$ROOT/build/khu" helper-bundle --out "$K/Update Studio KH Publisher.app" \
  --name "Update Studio KH Publisher" --id com.khupdater.publisher \
  --exec "$K/bin/khu" --executable "Update Studio KH Publisher" \
  --icon "$ROOT/build/AppIcon.icns" >/dev/null

PUBLIC=$("$K/bin/khu" keygen "$K/keys" | sed -n 's/^public key: //p')
[[ -n "$PUBLIC" && -f "$KEY" ]] || fail "khu keygen did not produce a key"

cp "$KEY" "$BACKUP_KEY"
chmod 600 "$BACKUP_KEY"
cmp -s "$KEY" "$BACKUP_KEY" || fail "the backup copy does not match the key; do not use this key until it does"

# The URL every Mac copies must survive this Mac's address changing, so it carries the Tailscale
# MagicDNS name — derived from `tailscale status` unless --tailnet-host names one, with "none"
# keeping the numeric address. The launchd job binds "auto", which the server resolves to this
# Mac's address when it starts and refuses to start without.
if [[ "$TAILNET_HOST" == "none" ]]; then
  TAILNET_HOST=""
elif [[ -z "$TAILNET_HOST" ]]; then
  TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  if command -v tailscale >/dev/null 2>&1; then TS="$(command -v tailscale)"; fi
  if [[ -x "$TS" ]]; then
    TAILNET_HOST=$("$TS" status --json 2>/dev/null \
      | python3 -I -c 'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null || true)
  fi
fi
FEED_HOST="${TAILNET_HOST:-$TAILSCALE_IP}"
[[ "$FEED_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "not a host name: $FEED_HOST" 2
[[ -n "$TAILNET_HOST" ]] || echo "note: no MagicDNS name found; publisher.json keeps the numeric address" >&2
FEED_URL="http://${FEED_HOST}:8790/release.json"
ENROL_URL="http://${FEED_HOST}:8790/enrol"
BIND="auto"
python3 -I - "$K/publisher.json" "$FEED_URL" "$ENROL_URL" "$PUBLIC" <<'PY'
import json, sys
path, feed_url, enrol_url, public = sys.argv[1:]
with open(path, "x") as f:
    json.dump({"feedURL": feed_url, "enrolURL": enrol_url, "publicKey": public, "testAuthority": False}, f, indent=2)
PY
chmod 644 "$K/publisher.json"

sed -e "s|__HOME__|$HOME_DIR|g" -e "s|__TAILSCALE_IP__|$BIND|g" \
  "$ROOT/packaging/com.khupdater.publisher.plist" > "$PLIST.tmp"
/usr/bin/plutil -lint "$PLIST.tmp" >/dev/null
mv "$PLIST.tmp" "$PLIST"

echo "publisher set up (not started)"
echo "  feed:       $FEED_URL"
echo "  bind:       $BIND"
echo "  enrol:      $ENROL_URL"
echo "  public key: $PUBLIC"
echo "  backup:     $BACKUP_KEY (checked; keep that drive offline)"
echo "  for Hub:    $K/publisher.json"
echo "next: launchctl bootstrap gui/$(id -u) $PLIST"
