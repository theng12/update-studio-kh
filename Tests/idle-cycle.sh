#!/bin/zsh
# One real cycle, then an idle window, then compare — the owner's rule (2026-11-19): every app's
# acceptance names its idle footprint and what it does when idle, measured, not assumed.
#
#   zsh Tests/idle-cycle.sh <path to khu> [idle seconds] [ceiling MB]
#
# The helper runs against a local server, so every interval is a real request cycle through the
# URLSession path that leaked before, with nothing installed. It is never shown and keeps its own
# state directory under $TMPDIR. Flat is the only pass: growth while idle is the defect a single
# reading cannot see.
set -u
helper=${1:?usage: idle-cycle.sh <path to khu> [idle seconds] [ceiling MB]}
idle=${2:-600}
ceiling=${3:-300}
[[ "$helper" == /* ]] || helper="$PWD/$helper"
[[ -x "$helper" ]] || { echo "idle-cycle: $helper is not executable"; exit 2 }

# The key this build pins: the saved config must name it, or the helper refuses before any request.
public=$(sed -n 's/.*public static let base64: String? = "\([^"]*\)".*/\1/p' Sources/KHUpdaterCore/PinnedKey.swift | head -1)
[[ -n "$public" ]] || { echo "idle-cycle: the pinned key could not be read from PinnedKey.swift"; exit 2 }
root=$(mktemp -d "${TMPDIR:-/tmp}/idle-cycle.XXXXXX") || exit 2
mkdir -p "$root/state"
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')

# Answers every path with 200 and an empty JSON body: the helper completes a request cycle (the path
# that leaked before) and then refuses the empty feed, as it should.
cat > "$root/serve.py" <<'SRV'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def _ok(self):
        body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    do_GET = _ok
    do_POST = _ok
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H) as srv:
    srv.serve_forever()
SRV

cat > "$root/config.json" <<JSON
{"feedURL":"http://127.0.0.1:$port/release.json","publicKey":"$public","stateDir":"$root/state",
 "machine":"idle-mac","token":"idle-token","apps":{},"intervalMinutes":1,"once":false}
JSON

server_pid=""; helper_pid=""
cleanup() {
  [[ -n "$helper_pid" ]] && kill "$helper_pid" 2>/dev/null
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

python3 -I "$root/serve.py" "$port" >/dev/null 2>&1 &
server_pid=$!
sleep 1
"$helper" agent --config "$root/config.json" > "$root/agent.log" 2>&1 &
helper_pid=$!

# One cycle: the helper's start line, then the result of its first check (success or the refusal it
# made when the feed did not decode). Both are in its own log, not on stdout.
# A check has finished when the helper's log names its start and its stdout carries that check's
# result — the empty feed is refused, which is a completed request cycle with nothing installed.
cycled=0
for _ in {1..90}; do
  started=0; finished=0
  [[ -f "$root/state/agent.log" ]] && grep -q "agent start:" "$root/state/agent.log" 2>/dev/null && started=1
  grep -q "agent error:\|agent run:" "$root/agent.log" 2>/dev/null && finished=1
  if (( started && finished )); then cycled=1; break; fi
  if ! kill -0 "$helper_pid" 2>/dev/null; then break; fi
  sleep 1
done
if [[ "$cycled" != 1 ]]; then
  echo "idle-cycle: the helper never finished a check — tail of its log:"
  tail -5 "$root/agent.log" 2>/dev/null | sed 's/^/  /'
  exit 3
fi
echo "idle-cycle: first check done — $(tail -1 "$root/agent.log" 2>/dev/null)"

sample() {  # rss MB, open fds, threads, sockets
  local rss fds threads socks
  rss=$(ps -o rss= -p "$helper_pid" 2>/dev/null | awk '{printf "%d", $1/1024}')
  fds=$(lsof -p "$helper_pid" 2>/dev/null | wc -l | tr -d ' ')
  threads=$(ps -M "$helper_pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  socks=$(lsof -p "$helper_pid" -a -i 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  echo "${rss:-0} ${fds:-0} ${threads:-0} ${socks:-0}"
}
read -r rss_a fds_a thr_a sock_a <<< "$(sample)"
echo "idle-cycle: after the first check — ${rss_a} MB, ${fds_a} fds, ${thr_a} threads, ${sock_a} sockets; idle for ${idle}s"
sleep "$idle"
if ! kill -0 "$helper_pid" 2>/dev/null; then echo "idle-cycle: the helper exited during the idle window"; exit 1; fi
read -r rss_b fds_b thr_b sock_b <<< "$(sample)"
lines=0; [[ -f "$root/state/agent.log" ]] && lines=$(wc -l < "$root/state/agent.log" | tr -d ' ')
echo "idle-cycle: after ${idle}s idle — ${rss_b} MB, ${fds_b} fds, ${thr_b} threads, ${sock_b} sockets; ${lines} log line(s)"

fail=0
(( rss_b > ceiling )) && { echo "idle-cycle: ${rss_b} MB is over the ${ceiling} MB ceiling"; fail=1; }
(( rss_b - rss_a > 20 )) && { echo "idle-cycle: RSS grew $((rss_b - rss_a)) MB while idle"; fail=1; }
(( fds_b - fds_a > 2 )) && { echo "idle-cycle: open files grew $((fds_b - fds_a)) while idle"; fail=1; }
(( thr_b - thr_a > 2 )) && { echo "idle-cycle: threads grew $((thr_b - thr_a)) while idle"; fail=1; }
(( sock_b - sock_a > 2 )) && { echo "idle-cycle: sockets grew $((sock_b - sock_a)) while idle"; fail=1; }
(( fail )) && { echo "idle-cycle: FAILED — not flat"; exit 1; }
echo "idle-cycle: OK — flat within ${ceiling} MB (${rss_a}→${rss_b} MB, ${fds_a}→${fds_b} fds, ${thr_a}→${thr_b} threads, ${sock_a}→${sock_b} sockets)"
exit 0