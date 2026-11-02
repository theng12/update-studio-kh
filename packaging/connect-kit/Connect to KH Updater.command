#!/bin/sh
# INSTALL KH UPDATER
#
# Double-click this file on any Mac that runs one of the three apps — Story Studio, GatewayKH or
# Studio Hub. It installs **KH Updater**, the small agent that keeps those apps up to date, and
# starts it. Nothing else on the Mac is changed and nothing needs the administrator password:
# everything lives in your own ~/Library/KHUpdater.
#
# You can run it on every Mac in the fleet. On a Hub Mac Studio Hub already installs this agent by
# itself; whichever runs first installs, and the other one just says it is already there.
#
# What it does, in order:
#
#   - Checks the agent kit in this folder (`khu-agent/`) against the checksums written beside it,
#     and checks that its `publisher.json` is a real publisher record. A kit that was altered on
#     the drive is refused.
#   - Installs the agent under ~/Library/KHUpdater and enrols this Mac with the publisher, using
#     the pairing code it asks you for: the one shown in KH Updater on the Mac Studio, under
#     Connect a Mac. A wrong code is refused, and a refused run leaves nothing behind.
#   - Starts the agent at login with a launchd job (`com.khupdater.agent`).
#
# It asks for the name this Mac should enrol under, showing what it proposes. On a Hub Mac that is
# the Hub's own name; on any other Mac it is this computer's name. Press Return to accept it. Then
# it asks once for the pairing code.
#
#   - Already installed and enrolled: it says so and changes nothing.
#   - Agent kit or publisher record missing: it says which, and installs nothing. (A kit whose
#     publisher key has not been created yet has no install file at all, only a README.)
#   - Enrolment refused: nothing is left half-installed - whatever it wrote is moved to
#     ~/Library/_trash and it says where.
#   - Installed, but launchd refused to start it: the install is KEPT (the agent is enrolled and
#     its launchd job is written), it prints launchctl's own reason and the one command that
#     retries the start, and exits non-zero.
#
# The `KH_UPDATER_*` names below are for testing this against scratch folders with a stand-in
# publisher; nobody sets them in real use.
set -u
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
KIT="$HERE/khu-agent"
HELPER="$HERE/khu-install.py"
APPS="$HERE/apps.json"
UNATTENDED="${KH_UPDATER_UNATTENDED:-}"

if [ -n "${KH_UPDATER_KIT:-}" ]; then KIT="$KH_UPDATER_KIT"; fi
if [ -n "${KH_UPDATER_HELPER:-}" ]; then HELPER="$KH_UPDATER_HELPER"; fi
if [ -n "${KH_UPDATER_APPS:-}" ]; then APPS="$KH_UPDATER_APPS"; fi

[ "$UNATTENDED" = "1" ] || clear
echo "  KH Updater"

finish() {
  if [ "$UNATTENDED" != "1" ]; then
    echo
    echo "  Press Return to close."
    read _ || true
  fi
  exit "$1"
}
fail() {
  echo
  echo "  KH Updater was NOT installed: $1"
  echo "  Nothing else on this Mac was touched."
  finish "${2:-1}"
}

# A Python to run the installer with. Prefer the one inside an installed Studio Hub, because that
# is the interpreter this Mac's own app runs; fall back to the system one, and only use the copy on
# this drive if there is nothing else (a drive can be unplugged mid-run).
if [ -n "${KH_UPDATER_PYTHON:-}" ]; then
  PY="$KH_UPDATER_PYTHON"
else
  PY=""
  for candidate in "/Applications/Studio Hub.app/Contents/Resources/runtimes/voice/bin/python3" \
                   "$HOME/Applications/Studio Hub.app/Contents/Resources/runtimes/voice/bin/python3" \
                   "/usr/bin/python3" \
                   "$HERE/../Studio Hub KH/Studio Hub.app/Contents/Resources/runtimes/voice/bin/python3"; do
    [ -x "$candidate" ] || continue
    # `/usr/bin/python3` is present on a Mac with no developer tools and only prints a prompt to
    # install them, so the candidate has to actually run.
    "$candidate" -c 'pass' >/dev/null 2>&1 || continue
    PY="$candidate"
    break
  done
fi

[ -n "$PY" ] || fail "no Python could be found on this Mac (install Studio Hub, or the developer
  command line tools) - run this file again afterwards." 2
[ -f "$HELPER" ] || fail "the installer beside this file is missing ('$HELPER')."
[ -f "$APPS" ] || fail "the apps config beside this file is missing ('$APPS')."
[ -d "$KIT" ] || fail "the agent kit folder is missing ('$KIT')."
[ -f "$KIT/publisher.json" ] || fail "the agent kit has no publisher.json, so this kit cannot
  enrol anything yet."

set -- --kit "$KIT" --home "$HOME" --apps "$APPS"
[ -n "${KH_UPDATER_MACHINE:-}" ] && set -- "$@" --machine "$KH_UPDATER_MACHINE"
[ "${KH_UPDATER_ALLOW_TEST:-}" = "1" ] && set -- "$@" --allow-test
[ "$UNATTENDED" = "1" ] && set -- "$@" --unattended

"$PY" "$HELPER" "$@"
STATUS=$?
finish "$STATUS"
