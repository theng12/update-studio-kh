#!/usr/bin/env bash
# Headless, isolated Sparkle 2 live self-update proof for Studio Launcher KH.app.
#
# Builds an isolated old (0.1.84) -> new (0.1.85) Studio Launcher KH.app pair signed with the local
# signing identity, seals the new DMG, signs a local loopback appcast via packaging/local-appcast.py,
# and proves:
#   (a1) fresh install-in-progress marker refuses without touching the hold or swapping;
#   (a2) busy hold (safe:false) refuses without downloading or swapping;
#   (b)  live old -> new Sparkle self-update takes the hold, downloads/verifies the EdDSA DMG,
#        replaces the .app bundle, relaunches silently with zero visible windows, consumes the
#        sparkle-relaunch marker, releases the hold (DELETE), and reads back version 0.1.85;
#   (c)  a subsequent sparkle-check takes/releases the hold and performs no duplicate update.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="${KHU_SIGN_IDENTITY:-KH Studio Local Signing}"
KEY="${KHU_SPARKLE_KEY:-$HOME/.kh-sparkle/com.khupdater.launcher/private.key}"
OLD_VER="0.1.84"
NEW_VER="0.1.85"

[[ -x build/khu ]] || { echo "FAIL: build/khu missing — run ./build.sh build first" >&2; exit 2; }
[[ -d vendor/khsparkle/Sparkle.framework ]] || { echo "FAIL: vendor/khsparkle/Sparkle.framework missing" >&2; exit 2; }
[[ -f "$KEY" ]] || { echo "FAIL: Launcher Sparkle private key missing at $KEY" >&2; exit 2; }
[[ -f packaging/local-appcast.py ]] || { echo "FAIL: packaging/local-appcast.py missing" >&2; exit 2; }

TMP="$(mktemp -d -t kh-sparkle-proof.XXXXXX)"
SERVER_PID=""
WINMON_PID=""
CHECK_PID=""

cleanup() {
  local rc=$?
  for pid in "${CHECK_PID:-}" "${WINMON_PID:-}" "${SERVER_PID:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$TMP/apps" "$TMP/new-src" "$TMP/feed" "$TMP/state" "$TMP/kit"
printf 'proof\n' > "$TMP/kit/README.txt"

TOKEN_FILE="$TMP/state/launcher-hold-token"
INSTALL_MARKER="$TMP/state/install-in-progress"
HOLD_MODE_FILE="$TMP/state/hold-mode"
HOLD_EVENTS="$TMP/state/hold-events.jsonl"
FEED_EVENTS="$TMP/state/feed-events.jsonl"
PORTS_FILE="$TMP/state/ports.json"
WIN_LOG="$TMP/state/windows.log"

# 32-byte hex hold token, mode 0600, matching LauncherHold.token(in:).
python3 -B -I - "$TOKEN_FILE" <<'PY'
import os, secrets, sys
path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(secrets.token_hex(32))
PY
printf 'idle\n' > "$HOLD_MODE_FILE"

# Start loopback feed + hold server on ephemeral ports.
python3 -B -I - "$TMP/feed" "$TOKEN_FILE" "$HOLD_MODE_FILE" "$HOLD_EVENTS" "$FEED_EVENTS" "$PORTS_FILE" <<'PY' &
import http.server
import json
import os
import pathlib
import socketserver
import sys
import threading
import time

feed_dir, token_file, mode_file, hold_log, feed_log, ports_file = sys.argv[1:]
expected_token = pathlib.Path(token_file).read_text(encoding="utf-8").strip()
log_lock = threading.Lock()


def append_event(path, obj):
    obj["ts"] = time.time()
    with log_lock:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj, sort_keys=True) + "\n")


class FeedHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=feed_dir, **kwargs)

    def do_GET(self):
        append_event(feed_log, {"method": "GET", "path": self.path})
        super().do_GET()

    def do_HEAD(self):
        append_event(feed_log, {"method": "HEAD", "path": self.path})
        super().do_HEAD()

    def log_message(self, format, *args):
        pass


