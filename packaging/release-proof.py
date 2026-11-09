#!/usr/bin/env python3
"""Collect existing shared testctl evidence. This does not run tests or define lanes."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def checked(command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout


def collect(config, repo, started_at, testctl, check=checked):
    config, repo = Path(config).resolve(), Path(repo).resolve()
    policy = json.loads(config.read_text())
    project = policy["projects"]["kh-updater"]
    if Path(project["path"]).resolve() != repo:
        raise ValueError("shared testctl policy points at a different checkout")
    started = datetime.datetime.fromisoformat(started_at.replace("Z", "+00:00"))
    if started.tzinfo is None:
        raise ValueError("release start time needs a timezone")
    head = check(["git", "-C", str(repo), "rev-parse", "HEAD"]).strip()
    rows = []
    if not project["lanes"]:
        raise ValueError("the shared policy has no Updater lanes")
    for lane in project["lanes"]:
        result = json.loads(check([str(testctl), "check", "kh-updater", lane, "--config", str(config), "--json"]))
        receipt = result.get("receipt") or {}
        if not result.get("match") or receipt.get("status") != "pass" or receipt.get("exitCode") != 0:
            raise ValueError(f"no matching passing testctl receipt: {lane}")
        if receipt.get("project") != "kh-updater" or receipt.get("lane") != lane:
            raise ValueError(f"receipt belongs to another lane: {lane}")
        log = receipt["log"]
        raw = Path(log["file"]).read_bytes()
        if len(raw) != log["bytes"] or hashlib.sha256(raw).hexdigest() != log["sha256"]:
            raise ValueError(f"testctl log changed: {lane}")
        at = datetime.datetime.fromisoformat(receipt["startedAt"].replace("Z", "+00:00"))
        if at.tzinfo is None:
            raise ValueError(f"receipt time needs a timezone: {lane}")
        rows.append({"lane": lane, "status": "passed" if at >= started else "skipped-unchanged",
                     "ranOnSource": receipt["tree"]["head"], "verifiedForSource": head,
                     "receiptKey": receipt["key"], "startedAt": receipt["startedAt"],
                     "commands": receipt["commands"], "log": log, "receipt": receipt})
    return {"schema": 1, "source": head, "releaseStartedAt": started_at,
            "sharedPolicy": str(config), "sharedPolicySHA256": hashlib.sha256(config.read_bytes()).hexdigest(),
            "checks": rows, "packagedLaunch": "not-checked", "installedLive": "not-checked"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / "Developer/portfolio/test-policy/projects.json")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--testctl", type=Path, default=Path.home() / "Developer/portfolio/bin/testctl")
    parser.add_argument("--started-at", required=True, help="UTC release gate start; older matching evidence is labelled skipped-unchanged")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    proof = collect(args.config, args.repo, args.started_at, args.testctl)
    with args.out.open("x") as output:
        json.dump(proof, output, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
