#!/usr/bin/env python3
"""Measure the shipped khu agent while IDLE: one full cycle against a loopback fixture publisher,
then ten minutes of 30 s samples of its own process.

The fixture is what an enrolled Mac sees: `khu keygen` makes a publisher key, `khu publish` signs
one `updater` release into a temp feed, `khu serve` serves that feed on 127.0.0.1, and the real
`khu agent` runs headless with its own config, token and state under this run's temp dir. The agent
is always started with `KHU_NO_MENU=1` (no menu-bar icon) and `KHU_HOLD_TOKEN_FILE` pointing inside
the temp dir, so nothing touches the real `~/Library/KHUpdater`, the real launchd domain, the
publisher on 1301, or the owner's desktop. Scratch is retired into the repository's own `_trash`
on success; on a failure it is kept where it is as evidence.

The agent's run interval is a STARTUP value: `AgentConfig.reloadingConnection` (Config.swift)
carries only feedURL, token and network from the saved file, and the loop's sleep uses the config
loaded at start (`Sources/khu/main.swift`, `agent` case). So the fixture starts with
`intervalMinutes: 30`: the first cycle runs immediately, and the sleep that follows outlasts the
whole sampling window. A second `agent run:` line in the window therefore means the sleep did not
hold, and the run fails.

Flatness is judged after the first two samples (the early ones still carry the run's retiring
URLSession threads): no strictly increasing series, and the last sample within +5 fds, +2 threads,
+8 MB RSS and +20 Mach ports of the first settled sample. `lsmp` needs task_for_pid, which a
non-debugger shell may be refused; a refusal is recorded and that one metric is SKIPped, never
counted as a pass.

    python3 -I Tests/test_agent_idle_leak.py
"""
from pathlib import Path
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
KHU = REPO / "build" / "khu"
VERSION = "9.9.99"
SAMPLE_SECONDS = 30
WINDOW_SECONDS = 600
SETTLE_SAMPLES = 2

# metric name, limit of growth over the settled window
LIMITS = (("fds", 5), ("threads", 2), ("rss", 8 * 1024), ("ports", 20))


def run(argv, timeout=120, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kwargs)