class HoldHandler(http.server.BaseHTTPRequestHandler):
    def _handle(self, method):
        path = self.path.split("?", 1)[0]
        if path not in ("/api/maintenance/hold", "/api/maintenance/hold/"):
            self._send(404, {"error": "no such route"})
            return
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {expected_token}":
            append_event(hold_log, {"method": method, "status": 401})
            self._send(401, {"error": "unauthorized"})
            return
        mode = pathlib.Path(mode_file).read_text(encoding="utf-8").strip()
        if method == "POST":
            safe = mode == "idle"
            unsettled = [] if safe else ["story"]
            body = {
                "safe": safe,
                "unsettled": unsettled,
                "dispatch_paused_s": 120,
                "in_flight": len(unsettled),
                "waiting": 0,
            }
            append_event(hold_log, {"method": "POST", "status": 200, "safe": safe, "unsettled": unsettled})
            self._send(200, body)
        elif method == "DELETE":
            body = {"safe": True, "unsettled": [], "dispatch_paused_s": 120, "in_flight": 0, "waiting": 0}
            append_event(hold_log, {"method": "DELETE", "status": 200, "safe": True})
            self._send(200, body)
        else:
            self._send(405, {"error": "method not allowed"})

    def _send(self, code, payload):
        raw = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        self._handle("POST")

    def do_DELETE(self):
        self._handle("DELETE")

    def log_message(self, format, *args):
        pass


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


feed_srv = ThreadingHTTPServer(("127.0.0.1", 0), FeedHandler)
hold_srv = ThreadingHTTPServer(("127.0.0.1", 0), HoldHandler)
ports = {"feed": feed_srv.server_address[1], "hold": hold_srv.server_address[1]}
pathlib.Path(ports_file).write_text(json.dumps(ports), encoding="utf-8")

t1 = threading.Thread(target=feed_srv.serve_forever, daemon=True)
t2 = threading.Thread(target=hold_srv.serve_forever, daemon=True)
t1.start()
t2.start()
try:
    while True:
        time.sleep(0.5)
except KeyboardInterrupt:
    pass
finally:
    feed_srv.shutdown()
    hold_srv.shutdown()
PY
SERVER_PID=$!

for _ in $(seq 1 50); do
  [[ -s "$PORTS_FILE" ]] && break
  sleep 0.1
done
[[ -s "$PORTS_FILE" ]] || { echo "FAIL: loopback proof server did not bind" >&2; exit 1; }

FEED_PORT="$(python3 -B -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["feed"])' "$PORTS_FILE")"
HOLD_PORT="$(python3 -B -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hold"])' "$PORTS_FILE")"
FEED_URL="http://127.0.0.1:${FEED_PORT}/appcast.xml"
DMG_URL="http://127.0.0.1:${FEED_PORT}/Studio-Launcher-KH-${NEW_VER}.dmg"
HOLD_URL="http://127.0.0.1:${HOLD_PORT}/api/maintenance/hold"

# Compile tiny headless CoreGraphics window checker (zero permission prompts).
cat > "$TMP/wincheck.m" <<'OBJC'
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <stdio.h>
#include <string.h>

int main(int argc, const char *argv[]) {
    if (argc < 2) return 2;
    const char *prefix = argv[1];
    size_t plen = strlen(prefix);
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    int hits = 0;
    if (list) {
        for (NSDictionary *w in (__bridge NSArray *)list) {
            pid_t pid = [w[(id)kCGWindowOwnerPID] intValue];
            if (pid <= 0) continue;
            char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0 && strncmp(pathbuf, prefix, plen) == 0) {
                int layer = [w[(id)kCGWindowLayer] intValue];
                if (layer == 0) {
                    printf("WINDOW pid=%d layer=%d path=%s\n", pid, layer, pathbuf);
                    hits++;
                }
            }
        }
        CFRelease(list);
    }
    return hits > 0 ? 1 : 0;
}
OBJC
xcrun clang -fobjc-arc -O1 -framework Foundation -framework CoreGraphics "$TMP/wincheck.m" -o "$TMP/wincheck"

