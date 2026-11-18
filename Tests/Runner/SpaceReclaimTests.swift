import Foundation

/// Space reclaim tests: a leftover staged copy is removed; a superseded rollback copy is retired
/// into this Mac's own trash rather than deleted.
/// A FileManager that refuses to remove anything: the shape of a tree the system will not unlink.
final class StubbornRemoval: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

/// A shell that refuses the two commands `Space.remove` uses to force a removal, so a leftover
/// really does survive it. Everything else (ditto, hdiutil) is the rig's own shell.
struct NoRemovalShell: Shell {
    let inner: RecordingShell
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/bin/rm" || executable == "/bin/chmod" || executable == "/usr/bin/chflags" {
            return ShellResult(exitCode: 1, stdout: "", stderr: "operation not permitted")
        }
        return try inner.run(executable, arguments: arguments, timeout: timeout)
    }
}

/// Everything under this Mac's own trash, however deep: `Trash.move` buckets by timestamp.
func trashed(in state: URL) -> [URL] {
    let root = Trash.root(in: state)
    guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return walk.compactMap { $0 as? URL }
}

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

        // v1 no longer holds the rollback slot, and it is not deleted either: the copy it was
        // replaced by goes into this Mac's own trash, where it can be put back by hand
        // (owner, 2026-11-11: nothing deleted for good).
        expect(trashed(in: rig.state).contains { marker($0) == "1.0.0" },
               "SR2 the replaced rollback copy is kept in state/_trash, not deleted")
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

    // SR4: a rollback copy left by an earlier update never fails the next install — the case the
    // owner hit on 2026-11-17, where the move failed with NSCocoaErrorDomain 516, "an item with the
    // same name already exists", and the row read `install_failed` because of our own bookkeeping.
    do {
        let rig = RecipeRig("sr4", installedVersion: "2.0.0", dmgVersion: "3.0.0")
        // A rollback copy is already there, from a previous update that ended some other way.
        try? fm.createDirectory(at: rig.rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
        makeApp(rig.rollback, version: "1.0.0", marker: "1.0.0")
        expect(fm.fileExists(atPath: rig.rollback.path), "SR4 precondition: an old rollback copy is in the way")
        let app = FakeApp(installed: rig.installed, healthy: ["3.0.0"])
        let res = try? rig.run(app, version: "3.0.0").get()
        expect(res?.status == "updated", "SR4 an existing rollback copy does not fail the install (\(res?.status ?? "nil"))")
        expect(marker(rig.rollback) == "2.0.0", "SR4 the new fallback took the slot (\(marker(rig.rollback) ?? "nil"))")
        expect(trashed(in: rig.state).contains { marker($0) == "1.0.0" },
               "SR4 the copy that was in the way is recoverable in state/_trash")
    }
    // SR5: the row speaks a sentence, never Foundation's domain, code and path.
    do {
        let ns = NSError(domain: NSCocoaErrorDomain, code: 516, userInfo: [
            NSLocalizedDescriptionKey: "Hub Studio KH couldn't be moved to rollback-hub because an item with the same name already exists",
            "NSDestinationFilePath": "/Users/someone/Library/KHUpdater/state/rollback-hub/Hub Studio KH.app",
        ])
        let said = PlainFailure.sentence(ns, app: "hub")
        expect(!said.contains("NSCocoaErrorDomain") && !said.contains("Code=") && !said.contains("/Users/"),
               "SR5 a system failure is said without its domain, code or path (\(said))")
        expect(said.contains("same name already exists") && said.hasPrefix("hub could not be installed"),
               "SR5 the row keeps the cause and names the app (\(said))")
        let ours = PlainFailure.sentence(khuFail("the previous rollback copy was in the way, so the app was left where it was"), app: "hub")
        expect(ours.hasPrefix("hub could not be installed") && ours.contains("rollback copy was in the way"),
               "SR5 a recipe's own sentence is passed through and still names the app (\(ours))")
    }
    // SR6: a tree whose folders are 0555 is really removed. Hub ships one (1071 read-only folders,
    // 7867 read-only files), and `chflags nouchg` alone left it behind while reporting success, so
    // every retry copied into it and failed with "ditto: … Permission denied" for ever.
    do {
        let root = tmpDir("sr6-readonly")
        let bundle = root.appendingPathComponent("Studio Hub.app")
        let inner = bundle.appendingPathComponent("Contents/Resources/runtimes/music-yue2/bin")
        try! fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try! Data("payload".utf8).write(to: inner.appendingPathComponent("mx_1m"))
        // The real shape: read-only files inside read-only folders.
        try! fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: inner.appendingPathComponent("mx_1m").path)
        // The bundle's own tree is read-only; its parent is writable, exactly as /Applications is.
        for dir in [inner, inner.deletingLastPathComponent(), inner.deletingLastPathComponent().deletingLastPathComponent(),
                    bundle.appendingPathComponent("Contents/Resources"), bundle.appendingPathComponent("Contents"),
                    bundle] {
            try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        }
        expect(fm.fileExists(atPath: bundle.path), "SR6 precondition: the 0555 bundle exists")
        let freed = Space.remove(bundle, shell: SystemShell(), fileManager: fm)
        expect(!fm.fileExists(atPath: bundle.path), "SR6 a 0555 tree is removed, not left behind")
        expect(freed > 0, "SR6 the removal reports the bytes it freed (\(freed))")
    }
    // SR7: when a leftover staging copy genuinely cannot be cleared, the install refuses in one
    // sentence naming it — it never copies into the leftover and loops on ditto's stderr.
    do {
        let rig = RecipeRig("sr7-staging")
        let staged = rig.installed.deletingLastPathComponent()
            .appendingPathComponent(".\(rig.installed.lastPathComponent).khu-staging")
        makeApp(staged, version: "0.0.1", marker: "leftover")
        // A staging copy that will not go: removal is refused by the file system, and the shell
        // that would force it is the rig's recording shell, which runs nothing.
        let stubborn = StubbornRemoval()
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        // The removal must really fail: neither the file manager nor the forcing shell may clear it,
        // which is the state a 0555 tree was in before Space.remove learned to strip mode bits.
        let shell = NoRemovalShell(inner: rig.shell)
        let freed = Space.remove(staged, shell: shell, fileManager: stubborn)
        expect(freed == 0 && fm.fileExists(atPath: staged.path),
               "SR7 precondition: the leftover survives a refused removal")
        let result = Result { try Recipe.appDmg(shell: shell, installedPath: rig.installed.path, artifactPath: "/tmp/x.dmg",
                                                feedVersion: "1.2.3", expectedBundleID: nil, stateDir: rig.state.path,
                                                app: "foo", control: app.control, fileManager: stubborn) }
        guard case .failure(let error) = result else {
            let status = (try? result.get())?.status ?? "?"
            expect(false, "SR7 a leftover that cannot be cleared refuses the install (\(status))")
            return
        }
        let said = "\(error)"
        expect(said.contains("unfinished copy") && said.contains(staged.lastPathComponent),
               "SR7 the refusal names the leftover in one sentence (\(said))")
        expect(!said.contains("Permission denied") && !said.contains("ditto:"),
               "SR7 the row does not paste ditto's stderr (\(said))")
    }
}