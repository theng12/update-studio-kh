#!/bin/bash
# A fresh per-user install only. Activation is a separate owner action on the destination Mac.
set -euo pipefail
umask 077
KIT="$(cd "$(dirname "$0")" && pwd)"
if [[ $# != 2 ]]; then echo "usage: $0 <filled-agent-config.json> <destination-home>" >&2; exit 2; fi
CONFIG="$1"
DEST_HOME="$2"
fail() { echo "$1" >&2; exit 1; }
[[ "$DEST_HOME" == /* && -d "$DEST_HOME" ]] || fail 'Destination home must be an existing absolute directory.'
[[ -f "$CONFIG" && -x "$KIT/bin/khu" && -x "$KIT/bin/khu-stub" ]] || fail 'Missing config or kit binaries.'
VERSION="$(cat "$KIT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail 'Invalid kit version.'
/usr/bin/plutil -convert json -o /dev/null "$CONFIG" >/dev/null 2>&1 || fail 'Config is not valid JSON/plist.'
for field in feedURL publicKey machine token; do
    value="$(/usr/bin/plutil -extract "$field" raw -expect string -o - "$CONFIG" 2>/dev/null)" || fail "Config needs $field."
    [[ -n "$value" && "$value" != *'__'* ]] || fail "Fill in $field before installing."
done
/usr/bin/plutil -extract apps json -expect dictionary -o /dev/null "$CONFIG" 2>/dev/null || fail 'Config needs an apps dictionary.'
K="$DEST_HOME/Library/KHUpdater"
PLIST="$DEST_HOME/Library/LaunchAgents/com.khupdater.agent.plist"
[[ ! -e "$K" && ! -L "$K" && ! -e "$PLIST" && ! -L "$PLIST" ]] || fail 'KH Updater already exists; preserve it and use the upgrade/repair procedure.'
mkdir -p "$DEST_HOME/Library/LaunchAgents" "$DEST_HOME/Library/Logs"
STAGE="$(mktemp -d "$DEST_HOME/Library/.KHUpdater-install.XXXXXXXX")"
PLIST_STAGE="$STAGE/agent.plist"
PROMOTED=false
cleanup() {
    local code=$?
    if [[ $code != 0 ]]; then
        local trash="$DEST_HOME/Library/_trash/$(basename "$STAGE")"
        mkdir -p "$trash"
        if [[ "$PROMOTED" == true ]]; then mv "$K" "$trash/KHUpdater"; fi
        if [[ -d "$STAGE" ]]; then mv "$STAGE" "$trash/staging"; fi
        echo "Incomplete install preserved at $trash" >&2
    fi
}
trap cleanup EXIT
mkdir -p "$STAGE/KHUpdater/bin" "$STAGE/KHUpdater/state" "$STAGE/KHUpdater/base/versions/$VERSION"
cp "$KIT/bin/khu-stub" "$STAGE/KHUpdater/bin/"
cp "$KIT/bin/khu" "$STAGE/KHUpdater/base/versions/$VERSION/"
chmod 755 "$STAGE/KHUpdater/bin/khu-stub" "$STAGE/KHUpdater/base/versions/$VERSION/khu"
ln -s "versions/$VERSION/khu" "$STAGE/KHUpdater/base/current"
/usr/bin/plutil -convert json -o "$STAGE/KHUpdater/base/config.json" "$CONFIG"
/usr/bin/plutil -replace stateDir -string "$K/state" "$STAGE/KHUpdater/base/config.json"
/usr/bin/plutil -replace stubBase -string "$K/base" "$STAGE/KHUpdater/base/config.json"
/usr/bin/plutil -replace once -bool NO "$STAGE/KHUpdater/base/config.json"
chmod 600 "$STAGE/KHUpdater/base/config.json"
cp "$KIT/com.khupdater.agent.plist" "$PLIST_STAGE"
/usr/bin/plutil -remove ProgramArguments "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments -array "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments.0 -string "$K/bin/khu-stub" "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments.1 -string '--base' "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments.2 -string "$K/base" "$PLIST_STAGE"
/usr/bin/plutil -replace StandardOutPath -string "$DEST_HOME/Library/Logs/khupdater-agent.log" "$PLIST_STAGE"
/usr/bin/plutil -replace StandardErrorPath -string "$DEST_HOME/Library/Logs/khupdater-agent.log" "$PLIST_STAGE"
/usr/bin/plutil -lint "$PLIST_STAGE" >/dev/null
mv "$STAGE/KHUpdater" "$K"
PROMOTED=true
mv "$PLIST_STAGE" "$PLIST"
# Keep the now-empty staging folder out of the way; never delete it.
mkdir -p "$DEST_HOME/Library/_trash"
mv "$STAGE" "$DEST_HOME/Library/_trash/"
echo 'Agent installed but NOT started. Activate the LaunchAgent locally after reviewing the config.'