build_signed_app() {
  local out_app="$1" ver="$2"
  build/khu launcher-bundle --out "$out_app" --version "$ver" --kit "$TMP/kit" >/dev/null
  python3 -B -I - "$out_app/Contents/Info.plist" "$FEED_URL" "$HOLD_URL" "$TOKEN_FILE" <<'PY'
import plistlib, sys
plist_path, feed_url, hold_url, token_file = sys.argv[1:]
with open(plist_path, "rb") as fh:
    info = plistlib.load(fh)
info["SUFeedURL"] = feed_url
info["KHHoldURL"] = hold_url
info["KHHoldTokenFile"] = token_file
info["SUEnableAutomaticChecks"] = True
with open(plist_path, "wb") as fh:
    plistlib.dump(info, fh)
PY
  local fw="$out_app/Contents/Frameworks/Sparkle.framework"
  mkdir -p "$out_app/Contents/Frameworks"
  ditto vendor/khsparkle/Sparkle.framework "$fw"
  for inner in "$fw"/Versions/Current/XPCServices/*.xpc "$fw"/Versions/Current/Autoupdate "$fw"/Versions/Current/Updater.app; do
    [[ -e "$inner" ]] || continue
    codesign --force --sign "$IDENTITY" --timestamp=none "$inner"
  done
  codesign --force --sign "$IDENTITY" --timestamp=none "$fw"
  codesign --force --sign "$IDENTITY" --timestamp=none "$out_app"
  codesign --verify --deep --strict "$out_app"
}

app_version() {
  python3 -B -I - "$1/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    print(plistlib.load(fh).get("CFBundleShortVersionString", ""))
PY
}

OLD_APP="$TMP/apps/Studio Launcher KH.app"
NEW_APP="$TMP/new-src/Studio Launcher KH.app"
NEW_DMG="$TMP/feed/Studio-Launcher-KH-${NEW_VER}.dmg"
APPCAST="$TMP/feed/appcast.xml"

echo "==> Building isolated signed pair: $OLD_VER -> $NEW_VER"
build_signed_app "$OLD_APP" "$OLD_VER"
build_signed_app "$NEW_APP" "$NEW_VER"

hdiutil create -quiet -volname "Studio Launcher KH" -srcfolder "$TMP/new-src" -ov -format UDZO "$NEW_DMG"
hdiutil verify "$NEW_DMG" >/dev/null
python3 -B -I packaging/local-appcast.py --dmg "$NEW_DMG" --url "$DMG_URL" --out "$APPCAST" 2>"$TMP/state/appcast-meta.json"
echo "    signed local appcast: $(cat "$TMP/state/appcast-meta.json")"

# Continuous window monitor watching only processes launched from $TMP/apps/
(
  while true; do
    "$TMP/wincheck" "$TMP/apps/" >> "$WIN_LOG" 2>&1 || true
    sleep 0.1
  done
) &
WINMON_PID=$!

# ---------------------------------------------------------------------------
# Scenario (a1): fresh install-in-progress marker refuses without swapping
# ---------------------------------------------------------------------------
echo "==> Scenario (a1): fresh install-in-progress marker refuses"
: > "$HOLD_EVENTS"
: > "$FEED_EVENTS"
python3 -B -I - "$INSTALL_MARKER" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("story\n")
PY
set +e
OUT_A1="$(KH_SPARKLE_INSTALL_MARKER="$INSTALL_MARKER" "$OLD_APP/Contents/MacOS/Studio Launcher KH" sparkle-check --timeout 20 2>&1)"
RC_A1=$?
set -e
rm -f "$INSTALL_MARKER"
[[ "$RC_A1" -ne 0 ]] || { echo "FAIL (a1): expected non-zero exit, got 0 ($OUT_A1)" >&2; exit 1; }
grep -qi "install is in progress" <<<"$OUT_A1" || { echo "FAIL (a1): expected install-in-progress reason, got: $OUT_A1" >&2; exit 1; }
[[ ! -s "$HOLD_EVENTS" ]] || { echo "FAIL (a1): hold should not be called while install-in-progress is set" >&2; exit 1; }
[[ ! -s "$FEED_EVENTS" ]] || { echo "FAIL (a1): feed should not be fetched while install-in-progress is set" >&2; exit 1; }
[[ "$(app_version "$OLD_APP")" == "$OLD_VER" ]] || { echo "FAIL (a1): app version changed" >&2; exit 1; }
echo "    PASS (a1): refused cleanly ($OUT_A1)"

# ---------------------------------------------------------------------------
# Scenario (a2): busy hold (safe:false) refuses without downloading or swapping
# ---------------------------------------------------------------------------
echo "==> Scenario (a2): busy hold (safe:false) refuses"
: > "$HOLD_EVENTS"
: > "$FEED_EVENTS"
printf 'busy\n' > "$HOLD_MODE_FILE"
set +e
OUT_A2="$(KH_SPARKLE_INSTALL_MARKER="$INSTALL_MARKER" "$OLD_APP/Contents/MacOS/Studio Launcher KH" sparkle-check --timeout 20 2>&1)"
RC_A2=$?
set -e
[[ "$RC_A2" -ne 0 ]] || { echo "FAIL (a2): expected non-zero exit, got 0 ($OUT_A2)" >&2; exit 1; }
grep -qi "hold" <<<"$OUT_A2" || { echo "FAIL (a2): expected hold refusal reason, got: $OUT_A2" >&2; exit 1; }
python3 -B -I - "$HOLD_EVENTS" "$FEED_EVENTS" <<'PY'
import json, pathlib, sys
hold = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
feed = [json.loads(l) for l in pathlib.Path(sys.argv[2]).read_text().splitlines() if l.strip()]
assert any(e.get("method") == "POST" and e.get("safe") is False for e in hold), f"expected POST safe:false, got {hold}"
assert not any(e.get("path", "").endswith(".dmg") for e in feed), f"DMG should not download on busy hold: {feed}"
PY
[[ "$(app_version "$OLD_APP")" == "$OLD_VER" ]] || { echo "FAIL (a2): app version changed" >&2; exit 1; }
echo "    PASS (a2): refused cleanly on safe:false hold"

# ---------------------------------------------------------------------------
# Scenario (b): live old -> new Sparkle self-update (0.1.84 -> 0.1.85)
# ---------------------------------------------------------------------------
echo "==> Scenario (b): live Sparkle self-update ($OLD_VER -> $NEW_VER)"
: > "$HOLD_EVENTS"
: > "$FEED_EVENTS"
rm -f "$TMP/state/sparkle.log" "$TMP/state/sparkle-relaunch"
printf 'idle\n' > "$HOLD_MODE_FILE"

KH_SPARKLE_INSTALL_MARKER="$INSTALL_MARKER" "$OLD_APP/Contents/MacOS/Studio Launcher KH" sparkle-check --timeout 90 >"$TMP/state/check-b.out" 2>&1 &
CHECK_PID=$!

SWAPPED=0
RELAUNCHED=0
for _ in $(seq 1 900); do
  cur_ver="$(app_version "$OLD_APP" 2>/dev/null || true)"
  if [[ "$cur_ver" == "$NEW_VER" ]]; then
    SWAPPED=1
  fi
  if [[ -f "$TMP/state/sparkle.log" ]] && grep -q "relaunched silently at ${NEW_VER}" "$TMP/state/sparkle.log"; then
    RELAUNCHED=1
  fi
  if [[ "$SWAPPED" -eq 1 && "$RELAUNCHED" -eq 1 ]]; then
    break
  fi
  sleep 0.1
done
# Wait briefly for check-b process to exit if it hasn't already
for _ in $(seq 1 30); do
  kill -0 "$CHECK_PID" 2>/dev/null || break
  sleep 0.1
done
CHECK_PID=""

if [[ "$SWAPPED" -ne 1 ]]; then
  echo "FAIL (b): bundle did not swap to $NEW_VER (current=$(app_version "$OLD_APP" 2>/dev/null || echo unreadable))" >&2
  echo "--- sparkle-check output ---" >&2
  cat "$TMP/state/check-b.out" >&2 || true
  echo "--- hold events ---" >&2
  cat "$HOLD_EVENTS" >&2 || true
  echo "--- feed events ---" >&2
  cat "$FEED_EVENTS" >&2 || true
  exit 1
fi

codesign --verify --deep --strict "$OLD_APP"

if [[ "$RELAUNCHED" -ne 1 ]]; then
  echo "FAIL (b): bundle swapped to $NEW_VER, but silent relaunch did not complete within timeout" >&2
  echo "  relaunch marker present: $([[ -f "$TMP/state/sparkle-relaunch" ]] && echo yes || echo no)" >&2
  echo "--- sparkle-check output ---" >&2
  cat "$TMP/state/check-b.out" >&2 || true
  echo "--- sparkle.log ---" >&2
  cat "$TMP/state/sparkle.log" >&2 || true
  echo "--- hold events ---" >&2
  cat "$HOLD_EVENTS" >&2 || true
  exit 1
fi

[[ ! -f "$TMP/state/sparkle-relaunch" ]] || { echo "FAIL (b): sparkle-relaunch marker was not consumed" >&2; exit 1; }

python3 -B -I - "$HOLD_EVENTS" "$FEED_EVENTS" "$NEW_VER" <<'PY'
import json, pathlib, sys
hold = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
feed = [json.loads(l) for l in pathlib.Path(sys.argv[2]).read_text().splitlines() if l.strip()]
new_ver = sys.argv[3]
assert any(e.get("method") == "POST" and e.get("safe") is True for e in hold), f"expected POST safe:true, got {hold}"
assert any(e.get("method") == "DELETE" and e.get("status") == 200 for e in hold), f"expected DELETE hold release after silent relaunch, got {hold}"
assert any(e.get("path") == "/appcast.xml" for e in feed), f"expected appcast fetch, got {feed}"
assert any(e.get("path") == f"/Studio-Launcher-KH-{new_ver}.dmg" for e in feed), f"expected DMG download, got {feed}"
PY

if [[ -s "$WIN_LOG" ]]; then
  echo "FAIL (b): visible window detected from test bundle during self-update:" >&2
  cat "$WIN_LOG" >&2
  exit 1
fi
echo "    PASS (b): swapped to $NEW_VER, codesign verified, relaunched silently, hold released, 0 visible windows"
echo "    relaunch log: $(cat "$TMP/state/sparkle.log")"

# ---------------------------------------------------------------------------
# Scenario (c): subsequent check performs no duplicate update
# ---------------------------------------------------------------------------
echo "==> Scenario (c): subsequent sparkle-check performs no duplicate update"
: > "$HOLD_EVENTS"
: > "$FEED_EVENTS"
set +e
OUT_C="$(KH_SPARKLE_INSTALL_MARKER="$INSTALL_MARKER" "$OLD_APP/Contents/MacOS/Studio Launcher KH" sparkle-check --timeout 30 2>&1)"
RC_C=$?
set -e
[[ "$RC_C" -eq 0 ]] || { echo "FAIL (c): expected exit 0 on up-to-date check, got $RC_C ($OUT_C)" >&2; exit 1; }
grep -qi "no update" <<<"$OUT_C" || { echo "FAIL (c): expected 'no update' in stderr, got: $OUT_C" >&2; exit 1; }
python3 -B -I - "$HOLD_EVENTS" "$FEED_EVENTS" <<'PY'
import json, pathlib, sys
hold = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
feed = [json.loads(l) for l in pathlib.Path(sys.argv[2]).read_text().splitlines() if l.strip()]
assert any(e.get("method") == "POST" and e.get("safe") is True for e in hold), f"expected POST safe:true, got {hold}"
assert any(e.get("method") == "DELETE" and e.get("status") == 200 for e in hold), f"expected DELETE hold release, got {hold}"
assert any(e.get("path") == "/appcast.xml" for e in feed), f"expected appcast fetch, got {feed}"
assert not any(e.get("path", "").endswith(".dmg") for e in feed), f"duplicate DMG download on up-to-date app: {feed}"
PY
[[ "$(app_version "$OLD_APP")" == "$NEW_VER" ]] || { echo "FAIL (c): version changed unexpectedly" >&2; exit 1; }
if [[ -s "$WIN_LOG" ]]; then
  echo "FAIL (c): visible window detected:" >&2
  cat "$WIN_LOG" >&2
  exit 1
fi
echo "    PASS (c): no duplicate update, hold acquired & released, 0 visible windows"
echo "SPARKLE PROOF PASS: $OLD_VER -> $NEW_VER (all 4 scenarios verified headless)"
