#!/bin/bash
# Open the verified SSD Launcher in local update/repair mode, without a network request.
# Native tools only: /usr/bin/python3 is not on a fresh Mac, and asking for it makes macOS offer to
# install the Command Line Tools before anything happens (2026-11-20). Every check the Python entry
# made is kept: the SSD's own checksum, a private re-verified copy, one mounted volume and device,
# the app's identity and version, its signature, and the index hash being the one that was verified.
set -euo pipefail
umask 077

fail() { echo "Update installed apps: $1" >&2; exit 1; }
[[ $# == 1 ]] || fail 'Open Update installed apps.command from the SSD root.'
ROOT="$(cd "$1" 2>/dev/null && pwd -P)" || fail 'The SSD installer could not be opened. Use a refreshed SSD and try again.'
INDEX="$ROOT/apps.json"
[[ -f "$INDEX" ]] || fail 'This SSD has no apps list. Use a refreshed SSD.'
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

STATE="$HOME/Library/KHUpdater/state"
STAGING="$STATE/ssd-bootstrap/$(/usr/bin/uuidgen)"
mkdir -p "$STATE/ssd-bootstrap" "$STAGING"
MOUNT=""
DEVICE=""
cleanup() {
    local code=$?
    if [[ -n "$MOUNT" ]]; then
        hdiutil detach "$DEVICE" >/dev/null 2>&1 \
            || echo "The installer volume is still mounted. No force-eject was attempted." >&2
    fi
    if [[ -d "$STAGING" ]]; then
        mkdir -p "$STATE/_trash"
        mv "$STAGING" "$STATE/_trash/ssd-bootstrap-$(basename "$STAGING")" 2>/dev/null || true
    fi
    exit $code
}
trap cleanup EXIT

/usr/bin/plutil -convert xml1 -o "$STAGING/apps.plist" "$INDEX" 2>/dev/null \
    || fail 'This SSD has an unreadable apps list. Use a refreshed SSD.'
get() { /usr/bin/plutil -extract "$1" raw -o - "$STAGING/apps.plist" 2>/dev/null || true; }
[[ "$(get format)" == "kh.apps.v1" ]] || fail 'This SSD has an unsupported apps list. Use a refreshed SSD.'

# Exactly one row must be the Launcher, and it must be the Launcher.
COUNT=0
while /usr/bin/plutil -extract "apps.$COUNT" json -o /dev/null "$STAGING/apps.plist" 2>/dev/null; do COUNT=$((COUNT + 1)); done
ROW=""
for ((i = 0; i < COUNT; i++)); do
    [[ "$(get "apps.$i.id")" == updater ]] || continue
    [[ -z "$ROW" ]] || fail 'This SSD does not name exactly one Studio Launcher installer.'
    ROW=$i
done
[[ -n "$ROW" && "$(get "apps.$ROW.bundleID")" == com.khupdater.launcher ]] \
    || fail 'This SSD does not name exactly one Studio Launcher installer.'
VERSION="$(get "apps.$ROW.version")"
FILE="$(get "apps.$ROW.file")"
EXPECTED="$(get "apps.$ROW.sha256")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || fail 'The Launcher installer has no valid checksum.'
[[ -n "$FILE" ]] || fail 'The Launcher installer must be a file on this SSD.'

# Resolved against the SSD itself, so a link out of it is refused rather than followed.
IMAGE_DIR="$(cd "$ROOT/$(dirname "$FILE")" 2>/dev/null && pwd -P)" \
    || fail 'The Launcher installer must be a file on this SSD.'
IMAGE="$IMAGE_DIR/$(basename "$FILE")"
case "$IMAGE" in "$ROOT"/*) ;; *) fail 'The Launcher installer must be a file on this SSD.' ;; esac
# A link as the last name could point anywhere, and `pwd -P` above only resolved the folders.
[[ -f "$IMAGE" && ! -L "$IMAGE" ]] || fail 'The Launcher installer must be a file on this SSD.'
[[ "$(sha "$IMAGE")" == "$EXPECTED" ]] || fail 'The Launcher installer checksum does not match. Nothing was started.'

# The hash of the list that was just verified: every later read of the SSD is checked against this.
INDEX_SHA="$(sha "$INDEX")"

# A private copy on this Mac, re-verified: the SSD may be pulled out while the installer runs.
LOCAL="$STAGING/Launcher.dmg"
cp "$IMAGE" "$LOCAL"
chmod 600 "$LOCAL"
[[ "$(sha "$LOCAL")" == "$EXPECTED" ]] || fail 'The Launcher installer changed while copying. Nothing was started.'

hdiutil attach -readonly -nobrowse -plist "$LOCAL" >"$STAGING/attach.plist" 2>"$STAGING/attach.err" \
    || fail 'The Launcher installer could not be mounted. Use a refreshed SSD and try again.'
ENTITIES=0
while /usr/bin/plutil -extract "system-entities.$ENTITIES" json -o /dev/null "$STAGING/attach.plist" 2>/dev/null; do
    ENTITIES=$((ENTITIES + 1))
done
MOUNTS=()
MOUNT_DEVICE=""
DEVICES=()
for ((i = 0; i < ENTITIES; i++)); do
    dev="$(/usr/bin/plutil -extract "system-entities.$i.dev-entry" raw -o - "$STAGING/attach.plist" 2>/dev/null || true)"
    point="$(/usr/bin/plutil -extract "system-entities.$i.mount-point" raw -o - "$STAGING/attach.plist" 2>/dev/null || true)"
    [[ "$dev" =~ ^/dev/disk[0-9]+$ ]] && DEVICES+=("$dev")
    if [[ -n "$point" ]]; then
        MOUNTS+=("$point")
        MOUNT_DEVICE="$dev"
    fi
done
# Its own device only — never a volume name, never a synthesized whole-disk node.
if [[ ${#MOUNTS[@]} -ne 1 || "${MOUNTS[0]}" != /* || ! "$MOUNT_DEVICE" =~ ^/dev/disk[0-9]+(s[0-9]+)*$ ]]; then
    for dev in "${DEVICES[@]+"${DEVICES[@]}"}"; do
        hdiutil detach "$dev" >/dev/null 2>&1 || true
    done
    fail 'The Launcher installer did not return one mounted volume and device.'
fi
MOUNT="${MOUNTS[0]}"
DEVICE="$MOUNT_DEVICE"

APPS=()
for app in "$MOUNT"/*.app; do
    [[ -e "$app" ]] && APPS+=("$app")
done
[[ ${#APPS[@]} -eq 1 ]] || fail 'The Launcher installer must contain one app.'
APP="$(cd "${APPS[0]}" && pwd -P)"
INFO="$APP/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$INFO" 2>/dev/null || true)" == com.khupdater.launcher \
    && "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO" 2>/dev/null || true)" == "$VERSION" ]] \
    || fail 'The Launcher installer identity or version does not match the SSD list.'
EXE_NAME="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$INFO" 2>/dev/null || true)"
EXE_DIR="$(cd "$APP/Contents/MacOS" 2>/dev/null && pwd -P)" || fail 'The Launcher executable is outside its app.'
EXE="$EXE_DIR/$EXE_NAME"
case "$EXE" in "$APP"/*) ;; *) fail 'The Launcher executable is outside its app.' ;; esac
[[ -n "$EXE_NAME" && -x "$EXE" && ! -L "$EXE" ]] || fail 'The Launcher executable is outside its app.'

codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
    || fail 'The Launcher installer is not signed as expected. Nothing was started.'

rc=0
"$EXE" ssd-update --volume "$ROOT" --index-sha256 "$INDEX_SHA" || rc=$?

if ! hdiutil detach "$DEVICE" >/dev/null 2>&1; then
    echo "The installer volume is still mounted. No force-eject was attempted." >&2
else
    MOUNT=""
fi
exit $rc