def lines(argv):
    return len(run(argv, timeout=60).stdout.splitlines())


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_port(port, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def footprint_kb(pid):
    result = run(["footprint", "-p", str(pid)], timeout=60)
    match = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", result.stdout)
    if not match:
        return None
    scale = {"KB": 1, "MB": 1024, "GB": 1024 * 1024}[match.group(2)]
    return int(float(match.group(1)) * scale)


def sample(pid):
    row = {"fds": lines(["lsof", "-p", str(pid)]),
           "net": lines(["lsof", "-a", "-i", "-p", str(pid)]),
           "threads": lines(["ps", "-M", str(pid)])}
    rss = run(["ps", "-o", "rss=", "-p", str(pid)], timeout=30).stdout.strip()
    row["rss"] = int(rss) if rss.isdigit() else None
    row["footprint"] = footprint_kb(pid)
    ports = run(["lsmp", "-p", str(pid)], timeout=60)
    if ports.returncode == 0 and ports.stdout.strip():
        row["ports"] = len(ports.stdout.splitlines())
    else:
        row["ports"] = None
        row["ports_why"] = (ports.stderr.strip().splitlines() or ["no output"])[0]
    return row


def retire(directory):
    """House rule: scratch moves into the repository's own _trash, never away.

    The owner may empty their trash at any time, which leaves the repo's `_trash` link dangling,
    so create what it points at rather than the link itself.
    """
    trash = (REPO / "_trash" / "test-tmp").resolve()
    trash.mkdir(parents=True, exist_ok=True)
    directory.rename(trash / (directory.name + "." + uuid.uuid4().hex))


def stop(process):
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def where(step, detail, scratch=None):
    print("FAIL: stopped at %s" % step)
    for line in (detail or "").strip().splitlines()[-8:]:
        print("  | " + line)
    if scratch is not None:
        print("evidence kept at %s" % scratch)


def main():
    sys.stdout.reconfigure(line_buffering=True)
    if not KHU.exists():
        print("building build/khu (./build.sh build) ...")
        built = run([str(REPO / "build.sh"), "build"], timeout=900, cwd=str(REPO))
        if built.returncode != 0 or not KHU.exists():
            print("FAIL: ./build.sh build failed")
            print((built.stdout + built.stderr)[-2000:])
            return 1

    scratch = Path(tempfile.mkdtemp(prefix="agent-idle-leak-"))
    machine = "idle-leak-" + uuid.uuid4().hex[:8]
    keys, feed, pubstate = scratch / "keys", scratch / "feed", scratch / "pubstate"
    changelog = scratch / "CHANGELOG.md"
    artifact = scratch / "khu-artifact"
    config = scratch / "config.json"
    agent_log = scratch / "agent.log"
    server = agent = None
    serve_log = agent_out = None
    try:
        keygen = run([str(KHU), "keygen", str(keys)])
        public_key = next((line.split(": ", 1)[1] for line in keygen.stdout.splitlines()
                           if line.startswith("public key: ")), None) if keygen.returncode == 0 else None
        if not public_key:
            where("keygen", keygen.stdout + keygen.stderr, scratch)
            return 1

        changelog.write_text("## %s — 2026-11-17\n\n- idle leak fixture release\n" % VERSION,
                             encoding="utf-8")
        shutil.copy2(KHU, artifact)
        published = run([str(KHU), "publish", "--feed", str(feed), "--key", str(keys / "private.key"),
                         "--app", "updater", "--version", VERSION, "--artifact", str(artifact),
                         "--kind", "updater", "--changelog", str(changelog)])
        if published.returncode != 0:
            where("publish", published.stdout + published.stderr, scratch)
            return 1

        enrolled = run([str(KHU), "enrol", "--state", str(pubstate), "--machine", machine])
        token = enrolled.stdout.strip() if enrolled.returncode == 0 else ""
        if not token:
            where("enrol", enrolled.stdout + enrolled.stderr, scratch)
            return 1

        port = free_port()
        serve_log = (scratch / "serve.log").open("w")
        server = subprocess.Popen([str(KHU), "serve", "--feed", str(feed), "--state", str(pubstate),
                                   "--key", str(keys / "private.key"), "--bind", "127.0.0.1",
                                   "--port", str(port)], stdout=serve_log, stderr=subprocess.STDOUT,
                                  cwd=str(scratch))
        if not wait_port(port, 20):
            serve_log.flush()
            where("serve", (scratch / "serve.log").read_text(), scratch)
            return 1

        config.write_text(json.dumps({
            "feedURL": "http://127.0.0.1:%d/release.json" % port, "publicKey": public_key,
            "stateDir": str(scratch / "agent-state"), "machine": machine, "token": token,
            # A startup value (see the docstring): the first cycle runs now, the next is +30 min.
            "intervalMinutes": 30, "once": False,
            # Automatic is off, so the offered update is evaluated but never installed: this
            # measures the idle agent after a cycle, not a self-update.
            "apps": {"updater": {"bundlePath": "", "recipe": "updater", "automatic": False}},
        }, indent=2) + "\n", encoding="utf-8")

        environment = dict(os.environ, KHU_NO_MENU="1",
                           KHU_HOLD_TOKEN_FILE=str(scratch / "hold-token"))
        agent_out = agent_log.open("w")
        agent = subprocess.Popen([str(KHU), "agent", "--config", str(config)],
                                 stdout=agent_out, stderr=subprocess.STDOUT,
                                 cwd=str(scratch), env=environment)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if agent.poll() is not None:
                where("the first agent run (the agent exited)", agent_log.read_text(), scratch)
                return 1
            if "agent run:" in agent_log.read_text():
                break
            time.sleep(0.5)
        else:
            where("the first agent run (no 'agent run:' line within 180 s)", agent_log.read_text(), scratch)
            return 1
        print("fixture: agent %d, feed on 127.0.0.1:%d, one cycle done" % (agent.pid, port))
        for line in agent_log.read_text().splitlines()[:2]:
            print("  | " + line)

        print("\n  t(s)   fds  net  threads   rss(KB)  footprint(KB)  ports")
        samples = []
        started = time.monotonic()
        for index in range(WINDOW_SECONDS // SAMPLE_SECONDS + 1):
            if agent.poll() is not None:
                print("FAIL: the agent exited during the sampling window (sample %d)" % index)
                for line in agent_log.read_text().strip().splitlines()[-8:]:
                    print("  | " + line)
                print("evidence kept at %s" % scratch)
                return 1
            row = sample(agent.pid)
            samples.append(row)
            print("  %4d  %4s  %3s  %7s  %8s  %13s  %5s" % (
                int(time.monotonic() - started), row["fds"], row["net"], row["threads"],
                row["rss"], row["footprint"],
                row["ports"] if row["ports"] is not None else "-"))
            if index < WINDOW_SECONDS // SAMPLE_SECONDS:
                time.sleep(max(0, started + (index + 1) * SAMPLE_SECONDS - time.monotonic()))

        runs = [line for line in agent_log.read_text().splitlines() if line.startswith("agent run:")]
        if len(runs) != 1:
            print("FAIL: %d agent runs in the window, not one; the idle premise does not hold" % len(runs))
            return 1

        ok = True
        if any(row["ports"] is None for row in samples):
            why = next(row["ports_why"] for row in samples if "ports_why" in row)
            print("SKIP: Mach ports (lsmp refused: %s)" % why)
        settled = samples[SETTLE_SAMPLES - 1:]
        for name, limit in LIMITS:
            values = [row[name] for row in settled]
            if any(value is None for value in values):
                continue
            grew = all(later > earlier for earlier, later in zip(values, values[1:]))
            delta = values[-1] - values[0]
            verdict = "PASS" if delta <= limit and not grew else "FAIL"
            ok = ok and verdict == "PASS"
            print("%s: %s %s -> %s (%+d, limit +%d)%s" % (
                verdict, name, values[0], values[-1], delta, limit,
                "; STRICTLY INCREASING over the window" if grew else ""))
        print("\n%s: agent idle for %d s after one cycle%s" % (
            "PASS" if ok else "FAIL", WINDOW_SECONDS,
            "" if ok else "; see the failing metric above"))
        if ok:
            retire(scratch)
        else:
            print("evidence kept at %s" % scratch)
        return 0 if ok else 1
    finally:
        stop(agent)
        stop(server)
        for handle in (agent_out, serve_log):
            if handle is not None and not handle.closed:
                handle.close()


if __name__ == "__main__":
    sys.exit(main())
