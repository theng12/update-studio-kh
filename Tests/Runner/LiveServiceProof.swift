import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A real launchd round-trip for the helper lifecycle, isolated to a temp bundle and a temp job
/// plist: no job is written to the owner's LaunchAgents and no other job is touched. Run only via
/// `KHU_SERVICE_PROOF=1 ./build/khu-tests`; it is not part of the suite.
func runLiveServiceProof() -> Never {
    let root = tmpDir("live-service-proof")
    let app = makeApp(root.appendingPathComponent("Proof.app"), version: "1.0.0", id: "com.khproof.proof")
    let helper = app.appendingPathComponent("Contents/Resources/Helper")
    try! fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! fm.copyItem(atPath: "/bin/sleep", toPath: helper.path)
    _ = try? SystemShell().run("/usr/bin/codesign", arguments: ["-f", "-s", "-", helper.path], timeout: 10)
    let label = "com.khproof.updaterproof.\(getpid())"
    let plist = root.appendingPathComponent("\(label).plist")
    let job: [String: Any] = ["Label": label, "RunAtLoad": true, "KeepAlive": true,
                              "ProgramArguments": [helper.path, "30"]]
    try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
    let shell = SystemShell()
    let domain = "gui/\(getuid())"
    func launchctl(_ arguments: [String]) -> ShellResult? {
        try? shell.run("/bin/launchctl", arguments: arguments, timeout: 20)
    }
    func listed() -> (loaded: Bool, running: Bool) {
        guard let out = launchctl(["list"])?.stdout else { return (false, false) }
        for line in out.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 3, String(fields[2]) == label {
                return (true, (pid_t(fields[0]) ?? 0) > 1)
            }
        }
        return (false, false)
    }
    func waitListed(running: Bool, seconds: Double) -> Bool {
        waitListed(label: label, running: running, seconds: seconds)
    }
    /// The same wait for any label this proof owns.
    func waitListed(label: String, running: Bool, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var now = (loaded: false, running: false)
            if let out = launchctl(["list"])?.stdout {
                for line in out.split(separator: "\n") {
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    if fields.count == 3, String(fields[2]) == label {
                        now = (true, (pid_t(fields[0]) ?? 0) > 1)
                    }
                }
            }
            if now.loaded && (now.running || !running) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
    defer {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        _ = try? fm.removeItem(at: root)
    }
    _ = launchctl(["bootout", "\(domain)/\(label)"])   // a previous interrupted run leaves nothing

    expect(launchctl(["bootstrap", domain, plist.path])?.exitCode == 0 && waitListed(running: true, seconds: 15),
           "LP1 a real keep-alive helper job is loaded and running")
    let control = LiveControl.appDmg(app.path, shell: shell, agentsDirectory: root, quitWait: 20)
    expect(control.isRunning() == true, "LP1 the running job is seen inside the bundle")
    expect(control.quit(), "LP2 the app's own helper is not the app: quit returns while it runs")
    expect(control.stopService() && !listed().loaded && !listed().running,
           "LP3 a real launchctl bootout stops the unconditional job")
    let resumed = control.resumeServices()
    expect(resumed.ok && waitListed(running: true, seconds: 15),
           "LP4 resumeServices bootstraps the job back and launchd really runs it (\(resumed.reason ?? "ok"))")

    // Recovery: the job is unloaded again, and a journal that says it was running must bring it back.
    _ = launchctl(["bootout", "\(domain)/\(label)"])
    let state = root.appendingPathComponent("state").path
    var journal = InstallJournal(phase: "promoted", installed: app.path, staged: "", rollback: root.appendingPathComponent("rollback").path,
                                 previousVersion: nil, wasRunning: false)
    journal.testInstance = false
    journal.relaunchAfterwards = false
    journal.version = "1.0.0"
    journal.serviceLabels = [label]
    try! AtomicFile.writeJSON(journal, to: Recipe.journalURL(stateDir: state, app: "proof"))
    let note = (try? Recipe.recover(installedPath: app.path, stateDir: state, app: "proof", control: control)) ?? ""
    expect(!note.isEmpty && !fm.fileExists(atPath: Recipe.journalURL(stateDir: state, app: "proof").path)
           && waitListed(running: true, seconds: 15),
           "LP5 recovery puts an unloaded job back from the journal and clears it (\(note))")

    _ = launchctl(["bootout", "\(domain)/\(label)"])

    // LP6 a swapped binary on a job that is NOT unconditional KeepAlive. The new build's CDHash
    // differs, and launchd's cached code requirement then refuses the spawn however valid the file
    // is ("needs LWCR update", OS_REASON_CODESIGNING; macmini-angkor, 2026-11-19). Only bootout then
    // bootstrap from the plist clears it; kickstart -k re-spawns against the same stale requirement.
    do {
        let label2 = "com.khproof.reload.\(getpid())"
        let program = root.appendingPathComponent("swapped-helper")
        func sign(_ identifier: String) {
            try? fm.removeItem(at: program)
            try! fm.copyItem(atPath: "/bin/sleep", toPath: program.path)
            _ = try? shell.run("/usr/bin/codesign", arguments: ["-f", "-s", "-", "--identifier", identifier, program.path], timeout: 10)
        }
        func cdhash() -> String {
            // codesign prints its details on stderr, and the `-d` run exits non-zero.
            guard let answer = try? shell.run("/usr/bin/codesign", arguments: ["-dvvv", program.path], timeout: 10) else { return "unknown" }
            return (answer.stdout + "\n" + answer.stderr).split(separator: "\n")
                .first { $0.hasPrefix("CDHash=") }.map { String($0.dropFirst(7)) } ?? "unknown"
        }
        sign("khproof.one")
        let before = cdhash()
        let plist2 = root.appendingPathComponent("\(label2).plist")
        let job2: [String: Any] = ["Label": label2, "RunAtLoad": true,
                                   "KeepAlive": ["SuccessfulExit": false],
                                   "ProgramArguments": [program.path, "60"]]
        try! PropertyListSerialization.data(fromPropertyList: job2, format: .xml, options: 0).write(to: plist2)
        func listed2() -> (loaded: Bool, pid: pid_t) {
            guard let out = launchctl(["list"])?.stdout else { return (false, 0) }
            for line in out.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                if fields.count == 3, String(fields[2]) == label2 { return (true, pid_t(fields[0]) ?? 0) }
            }
            return (false, 0)
        }
        func printHasLwcr() -> Bool {
            ((launchctl(["print", "\(domain)/\(label2)"])?.stdout ?? "") + (launchctl(["print", "\(domain)/\(label2)"])?.stderr ?? ""))
                .lowercased().contains("needs lwcr update")
        }
        defer { _ = launchctl(["bootout", "\(domain)/\(label2)"]) }
        _ = launchctl(["bootout", "\(domain)/\(label2)"])
        expect(launchctl(["bootstrap", domain, plist2.path])?.exitCode == 0 && waitListed(label: label2, running: true, seconds: 15),
               "LP6 a real restart-on-failure job is loaded and running")
        // Swap the program under the loaded job: a different identifier gives a different CDHash.
        sign("khproof.two")
        let after = cdhash()
        expect(before != "unknown" && after != "unknown" && before != after,
               "LP6 the swapped binary really is a different build (\(before) → \(after))")
        _ = launchctl(["kickstart", "-k", "\(domain)/\(label2)"])
        Thread.sleep(forTimeInterval: 1.5)
        let afterKickstart = listed2()
        print("LP6 kickstart -k left pid \(afterKickstart.pid), needs LWCR update: \(printHasLwcr())")
        // The reload the installer now performs: bootout, then bootstrap from the plist.
        _ = launchctl(["bootout", "\(domain)/\(label2)"])
        expect(launchctl(["bootstrap", domain, plist2.path])?.exitCode == 0,
               "LP6 the job bootstraps again after the swap")
        expect(waitListed(label: label2, running: true, seconds: 15),
               "LP6 launchd starts the swapped binary and shows a pid, with nobody touching the machine")
        expect(!printHasLwcr(),
               "LP6 the reloaded job carries no 'needs LWCR update', so the next spawn is not refused")
    }

    print("TESTS: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
