import Foundation

/// Studio Launcher KH.app is a one-shot FrontDoor bundle (hands off to the separately managed
/// Helper and exits 0 immediately). Proves LiveControl.launcher judges health on disk without
/// launching a visible window or requiring a resident process inside the bundle, un-wedges a
/// `promoted` journal with `previousVersion == nil`, and still refuses a genuinely broken bundle.
func launcherHealthTests() {
    /// `try!` in a test turns one thrown error into a SIGTRAP that kills the rest of the suite.
    /// Each call reports its own failure instead.
    func attempt<T>(_ name: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch { expect(false, "\(name) threw: \(error)"); return nil }
    }
    func makeSignedLauncher(_ url: URL, version: String, id: String = "com.khupdater.launcher",
                            executable: Bool = true) -> URL {
        _ = makeApp(url, version: version, id: id, executable: executable)
        if executable {
            // Ad-hoc sign the bundle so `codesign --verify --strict` succeeds just like a real install.
            let res = (try? SystemShell().run("/usr/bin/codesign", arguments: ["--force", "--deep", "-s", "-", url.path], timeout: 15))
            expect(res?.exitCode == 0, "the fixture bundle was ad-hoc signed (\(res?.stderr ?? "no answer"))")
        }
        return url
    }

    // LH1: Signed, non-running Launcher bundle is healthy; launch() never invokes `open`.
    do {
        let dir = tmpDir("lh1")
        let app = makeSignedLauncher(dir.appendingPathComponent("Studio Launcher KH.app"), version: "0.1.83")
        let shell = RecordingShell(mount: dir)
        let ctl = LiveControl.launcher(app.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents"))
        expect(ctl.staysRunning == false, "LH1 staysRunning is false for one-shot Launcher")
        expect(ctl.isRunning() == false, "LH1 bundle is not running")
        ctl.launch()
        expect(!shell.calls.contains { $0.contains("/usr/bin/open") },
               "LH1 launch() never calls open (calls=\(shell.calls))")
        expect(ctl.healthy("0.1.83") == true, "LH1 signed 0.1.83 bundle is healthy even while not running")
        expect(ctl.healthRequirement("0.1.83") == nil, "LH1 healthy bundle has nil healthRequirement")
    }

    // LH2: Genuinely unhealthy Launcher bundles are refused with exact diagnostic reasons.
    do {
        let dir = tmpDir("lh2")
        let app = makeSignedLauncher(dir.appendingPathComponent("Studio Launcher KH.app"), version: "0.1.83")
        let shell = RecordingShell(mount: dir)
        let ctl = LiveControl.launcher(app.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents"))

        expect(ctl.healthy("0.1.84") == false, "LH2 wrong version is not healthy")
        expect(ctl.healthRequirement("0.1.84")?.contains("0.1.83") == true,
               "LH2 version mismatch names disk version (\(ctl.healthRequirement("0.1.84") ?? "nil"))")

        // Tamper a sealed file inside the signed bundle -> codesign must reject it.
        _ = try? "tampered".write(to: app.appendingPathComponent("Contents/MacOS/Foo"), atomically: true, encoding: .utf8)
        expect(ctl.healthy("0.1.83") == false, "LH2 tampered bundle fails signature check")
        expect(ctl.healthRequirement("0.1.83")?.contains("signature") == true,
               "LH2 tampered bundle names signature failure (\(ctl.healthRequirement("0.1.83") ?? "nil"))")

        // Missing executable -> fails runnable check before signature.
        let noExe = makeApp(dir.appendingPathComponent("MissingExe.app"), version: "0.1.83",
                            id: "com.khupdater.launcher", executable: false)
        let ctlNoExe = LiveControl.launcher(noExe.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents"))
        expect(ctlNoExe.healthy("0.1.83") == false, "LH2 missing executable is not healthy")
        expect(ctlNoExe.healthRequirement("0.1.83")?.contains("executable") == true,
               "LH2 missing executable names executable (\(ctlNoExe.healthRequirement("0.1.83") ?? "nil"))")
    }

    // LH3: Exact live wedge recovery — promoted 0.1.83 journal with previousVersion == nil clears cleanly.
    do {
        let dir = tmpDir("lh3")
        let stateDir = dir.appendingPathComponent("state")
        _ = try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let app = makeSignedLauncher(dir.appendingPathComponent("Studio Launcher KH.app"), version: "0.1.83")
        let journal = InstallJournal(phase: "promoted", installed: app.path,
                                     staged: dir.appendingPathComponent(".Studio Launcher KH.app.khu-staging").path,
                                     rollback: stateDir.appendingPathComponent("rollback-launcher/Studio Launcher KH.app").path,
                                     previousVersion: nil, wasRunning: false, testInstance: false,
                                     relaunchAfterwards: true, version: "0.1.83")
        let journalURL = Recipe.journalURL(stateDir: stateDir.path, app: "launcher")
        expect((try? AtomicFile.writeJSON(journal, to: journalURL)) != nil, "LH3 the journal fixture was written")

        let shell = RecordingShell(mount: dir)
        let ctl = LiveControl.launcher(app.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents"))
        guard let note = attempt("LH3 recovery", { try Recipe.recover(installedPath: app.path, stateDir: stateDir.path, app: "launcher", control: ctl) }) else { return }
        expect(!Recipe.isUnresolved(stateDir: stateDir.path, app: "launcher"),
               "LH3 recovery clears the wedged promoted journal (note=\(note))")
        expect(note.contains("healthy") && !note.contains("not healthy"),
               "LH3 recovery note reports healthy (\(note))")
        expect(!shell.calls.contains { $0.contains("/usr/bin/open") },
               "LH3 recovery never calls open")
    }

    // LH4: Recovery on a genuinely broken/tampered bundle with previousVersion == nil keeps the journal.
    do {
        let dir = tmpDir("lh4")
        let stateDir = dir.appendingPathComponent("state")
        _ = try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let app = makeSignedLauncher(dir.appendingPathComponent("Studio Launcher KH.app"), version: "0.1.83")
        _ = try? "corrupt".write(to: app.appendingPathComponent("Contents/MacOS/Foo"), atomically: true, encoding: .utf8)
        let journal = InstallJournal(phase: "promoted", installed: app.path,
                                     staged: dir.appendingPathComponent(".Studio Launcher KH.app.khu-staging").path,
                                     rollback: stateDir.appendingPathComponent("rollback-launcher/Studio Launcher KH.app").path,
                                     previousVersion: nil, wasRunning: false, testInstance: false,
                                     relaunchAfterwards: true, version: "0.1.83")
        expect((try? AtomicFile.writeJSON(journal, to: Recipe.journalURL(stateDir: stateDir.path, app: "launcher"))) != nil, "LH4 the journal fixture was written")

        let shell = RecordingShell(mount: dir)
        var ctl = LiveControl.launcher(app.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents"))
        ctl.healthTimeout = 0.2
        ctl.pollInterval = 0.05
        guard let note = attempt("LH3 recovery", { try Recipe.recover(installedPath: app.path, stateDir: stateDir.path, app: "launcher", control: ctl) }) else { return }
        expect(Recipe.isUnresolved(stateDir: stateDir.path, app: "launcher"),
               "LH4 broken Launcher bundle keeps the journal instead of falsely clearing it")
        expect(note.contains("not healthy"), "LH4 note reports unhealthy (\(note))")
    }

    // LH5: Agent.liveControl routes launcher (by app id or bundleID) to LiveControl.launcher.
    do {
        let dir = tmpDir("lh5")
        let shell = RecordingShell(mount: dir)
        let byApp = Agent.liveControl(app: "launcher",
                                      AppConfig(bundlePath: dir.appendingPathComponent("Studio Launcher KH.app").path,
                                                recipe: "app-dmg", automatic: true, bundleID: nil),
                                      shell: shell)
        expect(byApp.staysRunning == false, "LH5 app=='launcher' selects LiveControl.launcher")

        let byBundleID = Agent.liveControl(app: "other",
                                           AppConfig(bundlePath: dir.appendingPathComponent("Studio Launcher KH.app").path,
                                                     recipe: "app-dmg", automatic: true, bundleID: "com.khupdater.launcher"),
                                           shell: shell)
        expect(byBundleID.staysRunning == false, "LH5 bundleID=='com.khupdater.launcher' selects LiveControl.launcher")

        let regular = Agent.liveControl(app: "hub",
                                        AppConfig(bundlePath: dir.appendingPathComponent("Hub Studio KH.app").path,
                                                  recipe: "app-dmg", automatic: true, bundleID: "local.studiohub.standalone"),
                                        shell: shell)
        expect(regular.staysRunning == true, "LH5 regular app-dmg keeps staysRunning==true")
    }

    // LH6: First install (previousVersion == nil) and relaunchIfClosed both settle cleanly with LiveControl.launcher.
    do {
        let dir = tmpDir("lh6")
        let stateDir = dir.appendingPathComponent("state")
        _ = try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // A fixture bundle id, never com.khupdater.launcher: promoteAndSettle retires duplicate
        // bundles by id across /Applications, and a test must never move the owner's app.
        let installed = dir.appendingPathComponent("Studio Launcher KH.app")
        let paths = Recipe.Paths(installedPath: installed.path, stateDir: stateDir.path, app: "launcher")
        _ = makeSignedLauncher(paths.staged, version: "0.1.84", id: "com.example.launcher-fixture")

        let shell = RecordingShell(mount: dir)
        let ctl = LiveControl.launcher(installed.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents"))
        guard let res = attempt("LH6 promoteAndSettle", {
            try Recipe.promoteAndSettle(paths: paths, targetVersion: "0.1.84", installedInfo: nil,
                                        order: nil, control: ctl, fileManager: fm, notes: [],
                                        relaunchAfterInstall: true, relaunchIfClosed: true)
        }) else { return }
        expect(res.status == "updated", "LH6 first install of Launcher settles as updated (got \(res.status): \(res.reason ?? ""))")
        expect(!Recipe.isUnresolved(stateDir: stateDir.path, app: "launcher"),
               "LH6 journal is cleared after Launcher promoteAndSettle")
        expect(!shell.calls.contains { $0.contains("/usr/bin/open") },
               "LH6 promoteAndSettle never calls open on Launcher")
    }
}
