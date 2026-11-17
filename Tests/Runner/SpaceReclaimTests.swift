import Foundation

/// Space reclaim tests: staged copies and superseded rollbacks are removed, not retired into trash.
/// Each test fails against the old Trash.move behaviour (whole bundles accumulating in state/_trash).
func spaceReclaimTests() {
    // SR1: a leftover staged copy is gone after a successful install; nothing lands in state/_trash.
    do {
        let rig = RecipeRig("sr1")
        // Plant a leftover staged copy with a marker so we can prove it was removed, not moved.
        let staged = rig.installed.deletingLastPathComponent()
            .appendingPathComponent(".\(rig.installed.lastPathComponent).khu-staging")
        makeApp(staged, version: "0.0.1", marker: "leftover")
        expect(fm.fileExists(atPath: staged.path), "SR1 precondition: leftover staged exists")

        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = try? rig.run(app).get()
        expect(res?.status == "updated", "SR1 install succeeded")
        expect(!fm.fileExists(atPath: staged.path), "SR1 leftover staged removed (not in trash)")

        // Nothing of the staged copy should be in state/_trash.
        let trashRoot = Trash.root(in: rig.state)
        let trashEntries = (try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)) ?? []
        let hasLeftover = trashEntries.contains { url in
            let markerPath = url.appendingPathComponent("marker").path
            return (try? String(contentsOfFile: markerPath, encoding: .utf8)) == "leftover"
        }
        expect(!hasLeftover, "SR1 no leftover staged copy in state/_trash")
    }

    // SR2: two installs in a row (v1→v2→v3) leave exactly one rollback holding v2; v1 is gone.
    do {
        let rig = RecipeRig("sr2", installedVersion: "1.0.0", dmgVersion: "2.0.0")
        // First install: v1.0.0 → v2.0.0. Rollback should hold v1.0.0.
        let app1 = FakeApp(installed: rig.installed, healthy: ["2.0.0"])
        let res1 = try? rig.run(app1, version: "2.0.0").get()
        expect(res1?.status == "updated", "SR2 first install succeeded")
        expect(marker(rig.rollback) == "1.0.0", "SR2 rollback holds v1 after first install")

        // Second install: v2.0.0 → v3.0.0. Rollback should now hold v2.0.0; v1.0.0 must be gone.
        // Update the DMG mount to serve v3.0.0.
        makeApp(rig.mount.appendingPathComponent("Foo.app"), version: "3.0.0")
        let app2 = FakeApp(installed: rig.installed, healthy: ["3.0.0"])
        let res2 = try? rig.run(app2, version: "3.0.0").get()
        expect(res2?.status == "updated", "SR2 second install succeeded")
        expect(marker(rig.rollback) == "2.0.0", "SR2 rollback holds v2 after second install")

        // v1 must not exist anywhere: not in rollback, not in state/_trash.
        let trashRoot = Trash.root(in: rig.state)
        let trashEntries = (try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)) ?? []
        let v1Anywhere = trashEntries.contains { url in
            marker(url) == "1.0.0"
        }
        expect(!v1Anywhere, "SR2 v1 not in state/_trash")
        expect(marker(rig.rollback) != "1.0.0", "SR2 v1 not in rollback")

        // Exactly one rollback folder for this app.
        let rollbackDir = rig.state.appendingPathComponent("rollback-foo")
        let rollbackContents = (try? fm.contentsOfDirectory(at: rollbackDir, includingPropertiesForKeys: nil)) ?? []
        let appBundles = rollbackContents.filter { $0.pathExtension == "app" }
        expect(appBundles.count == 1, "SR2 exactly one rollback bundle (got \(appBundles.count))")
    }

    // SR3: a leftover staged copy with the immutable flag is still reclaimed and install succeeds.
    do {
        let rig = RecipeRig("sr3")
        let staged = rig.installed.deletingLastPathComponent()
            .appendingPathComponent(".\(rig.installed.lastPathComponent).khu-staging")
        makeApp(staged, version: "0.0.1", marker: "immutable-leftover")
        // Set the immutable flag on the marker file inside the staged copy.
        _ = try? SystemShell().run("/usr/bin/chflags", arguments: ["-R", "uchg", staged.path], timeout: 10)
        expect(fm.fileExists(atPath: staged.path), "SR3 precondition: immutable leftover staged exists")

        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = try? rig.run(app).get()
        expect(res?.status == "updated", "SR3 install succeeded despite immutable staged copy")
        expect(!fm.fileExists(atPath: staged.path), "SR3 immutable leftover staged was removed")
    }
}