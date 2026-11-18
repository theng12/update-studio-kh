#!/usr/bin/env python3
"""A Dock click after Close brings the Launcher window back.

Runs the product's own `applicationShouldHandleReopen` and `showWindow`, headless: the window is
placed off screen and the app is an accessory, so nothing appears on the owner's desktop and the
Dock is not touched. The one line removed from `showWindow` is `NSApp.activate`, the one step a
test must never take; the test asserts that line is there before removing it, so the rest runs as
shipped. What this cannot prove is the real Dock click itself — that needs a visible window.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
MENU = ROOT / "Sources/khu/Menu.swift"
LAUNCHER = ROOT / "Sources/khu/Launcher.swift"


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class ReopenTests(unittest.TestCase):
    def test_a_dock_click_brings_the_closed_window_back(self):
        reopen = method(MENU.read_text(), "    func applicationShouldHandleReopen(")
        show = method(LAUNCHER.read_text(), "    func showWindow() {")
        activate = "        NSApp.activate(ignoringOtherApps: true)\n"
        self.assertIn(activate, show, "showWindow must still activate as shipped")
        show = show.replace(activate, "")
        harness = '''import AppKit
func verify(_ ok: Bool, _ what: String = "reopen path differs") { if !ok { print("FAIL: " + what); exit(1) } }

final class LauncherWindow {
    let window: NSWindow
    init(helper: AnyObject) {
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
    }
    func reload() {}
}

enum LauncherBundle { static let shownNotification = Notification.Name("com.khupdater.launcher.shown") }

final class HelperMenu: NSObject, NSApplicationDelegate {
    var window: LauncherWindow?
    var rescans = 0
    let wake = DispatchSemaphore(value: 0)
    func rescanSSDs() { rescans += 1 }
    func setMenuIcon(visible: Bool) {}
SHOW
REOPEN
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = HelperMenu()
verify(helper.window == nil)
verify(helper.applicationShouldHandleReopen(app, hasVisibleWindows: false), "a reopen must be handled")
verify(helper.window != nil && helper.window!.window.isVisible, "the first reopen must leave a visible window")
let first = helper.window!
first.window.orderOut(nil)
verify(!first.window.isVisible, "the closed window must be off screen")
verify(helper.applicationShouldHandleReopen(app, hasVisibleWindows: false), "a reopen after Close must be handled")
verify(helper.window === first && first.window.isVisible, "the same window must come back")
helper.window = nil
verify(helper.applicationShouldHandleReopen(app, hasVisibleWindows: false), "a released window's reopen must be handled")
verify(helper.window != nil && helper.window!.window.isVisible, "a released window must be made again")
print("PASS: a Dock click is handled and brings the closed window back")
'''.replace("SHOW", show).replace("REOPEN", reopen)
        work = Path(tempfile.mkdtemp(prefix="khu-launcher-reopen-"))
        try:
            swift = work / "main.swift"
            swift.write_text(harness)
            binary = work / "reopen-check"
            built = subprocess.run(["swiftc", str(swift), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: a Dock click", result.stdout)
        finally:
            trash = Path(tempfile.gettempdir()) / "_trash"
            trash.mkdir(exist_ok=True)
            work.rename(trash / (work.name + "." + uuid.uuid4().hex))


if __name__ == "__main__":
    unittest.main()
