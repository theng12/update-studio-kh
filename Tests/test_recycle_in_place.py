#!/usr/bin/env python3
"""The helper starts itself again in place, and the fixture proves it on a real process.

`khu agent` is given an unreachable publisher and a tiny transfer cap, so every run crosses the cap
and the agent re-execs itself. The process must stay alive under one pid (a re-exec is not an exit),
the log must carry one line per recycle, and nothing else may be needed from the system.

The whole run happens in a temporary home with `KHU_NO_MENU=1`; the real helper, the real state dir
and the real launchd domain are never touched. Scratch retires into the repository's `_trash`.
"""
import os
import pathlib
import re
import signal
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
KHU = REPO / "build/khu"
SECONDS = 8
MIN_RECYCLES = 2


def main() -> int:
    if not os.access(KHU, os.X_OK):
        print("FAIL: build/khu is missing; run ./build.sh build first")
        return 2
    root = pathlib.Path(tempfile.mkdtemp(prefix="khu-test-recycle-", dir=tempfile.gettempdir()))
    state = root / "state"
    state.mkdir()
    config = root / "config.json"
    config.write_text(
        '{"feedURL":"http://127.0.0.1:1/release.json","publicKey":"unused-here",'
        '"stateDir":"%s","machine":"recycle-fixture","token":"t","intervalMinutes":1,"apps":{}}' % state
    )
    env = dict(os.environ, KHU_NO_MENU="1", KHU_RECYCLE_TRANSFERS="2")
    log = (root / "agent.log").open("wb")
    process = subprocess.Popen([str(KHU), "agent", "--config", str(config)],
                               stdout=log, stderr=subprocess.STDOUT, env=env)
    alive_throughout = True
    for _ in range(SECONDS * 4):
        time.sleep(0.25)
        if process.poll() is not None:
            alive_throughout = False
            break
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
    log.close()
    text = (root / "agent.log").read_text(errors="replace")
    recycles = len(re.findall(r"note: starting this helper again in place", text))

    ok = True
    if not alive_throughout:
        print("FAIL: the helper exited instead of starting again in place")
        ok = False
    if recycles < MIN_RECYCLES:
        print("FAIL: %d recycles in %d s, expected at least %d" % (recycles, SECONDS, MIN_RECYCLES))
        ok = False
    if ok:
        print("PASS: %d re-execs in %d s, one pid throughout, one log line each" % (recycles, SECONDS))

    # Evidence is kept only when something failed; a passing run retires its scratch like the others.
    if ok:
        import shutil
        trash = REPO / "_trash/test-tmp"
        trash.mkdir(parents=True, exist_ok=True)
        shutil.move(str(root), str(trash / root.name))
    else:
        print("evidence kept in %s" % root)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
