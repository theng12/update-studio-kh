#!/usr/bin/env python3
"""Execute the actual request method with isolated queue/UI stand-ins."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

MENU = Path(__file__).resolve().parents[1] / "Sources/khu/Menu.swift"


class RequestProgressTests(unittest.TestCase):
    def test_requests_cannot_claim_transfer_ownership(self):
        source = MENU.read_text()
        start = source.index("    func request(_ app: String) {")
        end = source.index("\n    }", start) + len("\n    }")
        method = source[start:end]
        harness = '''import Foundation
func verify(_ condition: Bool, _ message: String = "queue state differs") {
    if !condition { print("FAIL: " + message); exit(1) }
}

enum DownloadControl {
    static var phase = "downloading"
    static var received = 200
    static func updateProgress(_ phase: String) {
        self.phase = phase; received = 0
    }
}
final class Pacing {
    var wakes = 0
    func wakeByPerson() { wakes += 1 }
}
final class HelperMenu {
    let lock = NSLock()
    let pacing = Pacing()
    var requested = Set<String>()
    var installingApp: String?
    let wake = DispatchSemaphore(value: 0)
    func installing(_ app: String) { installingApp = app }
METHOD
}
let helper = HelperMenu()
helper.installingApp = "app-a"
helper.request("app-b")
verify(helper.requested == ["app-b"], "the second app must be queued")
verify(helper.installingApp == "app-a", "a queued click stole another app's progress")
verify(DownloadControl.phase == "downloading" && DownloadControl.received == 200)
verify(helper.pacing.wakes == 1, "a queued click wakes the run loop")
helper.installingApp = nil
helper.request("app-c")
verify(helper.requested == ["app-b", "app-c"])
verify(helper.installingApp == nil, "a queued click claimed a pre-install mirror transfer")
verify(DownloadControl.received == 200, "a click reset unrelated transfer counters")
verify(helper.pacing.wakes == 2, "each queued click wakes the run loop without starting work")
print("PASS: queued requests preserve active ownership and do not claim preparatory transfers")
'''.replace("METHOD", method)
        work = Path(tempfile.mkdtemp(prefix="khu-request-progress-"))
        try:
            swift = work / "main.swift"
            swift.write_text(harness)
            binary = work / "queue-check"
            built = subprocess.run(["swiftc", str(swift), "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: queued requests", result.stdout)
        finally:
            trash = Path(tempfile.gettempdir()) / "_trash"
            trash.mkdir(exist_ok=True)
            work.rename(trash / (work.name + "." + uuid.uuid4().hex))


if __name__ == "__main__":
    unittest.main()
