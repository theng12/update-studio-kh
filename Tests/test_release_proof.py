#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("release_proof", Path(__file__).resolve().parent.parent / "packaging/release-proof.py")
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class ReleaseProofTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="khu-release-proof-"))
        self.config = self.root / "policy.json"
        self.config.write_text(json.dumps({"projects": {"kh-updater": {"path": str(self.root), "lanes": {"fast": {"paths": ["Sources"]}}}}}))
        self.log = self.root / "fast.log"
        self.log.write_bytes(b"checks passed\n")
        self.receipt = {"project": "kh-updater", "lane": "fast", "status": "pass", "exitCode": 0,
                        "key": "fixture-key", "tree": {"head": "prior-source"},
                        "startedAt": "2026-11-08T01:00:00Z", "commands": [["fixture"]],
                        "log": {"file": str(self.log), "bytes": self.log.stat().st_size,
                                "sha256": hashlib.sha256(self.log.read_bytes()).hexdigest()}}
        self.match = True

    def tearDown(self):
        trash = Path(tempfile.gettempdir()) / "_trash"
        trash.mkdir(exist_ok=True)
        shutil.move(str(self.root), str(trash / (self.root.name + "-" + uuid.uuid4().hex)))

    def check(self, command):
        if command[0] == "git":
            return "current-source\n"
        return json.dumps({"match": self.match, "receipt": self.receipt})

    def collect(self):
        return proof.collect(self.config, self.root, "2026-11-09T01:00:00Z", "testctl", self.check)

    def test_reuse_is_explicit_and_bound_to_both_sources(self):
        result = self.collect()
        row = result["checks"][0]
        self.assertEqual(row["status"], "skipped-unchanged")
        self.assertEqual(row["ranOnSource"], "prior-source")
        self.assertEqual(row["verifiedForSource"], "current-source")
        self.assertEqual(row["verificationScope"], {"authority": "shared-testctl-input-key", "paths": ["Sources"]})
        self.assertEqual(result["installedLive"], "not-checked")

    def test_fresh_execution_is_labelled_passed(self):
        self.receipt["startedAt"] = "2026-11-09T01:01:00Z"
        self.assertEqual(self.collect()["checks"][0]["status"], "passed")

    def test_stale_or_failed_receipt_is_refused(self):
        self.match = False
        with self.assertRaises(ValueError):
            self.collect()
        self.match = True
        self.receipt["exitCode"] = 1
        with self.assertRaises(ValueError):
            self.collect()

    def test_tampered_log_is_refused(self):
        self.log.write_bytes(b"different log\n")
        with self.assertRaises(ValueError):
            self.collect()

    def test_other_checkout_is_refused(self):
        self.config.write_text(json.dumps({"projects": {"kh-updater": {"path": str(self.root / "elsewhere"), "lanes": {"fast": {}}}}}))
        with self.assertRaises(ValueError):
            self.collect()

    def test_other_lane_is_refused(self):
        self.receipt["lane"] = "full"
        with self.assertRaises(ValueError):
            self.collect()


if __name__ == "__main__":
    unittest.main()
