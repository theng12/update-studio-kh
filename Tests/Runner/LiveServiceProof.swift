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
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let now = listed()
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
    print("TESTS: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
