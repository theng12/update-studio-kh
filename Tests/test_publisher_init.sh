#!/bin/bash
# Runs packaging/publisher-init.sh against a temporary home and a temporary "drive". The key it
# makes is real (khu keygen) but throwaway, in the system's temporary space, never the owner's home.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
INIT="$ROOT/packaging/publisher-init.sh"
[[ -x "$ROOT/build/khu" ]] || { echo "build/khu missing; run ./build.sh build first" >&2; exit 2; }
WORK=$(mktemp -d -t khu-publisher-init-XXXXXX)
HOME_T="$WORK/home"; DRIVE="$WORK/drive"
mkdir -p "$HOME_T" "$DRIVE"
export KHU_TEST_ALLOW_LOCAL_BACKUP=1
FAILS=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS+1)); fi; }
run() { "$INIT" --home "$HOME_T" "$@" >"$WORK/out" 2>&1; }
K="$HOME_T/Library/KHUpdater"

check "refuses without --backup-to" '! run --tailscale-ip 100.64.0.1'
check "refuses a non-Tailscale address" '! run --tailscale-ip 192.168.1.5 --backup-to "$DRIVE"'
check "refuses a backup on this Mac's own disk" '! KHU_TEST_ALLOW_LOCAL_BACKUP= run --tailscale-ip 100.64.0.1 --backup-to "$DRIVE" && grep -q "own disk" "$WORK/out"'
check "a refusal leaves no key" '[[ ! -e "$K/keys/private.key" ]]'

check "fresh run succeeds" 'run --tailscale-ip 100.64.0.1 --backup-to "$DRIVE"'
check "key is mode 600" '[[ "$(stat -f %Lp "$K/keys/private.key")" == 600 ]]'
check "binary installed where the plist runs it" 'cmp -s "$ROOT/build/khu" "$K/bin/khu"'
check "backup equals key" 'cmp -s "$K/keys/private.key" "$DRIVE/khupdater-publisher-private.key"'
check "backup is mode 600" '[[ "$(stat -f %Lp "$DRIVE/khupdater-publisher-private.key")" == 600 ]]'
check "no key copy left in home" '[[ -z "$(find "$HOME_T" -name "*backup*" -o -name "*.key" | grep -v "/keys/private.key$")" ]]'
PUB=$(sed -n 's/^  public key: //p' "$WORK/out")
check "publisher.json is exactly what Hub reads" 'python3 -I -c "
import json,sys
c=json.load(open(sys.argv[1]))
assert set(c)=={\"feedURL\",\"enrolURL\",\"publicKey\",\"testAuthority\"}, c
assert c[\"feedURL\"]==\"http://100.64.0.1:8790/release.json\"
assert c[\"enrolURL\"]==\"http://100.64.0.1:8790/enrol\"
assert c[\"publicKey\"]==sys.argv[2] and c[\"testAuthority\"] is False
" "$K/publisher.json" "$PUB"'
P="$HOME_T/Library/LaunchAgents/com.khupdater.publisher.plist"
check "plist lints" '/usr/bin/plutil -lint "$P" >/dev/null'
check "plist has no placeholders" '! grep -q __ "$P"'
check "plist serves on 8790 for loopback and auto" '[[ "$(/usr/bin/plutil -extract ProgramArguments json -o - "$P")" == *"\"--bind\",\"127.0.0.1\",\"--bind\",\"auto\",\"--port\",\"8790\""* ]]'
check "plist runs the named publisher bundle" '[[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$P")" == "$K/Update Studio KH Publisher.app/Contents/MacOS/Update Studio KH Publisher" ]]'
check "publisher bundle names the product" 'I="$K/Update Studio KH Publisher.app/Contents/Info.plist"; [[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$I")" == "Update Studio KH Publisher" && "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$I")" == com.khupdater.publisher && "$(/usr/bin/plutil -extract LSUIElement raw -o - "$I")" == true ]]'
check "publisher bundle allows the tailnet HTTP feed" 'I="$K/Update Studio KH Publisher.app/Contents/Info.plist"; /usr/bin/plutil -p "$I" | grep -q "NSExceptionAllowsInsecureHTTPLoads"'
check "installed khu can load the key" 'printf "## 1.0.0 — 2026-11-02\n- x\n" > "$WORK/log.md" && "$K/bin/khu" publish --feed "$WORK/feed" --key "$K/keys/private.key" --app x --version 1.0.0 --kind fake-for-tests --changelog "$WORK/log.md" --artifact "$ROOT/build/khu-stub" >/dev/null'

KEYSUM=$(shasum "$K/keys/private.key")
check "second run refuses" '! run --tailscale-ip 100.64.0.1 --backup-to "$WORK"'
check "second run says why" 'grep -q "already exists" "$WORK/out"'
check "second run kept the key" '[[ "$(shasum "$K/keys/private.key")" == "$KEYSUM" ]]'

# $WORK stays in the system temp space (macOS clears it); nothing is deleted here.
[[ $FAILS == 0 ]] && echo "PUBLISHER-INIT: all checks passed" || { echo "PUBLISHER-INIT: $FAILS failed"; exit 1; }
