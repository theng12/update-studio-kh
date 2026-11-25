#!/usr/bin/env python3
"""Static wiring checks for the Launcher's Sparkle self-update; no app build or network."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text()


class SparkleRuntimeTests(unittest.TestCase):
    def test_hold_precedes_every_sparkle_action(self):
        main = source("Sources/khu/main.swift")
        self.assertLess(main.index("try hold.start()"), main.index("kh_sparkle_start()"))
        self.assertLess(main.index("hold.waitUntilBound()"), main.index("kh_sparkle_start()"))
        self.assertLess(main.index("NSClassFromString(\"SPUUpdater\")"), main.index("kh_sparkle_start()"))
        self.assertIn("kh_sparkle_set_state_callback(sparkleStateChanged)", main)

    def test_agent_waits_for_the_hold_before_any_run(self):
        main = source("Sources/khu/main.swift")
        gate = main.index("SparkleProgress.shared.busy")
        self.assertLess(gate, main.index("Agent.runOnce(config: current"))
        self.assertIn("hold.waitForResume(limit: 30)", main)
        self.assertIn("SparkleProgress.shared.waitForIdle(limit: 30)", main)

    def test_hold_reports_busy_and_the_pause_sequence(self):
        hold = source("Sources/KHUpdaterCore/LauncherHold.swift")
        self.assertIn("\"safe\": installing.isEmpty", hold)
        self.assertIn("\"unsettled\": installing", hold)
        self.assertIn("new work paused \\(Self.pauseSeconds) s", hold)
        self.assertIn("held = \"resumed\"", hold)
        self.assertIn("public func paused(", hold)
        self.assertIn("public func waitForResume(", hold)

    def test_plist_keeps_all_four_shim_keys(self):
        bundle = source("Sources/khu/Launcher.swift")
        for key in ("KHHoldURL", "SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "KHHoldTokenFile"):
            self.assertIn(f'"{key}"', bundle)

    def test_helper_bundle_never_hosts_sparkle(self):
        helper = source("Sources/KHUStub/HelperBundle.swift")
        for forbidden in ("SUFeedURL", "SUPublicEDKey", "Sparkle.framework", "KHHoldURL"):
            self.assertNotIn(forbidden, helper)

    def test_sparkle_check_and_silent_relaunch_wired(self):
        main = source("Sources/khu/main.swift")
        launcher = source("Sources/khu/Launcher.swift")
        check = source("Sources/khu/SparkleCheck.swift")
        self.assertIn('case "sparkle-check":', main)
        self.assertIn("SparkleCheckScheduler", main)
        self.assertLess(main.index("sparkleScheduler?.running"), main.index("Agent.runOnce(config: current"))
        self.assertIn("sparkleScheduler.triggerIfDue(", main)
        self.assertLess(launcher.index("SparkleCheck.handleSilentRelaunchIfPending()"),
                        launcher.index("askHelper(seconds: 2)"))
        self.assertIn("setActivationPolicy(.prohibited)", check)
        self.assertIn("SparkleRelaunchMarker.write(", check)
        self.assertIn("SparkleRelaunchMarker.consumeIfFresh(", check)
        self.assertIn("SparkleRelaunchMarker.releaseHold(", check)

    def test_framework_stays_weak_and_signs_inside_out(self):
        build = source("build.sh")
        script = source("packaging/build-launcher.sh")
        self.assertIn("-Xlinker -weak_framework", build)
        self.assertLess(script.index("XPCServices/*.xpc"), script.index('codesign --force --sign "$IDENTITY" --timestamp=none "$FW"'))
        self.assertLess(script.index('codesign --force --sign "$IDENTITY" --timestamp=none "$FW"'),
                        script.index('codesign --force --sign "$IDENTITY" --timestamp=none "$APP"'))
        self.assertIn("codesign --verify --deep --strict", script)

    def test_install_marker_contract_is_wired(self):
        hold = source("Sources/KHUpdaterCore/LauncherHold.swift")
        main = source("Sources/khu/main.swift")
        ssd = source("Sources/khu/SSDCommand.swift")
        self.assertIn("Library/Application Support/kh-sparkle/install-in-progress", hold)
        self.assertIn("KH_SPARKLE_INSTALL_MARKER", hold)
        self.assertIn("SparkleInstallMarker.set(app)", main)
        self.assertIn("SparkleInstallMarker.set(nil)", main)
        self.assertIn('SparkleInstallMarker.set("ssd")', ssd)


if __name__ == "__main__":
    unittest.main()
