#!/usr/bin/env python3
"""Exercise only the post-acceptance caller with stand-in DMGs; no native app runs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get("KHU_RELEASE_DIST_TOOL", str(Path.home() / "Developer/Shared Tools/portfolio/tools/release-dist.py")))


class ReleaseDistHook(unittest.TestCase):
    def test_shared_helper_keeps_both_app_pairs_and_reports_refusal(self):
        fixture = Path(tempfile.mkdtemp(prefix="updater-dist-hook-", dir=os.environ.get("TMPDIR")))
        project = fixture / "canonical project"
        project.mkdir()
        apps = []
        expected = {}
        for app, versions in [("Update Studio KH", ["1.0.17", "1.0.15"]),
                              ("Studio Launcher KH", ["0.1.14", "0.1.12"])]:
            releases = []
            for version in versions:
                data = f"stand-in {app} {version}".encode()
                source = fixture / f"hash prefix {app}-{version}.dmg"
                source.write_bytes(data)
                releases.append(dict(version=version, source=str(source),
                                     sha256=hashlib.sha256(data).hexdigest(), bytes=len(data),
                                     evidence="fixture installed acceptance"))
                expected[f"{app}-{version}.dmg"] = data
            apps.append(dict(app=app, project=str(project), releases=releases))
        pins = fixture / "accepted pins.json"
        document = dict(schema=1, apps=apps)
        pins.write_text(json.dumps(document))
        env = dict(os.environ, KHU_RELEASE_DIST_TOOL=str(TOOL))
        command = ["sh", str(ROOT / "packaging/retain-release.sh"), str(pins)]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(json.loads(result.stdout)), {app["app"] for app in apps})
        self.assertEqual({p.name: p.read_bytes() for p in (project / "dist").glob("*.dmg")}, expected)
        # A rejected pin must propagate failure and leave both accepted pairs intact.
        document["apps"][0]["releases"][0]["sha256"] = "0" * 64
        pins.write_text(json.dumps(document))
        refused = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in (project / "dist").glob("*.dmg")}, expected)
        print(f"Retained fixture: {fixture}")


if __name__ == "__main__":
    unittest.main()
