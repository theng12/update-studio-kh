#!/bin/bash
# A fresh per-user install, then the LaunchAgent is loaded here (owner, 2026-10-26) — the same
# activation Studio Hub's khu_agent performs. Nothing is started if the install is refused or fails.
#
# With a third --repair argument this finishes an incomplete install on this Mac that has no
# config yet: every file that is already there is kept, the missing pieces are added, and an
# existing config is never touched. --repair-saved does the same for a Mac whose connection was
# already saved but whose helper files or LaunchAgent are incomplete: the saved config is read
# and verified, and it is never rewritten.
set -euo pipefail
umask 077
KIT="$(cd "$(dirname "$0")" && pwd)"
REPAIR=false
SAVED=false
if [[ $# == 3 && "$3" == "--repair" ]]; then
    REPAIR=true
elif [[ $# == 3 && "$3" == "--repair-saved" ]]; then
    REPAIR=true; SAVED=true
elif [[ $# != 2 ]]; then
    echo "usage: $0 <filled-agent-config.json> <destination-home> [--repair|--repair-saved]" >&2; exit 2
fi
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
CONFIG_PATH="$K/base/config.json"
LAUNCHCTL="$(command -v launchctl || true)"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/com.khupdater.agent"
JOB_LABEL="com.khupdater.agent"

# A loaded job keeps the code requirement it was spawned with. Replacing bin/khu-stub or the helper
# bundle changes the binary's CDHash, and launchd then refuses the next spawn ("needs LWCR update",
# OS_REASON_CODESIGNING) however valid the file is. Only a real unload clears it; kickstart -k does
# not. Read the pid back after bootstrap: an exit code alone is not proof the job runs.
job_pid() {
    [[ -n "$LAUNCHCTL" ]] || return 1
    "$LAUNCHCTL" list 2>/dev/null | /usr/bin/awk -v l="$JOB_LABEL" '$3==l && $1+0>1 { print $1; exit }'
}
job_running() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -n "$(job_pid)" ]]; then return 0; fi
        sleep 0.3
    done
    return 1
}
STAGE=""
PROMOTED=false

# The launchd job runs from a named bundle so process lists show the product, not a bare
# khu-stub. The icon is optional: a kit built before the app still installs.
helper_bundle() {
    local out="$1" source="$2"
    if [[ -f "$KIT/AppIcon.icns" ]]; then
        "$KIT/bin/khu" helper-bundle --out "$out" --name "Studio Launcher KH Helper" \
            --id com.khupdater.agent --exec "$source" --executable "Studio Launcher KH Helper" \
            --version "$VERSION" --icon "$KIT/AppIcon.icns" --dock >/dev/null
    else
        "$KIT/bin/khu" helper-bundle --out "$out" --name "Studio Launcher KH Helper" \
            --id com.khupdater.agent --exec "$source" --executable "Studio Launcher KH Helper" \
            --version "$VERSION" --dock >/dev/null
    fi
}
COMMITTED=false
STOPPED_JOB=false
REPAIR_TRASH=""
UNDO_LOG=""

# Where a symlink points, resolved against its own folder.
link_target() {
    local link="$1" target
    target="$(readlink "$link")" || return 1
    [[ "$target" == /* ]] || target="$(dirname "$link")/$target"
    printf '%s\n' "$target"
}

# Move an existing file aside into this install's own trash, remembering how to put it back.
archive() {
    local path="$1" label="$2" dest n=1
    [[ -e "$path" || -L "$path" ]] || return 0
    mkdir -p "$REPAIR_TRASH"
    dest="$REPAIR_TRASH/$label"
    while [[ -e "$dest" || -L "$dest" ]]; do dest="$REPAIR_TRASH/$label-$n"; n=$((n+1)); done
    mv "$path" "$dest"
    printf 'old\t%s\t%s\n' "$path" "$dest" >> "$UNDO_LOG"
}

# Remember a file the repair made, so a failure can move it aside again.
created() {
    printf 'new\t%s\t\n' "$1" >> "$UNDO_LOG"
}

# Put back everything the repair replaced, newest first. Nothing is deleted: what was replaced
# goes to the trash, and the original returns to the place it came from. A file the repair made
# is moved to the trash too, so the same repair can run again.
undo_repair() {
    [[ -n "$UNDO_LOG" && -s "$UNDO_LOG" ]] || return 0
    local action path saved i=0
    while IFS=$'\t' read -r action path saved; do
        [[ -n "$action" && -n "$path" ]] || continue
        i=$((i+1))
        if [[ -e "$path" || -L "$path" ]]; then
            mkdir -p "$REPAIR_TRASH/undone"
            mv "$path" "$REPAIR_TRASH/undone/$(basename "$path").$i" 2>/dev/null || true
        fi
        if [[ "$action" == old && -n "$saved" && ( -e "$saved" || -L "$saved" ) ]]; then
            mkdir -p "$(dirname "$path")" 2>/dev/null || true
            mv "$saved" "$path" 2>/dev/null || true
        fi
    done < <(awk '{line[NR]=$0} END{for(i=NR;i>=1;i--) print line[i]}' "$UNDO_LOG")
}

# Start the job that was running before the repair, from the plist that was there before it.
restart_job() {
    [[ -n "$LAUNCHCTL" && -f "$PLIST" ]] || return 1
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1
}

cleanup() {
    local code=$?
    # Past COMMITTED the install is complete; only a failed start remains, and that must leave
    # the files where they are (it is retried by opening Studio Launcher again, not a reinstall).
    if [[ $code != 0 && "$COMMITTED" != true ]]; then
        if [[ "$REPAIR" == true ]]; then
            undo_repair
            if [[ "$STOPPED_JOB" == true ]] && ! restart_job; then
                echo "KH Updater's helper was stopped and could not be started again; your files are kept." >&2
            fi
        fi
        if [[ -n "$STAGE" && -d "$STAGE" ]]; then
            local trash="$DEST_HOME/Library/_trash/$(basename "$STAGE")"
            mkdir -p "$trash"
            if [[ "$PROMOTED" == true ]]; then mv "$K" "$trash/KHUpdater"; fi
            mv "$STAGE" "$trash/staging"
            echo "Incomplete install preserved at $trash" >&2
        fi
    fi
}

# --------------------------------------------------------------------- fresh install
if [[ "$REPAIR" == false ]]; then
    [[ ! -e "$K" && ! -L "$K" && ! -e "$PLIST" && ! -L "$PLIST" ]] || fail 'KH Updater already exists; preserve it and use the upgrade/repair procedure.'
    mkdir -p "$DEST_HOME/Library/LaunchAgents" "$DEST_HOME/Library/Logs"
    STAGE="$(mktemp -d "$DEST_HOME/Library/.KHUpdater-install.XXXXXXXX")"
    PLIST_STAGE="$STAGE/agent.plist"
    trap cleanup EXIT
    mkdir -p "$STAGE/KHUpdater/bin" "$STAGE/KHUpdater/state" "$STAGE/KHUpdater/base/versions/$VERSION"
    cp "$KIT/bin/khu-stub" "$STAGE/KHUpdater/bin/"
    cp "$KIT/bin/khu" "$STAGE/KHUpdater/base/versions/$VERSION/"
    chmod 755 "$STAGE/KHUpdater/bin/khu-stub" "$STAGE/KHUpdater/base/versions/$VERSION/khu"
    # The launchd job runs from a named helper bundle, so process lists show the product instead
    # of a bare khu-stub. The binary inside is a link to the same file as bin/khu-stub.
    helper_bundle "$STAGE/KHUpdater/Studio Launcher KH Helper.app" "$STAGE/KHUpdater/bin/khu-stub"
    # Every version folder carries its own helper bundle, built from that version's binary.
    helper_bundle "$STAGE/KHUpdater/base/versions/$VERSION/Studio Launcher KH Helper.app" "$STAGE/KHUpdater/base/versions/$VERSION/khu"
    ln -s "versions/$VERSION/khu" "$STAGE/KHUpdater/base/current"
    /usr/bin/plutil -convert json -o "$STAGE/KHUpdater/base/config.json" "$CONFIG"
    /usr/bin/plutil -replace stateDir -string "$K/state" "$STAGE/KHUpdater/base/config.json"
    /usr/bin/plutil -replace stubBase -string "$K/base" "$STAGE/KHUpdater/base/config.json"
    /usr/bin/plutil -replace once -bool NO "$STAGE/KHUpdater/base/config.json"
    chmod 600 "$STAGE/KHUpdater/base/config.json"
    cp "$KIT/com.khupdater.agent.plist" "$PLIST_STAGE"
    /usr/bin/plutil -remove ProgramArguments "$PLIST_STAGE"
    /usr/bin/plutil -insert ProgramArguments -array "$PLIST_STAGE"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$K/Studio Launcher KH Helper.app/Contents/MacOS/Studio Launcher KH Helper" "$PLIST_STAGE"
    /usr/bin/plutil -insert ProgramArguments.1 -string '--base' "$PLIST_STAGE"
    /usr/bin/plutil -insert ProgramArguments.2 -string "$K/base" "$PLIST_STAGE"
    /usr/bin/plutil -replace StandardOutPath -string "$DEST_HOME/Library/Logs/khupdater-agent.log" "$PLIST_STAGE"
    /usr/bin/plutil -replace StandardErrorPath -string "$DEST_HOME/Library/Logs/khupdater-agent.log" "$PLIST_STAGE"
    /usr/bin/plutil -lint "$PLIST_STAGE" >/dev/null
    mv "$STAGE/KHUpdater" "$K"
    PROMOTED=true
    mv "$PLIST_STAGE" "$PLIST"
    COMMITTED=true
    # Keep the now-empty staging folder out of the way; never delete it.
    mkdir -p "$DEST_HOME/Library/_trash"
    mv "$STAGE" "$DEST_HOME/Library/_trash/"

    # The same rule as Studio Hub's khu_agent.Bootstrap.activate: a loaded job is left alone (never a
    # second copy), and a job that is not loaded is bootstrapped from the plist written above.
    if [[ -z "$LAUNCHCTL" ]]; then
        REASON='launchctl was not found on this Mac'
    elif "$LAUNCHCTL" print "$JOB" >/dev/null 2>&1; then
        echo "Agent installed; launchd already has com.khupdater.agent loaded, so it was left alone."
        exit 0
    elif OUTPUT="$("$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>&1)" && job_running; then
        echo "Agent installed and started (launchd job com.khupdater.agent, pid $(job_pid))."
        exit 0
    else
        REASON="${OUTPUT:-launchd accepted the job but it is not running (no pid in launchctl list)}"
    fi
    # The install is finished and stays; only the start failed, and one command retries it.
    echo "Agent installed, but launchd did not start it: $REASON" >&2
    echo "The install is kept at $K; nothing was removed. Start it later with:" >&2
    echo "  launchctl bootstrap $DOMAIN $PLIST" >&2
    exit 1
fi

# ----------------------------------------------------------------------- repair install
# An incomplete install on this Mac: some of the KHUpdater folder or the LaunchAgent plist is
# there. Everything already on this Mac is kept. A fresh --repair has no config yet; a saved
# setup repairs from its own existing config, which is never rewritten.
if [[ "$SAVED" == true ]]; then
    [[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] \
        || fail "This Mac has no saved connection to repair; nothing was changed."
    [[ "$CONFIG" -ef "$CONFIG_PATH" ]] \
        || fail "A saved setup is repaired from its own base/config.json; nothing was changed."
else
    [[ ! -e "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] \
        || fail "KH Updater is already set up on this Mac; nothing was changed."
fi
# A link where a real folder belongs is refused: the repair would otherwise write through it.
for path in "$K" "$K/base" "$K/bin" "$K/state" "$K/base/versions" "$K/base/versions/$VERSION" \
            "$K/base/versions/$VERSION/khu" "$K/bin/khu-stub" "$PLIST"; do
    [[ ! -L "$path" ]] || fail "This Mac has a linked KH Updater folder where a real one belongs; nothing was changed."
done
for path in "$K" "$K/base" "$K/bin" "$K/state" "$K/base/versions" "$K/base/versions/$VERSION"; do
    [[ ! -e "$path" || -d "$path" ]] || fail "This Mac has a KH Updater folder that is not a folder; nothing was changed."
done
# Any other version folder on this Mac is kept, but it must be a real folder with a real binary.
for dir in "$K/base/versions"/*; do
    [[ -e "$dir" ]] || continue
    [[ -d "$dir" && ! -L "$dir" ]] || fail "This Mac has a linked version folder where a real one belongs; nothing was changed."
    [[ ! -L "$dir/khu" ]] || fail "This Mac has a linked version binary where a real one belongs; nothing was changed."
done

trap cleanup EXIT

mkdir -p "$DEST_HOME/Library/LaunchAgents" "$DEST_HOME/Library/Logs"
STAGE="$(mktemp -d "$DEST_HOME/Library/.KHUpdater-install.XXXXXXXX")"
UNDO_LOG="$STAGE/undo.log"
: > "$UNDO_LOG"
REPAIR_TRASH="$DEST_HOME/Library/_trash/repair-$(date +%Y%m%d-%H%M%S)"

# Everything is built and checked in the staging folder first, so a fault here leaves this Mac
# exactly as it was.
mkdir -p "$STAGE/KHUpdater/bin" "$STAGE/KHUpdater/base/versions/$VERSION"
cp "$KIT/bin/khu-stub" "$STAGE/KHUpdater/bin/"
cp "$KIT/bin/khu" "$STAGE/KHUpdater/base/versions/$VERSION/"
chmod 755 "$STAGE/KHUpdater/bin/khu-stub" "$STAGE/KHUpdater/base/versions/$VERSION/khu"
if [[ "$SAVED" == false ]]; then
    /usr/bin/plutil -convert json -o "$STAGE/KHUpdater/base/config.json" "$CONFIG"
    /usr/bin/plutil -replace stateDir -string "$K/state" "$STAGE/KHUpdater/base/config.json"
    /usr/bin/plutil -replace stubBase -string "$K/base" "$STAGE/KHUpdater/base/config.json"
    /usr/bin/plutil -replace once -bool NO "$STAGE/KHUpdater/base/config.json"
    chmod 600 "$STAGE/KHUpdater/base/config.json"
fi
cp "$KIT/com.khupdater.agent.plist" "$STAGE/agent.plist"
/usr/bin/plutil -remove ProgramArguments "$STAGE/agent.plist"
/usr/bin/plutil -insert ProgramArguments -array "$STAGE/agent.plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$K/Studio Launcher KH Helper.app/Contents/MacOS/Studio Launcher KH Helper" "$STAGE/agent.plist"
/usr/bin/plutil -insert ProgramArguments.1 -string '--base' "$STAGE/agent.plist"
/usr/bin/plutil -insert ProgramArguments.2 -string "$K/base" "$STAGE/agent.plist"
/usr/bin/plutil -replace StandardOutPath -string "$DEST_HOME/Library/Logs/khupdater-agent.log" "$STAGE/agent.plist"
/usr/bin/plutil -replace StandardErrorPath -string "$DEST_HOME/Library/Logs/khupdater-agent.log" "$STAGE/agent.plist"
/usr/bin/plutil -lint "$STAGE/agent.plist" >/dev/null

# Stop a loaded job only after staging succeeds, before replacing any of its files.
if [[ -n "$LAUNCHCTL" ]] && "$LAUNCHCTL" print "$JOB" >/dev/null 2>&1; then
    if ! STOP_OUTPUT="$("$LAUNCHCTL" bootout "$JOB" 2>&1)"; then
        fail "KH Updater's helper was running and could not be stopped; nothing was changed."
    fi
    STOPPED_JOB=true
else
    PRINT_EXIT=$?
    if [[ "$SAVED" == true && "$PRINT_EXIT" != 113 ]]; then
        fail "macOS could not confirm the helper's startup status (print exit $PRINT_EXIT); nothing was changed."
    fi
fi
# Promote: what is replaced moves into this install's own trash first, so it can be put back.
mkdir -p "$K/bin" "$K/base/versions" "$K/state"
archive "$K/bin/khu-stub" "bin-khu-stub"
created "$K/bin/khu-stub"
cp "$STAGE/KHUpdater/bin/khu-stub" "$K/bin/khu-stub"
chmod 755 "$K/bin/khu-stub"
# Through 0.1.35 this Mac's client engine was named "Update Studio KH Helper". An upgrade keeps the
# old bundle in this install's own trash (never deleted) and points the job at the new one below.
archive "$K/Update Studio KH Helper.app" "legacy-helper-app"
archive "$K/Studio Launcher KH Helper.app" "helper-app"
created "$K/Studio Launcher KH Helper.app"
helper_bundle "$K/Studio Launcher KH Helper.app" "$K/bin/khu-stub"
archive "$K/base/versions/$VERSION/khu" "versions-$VERSION-khu"
mkdir -p "$K/base/versions/$VERSION"
created "$K/base/versions/$VERSION/khu"
cp "$STAGE/KHUpdater/base/versions/$VERSION/khu" "$K/base/versions/$VERSION/khu"
chmod 755 "$K/base/versions/$VERSION/khu"
archive "$K/base/versions/$VERSION/Update Studio KH Helper.app" "legacy-versions-$VERSION-helper-app"
helper_bundle "$K/base/versions/$VERSION/Studio Launcher KH Helper.app" "$K/base/versions/$VERSION/khu"
# The version this Mac was running is kept as the fallback before `current` moves on. A `previous`
# that is already there is kept as it is.
OLD_CURRENT=""
if [[ -L "$K/base/current" ]]; then
    OLD_TARGET="$(link_target "$K/base/current" || true)"
    if [[ -n "$OLD_TARGET" && -f "$OLD_TARGET" && -x "$OLD_TARGET" ]]; then
        OLD_CURRENT="$(readlink "$K/base/current")"
    fi
fi
if [[ -n "$OLD_CURRENT" && "$OLD_CURRENT" != "versions/$VERSION/khu" && ! -e "$K/base/previous" && ! -L "$K/base/previous" ]]; then
    ln -s "$OLD_CURRENT" "$K/base/previous"
    created "$K/base/previous"
fi
archive "$K/base/current" "current"
created "$K/base/current"
ln -s "versions/$VERSION/khu" "$K/base/current"
# The config was refused above when it existed (and is never touched in a saved repair), so
# this only ever writes a missing one.
if [[ "$SAVED" == false ]]; then
    created "$CONFIG_PATH"
    cp "$STAGE/KHUpdater/base/config.json" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
fi
archive "$PLIST" "agent.plist"
created "$PLIST"
cp "$STAGE/agent.plist" "$PLIST"
COMMITTED=true
# Keep the now-empty staging folder out of the way; never delete it.
mkdir -p "$DEST_HOME/Library/_trash"
mv "$STAGE" "$DEST_HOME/Library/_trash/"

if [[ -z "$LAUNCHCTL" ]]; then
    REASON='launchctl was not found on this Mac'
elif OUTPUT="$("$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>&1)" && job_running; then
    echo "KH Updater is set up and its helper is running (launchd job com.khupdater.agent, pid $(job_pid))."
    exit 0
else
    REASON="${OUTPUT:-launchd accepted the job but it is not running (no pid in launchctl list)}"
fi
# The files are in place and stay; only the start failed, so the reason is plain and no command
# is asked of anyone.
echo "KH Updater is set up, but its helper could not be started: $REASON" >&2
echo "Your files are kept. Open Studio Launcher again to try starting it." >&2
exit 1
