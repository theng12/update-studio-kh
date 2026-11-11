#!/usr/bin/env python3
"""SIGTERM shutdown fixture for khu-stub: a supervisor must stop its own child and restart nothing.

Compiles the actual stub sources twice — once from the reviewed base commit, once from the
working tree — in the task-owned --output folder. It never runs launchctl, never touches an
installed stub/helper/publisher, and uses only fixture processes it started itself. The base run
reproduces the orphan being fixed; the fixed run proves the child is stopped, no replacement is
started, and a child that ignores TERM is reported rather than escalated to SIGKILL.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

BASE_COMMIT = "3dd8ae84813691bc20be5204e21648548439bd01"
SHUTDOWN_GRACE = 5

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)

results = []
details = {}
receipt = {
    "baseCommit": BASE_COMMIT,
    "fixedSource": "Sources/KHUStub/StubRunner.swift",
    "fixedSourceSHA256": hashlib.sha256((root / "Sources/KHUStub/StubRunner.swift").read_bytes()).hexdigest(),
    "baseSourceSHA256": None,
    "compiles": {},
    "cases": {},
    "liveLaunchctl": False,
    "scope": "actual stub sources only; fixture /bin/sh child; SIGTERM sent to the supervisor pid alone",
}


def check(name, ok, **proof):
    results.append(ok)
    receipt["cases"][name] = {"pass": bool(ok), **proof}
    if not ok:
        print("FAIL", name, proof)


def compile_stub(label, runner_source):
    directory = out / label
    directory.mkdir()
    sources = sorted((root / "Sources/KHUStub").glob("*.swift")) + [root / "Sources/khu-stub/StubMain.swift"]
    sources = [directory / "StubRunner.swift" if s.name == "StubRunner.swift" else s for s in sources]
    (directory / "StubRunner.swift").write_text(runner_source)
    binary = directory / "khu-stub"
    command = ["swiftc", "-parse-as-library", "-o", str(binary)] + [str(s) for s in sources]
    run = subprocess.run(command, capture_output=True, text=True, timeout=180)
    receipt["compiles"][label] = {"command": command, "exit": run.returncode,
                                  "output": (run.stdout + run.stderr)[-4000:]}
    if run.returncode != 0:
        print((run.stdout + run.stderr)[-4000:])
        sys.exit(1)
    return binary


def make_base(label, child_body):
    base = out / label / "base"
    starts = out / label / "starts"
    binary = base / "versions/0.1.17/khu"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\n" + child_body.format(starts=shlex.quote(str(starts))) + "\n")
    binary.chmod(0o755)
    os.symlink(binary, base / "current")
    return base, starts


def child_pid(starts, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if starts.exists():
            lines = starts.read_text().split()
            if lines:
                return int(lines[0])
        time.sleep(0.05)
    raise AssertionError(f"fixture child never started ({starts})")


def start_stub(binary, base, label):
    log = open(out / label / "stub.out", "wb")
    process = subprocess.Popen([str(binary), "--base", str(base), "--", "fixture"],
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    return process


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def ppid_of(pid):
    probe = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True)
    return int(probe.stdout.strip()) if probe.stdout.strip() else None


def wait_gone(pid, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not alive(pid):
            return True
        time.sleep(0.05)
    return False


def cleanup_group(process, child):
    for pgid in {process.pid, child}:
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.2)
    for pgid in {process.pid, child}:
        try:
            os.killpg(pgid, signal.SIGKILL)  # fixture cleanup only, never the supervisor's behavior
        except ProcessLookupError:
            pass


TERMABLE = 'echo $$ >> {starts}; exec /bin/sleep 600'
IGNORES_TERM = "trap '' TERM; echo $$ >> {starts}; while :; do sleep 1; done"

base_source = subprocess.run(["git", "-C", str(root), "show", f"{BASE_COMMIT}:Sources/KHUStub/StubRunner.swift"],
                             capture_output=True, text=True, timeout=30)
if base_source.returncode != 0:
    print("cannot read base StubRunner:", base_source.stderr)
    sys.exit(1)
receipt["baseSourceSHA256"] = hashlib.sha256(base_source.stdout.encode()).hexdigest()
base_stub = compile_stub("base", base_source.stdout)
fixed_stub = compile_stub("fixed", (root / "Sources/KHUStub/StubRunner.swift").read_text())

# 1. Base: SIGTERM to the supervisor alone leaves the child running and reparented.
base, starts = make_base("base-run", TERMABLE)
process = start_stub(base_stub, base, "base-run")
pid = child_pid(starts)
os.kill(process.pid, signal.SIGTERM)
process.wait(timeout=10)
deadline = time.time() + 5
while time.time() < deadline and ppid_of(pid) != 1:
    time.sleep(0.05)
check("base-sigterm-orphans-child",
      process.returncode == -signal.SIGTERM and alive(pid) and ppid_of(pid) == 1,
      stubExit=process.returncode, childPid=pid, childAlive=alive(pid), childPPID=ppid_of(pid))
cleanup_group(process, pid)

# 2. Fixed: SIGTERM stops the child, exits 143, and starts no replacement.
base, starts = make_base("fixed-run", TERMABLE)
process = start_stub(fixed_stub, base, "fixed-run")
pid = child_pid(starts)
os.kill(process.pid, signal.SIGTERM)
process.wait(timeout=15)
gone = wait_gone(pid, timeout=5)
time.sleep(1.5)  # longer than the fixture's restart delay: a restart would have written a second line
starts_lines = starts.read_text().splitlines() if starts.exists() else []
log = (out / "fixed-run" / "stub.out").read_text()
check("fixed-sigterm-stops-own-child",
      process.returncode == 143 and gone and len(starts_lines) == 1
      and "shutdown: sending SIGTERM to child" in log and "shutdown: child" in log,
      stubExit=process.returncode, childPid=pid, childGone=gone, starts=len(starts_lines),
      logLines=[line for line in log.splitlines() if "shutdown" in line])
cleanup_group(process, pid)

# 3. Fixed: a child that ignores TERM is waited for a bounded time and reported, never killed.
base, starts = make_base("fixed-ignores", IGNORES_TERM)
process = start_stub(fixed_stub, base, "fixed-ignores")
pid = child_pid(starts)
began = time.time()
os.kill(process.pid, signal.SIGTERM)
process.wait(timeout=15)
elapsed = time.time() - began
log = (out / "fixed-ignores" / "stub.out").read_text()
starts_lines = starts.read_text().splitlines() if starts.exists() else []
check("fixed-refusal-is-bounded-and-honest",
      process.returncode == 143 and elapsed >= SHUTDOWN_GRACE - 0.5 and alive(pid)
      and len(starts_lines) == 1 and "refusing to escalate" in log,
      stubExit=process.returncode, childPid=pid, childAlive=alive(pid), elapsed=round(elapsed, 2),
      starts=len(starts_lines), logLines=[line for line in log.splitlines() if "shutdown" in line])
cleanup_group(process, pid)

passed, failed = results.count(True), results.count(False)
receipt["result"] = {"passed": passed, "failed": failed}
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
print(f"STUB SHUTDOWN FIXTURES: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
