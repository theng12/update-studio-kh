import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

// Regression tests for KH Updater. Every finding of the 2026-10-24 reliability review (R1–R35)
// and security review (S1–S11) has at least one check here, named by its finding number, written
// so the old code fails it. Nothing touches /Applications, launchd or a real app.

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}
func expectThrows(_ name: String, contains: String? = nil, _ block: () throws -> Void) {
    do { try block(); failed += 1; print("FAIL \(name) (no throw)") }
    catch {
        if let contains, !"\(error)".contains(contains) { failed += 1; print("FAIL \(name) (threw: \(error))") }
        else { passed += 1; print("PASS \(name)") }
    }
}

let fm = FileManager.default
func tmpDir(_ tag: String) -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("khu-test-\(tag)-\(UUID().uuidString.prefix(8))")
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal app bundle: Info.plist and an executable shell script.
@discardableResult
func makeApp(_ url: URL, version: String, id: String = "com.example.foo", executable: Bool = true, marker: String? = nil) -> URL {
    let contents = url.appendingPathComponent("Contents")
    try! fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": id, "CFBundleExecutable": "Foo"]
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    if executable {
        let exe = contents.appendingPathComponent("MacOS/Foo")
        try! "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        chmod(exe.path, 0o755)
    }
    try! (marker ?? version).write(to: url.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    return url
}
/// Put a copy of /bin/sleep in the bundle as its executable and start it: a real process whose
/// executable path is inside the bundle (a shell script would show up as /bin/sh).
func startInBundle(_ app: URL) -> Process {
    let exe = app.appendingPathComponent("Contents/MacOS/Foo")
    _ = try? Trash.move(exe, into: Trash.root(in: app.deletingLastPathComponent()))
    try! fm.copyItem(atPath: "/bin/sleep", toPath: exe.path)
    // Ad-hoc sign the copied executable to prevent the kernel from killing it with
    // SIGKILL (Code Signature Invalid), which triggers ReportCrash and the "quit unexpectedly" dialog.
    let savedMarker = app.deletingLastPathComponent().appendingPathComponent("marker-" + UUID().uuidString)
    try! fm.moveItem(at: app.appendingPathComponent("marker"), to: savedMarker)
    let signing = try! SystemShell().run("/usr/bin/codesign", arguments: ["-f", "-s", "-", exe.path], timeout: 10)
    try! fm.moveItem(at: savedMarker, to: app.appendingPathComponent("marker"))
    precondition(signing.exitCode == 0, "fixture signing failed: \(signing.stderr)")
    let p = Process(); p.executableURL = exe; p.arguments = ["30"]
    try! p.run()
    Thread.sleep(forTimeInterval: 0.3)
    return p
}
func marker(_ app: URL) -> String { (try? String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)) ?? "none" }

/// hdiutil is faked (the "mount" is a folder the test prepares); everything else really runs,
/// so `ditto` really copies.
final class RecordingShell: Shell, @unchecked Sendable {
    let mount: URL
    var calls: [String] = []
    var dittoExit: Int32? = nil      // force a non-zero ditto
    var dittoThrows = false
    let lock = NSLock()
    init(mount: URL) { self.mount = mount }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        lock.lock(); calls.append(([executable] + arguments).joined(separator: " ")); lock.unlock()
        // Regression guard: tests must never launch anything through LaunchServices or `open`.
        // Any test path that reaches it without an injected launcher must fail here, not on the owner's desktop.
        if executable == "/usr/bin/open" || executable == "/usr/bin/osascript" {
            throw khuFail("REGRESSION: desktop helper \(executable) was invoked during tests; inject a fake instead.")
        }
        if executable == "/usr/bin/hdiutil" {
            if arguments.first == "attach" {
                let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": mount.path]]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        if executable == "/usr/bin/ditto" {
            if dittoThrows { throw khuFail("timeout running /usr/bin/ditto") }
            if let code = dittoExit {
                // A copy that leaves nothing behind: the completeness check refuses it whatever
                // the exit code says.
                if arguments.count > 1 { _ = try? FileManager.default.removeItem(atPath: arguments[1]) }
                return ShellResult(exitCode: code, stdout: "", stderr: "ditto: copy stopped")
            }
        }
        return try SystemShell().run(executable, arguments: arguments, timeout: timeout)
    }
    var detaches: Int { calls.filter { $0.hasPrefix("/usr/bin/hdiutil detach") }.count }
}

/// A fake app: running state, scripted quit/stop answers and a health rule by version.
final class FakeApp: @unchecked Sendable {
    var events: [String] = []
    var running: Bool
    var quits: [Bool]
    var stops: [Bool]
    var healthyVersions: Set<String>
    var testInstance = false
    var healthTimeout: TimeInterval = 0.3
    /// Virtual seconds between a launch and the process appearing; nil means at once.
    var appearsAfter: TimeInterval?
    /// When set, only this installed version goes through `appearsAfter`: a rolled-back previous
    /// version comes up at once, so a "never started" case can still restore and settle.
    var appearsOnlyFor: String?
    var clock: () -> TimeInterval = Mono.now
    /// What a failed health check is missing, when a test sets it.
    var healthRequirement: ((String) -> String?)?
    private var launchedAt: TimeInterval?
    let installed: URL
    init(installed: URL, running: Bool = true, quits: [Bool] = [true], stops: [Bool] = [true], healthy: Set<String>) {
        self.installed = installed; self.running = running; self.quits = quits; self.stops = stops; self.healthyVersions = healthy
    }
    /// The process is there only once its own start has taken `appearsAfter` virtual seconds.
    private var up: Bool {
        if let only = appearsOnlyFor {
            let onDisk = (try? BundleInfo.read(installed.path))?.version
            if onDisk != only { return true }
        }
        if let delay = appearsAfter, let at = launchedAt { return clock() >= at + delay }
        return running
    }
    var control: AppControl {
        AppControl(
            isRunning: { self.up },
            quit: { self.events.append("quit"); let ok = self.quits.count > 1 ? self.quits.removeFirst() : self.quits[0]; if ok { self.running = false; self.launchedAt = nil }; return ok },
            launch: { self.events.append("launch"); self.launchedAt = self.clock(); self.running = self.appearsAfter == nil },
            stopService: { self.events.append("stop"); return self.stops.count > 1 ? self.stops.removeFirst() : self.stops[0] },
            healthy: { expected in
                let onDisk = (try? BundleInfo.read(self.installed.path))?.version
                return self.up && onDisk == expected && self.healthyVersions.contains(expected)
            },
            healthRequirement: self.healthRequirement ?? { _ in nil },
            healthTimeout: self.healthTimeout, pollInterval: 0.05,
            isTestInstance: { self.testInstance })
    }
}

/// Records shell commands without running them, for the launch path.
final class LaunchShell: Shell, @unchecked Sendable {
    var calls: [String] = []
    /// What the signature check and `open` answer; both succeed unless a test says otherwise.
    var codesignExit: Int32 = 0
    var openExit: Int32 = 0
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        calls.append(([executable] + arguments).joined(separator: " "))
        switch executable {
        case "/usr/bin/codesign":
            return ShellResult(exitCode: codesignExit, stdout: "", stderr: codesignExit == 0 ? "" : "code object is not signed at all")
        case "/usr/bin/open":
            return ShellResult(exitCode: openExit, stdout: "", stderr: openExit == 0 ? "" : "The application cannot be opened.")
        default:
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
    var opens: Int { calls.filter { $0.hasPrefix("/usr/bin/open") }.count }
}

/// Fails every request: a no-op install must never reach the network.
final class NoNetworkHTTP: HTTPClient, @unchecked Sendable {
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { throw URLError(.cannotConnectToHost) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw URLError(.cannotConnectToHost) }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { throw URLError(.cannotConnectToHost) }
}

struct RecipeRig {
    let root: URL, apps: URL, installed: URL, mount: URL, state: URL
    let shell: RecordingShell
    init(_ tag: String, installedVersion: String? = "1.0.0", dmgVersion: String = "1.2.3", dmgID: String = "com.example.foo",
         extraDMGApp: Bool = false, dmgExecutable: Bool = true) {
        root = tmpDir(tag)
        apps = root.appendingPathComponent("Applications"); installed = apps.appendingPathComponent("Foo.app")
        try! fm.createDirectory(at: apps, withIntermediateDirectories: true)
        if let installedVersion { makeApp(installed, version: installedVersion) }
        mount = root.appendingPathComponent("Volumes/X")
        makeApp(mount.appendingPathComponent("Foo.app"), version: dmgVersion, id: dmgID, executable: dmgExecutable)
        if extraDMGApp { makeApp(mount.appendingPathComponent("Other.app"), version: dmgVersion) }
        state = root.appendingPathComponent("state")
        shell = RecordingShell(mount: mount)
    }
    func run(_ app: FakeApp, expectedID: String? = nil, relaunchAfterInstall: Bool = true,
             version: String = "1.2.3", fileManager: FileManager = .default,
             clock: @escaping () -> TimeInterval = Mono.now,
             appearCeiling: TimeInterval = Recipe.appearCeiling) -> Result<RecipeResult, Error> {
        Result { try Recipe.appDmg(shell: shell, installedPath: installed.path, artifactPath: "/tmp/x.dmg", feedVersion: version,
                                   expectedBundleID: expectedID, stateDir: state.path, app: "foo", control: app.control,
                                   relaunchAfterInstall: relaunchAfterInstall, appearCeiling: appearCeiling,
                                   fileManager: fileManager, clock: clock) }
    }
    var rollback: URL { state.appendingPathComponent("rollback-foo/Foo.app") }
    var journal: URL { state.appendingPathComponent("install-foo.json") }
}

/// A FileManager that fails one chosen move, to prove recovery paths.
final class FailingMoves: FileManager, @unchecked Sendable {
    var failWhen: (String, String) -> Bool = { _, _ in false }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failWhen(srcURL.path, dstURL.path) { throw khuFail("injected move failure") }
        try super.moveItem(at: srcURL, to: dstURL)
    }
    override func moveItem(atPath srcPath: String, toPath dstPath: String) throws {
        if failWhen(srcPath, dstPath) { throw khuFail("injected move failure") }
        try super.moveItem(atPath: srcPath, toPath: dstPath)
    }
}

func recipeTests() {
    // Happy path: staged before stop, quit → stop → launch, previous kept, journal cleared.
    do {
        let rig = RecipeRig("ok")
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = try? rig.run(app).get()
        expect(res?.status == "updated", "install updates")
        expect(app.events == ["quit", "stop", "launch"], "install order quit, stop, launch (got \(app.events))")
        expect(marker(rig.installed) == "1.2.3" && marker(rig.rollback) == "1.0.0", "previous bundle kept as rollback")
        expect(!fm.fileExists(atPath: rig.journal.path), "journal cleared after a finished install")
        expect(rig.shell.detaches >= 1, "R22 DMG detached after staging")
        expect(rig.shell.calls.filter { $0.hasPrefix("/usr/bin/hdiutil detach") }.allSatisfy { $0.hasSuffix(" /dev/disk9s1") },
               "DMG cleanup uses the attached device ID, never a volume path")
    }
    // A test/hidden instance is replaced but never relaunched into the owner's profile (2026-11-13).
    do {
        let rig = RecipeRig("testinstance")
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        app.testInstance = true
        let res = try? rig.run(app).get()
        expect(res?.status == "updated" && app.events == ["quit", "stop"],
               "a test instance is replaced and left stopped (events \(app.events))")
        expect(res?.reason?.contains("test instance") == true, "the report says a test instance was left stopped")
        expect(marker(rig.installed) == "1.2.3", "the test-instance install still promoted the new version")
    }
    // A launchd launch with a fixed flag is the owner's app, not a test run (2026-11-17): the
    // Gateway starts as `--background` and every install used to read that as a test instance and
    // leave it stopped. Only an explicit test flag or its own data location makes a test run.
    do {
        expect(!LiveControl.isTestLaunch(["/Applications/gateway-kh.app/Contents/MacOS/Gateway Studio KH", "--background"]),
               "a launchd flag alone is not a test instance")
        expect(!LiveControl.isTestLaunch(["/Applications/X.app/Contents/MacOS/X"]), "a bare launch is not a test instance")
        expect(!LiveControl.isTestLaunch(["/Applications/X.app/Contents/MacOS/X", "-psn_0_12345"]),
               "a system-supplied process serial number is not a test instance")
        expect(LiveControl.isTestLaunch(["/x/X", "--test-mode"]), "an explicit test flag is a test instance")
        expect(LiveControl.isTestLaunch(["/x/X", "--data-dir", "/tmp/run-1"]), "its own data directory is a test instance")
        expect(LiveControl.isTestLaunch(["/x/X", "--user-data-dir=/tmp/run-1"]),
               "an own-data-directory flag with a value is a test instance")
        expect(LiveControl.isTestLaunch(["/x/X", "--data-dir", "./tmp/run-1"]),
               "a relative data directory is a test instance")
        expect(LiveControl.isTestLaunch(["/x/X", "--data-dir", "~/run-1"]), "a home-relative data directory is a test instance")
        expect(LiveControl.isTestLaunch(["/x/X", "./tmp/run-1"]), "a relative positional path is a test instance")
    }
    // A Gateway-class restart longer than the health ceiling is not a rollback (2026-11-17): the
    // health clock starts when the new process appears, not when the quit began. 0.1.50 measured
    // 127 s quit-to-healthy against a 120 s window and rolled a same-version reinstall back.
    do {
        let rig = RecipeRig("slowstart")
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        app.healthTimeout = 120
        app.appearsAfter = 127
        var now: TimeInterval = 0
        let clock = { now += 5; return now }
        app.clock = clock
        // The per-app setting carries it: the Gateway is allowed longer than the default to appear.
        let res = try? rig.run(app, clock: clock, appearCeiling: 180).get()
        expect(res?.status == "updated", "a 127 s start is not rolled back (got \(res?.status ?? "nil"))")
        expect(app.events.contains("launch"), "the slow app was relaunched")
        expect(res?.reason?.contains("timings:") == true && res?.reason?.contains("appeared") == true,
               "the result carries the step timings (\(res?.reason ?? "nil"))")
    }
    // A process that never appears is its own failure, not a health-check rollback (2026-11-17):
    // its own status, the ceiling it used in the words, the previous bundle put back, and the
    // timings say the process never appeared.
    do {
        let rig = RecipeRig("neverappears")
        let app = FakeApp(installed: rig.installed, healthy: ["1.0.0"])
        app.healthTimeout = 5
        app.appearsAfter = 100_000
        app.appearsOnlyFor = "1.2.3"   // the new version never appears; the restored one does
        var now: TimeInterval = 0
        let clock = { now += 5; return now }
        app.clock = clock
        let res = try? rig.run(app, clock: clock).get()
        expect(res?.status == "did_not_start", "a process that never appears has its own status (got \(res?.status ?? "nil"))")
        expect(marker(rig.installed) == "1.0.0", "the previous bundle is restored when the new one never started")
        expect(res?.reason?.contains("did not start within 120 s") == true,
               "the reason names the ceiling it used (\(res?.reason ?? "nil"))")
        expect(res?.reason?.contains("did-not-appear") == true, "the timings say the process never appeared")
    }
    // A caller that asks for no relaunch leaves the app closed; the agent itself always relaunches.
    do {
        let rig = RecipeRig("norelaunch")
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = try? rig.run(app, relaunchAfterInstall: false).get()
        expect(res?.status == "updated" && app.events == ["quit", "stop"],
               "a no-relaunch caller leaves the app closed (events \(app.events))")
        expect(res?.reason?.contains("left closed") == true,
               "the report says the app was left closed")
        expect(marker(rig.installed) == "1.2.3", "the no-relaunch install still promoted the new version")
    }
    // A stale report must not reinstall a version already on disk (Media, 2026-11-13).
    do {
        let root = tmpDir("live-version")
        let bundle = makeApp(root.appendingPathComponent("Foo.app"), version: "1.2.3")
        let cfg = AgentConfig(feedURL: "", publicKey: "", stateDir: root.appendingPathComponent("state").path,
                              machine: "m", token: "",
                              apps: ["foo": AppConfig(bundlePath: bundle.path, bundleID: "com.example.foo")])
        let entry = FeedApp(version: "1.2.3", file: "x.dmg", sha256: String(repeating: "a", count: 64), bytes: 1, kind: "app-dmg")
        let feed = Feed(published_at: ISO.string(Date()), apps: ["foo": entry])
        let result = try? Agent.install(app: "foo", feed: feed, installed: "1.0.0", config: cfg,
                                        serverBase: URL(string: "http://127.0.0.1:1")!, stateDir: root,
                                        http: NoNetworkHTTP(), shell: LaunchShell(),
                                        control: { _, _ in AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true }) })
        expect(result?.status == "current" && result?.reason?.contains("already installed") == true,
               "a stale report does not reinstall an equal version already on disk")
    }
    // The relaunch asks LaunchServices for a hidden background launch, never a visible window.
    do {
        let dir = tmpDir("launch-hidden")
        let app = dir.appendingPathComponent("Foo.app")
        makeApp(app, version: "1.0.0")
        let shell = LaunchShell()
        LiveControl.appDmg(app.path, shell: shell, agentsDirectory: dir.appendingPathComponent("agents")).launch()
        expect(shell.calls.contains { $0.hasPrefix("/usr/bin/open -g -j ") },
               "the relaunch is hidden and background (calls \(shell.calls))")
    }
    // The test-instance signal reads a real process's own argv.
    do {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 20", "khu-test-marker"]
        try? p.run()
        let details = LiveControl.launchDetails(p.processIdentifier)
        expect(details?.argv.contains("khu-test-marker") == true, "a process's own argv is readable")
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
    }
    // R24 / S-pre: a DMG holding another app (right version) is refused before anything stops.
    do {
        let rig = RecipeRig("wrongid", dmgID: "com.evil.other")
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = rig.run(app)
        expect((try? res.get()) == nil && app.events.isEmpty && marker(rig.installed) == "1.0.0",
               "R24 a DMG with another bundle id is refused before quitting")
        let rig2 = RecipeRig("noexe", dmgExecutable: false)
        let app2 = FakeApp(installed: rig2.installed, healthy: ["1.2.3"])
        expect((try? rig2.run(app2).get()) == nil && app2.events.isEmpty, "R24 a DMG app with no executable is refused before quitting")
        let rig3 = RecipeRig("twoapps", extraDMGApp: true)
        let app3 = FakeApp(installed: rig3.installed, healthy: ["1.2.3"])
        expect((try? rig3.run(app3).get()) == nil && app3.events.isEmpty && rig3.shell.detaches >= 1,
               "R22 a refused DMG is still detached")
    }
    // DMG version mismatch refused before touching the app.
    do {
        let rig = RecipeRig("mismatch", dmgVersion: "9.9.9")
        let app = FakeApp(installed: rig.installed, healthy: ["9.9.9"])
        expect((try? rig.run(app).get()) == nil && app.events.isEmpty && marker(rig.installed) == "1.0.0", "version mismatch refused before quit")
    }
    // S6 / R2: ditto failing or throwing happens BEFORE anything stops now — nothing changed.
    do {
        let rig = RecipeRig("dittothrow")
        rig.shell.dittoThrows = true
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        expect((try? rig.run(app).get()) == nil && app.events.isEmpty && marker(rig.installed) == "1.0.0",
               "S6 a throwing copy leaves the installed app untouched and running")
        let rig2 = RecipeRig("dittofail")
        rig2.shell.dittoExit = 1
        let app2 = FakeApp(installed: rig2.installed, healthy: ["1.2.3"])
        expect((try? rig2.run(app2).get()) == nil && app2.events.isEmpty && marker(rig2.installed) == "1.0.0",
               "R2 a failed copy changes nothing")
    }
    // Refusals keep the old app.
    do {
        let rig = RecipeRig("noquit")
        let app = FakeApp(installed: rig.installed, quits: [false], healthy: ["1.2.3"])
        expect((try? rig.run(app).get()) == nil && app.events == ["quit"] && marker(rig.installed) == "1.0.0", "app won't quit -> nothing replaced")
        let rig2 = RecipeRig("nostop")
        let app2 = FakeApp(installed: rig2.installed, stops: [false], healthy: ["1.2.3"])
        expect((try? rig2.run(app2).get()) == nil && app2.events == ["quit", "stop", "launch"] && marker(rig2.installed) == "1.0.0",
               "service won't stop -> old app relaunched, nothing replaced")
        expect(!fm.fileExists(atPath: rig2.journal.path), "a refused install leaves no journal")
    }
    // R2: a throw after stopping (promotion fails) restores the previous app and relaunches it.
    do {
        let rig = RecipeRig("promotefail")
        let failing = FailingMoves()
        failing.failWhen = { src, _ in src.hasSuffix(".Foo.app.khu-staging") }
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = rig.run(app, fileManager: failing)
        expect((try? res.get()) == nil, "R2 promotion failure is reported")
        expect(marker(rig.installed) == "1.0.0" && app.events.last == "launch" && app.running,
               "R2 after a throw past the stop, the previous app is back and running")
        if case .failure(let error) = res { expect("\(error)".contains("previous app was put back"), "R2 the message says what was restored") }
    }
    // R4: restoring that fails is reported as such, never as "put back".
    do {
        let rig = RecipeRig("restorefail")
        let failing = FailingMoves()
        failing.failWhen = { src, dst in src.hasSuffix(".Foo.app.khu-staging") || (src.contains("rollback-foo") && dst.hasSuffix("Applications/Foo.app")) }
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        let res = rig.run(app, fileManager: failing)
        if case .failure(let error) = res {
            expect("\(error)".contains("NO APP IS INSTALLED") && !"\(error)".contains("was put back"), "R4 a failed restore is reported loudly")
        } else { expect(false, "R4 a failed restore is reported loudly") }
        expect(fm.fileExists(atPath: rig.rollback.path), "R4 the previous bundle is still where the message says")
    }
    // R17: rollback health checks the PREVIOUS version, not the rejected one.
    do {
        let rig = RecipeRig("rollback")
        let app = FakeApp(installed: rig.installed, healthy: ["1.0.0"])
        let res = try? rig.run(app).get()
        expect(res?.status == "rolled_back", "R17 unhealthy new version -> rolled_back (got \(res?.status ?? "error"))")
        expect(marker(rig.installed) == "1.0.0", "R17 the previous bundle is restored")
        expect(res?.reason?.contains("not healthy within") == true && res?.reason?.contains("timings:") == true,
               "R17 the result says why it rolled back and carries the timings (\(res?.reason ?? "nil"))")
    }
    // R6: an unhealthy version that refuses to stop blocks the rollback and keeps both bundles.
    do {
        let rig = RecipeRig("blocked")
        let app = FakeApp(installed: rig.installed, quits: [true, false], healthy: [])
        let res = try? rig.run(app).get()
        expect(res?.status == "rollback_blocked", "R6 a rollback needs the bad version stopped (got \(res?.status ?? "error"))")
        expect(marker(rig.installed) == "1.2.3" && marker(rig.rollback) == "1.0.0", "R6 both bundles are kept")
    }
    // R30: an app that was not running is installed and left stopped.
    do {
        let rig = RecipeRig("stopped")
        let app = FakeApp(installed: rig.installed, running: false, healthy: ["1.2.3"])
        let res = try? rig.run(app).get()
        expect(res?.status == "updated" && !app.events.contains("launch") && !app.running,
               "R30 an app that was stopped stays stopped (events \(app.events))")
    }
    // R29: with nothing installed, an existing rollback bundle is kept as the fallback.
    do {
        let rig = RecipeRig("missing", installedVersion: nil)
        makeApp(rig.rollback, version: "1.0.0")
        let app = FakeApp(installed: rig.installed, running: true, healthy: ["1.0.0"])
        let res = try? rig.run(app).get()
        expect(res?.status == "rolled_back" && marker(rig.installed) == "1.0.0",
               "R29 the kept rollback is restored when the new install is unhealthy (got \(res?.status ?? "error"))")
    }
    // R1: a run killed mid-install is finished or undone by the next run.
    do {
        let rig = RecipeRig("interrupted")
        // State a SIGKILL between "installed → rollback" and "staged → installed" leaves behind.
        makeApp(rig.rollback, version: "1.0.0")
        try! fm.moveItem(at: rig.installed, to: rig.root.appendingPathComponent("gone.app"))
        let staged = rig.apps.appendingPathComponent(".Foo.app.khu-staging")
        makeApp(staged, version: "1.2.3")
        try! AtomicFile.writeJSON(InstallJournal(phase: "moving", installed: rig.installed.path, staged: staged.path,
                                                 rollback: rig.rollback.path, previousVersion: "1.0.0", wasRunning: true), to: rig.journal)
        let app = FakeApp(installed: rig.installed, running: false, healthy: ["1.0.0"])
        let note = try? Recipe.recover(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo", control: app.control)
        expect(marker(rig.installed) == "1.0.0" && !fm.fileExists(atPath: staged.path) && !fm.fileExists(atPath: rig.journal.path),
               "R1 an interrupted install is undone: previous back, staging and journal cleared")
        expect(app.running && (note ?? "").contains("put back"), "R1 and the app is started again (\(note ?? "nil"))")
        // Killed after promotion: the new bundle stays.
        let rig2 = RecipeRig("interrupted2")
        try! fm.createDirectory(at: rig2.rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! fm.moveItem(at: rig2.installed, to: rig2.rollback)
        makeApp(rig2.installed, version: "1.2.3")
        try! AtomicFile.writeJSON(InstallJournal(phase: "promoted", installed: rig2.installed.path, staged: "", rollback: rig2.rollback.path,
                                                 previousVersion: "1.0.0", wasRunning: false, version: "1.2.3"), to: rig2.journal)
        let app2 = FakeApp(installed: rig2.installed, running: false, healthy: [])
        _ = try? Recipe.recover(installedPath: rig2.installed.path, stateDir: rig2.state.path, app: "foo", control: app2.control)
        expect(marker(rig2.installed) == "1.2.3" && !app2.running, "R1 a finished promotion is kept, a stopped app stays stopped")
    }
}

func supportTests() {
    // The agent's log file rotates at a cap, keeping a fixed number of older copies, because a log
    // that silently stops being written hid a working agent for hours (2026-11-13, 1301).
    do {
        let dir = tmpDir("log-rotate")
        let log = dir.appendingPathComponent("agent.log")
        try! Data(repeating: 65, count: 64).write(to: log)
        try! Data("one".utf8).write(to: log.appendingPathExtension("1"))
        LogFile.rotateIfNeeded(log, maxBytes: 32, keep: 3)
        let live = (try? Data(contentsOf: log))?.count
        let first = (try? Data(contentsOf: log.appendingPathExtension("1")))?.count
        let second = (try? String(contentsOf: log.appendingPathExtension("2")))
        expect(live == 0 && first == 64 && second == "one",
               "SUP1 the log rotates at its cap: the live file restarts empty and older copies shift")
        let small = dir.appendingPathComponent("small.log")
        try! Data("keep".utf8).write(to: small)
        LogFile.rotateIfNeeded(small, maxBytes: 32, keep: 3)
        expect((try? String(contentsOf: small)) == "keep", "SUP1 a log under the cap is left alone")
    }
    // S9: a private key never exists with wider permissions than asked for.
    do {
        let dir = tmpDir("key")
        let old = umask(0)
        defer { umask(old) }
        let key = dir.appendingPathComponent("private.key")
        try? Signing.savePrivateKey(Signing.generateKeyPair().privateKey, to: key)
        let mode = ((try? fm.attributesOfItem(atPath: key.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        expect(mode == 0o600, "S9 private key is 0600 even with umask 0 (got \(String(mode, radix: 8)))")
    }
    // R21 / S11: a helper that floods stdout finishes; one that ignores SIGTERM is killed and reaped.
    do {
        let start = Mono.now()
        let big = try? SystemShell().run("/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero"], timeout: 20)
        expect(big?.stdout.utf8.count == 3_000_000 && Mono.now() - start < 15, "R21 a helper filling its pipe does not deadlock")
        let dir = tmpDir("shell")
        let pidFile = dir.appendingPathComponent("pid")
        let late = dir.appendingPathComponent("late")
        let shell = SystemShell(killGrace: 1)
        let t0 = Mono.now()
        do {
            _ = try shell.run("/bin/sh", arguments: ["-c", "echo $$ > \(pidFile.path); trap '' TERM; sleep 3; touch \(late.path)"], timeout: 0.5)
            expect(false, "S11 timeout throws")
        } catch { expect("\(error)".contains("timeout"), "S11 timeout throws") }
        let pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        Thread.sleep(forTimeInterval: 3.5)
        expect(pid > 0 && kill(pid, 0) != 0 && !fm.fileExists(atPath: late.path) && Mono.now() - t0 < 10,
               "S11 a TERM-ignoring helper is killed and reaped, and writes nothing after")
    }
    // S12: a helper that runs commands all day must give every descriptor back. Two pipes per
    // command leaked until the 256-descriptor limit, and the next install failed with EMFILE.
    do {
        let shell = SystemShell()
        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        _ = try? shell.run("/bin/echo", arguments: ["warm"], timeout: 10)
        let before = openDescriptors()
        for _ in 0..<12 { _ = try? shell.run("/bin/echo", arguments: ["x"], timeout: 10) }
        let after = openDescriptors()
        expect(before > 0 && after <= before + 2, "S12 repeated commands do not leak descriptors (\(before) -> \(after))")
    }
    // R35: versions are dotted numbers only.
    expect(VersionCompare.parse("1.0.0-beta") == nil && !VersionCompare.isNewer("1.0.1-beta", than: "1.0.0")
           && VersionCompare.compare("1.0.0-beta", "1.0.0") == nil, "R35 a prerelease is not silently compared as a release")
    expect(VersionCompare.isNewer("1.4.355", than: "1.4.99") && VersionCompare.compare("0.2.197", "0.2.197") == 0, "versions compare numerically")
    // R34: optional config fields really are optional.
    let minimal = #"{"feedURL":"http://x/release.json","publicKey":"k","stateDir":"/tmp/s","machine":"m","token":"t","apps":{"g":{"bundlePath":"/A/G.app"}}}"#
    let cfg = try? JSONDecoder().decode(AgentConfig.self, from: Data(minimal.utf8))
    expect(cfg?.intervalMinutes == 5 && cfg?.once == false && cfg?.apps["g"]?.recipe == "app-dmg", "R34 a minimal config decodes with defaults")
    // S1: a bundle id that could close a quote is refused; quit passes the id as an argument.
    do {
        let dir = tmpDir("inject")
        let evil = makeApp(dir.appendingPathComponent("Evil.app"), version: "1.0", id: #"com.x" & (do shell script "touch /tmp/pwn") & ""#)
        expectThrows("S1 a bundle id with script characters is refused", contains: "bundle identifier") { _ = try BundleInfo.read(evil.path) }
        let fine = makeApp(dir.appendingPathComponent("Fine.app"), version: "1.0", id: "com.example.fine")
        let child = startInBundle(fine)
        let rec = RecordingShell(mount: dir)
        _ = LiveControl.quit(fine.path, shell: FakeQuitShell(record: rec), wait: 0.5)
        let script = rec.calls.first { $0.hasPrefix("/usr/bin/osascript") } ?? ""
        expect(script.contains("item 1 of argv") && script.hasSuffix(" com.example.fine") && !script.contains("id \"com"),
               "S1 osascript gets the bundle id as argv, never spliced into the script")
        // R23: a bundle path with regex characters is matched literally (pgrep -f could not).
        expect(LiveControl.isRunning(fine.path) == true, "R23 a running process is found by its real path")
        child.terminate(); child.waitUntilExit()
        let brackets = makeApp(dir.appendingPathComponent("Foo [1].app"), version: "1.0")
        let p2 = startInBundle(brackets)
        expect(LiveControl.isRunning(brackets.path) == true, "R23 a bundle path with [brackets] is matched literally")
        expect(LiveControl.isRunning(dir.appendingPathComponent("Foo 1.app").path) == false, "R23 and a near-miss path is not")
        p2.terminate(); p2.waitUntilExit()
    }
    // Docs: R31 the install steps create LaunchAgents before writing into it.
    let install = (try? String(contentsOfFile: "docs/INSTALL.md", encoding: .utf8)) ?? ""
    let mkdirs = install.split(separator: "\n").filter { $0.contains("mkdir -p") }
    expect(mkdirs.count >= 2 && mkdirs.allSatisfy { $0.contains("~/Library/LaunchAgents") },
           "R31 every INSTALL mkdir creates ~/Library/LaunchAgents before a plist is written there")
}

/// Records osascript instead of running it; process checks run for real.
struct FakeQuitShell: Shell {
    let record: RecordingShell
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        record.lock.lock(); record.calls.append(([executable] + arguments).joined(separator: " ")); record.lock.unlock()
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

// MARK: - The Gateway's stop/health identity (R5, S3)

/// A one-route HTTP server answering /health with a chosen pid.
final class HealthServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    var pid: Int32
    init(pid: Int32) {
        self.pid = pid
        let srv = FeedServer(feedDir: URL(fileURLWithPath: "/nonexistent"), stateDir: URL(fileURLWithPath: "/nonexistent"), bind: "127.0.0.1", port: 0)
        fd = try! srv.listen()
        port = FeedServer.boundPort(fd)
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                _ = HTTP.readRequest(from: c, deadline: 2)
                HTTP.send(c, HTTPResponse(200, "application/json", #"{"status":"ok","pid":\#(self.pid)}"#))
                close(c)
            }
        }
    }
}

func gatewayIdentityTests() {
    let dir = tmpDir("gateway")
    let bundle = makeApp(dir.appendingPathComponent("gateway-kh.app"), version: "0.2.197", id: "com.example.gateway")
    // An unrelated process, and a server that names it as the Gateway.
    let victim = Process(); victim.executableURL = URL(fileURLWithPath: "/bin/sleep"); victim.arguments = ["30"]
    try? victim.run()
    let server = HealthServer(pid: victim.processIdentifier)
    let control = LiveControl.gateway(bundle.path, shell: FakeQuitShell(record: RecordingShell(mount: dir)), port: server.port)
    expect(control.stopService() == false, "S3/R5 a /health pid outside the Gateway bundle is never signalled, and the install stops")
    expect(victim.isRunning, "S3 the unrelated process is still alive")
    expect(control.healthy("0.2.197") == false, "R5 a server that is not this Gateway never counts as healthy")
    victim.terminate(); victim.waitUntilExit()
    // The real one: a process running from inside the bundle is the health pid, but the port
    // is owned by the test process, not the bundle's process. The listener check correctly
    // refuses to signal a pid that doesn't own the port.
    let own = startInBundle(bundle)
    defer { if own.isRunning { own.terminate() }; own.waitUntilExit() }
    server.pid = own.processIdentifier
    let stopped = control.stopService()
    expect(own.isRunning, "R5 a pid that doesn't own the port is not signalled")
    expect(stopped == false, "R5 and the install stops (the port still answers)")
}

// MARK: - Stub (R7–R12, S2, S8)

func makeVersion(_ layout: StubLayout, _ version: String, script: String) {
    let binary = try! layout.binary(for: version)
    try! fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! ("#!/bin/sh\n" + script + "\n").write(to: binary, atomically: true, encoding: .utf8)
    chmod(binary.path, 0o755)
}

/// PR1–PR3: the version tree keeps two and says what it did with the rest (owner, 2026-11-17).
func stubPruneTests() {
    // PR1: three installs in a row leave the running version and the one before it.
    do {
        let layout = StubLayout(base: tmpDir("prune-three"))
        let switcher = StubSwitcher(layout: layout)
        let trash = tmpDir("prune-three-trash")
        for version in ["1.0.0", "2.0.0", "3.0.0"] {
            makeVersion(layout, version, script: "exit 0")
            _ = try? switcher.install(version: version)
            _ = try? layout.pruneVersions(trashRoot: trash, running: { _ in false })
        }
        let left = (try? fm.contentsOfDirectory(atPath: layout.versionsDirectory.path).sorted()) ?? []
        expect(left == ["2.0.0", "3.0.0"], "PR1 three installs in a row leave two versions (\(left))")
        let manifest = (try? String(contentsOf: trash.appendingPathComponent("MANIFEST.txt"), encoding: .utf8)) ?? ""
        expect(manifest.contains("1.0.0") && manifest.contains("→"),
               "PR1 what moved is written in the trash manifest with where it went")
    }
    // PR2: a version something is running from is never moved, and the run says it was skipped.
    do {
        let layout = StubLayout(base: tmpDir("prune-running"))
        let switcher = StubSwitcher(layout: layout)
        for version in ["1.0.0", "2.0.0", "3.0.0"] {
            makeVersion(layout, version, script: "exit 0"); _ = try? switcher.install(version: version)
        }
        makeVersion(layout, "0.9.0", script: "exit 0")
        let trash = tmpDir("prune-running-trash")
        let outcome = (try? layout.pruneVersions(trashRoot: trash, running: { $0.lastPathComponent == "0.9.0" })) ?? StubPrune()
        let left = (try? fm.contentsOfDirectory(atPath: layout.versionsDirectory.path).sorted()) ?? []
        expect(left.contains("0.9.0") && outcome.skipped.contains { $0.hasPrefix("0.9.0") }
               && !left.contains("1.0.0") && outcome.moved["1.0.0"] != nil,
               "PR2 an in-use version stays with a reason while the rest moves (\(left), \(outcome.skipped))")
    }
    // PR3: with no recorded fallback nothing moves and the run says why.
    do {
        let layout = StubLayout(base: tmpDir("prune-nofallback"))
        makeVersion(layout, "1.0.0", script: "exit 0"); makeVersion(layout, "0.9.0", script: "exit 0")
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "1.0.0")).path)
        let outcome = (try? layout.pruneVersions(trashRoot: tmpDir("prune-nofallback-trash"), running: { _ in false })) ?? StubPrune()
        let left = (try? fm.contentsOfDirectory(atPath: layout.versionsDirectory.path).sorted()) ?? []
        expect(outcome.note != nil && left == ["0.9.0", "1.0.0"],
               "PR3 no previous version means nothing moves and the reason is given (\(outcome.note ?? "nil"))")
    }
}

func stubTests() {
    // S8 / R7: installing the running version again is a no-op that keeps the real fallback.
    do {
        let layout = StubLayout(base: tmpDir("stub-same"))
        makeVersion(layout, "1.0.0", script: "exit 0"); makeVersion(layout, "2.0.0", script: "exit 0")
        let sw = StubSwitcher(layout: layout)
        _ = try? sw.install(version: "1.0.0"); _ = try? sw.install(version: "2.0.0")
        let again = try? sw.install(version: "2.0.0")
        expect(again == false && layout.previousBinary().map(StubLayout.version) == "1.0.0"
               && layout.currentBinary().map(StubLayout.version) == "2.0.0", "S8 the same version twice keeps previous = 1.0.0")
        // R8: links switch by rename; the superseded link is kept in _trash.
        let trashLinks = (fm.enumerator(atPath: layout.trash.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix("current") }
        expect(!trashLinks.isEmpty, "R8 the old link is kept in _trash")
    }
    // R10: a dangling previous is no fallback; a missing current falls back to previous.
    do {
        let layout = StubLayout(base: tmpDir("stub-missing"))
        makeVersion(layout, "1.0.0", script: "exit 0")
        try! fm.createSymbolicLink(atPath: layout.previousLink.path, withDestinationPath: layout.base.appendingPathComponent("versions/9.9.9/khu").path)
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "1.0.0")).path)
        expect((try? StubSwitcher(layout: layout).switchBack()) == .some(nil), "R10 a dangling previous is refused, current unchanged")
        let layout2 = StubLayout(base: tmpDir("stub-nocurrent"))
        makeVersion(layout2, "1.0.0", script: "exit 0")
        try! fm.createSymbolicLink(atPath: layout2.previousLink.path, withDestinationPath: (try! layout2.binary(for: "1.0.0")).path)
        let code = StubRunner(layout: layout2, childArguments: [], pollInterval: 0.05, restartDelay: 0.05).run()
        expect(code == 0 && layout2.currentBinary().map(StubLayout.version) == "1.0.0", "R10 a missing current falls back to previous and runs it")
    }
    // V1: `current` decides what runs; the recorded target is only the fallback, and a switcher
    // keeps both in agreement (owner, 2026-11-12: the helper stayed on 0.1.21 while current was 0.1.23).
    do {
        let layout = StubLayout(base: tmpDir("stub-current-wins"))
        let seen = layout.base.appendingPathComponent("seen")
        makeVersion(layout, "1.0.0", script: "echo old >> \(seen.path); exit 0")
        makeVersion(layout, "2.0.0", script: "echo new >> \(seen.path); exit 0")
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "2.0.0")).path)
        try! AtomicFile.writeJSON(StubState(switched_at: nil, target: (try! layout.binary(for: "1.0.0")).path), to: layout.stateFile)
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.05, restartDelay: 0.05).run()
        let ran = (try? String(contentsOf: seen, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        expect(code == 0 && ran == ["new"], "V1 current wins when it disagrees with the recorded target (ran \(ran))")
    }
    do {
        let layout = StubLayout(base: tmpDir("stub-target-fallback"))
        let marker = layout.base.appendingPathComponent("ran-target")
        makeVersion(layout, "1.0.0", script: "echo ran >> \(marker.path); exit 0")
        // No current and no previous: only the recorded target can run.
        try! AtomicFile.writeJSON(StubState(switched_at: nil, target: (try! layout.binary(for: "1.0.0")).path), to: layout.stateFile)
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.05, restartDelay: 0.05).run()
        let ran = (try? String(contentsOf: marker, encoding: .utf8))?.contains("ran") ?? false
        expect(code == 0 && ran && layout.currentBinary() == nil,
               "V1 a missing current runs the recorded target instead of giving up")
    }
    do {
        let layout = StubLayout(base: tmpDir("stub-state-target"))
        makeVersion(layout, "1.0.0", script: "exit 0"); makeVersion(layout, "2.0.0", script: "exit 0")
        let sw = StubSwitcher(layout: layout)
        _ = try? sw.install(version: "1.0.0")
        _ = try? sw.install(version: "2.0.0", at: Date(timeIntervalSince1970: 1_900_000_000))
        let installed = StubState.load(from: layout.stateFile)
        expect(installed.target == (try! layout.binary(for: "2.0.0")).standardizedFileURL.path && installed.switched_at != nil,
               "V1 a switch records stub-state target together with current")
        _ = try? sw.switchBack(at: Date(timeIntervalSince1970: 1_900_000_100))
        let rolled = StubState.load(from: layout.stateFile)
        expect(rolled.target == (try! layout.binary(for: "1.0.0")).standardizedFileURL.path,
               "V1 a rollback records stub-state target too")
    }
    do {
        let layout = StubLayout(base: tmpDir("stub-current-moves"))
        let seen = layout.base.appendingPathComponent("seen")
        makeVersion(layout, "1.0.0", script: "echo old >> \(seen.path); sleep 5")
        makeVersion(layout, "2.0.0", script: "echo new >> \(seen.path); exit 0")
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "1.0.0")).path)
        let target = (try! layout.binary(for: "2.0.0")).path
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let fresh = layout.base.appendingPathComponent(".current.tmp")
            try? fm.removeItem(at: fresh)
            try? fm.createSymbolicLink(atPath: fresh.path, withDestinationPath: target)
            rename(fresh.path, layout.currentLink.path)
        }
        let t0 = Mono.now()
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.05, restartDelay: 0.05,
                              policy: StubPolicy(crashWindow: 30, crashLimit: 3, heartbeatGrace: 30)).run()
        let ran = (try? String(contentsOf: seen, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        expect(code == 0 && ran == ["old", "new"] && Mono.now() - t0 < 4,
               "V1 a running stub follows current when the link moves (ran \(ran), \(Int(Mono.now() - t0)) s)")
    }
    do {
        let layout = StubLayout(base: tmpDir("stub-bundle"))
        makeVersion(layout, "1.0.0", script: "exit 0"); makeVersion(layout, "2.0.0", script: "exit 0")
        let sw = StubSwitcher(layout: layout)
        _ = try? sw.install(version: "1.0.0")
        let helper = (try! layout.helperBundle(for: "1.0.0")).appendingPathComponent("Contents/MacOS/Studio Launcher KH Helper")
        expect(fm.isExecutableFile(atPath: helper.path), "V1 every promoted version carries its helper bundle")
        makeVersion(layout, "3.0.0", script: "exit 0")
        try! Data("not a bundle".utf8).write(to: try! layout.helperBundle(for: "3.0.0"))
        expectThrows("V1 a switch refuses a version whose helper bundle cannot run", contains: "helper bundle") {
            _ = try sw.install(version: "3.0.0")
        }
        expect(layout.currentBinary().map(StubLayout.version) == "1.0.0", "V1 the refused version left current unchanged")
    }
    // R9 / S2: a new target gets its own probation, however long ago the last switch was.
    do {
        let layout = StubLayout(base: tmpDir("stub-probation"))
        let counter = layout.base.appendingPathComponent("starts-2")
        makeVersion(layout, "1.0.0", script: "exit 0")
        makeVersion(layout, "2.0.0", script: "echo x >> \(counter.path); exit 1")
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "1.0.0")).path)
        _ = try? StubSwitcher(layout: layout).install(version: "2.0.0")
        // A settled switch an hour ago, to the OLD target, with an old heartbeat.
        let hourAgo = ISO.string(Date().addingTimeInterval(-3600))
        try! AtomicFile.writeJSON(StubState(switched_at: nil, target: (try! layout.binary(for: "1.0.0")).path, heartbeat_at: hourAgo), to: layout.stateFile)
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.05, restartDelay: 0.05,
                              policy: StubPolicy(crashWindow: 30, crashLimit: 3, heartbeatGrace: 30)).run()
        let starts = (try? String(contentsOf: counter, encoding: .utf8))?.split(separator: "\n").count ?? 0
        expect(code == 0 && starts == 3 && layout.currentBinary().map(StubLayout.version) == "1.0.0",
               "R9/S2 a crashing new version is rolled back after 3 exits (starts \(starts), code \(code))")
    }
    // R11: a heartbeat with the wrong nonce does not vouch for the child; the right one does.
    do {
        let layout = StubLayout(base: tmpDir("stub-nonce"))
        let hb = layout.heartbeatFile.path
        makeVersion(layout, "1.0.0", script: "exit 0")
        makeVersion(layout, "2.0.0", script: #"echo "{\"at\":\"$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)\",\"pid\":$$,\"nonce\":\"stale\"}" > \#(hb); sleep 30"#)
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "1.0.0")).path)
        _ = try? StubSwitcher(layout: layout).install(version: "2.0.0")
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.1, restartDelay: 0.05,
                              policy: StubPolicy(crashWindow: 30, crashLimit: 3, heartbeatGrace: 1)).run()
        expect(code == 0 && layout.currentBinary().map(StubLayout.version) == "1.0.0", "R11 a foreign heartbeat does not prevent the rollback")

        let layout2 = StubLayout(base: tmpDir("stub-beat"))
        let hb2 = layout2.heartbeatFile.path
        makeVersion(layout2, "1.0.0", script: "exit 0")
        makeVersion(layout2, "2.0.0", script: #"echo "{\"at\":\"$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)\",\"pid\":$$,\"nonce\":\"$KHU_HEARTBEAT_NONCE\"}" > \#(hb2); sleep 2; exit 0"#)
        try! fm.createSymbolicLink(atPath: layout2.currentLink.path, withDestinationPath: (try! layout2.binary(for: "1.0.0")).path)
        _ = try? StubSwitcher(layout: layout2).install(version: "2.0.0")
        let code2 = StubRunner(layout: layout2, childArguments: [], pollInterval: 0.1, restartDelay: 0.05,
                               policy: StubPolicy(crashWindow: 1, crashLimit: 3, heartbeatGrace: 1)).run()
        let settled = (try? JSONDecoder().decode(StubState.self, from: Data(contentsOf: layout2.stateFile)))?.switched_at == nil
        expect(code2 == 0 && layout2.currentBinary().map(StubLayout.version) == "2.0.0" && settled,
               "R11 this child's own heartbeat keeps it, and the switch settles")
    }
    // R12: with no previous version, a silent child is not killed for nothing.
    do {
        let layout = StubLayout(base: tmpDir("stub-first"))
        makeVersion(layout, "1.0.0", script: "sleep 1.5; exit 0")
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: (try! layout.binary(for: "1.0.0")).path)
        let t0 = Mono.now()
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.1, restartDelay: 0.05,
                              policy: StubPolicy(crashWindow: 30, crashLimit: 3, heartbeatGrace: 0.2)).run()
        expect(code == 0 && Mono.now() - t0 >= 1.4, "R12 a first install with no fallback keeps running instead of being killed")
    }
}

// MARK: - Publisher, feed and server (R13–R16, R19, R20, R25–R27, R32, R33, S4, S5, S10)

struct Rig {
    let root: URL, feed: URL, state: URL, key: URL
    let pair: Signing.KeyPair
    init(_ tag: String) {
        root = tmpDir(tag); feed = root.appendingPathComponent("feed"); state = root.appendingPathComponent("state")
        try! fm.createDirectory(at: feed, withIntermediateDirectories: true)
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        pair = Signing.generateKeyPair()
        key = root.appendingPathComponent("private.key")
        try! Signing.savePrivateKey(pair.privateKey, to: key)
    }
    func artifact(_ name: String, _ text: String) -> URL {
        let dir = root.appendingPathComponent("src-\(UUID().uuidString.prefix(6))")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name); try! text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    func publish(_ app: String, _ version: String, _ artifact: URL, kind: String = "fake-for-tests", hold: String? = nil) throws {
        try FeedPublisher.publish(feedDir: feed, keyFile: key, app: app, version: version, artifact: artifact, kind: kind, allowSame: false, meta: nil, holdURL: hold)
    }
    var server: FeedServer { FeedServer(feedDir: feed, stateDir: state, bind: "127.0.0.1", port: 8790, commandKey: pair.privateKey) }
}

func publisherTests() {
    // R26: two apps with the same file name never overwrite each other.
    do {
        let rig = Rig("pub-same")
        try? rig.publish("a", "1.0.0", rig.artifact("app.dmg", "AAAA"))
        try? rig.publish("b", "1.0.0", rig.artifact("app.dmg", "BBBB"))
        let feed = try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey)
        let ok = ["a", "b"].allSatisfy { app in
            guard let entry = feed?.apps[app] else { return false }
            return (try? Signing.sha256Hex(fileAt: rig.feed.appendingPathComponent("artifacts/\(entry.file)")).hex) == entry.sha256
        }
        expect(ok && feed?.apps["a"]?.file != feed?.apps["b"]?.file, "R26 same basename for two apps: both artifacts still match their hashes")
        expectThrows("publish refuses a non-newer version", contains: "refused") { try rig.publish("a", "1.0.0", rig.artifact("app.dmg", "CCCC")) }
        expectThrows("R35 publish refuses a non-numeric version", contains: "dotted numeric") { try rig.publish("a", "2.0.0-beta", rig.artifact("app.dmg", "D")) }
    }
    // S10 / R26: a tampered or corrupt release is never re-signed.
    do {
        let rig = Rig("pub-tamper")
        try? rig.publish("one", "1.0.0", rig.artifact("one.dmg", "1111"))
        let file = FeedPublisher.releaseFile(in: rig.feed)
        var release = try! JSONDecoder().decode(Release.self, from: Data(contentsOf: file))
        var feed = try! JSONDecoder().decode(Feed.self, from: release.feedData!)
        feed.apps["one"]?.sha256 = String(repeating: "e", count: 64)
        release.feed = JSON.encode(feed).base64EncodedString()
        try! JSONEncoder().encode(release).write(to: file)
        expectThrows("S10 publishing over a feed that does not verify is refused", contains: "does not verify") {
            try rig.publish("two", "1.0.0", rig.artifact("two.dmg", "2222"))
        }
        try! Data("{not json".utf8).write(to: file)
        expectThrows("R26 a corrupt release is an error, not an empty feed") { try rig.publish("two", "1.0.0", rig.artifact("two.dmg", "2222")) }
    }
    // R25: feed validation and the high-water mark.
    do {
        let bad = Feed(published_at: "not a date", apps: [:])
        expectThrows("R25 an invalid published_at is refused") { _ = try bad.validated() }
        expectThrows("R25 an unknown schema is refused") { _ = try Feed(schema: 2, published_at: ISO.string(Date())).validated() }
    }
    // The Launcher app is its own feed entry; the `updater` entry is the helper binary and never
    // borrows an app's identity or icon.
    do {
        let rig = Rig("pub-launcher")
        let launcher = AppMeta(name: "Studio Launcher KH", bundleID: "com.khupdater.launcher",
                               bundleName: "Studio Launcher KH.app", version: "0.1.29", iconPNG: Data("png".utf8))
        // Simulate a feed written by the old flow: the helper entry inherited the Launcher's identity.
        try FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "updater", version: "0.1.29",
                                  artifact: rig.artifact("khu-29", "helper 29"), kind: "app-dmg", allowSame: false, meta: { _ in launcher })
        try FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "updater", version: "0.1.30",
                                  artifact: rig.artifact("khu-30", "helper 30"), kind: "updater", allowSame: false, meta: nil)
        try FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "launcher", version: "0.1.30",
                                  artifact: rig.artifact("Studio Launcher KH-0.1.30.dmg", "launcher bytes"), kind: "app-dmg",
                                  allowSame: false, meta: { _ in
            AppMeta(name: "Studio Launcher KH", bundleID: "com.khupdater.launcher",
                    bundleName: "Studio Launcher KH.app", version: "0.1.30", iconPNG: Data("png".utf8))
        })
        let feed = try FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey)
        expect(feed?.apps["updater"]?.bundleID == nil && feed?.apps["updater"]?.bundleName == nil
               && feed?.apps["updater"]?.icon == nil && feed?.apps["updater"]?.kind == "updater",
               "PB1 the updater entry is the helper binary: it never carries an app's identity or icon")
        expect(feed?.apps["launcher"]?.bundleID == "com.khupdater.launcher"
               && feed?.apps["launcher"]?.bundleName == "Studio Launcher KH.app" && feed?.apps["launcher"]?.name == "Studio Launcher KH",
               "PB2 the Launcher app is its own feed entry, with its own name, identity and icon")
        let catalog = Catalog.build(feed: feed, ssd: [])
        expect(catalog.contains { $0.id == "launcher" && $0.name == "Studio Launcher KH" }
               && !catalog.contains { $0.id == "updater" },
               "PB3 the Launcher app is listed and installable; the helper is never an app on offer")
    } catch { expect(false, "PB Launcher feed entries: \(error)") }
}

/// Calls the server's handler directly — the same code the sockets reach — with fault hooks.
final class InProcessClient: HTTPClient, @unchecked Sendable {
    let server: FeedServer
    var resultStatus: Int? = nil
    var downloads = 0
    var extraBytes = 0
    var downloadFailure: String?
    init(server: FeedServer) { self.server = server }
    func respond(_ method: String, _ url: URL, _ headers: [String: String], _ body: Data) -> HTTPResponse {
        var target = url.path
        if let q = url.query { target += "?" + q }
        var lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        // A real URLSession sends the Host the Mac typed; the publisher's reply must name that
        // address, so the fixture sends it too instead of falling back to the bind address.
        if lower["host"] == nil, let host = url.host {
            lower["host"] = host + (url.port.map { ":\($0)" } ?? "")
        }
        return server.handleRequest(HTTPRequest(method: method, path: target, headers: lower, body: body), remote: "100.64.0.9")
    }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        let r = respond("GET", url, headers, Data()); return (r.data, r.status)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if let resultStatus, url.path.hasSuffix("/result") { return (Data(), resultStatus) }
        if url.host == "127.0.0.1", url.path.contains("/api/maintenance/") {
            return (Data(#"{"safe":true,"unsettled":[],"dispatch_paused_s":120,"in_flight":0}"#.utf8), 200)
        }
        let r = respond("POST", url, headers, body); return (r.data, r.status)
    }
    func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        if url.host == "127.0.0.1", url.path.contains("/api/maintenance/") { return (Data(), 200) }
        return (Data(), 404)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        downloads += 1
        if let downloadFailure {
            try Data("partial".utf8).write(to: file)
            switch downloadFailure {
            case "transport": throw URLError(.networkConnectionLost)
            case "http": return 503
            case "size": return 200
            default: try Data(repeating: 120, count: Int(limit)).write(to: file); return 200
            }
        }
        let r = respond("GET", url, headers, Data())
        guard case .file(let source, let size) = r.body else { try r.data.write(to: file); return r.status }
        guard size + Int64(extraBytes) <= limit else { throw DeliveryMismatch(description: "larger than expected") }
        var data = try Data(contentsOf: source); data.append(Data(repeating: 0, count: extraBytes))
        try data.write(to: file)
        return r.status
    }
}

func agentConfig(_ rig: Rig, token: String, apps: [String: AppConfig]) -> AgentConfig {
    var cfg = AgentConfig(feedURL: "http://pub.test/release.json", publicKey: rig.pair.publicKeyBase64,
                          stateDir: rig.root.appendingPathComponent("agent").path, machine: "mac1", token: token, apps: apps, once: true)
    cfg.stubBase = rig.root.appendingPathComponent("stub").path
    return cfg
}

func agentAndServerTests() {
    // Installed apps for the agent to read.
    let rig = Rig("agent")
    let appA = makeApp(rig.root.appendingPathComponent("A.app"), version: "1.0.0")
    try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
    let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
    let client = InProcessClient(server: rig.server)
    let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: appA.path, recipe: "fake-for-tests")])

    let r1 = try? Agent.runOnce(config: cfg, http: client)
    expect(r1?.statusPosted == true && r1?.commandsRun == 0, "agent posts status; Automatic off and no order -> nothing installed")

    // R13: an order stays until its result arrives; R16: a lost result is re-reported, not re-run.
    let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
    _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                             body: Data(#"{"machine":"mac1","app":"demo"}"#.utf8)), remote: "127.0.0.1")
    let commands = { () -> [ServerCommand] in
        let r = rig.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=mac1", headers: ["authorization": "Bearer \(token)"]), remote: "100.64.0.9")
        guard let signed = try? JSONDecoder().decode(SignedReply.self, from: r.data),
              let body = signed.replyData else { return [] }
        return (try? JSONDecoder().decode(CommandsReply.self, from: body))?.commands ?? []
    }
    expect(commands().count == 1 && commands().count == 1, "R13 fetching orders does not consume them")
    client.resultStatus = 500
    let r2 = try? Agent.runOnce(config: cfg, http: client)
    expect(r2?.updates == 1 && client.downloads == 1 && commands().count == 1, "R16 a result the server refused keeps the order pending")
    client.resultStatus = nil
    let r3 = try? Agent.runOnce(config: cfg, http: client)
    expect(r3?.commandsRun == 0 && client.downloads == 1 && commands().isEmpty,
           "R16 the next run re-reports the stored result without installing again, and the order clears")

    // S7: an order never downgrades; the same version is "current".
    let appB = makeApp(rig.root.appendingPathComponent("B.app"), version: "9.0.0")
    let cfgB = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: appB.path, recipe: "fake-for-tests")])
    _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                             body: Data(#"{"machine":"mac1","app":"demo"}"#.utf8)), remote: "127.0.0.1")
    _ = try? Agent.runOnce(config: cfgB, http: client)
    let last = (try? StateStore.load(from: rig.state))?.machines["mac1"]?.lastResults?["demo"]
    expect(last?.status == "refused" && (last?.reason ?? "").contains("no downgrade") && client.downloads == 1,
           "S7 an order for an older version is refused before downloading")

    // R18: a version that failed here is not retried automatically.
    do {
        let rigF = Rig("rejected")
        let installed = makeApp(rigF.root.appendingPathComponent("F.app"), version: "1.0.0")
        try? rigF.publish("foo", "1.2.3", rigF.artifact("foo.dmg", "not a dmg"), kind: "app-dmg")
        let tok = try! Enrolment.enrol(stateDir: rigF.state, machine: "mac1")
        let c = InProcessClient(server: rigF.server)
        let cfgF = agentConfig(rigF, token: tok, apps: ["foo": AppConfig(bundlePath: installed.path, recipe: "app-dmg", automatic: true)])
        let failingControl: (String, AppConfig) -> AppControl = { _, _ in
            AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in false }, healthTimeout: 0.1, pollInterval: 0.05)
        }
        let first = try? Agent.runOnce(config: cfgF, http: c, shell: RecordingShell(mount: rigF.root.appendingPathComponent("empty")), control: failingControl)
        let second = try? Agent.runOnce(config: cfgF, http: c, shell: RecordingShell(mount: rigF.root.appendingPathComponent("empty")), control: failingControl)
        expect(first?.commandsRun == 1 && second?.commandsRun == 0 && c.downloads == 1,
               "R18 a failed version is not retried by Automatic until the artifact changes")
    }

    // R19: a download larger than the signed size is refused; old downloads go to _trash.
    do {
        let rigD = Rig("download")
        let app = makeApp(rigD.root.appendingPathComponent("D.app"), version: "1.0.0")
        try? rigD.publish("d", "2.0.0", rigD.artifact("d.zip", "dddd"))
        let tok = try! Enrolment.enrol(stateDir: rigD.state, machine: "mac1")
        let c = InProcessClient(server: rigD.server)
        c.extraBytes = 10
        let cfgD = agentConfig(rigD, token: tok, apps: ["d": AppConfig(bundlePath: app.path, recipe: "fake-for-tests", automatic: true)])
        _ = try? Agent.runOnce(config: cfgD, http: c)
        let res = (try? StateStore.load(from: rigD.state))?.machines["mac1"]?.lastResults?["d"]
        expect(res?.status == "download_failed" && (res?.reason ?? "").contains("larger"), "R19 an oversized download is refused")
        // Live proof R5-1: a bad transfer must not reject the signed release; once the server's
        // bytes are right again, the next Automatic run installs it.
        let mem = try? AtomicFile.readJSON(AgentMemory.self, from: URL(fileURLWithPath: cfgD.stateDir).appendingPathComponent("agent-memory.json"))
        expect(mem != nil && mem?.rejected["d"] == nil && mem?.deliveryMismatches?["d"]?.count == 1,
               "R5-1 one mismatched download does not reject the release")
        c.extraBytes = 0
        let retry = try? Agent.runOnce(config: cfgD, http: c)
        expect(retry?.updates == 1 && c.downloads == 2, "R5-1 the next run downloads it again and installs")
        let healed = try? AtomicFile.readJSON(AgentMemory.self, from: URL(fileURLWithPath: cfgD.stateDir).appendingPathComponent("agent-memory.json"))
        expect(healed != nil && healed?.deliveryMismatches?["d"] == nil, "R5-1 a good install clears the mismatch count")
    }

    // A failed transfer never throws away the bytes it already has: the partial file stays where
    // the next attempt will resume from it. Only bytes that cannot be the signed artifact (a size
    // or SHA mismatch) are retired — recoverably, to state/_trash.
    for failure in ["transport", "http", "size", "sha"] {
        let rig = Rig("partial-\(failure)")
        let installed = makeApp(rig.root.appendingPathComponent("Foo.app"), version: "1.0.0")
        try! rig.publish("foo", "2.0.0", rig.artifact("foo.dmg", "good-dmg"), kind: "app-dmg")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let client = InProcessClient(server: rig.server)
        client.downloadFailure = failure
        let config = agentConfig(rig, token: token, apps: ["foo": AppConfig(bundlePath: installed.path, recipe: "app-dmg", automatic: true)])
        let mount = rig.root.appendingPathComponent("mount")
        makeApp(mount.appendingPathComponent("Foo.app"), version: "2.0.0")
        let shell = RecordingShell(mount: mount)
        let app = FakeApp(installed: installed, running: false, healthy: ["2.0.0"])
        let control: (String, AppConfig) -> AppControl = { _, _ in app.control }
        _ = try? Agent.runOnce(config: config, http: client, shell: shell, control: control)
        let state = URL(fileURLWithPath: config.stateDir)
        let downloads = state.appendingPathComponent("downloads/foo")
        let parts = (try? fm.contentsOfDirectory(atPath: downloads.path))?.filter { $0.hasSuffix(".part") }
        let kept = parts?.first.flatMap { try? Data(contentsOf: downloads.appendingPathComponent($0)) }
        let trash = fm.enumerator(at: Trash.root(in: state), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let report = (try? StateStore.load(from: rig.state))?.machines["mac1"]?.lastResults?["foo"]
        let transportFailure = failure == "transport" || failure == "http"
        expect(report?.status == "download_failed"
               && (transportFailure ? kept == Data("partial".utf8)
                                    : parts?.isEmpty == true && trash.contains { $0.pathExtension == "part" })
               && marker(installed) == "1.0.0" && app.events.isEmpty,
               "R19/R5-1 \(failure) failure keeps its partial, and retires only bytes that cannot be the artifact")
        client.downloadFailure = nil
        let retry = try? Agent.runOnce(config: config, http: client, shell: shell, control: control)
        expect(retry?.updates == 1 && marker(installed) == "2.0.0" && !app.running
               && !app.events.contains("launch") && client.downloads == 2,
               "R5-1 a good run after \(failure) installs and leaves the app closed (Automatic never opens it)")
    }

    // R25: the agent's high-water mark.
    do {
        let rigH = Rig("highwater")
        let app = makeApp(rigH.root.appendingPathComponent("H.app"), version: "1.0.0")
        try? rigH.publish("h", "1.0.0", rigH.artifact("h.zip", "h"))
        let tok = try! Enrolment.enrol(stateDir: rigH.state, machine: "mac1")
        let c = InProcessClient(server: rigH.server)
        let cfgH = agentConfig(rigH, token: tok, apps: ["h": AppConfig(bundlePath: app.path, recipe: "fake-for-tests")])
        _ = try? Agent.runOnce(config: cfgH, http: c)
        // Same published_at, different signed content.
        let release = try! JSONDecoder().decode(Release.self, from: Data(contentsOf: FeedPublisher.releaseFile(in: rigH.feed)))
        var feed = try! JSONDecoder().decode(Feed.self, from: release.feedData!)
        // Different packaging (notes only) at the same published_at is the same release (0.1.64)
        // and is accepted; a different artifact at that instant is still refused.
        feed.apps["h"]?.notes = "changed"
        feed.apps["h"]?.sha256 = String(repeating: "d", count: 64)
        try! FeedPublisher.saveFeed(feed, to: rigH.feed, key: rigH.pair.privateKey)
        expectThrows("R25 a different artifact with an equal published_at is refused", contains: "different artifact identity") {
            _ = try Agent.runOnce(config: cfgH, http: c)
        }
        feed.published_at = ISO.string(Date().addingTimeInterval(10 * 24 * 3600))
        try! FeedPublisher.saveFeed(feed, to: rigH.feed, key: rigH.pair.privateKey)
        expectThrows("R25 a far-future feed is refused and does not become the high-water mark", contains: "future") {
            _ = try Agent.runOnce(config: cfgH, http: c)
        }
        let memory = try? AtomicFile.readJSON(AgentMemory.self, from: URL(fileURLWithPath: cfgH.stateDir).appendingPathComponent("agent-memory.json"))
        expect(memory?.feedPublishedAt.flatMap(ISO.date).map { $0 < Date().addingTimeInterval(3600) } == true, "R25 the high-water mark was not moved")
    }

    // R3: a second agent on the same Mac refuses instead of racing.
    do {
        let lockFile = URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("agent.lock")
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? FileLock.withExclusive(lockFile) { holding.signal(); release.wait() }
        }
        holding.wait()
        // A long-running agent (not a one-shot request: those wait for the run in progress).
        var refusing = cfg
        refusing.once = false
        expectThrows("R3 a second agent run refuses while one holds the lock", contains: "another KH Updater process") {
            _ = try Agent.runOnce(config: refusing, http: client)
        }
        release.signal()
        let twins = AgentConfig(feedURL: cfg.feedURL, publicKey: cfg.publicKey, stateDir: cfg.stateDir, machine: "mac1", token: token,
                                apps: ["a": AppConfig(bundlePath: appA.path), "b": AppConfig(bundlePath: appA.path + "/")], once: true)
        expectThrows("R3 two app ids naming one bundle are refused", contains: "one app per bundle") { _ = try Agent.runOnce(config: twins, http: client) }
    }

    // R7: the updater's own version comes from where it runs.
    do {
        let base = tmpDir("selfversion")
        let exe = base.appendingPathComponent("versions/1.4.2/khu")
        try! fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        var c = AgentConfig(feedURL: "", publicKey: "", stateDir: "", machine: "m", token: "")
        c.stubBase = base.path; c.updaterVersion = "1.0.0"
        expect(Agent.selfVersion(config: c, executable: exe.path) == "1.4.2", "R7 the running binary's version, not the static config")
        let bundled = base.appendingPathComponent("versions/1.4.3/Studio Launcher KH Helper.app/Contents/MacOS/Studio Launcher KH Helper")
        try! fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\n".write(to: bundled, atomically: true, encoding: .utf8)
        expect(Agent.selfVersion(config: c, executable: bundled.path) == "1.4.3", "R7b the named helper bundle reports its own version, not the static config")
    }

    // Server: R14 cross-process lock (six concurrent enrolments), R15 save failures, R27 corrupt state.
    do {
        let rigS = Rig("server")
        let group = DispatchGroup()
        for i in 0..<6 {
            group.enter()
            Thread.detachNewThread { _ = try? Enrolment.enrol(stateDir: rigS.state, machine: "m\(i)"); group.leave() }
        }
        group.wait()
        expect((try? StateStore.load(from: rigS.state))?.machines.count == 6, "R14 six concurrent enrolments all survive")
        let tok = try! Enrolment.enrol(stateDir: rigS.state, machine: "w")
        chmod(rigS.state.path, 0o500)
        let r = rigS.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(tok)"],
                                                      body: Data(#"{"machine":"w","installed":{"x":"1"}}"#.utf8)), remote: "100.64.0.9")
        chmod(rigS.state.path, 0o755)
        expect(r.status >= 500, "R15 a status that could not be saved is not a 200 (got \(r.status))")
        try! Data("CORRUPT".utf8).write(to: StateStore.stateFile(in: rigS.state))
        let c = rigS.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=w", headers: ["authorization": "Bearer \(tok)"]), remote: "100.64.0.9")
        let page = rigS.server.statusHTML()
        expect(c.status == 503 && page.contains("cannot be read") && (try? String(contentsOf: StateStore.stateFile(in: rigS.state), encoding: .utf8)) == "CORRUPT",
               "R27 corrupt state is a visible 503 and the file is left alone")
    }

    // S4: Host, Origin/Referer and page headers.
    do {
        let rigO = Rig("owner")
        _ = try! Enrolment.enrol(stateDir: rigO.state, machine: "mac1")
        let s = rigO.server
        let body = Data("machine=mac1&app=demo".utf8)
        let form = ["content-type": "application/x-www-form-urlencoded", "host": "127.0.0.1:8790"]
        expect(s.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: form, body: body), remote: "127.0.0.1").status == 403,
               "S4 a state change with neither Origin nor Referer is refused")
        var rebind = form; rebind["host"] = "attacker.example"; rebind["origin"] = "http://127.0.0.1:8790"
        expect(s.handleRequest(HTTPRequest(method: "GET", path: "/", headers: rebind), remote: "127.0.0.1").status == 403,
               "S4 a foreign Host (DNS rebinding) is refused")
        var good = form; good["referer"] = "http://127.0.0.1:8790/"
        expect(s.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: good, body: body), remote: "127.0.0.1").status == 303,
               "S4 the page's own form (Referer) works")
        let page = s.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": "localhost:8790"]), remote: "127.0.0.1")
        expect(page.headers["Content-Security-Policy"]?.contains("frame-ancestors 'none'") == true && page.headers["X-Frame-Options"] == "DENY",
               "S4 the owner page sends CSP and frame protection")
        expect(s.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1:8790"]), remote: "100.64.0.9").status == 403,
               "the owner page is refused from another Mac")
        // R32: the page shows what the agent will really do.
        let tok = try! Enrolment.enrol(stateDir: rigO.state, machine: "mac2")
        try? rigO.publish("demo", "1.0.0", rigO.artifact("demo.zip", "z"))
        _ = s.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(tok)"],
                                        body: Data(#"{"machine":"mac2","installed":{"demo":"0.9.0"},"automatic_default":{"demo":true}}"#.utf8)), remote: "100.64.0.9")
        let publisherNotes = WhatsNew.publisher.first!
        let firstItem = publisherNotes.items.first!.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        expect(s.statusHTML().contains("id=whats-new-pill title=\"What's New in Update Studio KH \(publisherNotes.version)\">")
               && s.statusHTML().contains("<dialog id=whats-new aria-labelledby=whats-new-title>")
               && s.statusHTML().contains(firstItem), "the pill opens What's New with the top CHANGELOG entry")
        // A retired app keeps its published entry (a published version is never withdrawn) but the page
        // presents no row and no update button for it: the fleet has one GUI app.
        try? rigO.publish("kh-updater-app", "1.0.42", rigO.artifact("u.zip", "u"))
        let retiredPage = s.statusHTML()
        expect(!retiredPage.contains("kh-updater-app") && !retiredPage.contains("Update Studio KH</td>"),
               "a retired app's feed entry is not listed or offered on the publisher page")
        do {
            let e = [WhatsNew.Entry(version: "2.0.0", date: "2026-11-16", items: ["a <b>", "**c** `d`"]),
                     WhatsNew.Entry(version: "1.9.0", date: "2026-11-10", items: ["old"])]
            let esc: (String) -> String = { $0.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
            let shown = WhatsNew.dialogBody(app: "X", shown: "2.0.0", entries: e, escape: esc)
            let other = WhatsNew.dialogBody(app: "X", shown: "3.0.0", entries: e, escape: esc)
            expect(shown.contains("<strong>X v2.0.0</strong><span class=tag>This version</span><span class=when>2026-11-16</span>")
                   && shown.contains("2 changes in this release.") && shown.contains("<li>a &lt;b&gt;</li>") && shown.contains("<li>c d</li>")
                   && shown.contains("<section class=rel><h3>v1.9.0 <span class=when>2026-11-10</span></h3>"),
                   "WN1 What's New shows version, date, count, its changes, then earlier releases")
            expect(!other.contains("This version") && other.contains("runs v3.0.0, which has no notes"),
                   "WN2 a version with no notes is said plainly, never labelled as this version")
        }
        expect(s.statusHTML().contains("Automatic: on"), "R32 a Mac whose own config is Automatic shows Automatic: on")
        // 1.0.2 page: one state per app, Update N Macs, history, failure details, notes, offline.
        expect(s.statusHTML().contains("Update available") && s.statusHTML().contains("Update 1 Mac"),
               "P1 a Mac behind the feed shows Update available and the Feed offers Update 1 Mac")
        let mac1Before = (try! StateStore.load(from: rigO.state)).machines["mac1"]?.pending.count
        expect(s.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: good, body: Data("app=demo".utf8)), remote: "127.0.0.1").status == 303,
               "P2 Update N Macs is the page's own form")
        let afterAll = try! StateStore.load(from: rigO.state)
        let order = afterAll.machines["mac2"]?.pending.first { $0.app == "demo" && $0.action == ServerCommand.update }
        expect(order != nil && afterAll.machines["mac1"]?.pending.count == mac1Before,
               "P2 Update N Macs orders exactly the Macs behind the feed (a Mac that never reported gets nothing)")
        _ = s.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: good, body: Data("app=demo".utf8)), remote: "127.0.0.1")
        expect((try! StateStore.load(from: rigO.state)).machines["mac2"]?.pending.filter { $0.app == "demo" }.count == 1,
               "P2 a second Update N Macs does not queue a second order for a Mac already updating")
        let res = s.handleRequest(HTTPRequest(method: "POST", path: "/commands/\(order?.id ?? "x")/result", headers: ["authorization": "Bearer \(tok)"],
                                              body: Data(#"{"machine":"mac2","app":"demo","status":"rolled_back","reason":"the new version was not healthy within 60 s"}"#.utf8)), remote: "100.64.0.9")
        let failedPage = s.statusHTML()
        expect(res.status == 200 && failedPage.contains("Copy error report") && failedPage.contains("Back on 0.9.0")
               && failedPage.contains("the new version was not healthy within 60 s") && failedPage.contains("0.9.0 → 1.0.0"),
               "P3 a failed result shows its reason, the version the Mac is back on, a copy button, and a history line from → to")
        expect(!FeedServer.updateAvailable((try! StateStore.load(from: rigO.state)).machines["mac2"]!, app: "demo", feed: FeedPublisher.loadFeed(from: rigO.feed), now: Date()),
               "P3 a failed app is looked at first, not swept into Update N Macs")
        for i in 1...12 {
            _ = s.handleRequest(HTTPRequest(method: "POST", path: "/automatic/auto-\(i)/result", headers: ["authorization": "Bearer \(tok)"],
                                            body: Data(#"{"machine":"mac2","app":"demo","status":"current"}"#.utf8)), remote: "100.64.0.9")
        }
        expect((try! StateStore.load(from: rigO.state)).machines["mac2"]?.history?.count == HistoryEntry.kept, "P4 a Mac keeps its last 10 results")
        expect(s.statusHTML().contains("data-confirm=\"Roll back demo on mac2 to ") && s.statusHTML().contains("No Macs match this filter.")
               && !s.statusHTML().contains("Macs removed (0)"), "P8 Roll back asks first, an empty filter says so, and an empty removed list is hidden")
        try? FeedPublisher.publish(feedDir: rigO.feed, keyFile: rigO.key, app: "noted", version: "1.0.0", artifact: rigO.artifact("n.zip", "n"),
                                   kind: "fake-for-tests", allowSame: false, notes: "- Copy error report button\n- Not tested on printer hardware")
        expect(FeedPublisher.loadFeed(from: rigO.feed)?.apps["noted"]?.notes?.contains("printer hardware") == true
               && s.statusHTML().contains("<li>Not tested on printer hardware</li>"), "P5 notes are signed into the feed and shown as What's new")
        try! StateStore.update(in: rigO.state) { $0.machines["mac2"]?.lastSeen = ISO.string(Date().addingTimeInterval(-3600)) }
        let quiet = s.statusHTML()
        expect(quiet.contains("Offline · ") && !quiet.contains("Update 1 Mac"), "P6 a Mac silent for an hour is Offline, never its last state")
        expect(FeedServer.model(of: "terranash-1607-m2-pro-32-512-hub") == "M2 Pro · 32 GB · 512 GB"
               && FeedServer.model(of: "terranash-1301-m1-16-1000-hub") == "M1 · 16 GB · 1 TB"
               && FeedServer.model(of: "terranes-1606-m1-16-512-hub") == nil && FeedServer.model(of: "vengthengs-mac-studio-hub") == nil,
               "P7 the model under a Mac's name is shown only when its name parses")
        // R33: an artifact whose name has a space is served.
        try? rigO.publish("spaced", "1.0.0", rigO.artifact("My App.dmg", "s"))
        let file = FeedPublisher.loadFeed(from: rigO.feed)?.apps["spaced"]?.file ?? ""
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        expect(s.handleRequest(HTTPRequest(method: "GET", path: "/artifacts/\(encoded)"), remote: "100.64.0.9").status == 200,
               "R33 a percent-encoded artifact name is served")
    }
}

// R20 / S5: one stalled client never blocks the others.
func socketTests() {
    let rig = Rig("socket")
    try? rig.publish("big", "1.0.0", rig.artifact("big.bin", String(repeating: "x", count: 8 << 20)))
    let server = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0)
    let fd = try! server.listen()
    let port = FeedServer.boundPort(fd)
    Thread.detachNewThread { try? server.serve(on: fd) }
    func connect() -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return s
    }
    let slow = connect()
    _ = "GET /release.json HTTP/1.1\r\nHo".withCString { write(slow, $0, strlen($0)) }   // never finishes
    let stalled = connect()
    let file = FeedPublisher.loadFeed(from: rig.feed)?.apps["big"]?.file ?? ""
    _ = "GET /artifacts/\(file) HTTP/1.1\r\n\r\n".withCString { write(stalled, $0, strlen($0)) }   // never reads
    Thread.sleep(forTimeInterval: 0.3)
    let t0 = Mono.now()
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/release.json")!); req.timeoutInterval = 5
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code = 0
    URLSession.shared.dataTask(with: req) { _, resp, _ in code = (resp as? HTTPURLResponse)?.statusCode ?? 0; sem.signal() }.resume()
    _ = sem.wait(timeout: .now() + 6)
    expect(code == 200 && Mono.now() - t0 < 3, "R20/S5 a slow client and a non-reading client do not block another Mac (\(code))")
    close(slow); close(stalled)
}

// R4-1 (live proof, 2026-10-25): an app that is healthy for a moment and then dies is NOT healthy.
func r41HealthMustHold() {
    var t = 0.0
    var polls = 0
    let flash = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in
        polls += 1; return polls == 1   // up for one look, then gone (exit(1) right after launch)
    }, healthTimeout: 5, pollInterval: 0, healthSettle: 3)
    expect(!Recipe.waitHealthy(flash, version: "1.0.2", clock: { t += 1; return t }),
           "R4-1 an app healthy for one poll and then dead is not accepted")
    t = 0
    let steady = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in true },
                            healthTimeout: 5, pollInterval: 0, healthSettle: 3)
    expect(Recipe.waitHealthy(steady, version: "1.0.1", clock: { t += 1; return t }),
           "R4-1 an app that stays healthy through the settle window is accepted")
    t = 0; polls = 0
    let flapping = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in
        polls += 1; return polls % 2 == 1
    }, healthTimeout: 5, pollInterval: 0, healthSettle: 3)
    expect(!Recipe.waitHealthy(flapping, version: "1.0.2", clock: { t += 1; return t }),
           "R4-1 a flapping app never accumulates a settle window")
    expect(AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in true }).healthSettle >= 5,
           "R4-1 live controls hold health for a real settle window by default")
}

// Inject a jumping wall clock into the observation and a separate monotonic deadline source.
func r28MonotonicWait() {
    var wall = Date()
    var calls = 0
    var ticks = 0.0
    let control = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in
        calls += 1
        wall = wall.addingTimeInterval(calls == 1 ? 3600 : -7200)
        return false
    }, healthTimeout: 0.3, pollInterval: 0.01)
    let healthy = Recipe.waitHealthy(control, version: "1.0", clock: { ticks += 0.1; return ticks })
    // Bound the injected clock, so scheduler delays cannot turn a correct deadline into a failure.
    expect(!healthy && calls >= 3 && ticks < 1,
           "R28 live health wait follows the monotonic deadline despite wall clock jumps")
    let realStart = Mono.now()
    let real = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in false },
                          healthTimeout: 0.12, pollInterval: 0.02)
    expect(!Recipe.waitHealthy(real, version: "1.0") && Mono.now() - realStart >= 0.1,
           "R28 default live health wait observes its monotonic duration")
}

// Round 2 probes exercise the shared production paths; no desktop applications are opened.
final class R2Client: HTTPClient, @unchecked Sendable {
    let inner: InProcessClient
    var commands: Data?
    /// When set, the status answer is exactly these bytes; otherwise `/status` goes to `inner`
    /// so tests that check `state.lastSeen` or the live `/status` path see the real server.
    var status: Data?
    var transient = false
    var corrupt = false
    var attempts = 0
    init(_ server: FeedServer) { inner = InProcessClient(server: server) }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        if url.path == "/commands", let commands { return (commands, 200) }
        return try inner.get(url, headers: headers)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if url.path == "/status", let status { return (status, 200) }
        return try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        attempts += 1
        if transient { throw URLError(.networkConnectionLost) }
        let code = try inner.download(url, headers: headers, to: file, limit: limit)
        if corrupt { try Data(repeating: 120, count: Int(limit)).write(to: file) }
        return code
    }
}

final class R2MenuShell: Shell, @unchecked Sendable {
    let menu: Process
    let inner: RecordingShell
    init(menu: Process, inner: RecordingShell) { self.menu = menu; self.inner = inner }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/usr/bin/osascript" {
            inner.lock.lock(); inner.calls.append("fake menu quit"); inner.lock.unlock()
            if menu.isRunning { menu.terminate(); menu.waitUntilExit() }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        return try inner.run(executable, arguments: arguments, timeout: timeout)
    }
}

func r2Journal(_ rig: RecipeRig, phase: String = "promoted", previous: String? = "1.0.0", running: Bool = true) {
    try! AtomicFile.writeJSON(InstallJournal(phase: phase, installed: rig.installed.path, staged: "",
                                            rollback: rig.rollback.path, previousVersion: previous,
                                            wasRunning: running, version: "1.2.3"), to: rig.journal)
}
func r2Sign(_ reply: CommandsReply, _ key: Curve25519.Signing.PrivateKey) -> Data {
    let body = JSON.encode(reply)
    return JSON.encode(SignedReply(reply: body, signature: try! Signing.sign(body, with: key)))
}

func round2Tests(only: Int? = nil) {
    func run(_ n: Int, _ body: () -> Void) { if only == nil || only == n { body() } }
    run(1) {
        let rig = RecipeRig("r2-putback")
        let fail = FailingMoves()
        fail.failWhen = { src, dst in dst == rig.installed.path && (src.contains("rollback-foo") || src.hasSuffix("khu-previous")) }
        let app = FakeApp(installed: rig.installed, healthy: ["1.0.0"])
        let result = try? rig.run(app, fileManager: fail).get()
        expect(result?.status == "rollback_failed" && fm.fileExists(atPath: rig.journal.path)
               && marker(rig.installed) == "1.2.3" && marker(rig.rollback) == "1.0.0",
               "R2-1 failed putBack retains installed bundle, fallback and journal")
        _ = try? Recipe.recover(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo", control: app.control)
        expect(marker(rig.installed) == "1.0.0" && !fm.fileExists(atPath: rig.journal.path),
               "R2-1 next recovery finishes the failed rollback")
        let interrupted = RecipeRig("r2-rollback-interrupted", installedVersion: "1.2.3")
        makeApp(interrupted.rollback, version: "1.0.0"); r2Journal(interrupted, phase: "rolling_back")
        let displaced = interrupted.apps.appendingPathComponent(".Foo.app.khu-unhealthy")
        try! fm.moveItem(at: interrupted.installed, to: displaced)
        let restart = FakeApp(installed: interrupted.installed, running: false, healthy: ["1.0.0"])
        _ = try? Recipe.recover(installedPath: interrupted.installed.path, stateDir: interrupted.state.path, app: "foo", control: restart.control)
        expect(marker(interrupted.installed) == "1.0.0" && restart.running && !fm.fileExists(atPath: interrupted.journal.path),
               "R2-1 killed rollback restores verified previous bundle from retained original")
        let rig2 = RecipeRig("r2-recover-move", installedVersion: nil)
        makeApp(rig2.rollback, version: "1.0.0"); r2Journal(rig2, phase: "moving")
        let fail2 = FailingMoves(); fail2.failWhen = { _, dst in dst == rig2.installed.path }
        let app2 = FakeApp(installed: rig2.installed, running: false, healthy: ["1.0.0"])
        _ = try? Recipe.recover(installedPath: rig2.installed.path, stateDir: rig2.state.path, app: "foo", control: app2.control, fileManager: fail2)
        expect(fm.fileExists(atPath: rig2.journal.path) && marker(rig2.rollback) == "1.0.0" && !app2.running,
               "R2-1 recovery move failure keeps intent and never launches an absent app")
    }
    run(2) {
        for phase in ["promoting", "promoted"] {
            let rig = RecipeRig("r2-health-\(phase)")
            try! fm.createDirectory(at: rig.rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! fm.moveItem(at: rig.installed, to: rig.rollback)
            makeApp(rig.installed, version: "1.2.3"); r2Journal(rig, phase: phase)
            let app = FakeApp(installed: rig.installed, running: false, healthy: ["1.0.0"])
            _ = try? Recipe.recover(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo", control: app.control)
            expect(marker(rig.installed) == "1.0.0" && app.control.healthy("1.0.0") && !fm.fileExists(atPath: rig.journal.path),
                   "R2-2 \(phase) recovery health-checks new version and rolls back to healthy previous")
        }
    }
    run(3) {
        let layout = StubLayout(base: tmpDir("r2-reboot"))
        makeVersion(layout, "1.0.0", script: "exit 0")
        makeVersion(layout, "2.0.0", script: "sleep 0.35; exit 0")
        _ = try! StubSwitcher(layout: layout).install(version: "1.0.0")
        _ = try! StubSwitcher(layout: layout).install(version: "2.0.0")
        try! AtomicFile.writeJSON(StubState(switched_at: ISO.string(Date().addingTimeInterval(-3600)), target: layout.currentBinary()!.path), to: layout.stateFile)
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.03, restartDelay: 0.03,
                              policy: StubPolicy(crashWindow: 6, heartbeatGrace: 3)).run()
        let state = try! AtomicFile.readJSON(StubState.self, from: layout.stateFile)!
        expect(code == 0 && layout.currentBinary().map(StubLayout.version) == "2.0.0"
               && state.switchedAt! > Date().addingTimeInterval(-10), "R2-3 restart gives an open probation its full grace")
    }
    run(4) {
        let rig = Rig("r2-self-reject"); let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        var cfg = agentConfig(rig, token: token, apps: ["updater": AppConfig(bundlePath: "", recipe: "updater", automatic: true)])
        cfg.updaterVersion = "1.0.0"
        let layout = StubLayout(base: URL(fileURLWithPath: cfg.stubBase!))
        makeVersion(layout, "1.0.0", script: "exit 0"); _ = try! StubSwitcher(layout: layout).install(version: "1.0.0")
        try! rig.publish("updater", "2.0.0", rig.artifact("khu", "#!/bin/sh\nexit 1\n"), kind: "updater")
        let client = R2Client(rig.server)
        let first = try? Agent.runOnce(config: cfg, http: client)
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.03, restartDelay: 0.03,
                              policy: StubPolicy(crashWindow: 10, crashLimit: 3, heartbeatGrace: 10)).run()
        let second = try? Agent.runOnce(config: cfg, http: client)
        expect(first?.restartRequested == true && code == 0 && second?.commandsRun == 0 && client.attempts == 1,
               "R2-4 agent rejects bytes the stub rolled back instead of reinstalling forever")
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]!.pending = [ServerCommand(machine: "mac1", app: "updater")] }
        let explicit = try? Agent.runOnce(config: cfg, http: client)
        _ = try? StubSwitcher(layout: layout).switchBack()
        let afterOrder = try? Agent.runOnce(config: cfg, http: client)
        expect(explicit?.restartRequested == true && afterOrder?.restartRequested == true,
               "R2-4 explicit retry consumes the old rollback record once")
        try! rig.publish("updater", "3.0.0", rig.artifact("khu", "#!/bin/sh\nexit 0\n"), kind: "updater")
        let replacement = try? Agent.runOnce(config: cfg, http: client)
        expect(replacement?.restartRequested == true && layout.currentBinary().map(StubLayout.version) == "3.0.0",
               "R2-4 new artifact can be installed despite earlier rollback rejection")
    }
    run(5) {
        let rig = RecipeRig("r2-first-install", installedVersion: nil)
        let app = FakeApp(installed: rig.installed, running: false, healthy: [])
        let first = try? rig.run(app).get()
        expect(first?.status == "rollback_failed" && Recipe.isUnresolved(stateDir: rig.state.path, app: "foo"),
               "R2-5 unhealthy first install stays unresolved even when initially stopped")
        let attempts = app.events.filter { $0 == "launch" }.count
        _ = try? Recipe.recover(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo", control: app.control)
        let config = AgentConfig(feedURL: "", publicKey: "", stateDir: rig.state.path, machine: "m", token: "",
                                apps: ["foo": AppConfig(bundlePath: rig.installed.path)])
        let rigHTTP = Rig("r2-first-http")
        let current = try? Agent.install(app: "foo", feed: Feed(published_at: ISO.string(Date())), installed: "1.2.3", config: config,
                                        serverBase: URL(string: "http://127.0.0.1:1")!, stateDir: rig.state,
                                        http: InProcessClient(server: rigHTTP.server), shell: rig.shell, control: { _, _ in app.control })
        expect(app.events.filter { $0 == "launch" }.count > attempts && current?.status == "unresolved"
               && fm.fileExists(atPath: rig.journal.path), "R2-5 next run retries health and never calls broken first install current")
        app.healthyVersions = ["1.2.3"]
        _ = try? Recipe.recover(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo", control: app.control)
        expect(!fm.fileExists(atPath: rig.journal.path) && app.control.healthy("1.2.3"),
               "R2-5 later successful health check resolves first-install journal")
    }
    run(6) {
        let root = tmpDir("r2-gateway")
        let bundle = makeApp(root.appendingPathComponent("Gateway.app"), version: "2.0.0")
        let victim = startInBundle(bundle)
        defer { if victim.isRunning { victim.terminate() }; victim.waitUntilExit() }
        let server = HealthServer(pid: victim.processIdentifier)
        let recorder = RecordingShell(mount: root)
        let control = LiveControl.gateway(bundle.path, shell: FakeQuitShell(record: recorder), port: server.port, quitWait: 0.05)
        let stopped = control.stopService()
        expect(!stopped && victim.isRunning && !control.healthy("2.0.0"),
               "R2-6 spoofed health cannot signal or vouch for a bundle process that does not own listener")
        let rig = RecipeRig("r2-real-listener")
        let exe = rig.installed.appendingPathComponent("Contents/MacOS/Foo")
        try! Trash.move(exe, into: Trash.root(in: rig.root))
        try! fm.copyItem(at: URL(fileURLWithPath: "build/khu-tests"), to: exe)
        let markerPath = rig.installed.appendingPathComponent("marker")
        let heldMarker = rig.root.appendingPathComponent("held-marker")
        try! fm.moveItem(at: markerPath, to: heldMarker)
        let signed = try? SystemShell().run("/usr/bin/codesign", arguments: ["-f", "-s", "-", exe.path], timeout: 10)
        try! fm.moveItem(at: heldMarker, to: markerPath)
        guard signed?.exitCode == 0 else { expect(false, "R2-6 listener fixture signs successfully (\(signed?.stderr ?? "no result"))"); return }
        let portFile = rig.root.appendingPathComponent("port")
        let process = Process(); process.executableURL = exe
        var environment = ProcessInfo.processInfo.environment; environment["R2_GATEWAY_PORT"] = portFile.path
        process.environment = environment; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try! process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let deadline = Mono.now() + 5
        while !fm.fileExists(atPath: portFile.path) && Mono.now() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard let port = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap(Int.init) else {
            expect(false, "R2-6 listener fixture starts"); return
        }
        let menu = Process(); menu.executableURL = exe
        var menuEnvironment = ProcessInfo.processInfo.environment
        menuEnvironment["R2_GATEWAY_MENU"] = "1"; menuEnvironment["R2_GATEWAY_PORT"] = nil
        menu.environment = menuEnvironment; menu.standardOutput = FileHandle.nullDevice; menu.standardError = FileHandle.nullDevice
        try! menu.run()
        defer { if menu.isRunning { menu.terminate() }; menu.waitUntilExit() }
        let menuShell = R2MenuShell(menu: menu, inner: rig.shell)
        var actual = LiveControl.gateway(rig.installed.path, shell: menuShell, port: port, quitWait: 0.1)
        expect(actual.healthy("1.0.0"), "R2-6 genuine in-bundle listener passes identity health")
        // Preserve live quit and service stop; launch/health after promotion are fake desktop actions.
        // The fake launch is also what makes the relaunched process "appear": the real processes this
        // test uses are gone by then, and an install waits for a process it stopped to come back.
        var launched = false
        let liveRunning = actual.isRunning
        actual.isRunning = { launched || (liveRunning() ?? false) }
        actual.launch = { launched = true }
        actual.healthy = { version in (try? BundleInfo.read(rig.installed.path).version) == version }
        var gatewayError = ""
        let result: RecipeResult
        do {
            result = try Recipe.appDmg(shell: rig.shell, installedPath: rig.installed.path, artifactPath: "/tmp/fake.dmg",
                                       feedVersion: "1.2.3", expectedBundleID: "com.example.foo", stateDir: rig.state.path,
                                       app: "foo", control: actual)
        } catch { gatewayError = " (\(error))"; result = RecipeResult(status: "error") }
        expect(result.status == "updated" && !process.isRunning && !menu.isRunning && rig.shell.calls.contains("fake menu quit") && marker(rig.installed) == "1.2.3",
               "R2-6 complete Gateway recipe quits menubar and stops genuine embedded listener (\(result.status)\(gatewayError))")

    }
    run(7) {
        let layout = StubLayout(base: tmpDir("r2-child-beat")); let counter = layout.base.appendingPathComponent("starts")
        makeVersion(layout, "1.0.0", script: "exit 0")
        makeVersion(layout, "2.0.0", script: #"echo x >> '\#(counter.path).count'; if [ ! -f '\#(counter.path)' ]; then touch '\#(counter.path)'; echo "{\"at\":\"$(date -u -v+1S +%Y-%m-%dT%H:%M:%SZ)\",\"pid\":$$,\"nonce\":\"$KHU_HEARTBEAT_NONCE\"}" > '\#(layout.heartbeatFile.path)'; sleep 0.5; exit 1; fi; sleep 4; exit 0"#)
        _ = try! StubSwitcher(layout: layout).install(version: "1.0.0")
        _ = try! StubSwitcher(layout: layout).install(version: "2.0.0")
        let code = StubRunner(layout: layout, childArguments: [], pollInterval: 0.03, restartDelay: 0.03,
                              policy: StubPolicy(crashWindow: 2.5, crashLimit: 3, heartbeatGrace: 2)).run()
        let starts = (try? String(contentsOf: URL(fileURLWithPath: counter.path + ".count"), encoding: .utf8))?.split(separator: "\n").count ?? 0
        expect(code == 0 && starts == 2 && layout.currentBinary().map(StubLayout.version) == "1.0.0",
               "R2-7 previous child heartbeat never settles a silent replacement child")
        var sup = StubSupervisor(); let now = Date(); sup.recordSwitch(at: now, target: "new")
        sup.recordHeartbeat(at: now, now: now); sup.recordExit(code: 1, at: now)
        expect(sup.state.heartbeat_at == nil, "R2-7 child exit clears heartbeat immediately")
    }
    run(8) {
        let rig = Rig("r2-orders"); let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let bundle = makeApp(rig.root.appendingPathComponent("A.app"), version: "1.0.0")
        try! rig.publish("demo", "2.0.0", rig.artifact("a.bin", "abc"))
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: bundle.path, recipe: "fake-for-tests")])
        let client = R2Client(rig.server)
        let order = ServerCommand(machine: "mac1", app: "demo")
        let good = CommandsReply(machine: "mac1", commands: [order], automatic: [:])
        let wrongMac = CommandsReply(machine: "another", commands: [order], automatic: [:])
        let stale = CommandsReply(machine: "mac1", at: ISO.string(Date().addingTimeInterval(-7200)), commands: [order], automatic: [:])
        let unsigned = JSON.encode(good)
        let badSig = r2Sign(good, Signing.generateKeyPair().privateKey)
        // Exercise the `/commands` fallback path as against an older publisher answering `{}`.
        client.status = Data("{}".utf8)
        for (name, body) in [("unsigned", unsigned), ("bad signature", badSig), ("another machine", r2Sign(wrongMac, rig.pair.privateKey)), ("stale", r2Sign(stale, rig.pair.privateKey))] {
            client.commands = body
            expectThrows("R2-8 \(name) orders refused") { _ = try Agent.runOnce(config: cfg, http: client) }
        }
        expect(client.attempts == 0, "R2-8 refused order replies trigger no download")
        // The same rules on the folded path: a status answer signed for another Mac is refused,
        // never quietly replaced by a good `/commands` answer.
        client.status = r2Sign(wrongMac, rig.pair.privateKey)
        client.commands = r2Sign(good, rig.pair.privateKey)
        expectThrows("R2-8 a signed status reply for another Mac is refused") { _ = try Agent.runOnce(config: cfg, http: client) }
        client.status = Data("{}".utf8)
        client.commands = r2Sign(good, rig.pair.privateKey)
        let accepted = try? Agent.runOnce(config: cfg, http: client)
        expect(accepted?.commandsRun == 1 && client.attempts == 1, "R2-8 fresh publisher-signed orders accepted once")
        let response = rig.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=mac1", headers: ["authorization": "Bearer \(token)"]), remote: "127.0.0.1")
        let signed = try? JSON.decode(SignedReply.self, from: response.data)
        expect(signed?.replyData.map { Signing.verify($0, signature: signed!.signatureData!, publicKey: rig.pair.privateKey.publicKey) } == true,
               "R2-8 publisher signs machine and freshness in command reply")
    }
    run(9) {
        let rig = Rig("r2-ack"); let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let token2 = try! Enrolment.enrol(stateDir: rig.state, machine: "mac2")
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]!.pending = [ServerCommand(id: "X", machine: "mac1", app: "gateway")] }
        func post(_ id: String, _ app: String) -> HTTPResponse {
            rig.server.handleRequest(HTTPRequest(method: "POST", path: "/commands/\(id)/result", headers: ["authorization": "Bearer \(token)"],
                body: JSON.encode(["machine": "mac1", "app": app, "status": "updated"])), remote: "127.0.0.1")
        }
        let mismatch = post("X", "other"); let absent = post("Y", "other")
        let foreign = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/commands/X/result", headers: ["authorization": "Bearer \(token2)"],
            body: JSON.encode(["machine": "mac2", "app": "gateway", "status": "updated"])), remote: "127.0.0.1")
        expect(foreign.status == 404, "R2-9 another machine cannot acknowledge this machine's order")
        let state = try! StateStore.load(from: rig.state).machines["mac1"]!
        expect(mismatch.status == 400 && absent.status == 404 && state.pending.count == 1 && state.lastResults == nil,
               "R2-9 mismatched and absent order results leave pending and app results untouched")
        let noApp = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/commands/X/result", headers: ["authorization": "Bearer \(token)"],
                                                        body: JSON.encode(["machine": "mac1", "status": "updated"])), remote: "127.0.0.1")
        expect(noApp.status == 400, "R2-9 missing app cannot acknowledge pending order")
        expect(post("X", "gateway").status == 200 && (try! StateStore.load(from: rig.state)).machines["mac1"]!.lastResults?["gateway"]?.commandId == "X",
               "R2-9 matching result records under looked-up app and clears only its order")
        let automatic = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/automatic/auto-demo-1/result",
            headers: ["authorization": "Bearer \(token)"], body: JSON.encode(["machine": "mac1", "app": "other", "status": "updated"])), remote: "127.0.0.1")
        expect(automatic.status == 200 && (try! StateStore.load(from: rig.state)).machines["mac1"]!.lastResults?["other"]?.status == "updated",
               "R2-9 automatic results use their own route without acknowledging an order")
    }
    run(10) {
        let rig = Rig("r2-transport"); let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let bundle = makeApp(rig.root.appendingPathComponent("A.app"), version: "1.0.0")
        try! rig.publish("demo", "2.0.0", rig.artifact("a.bin", "abc"))
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: bundle.path, recipe: "fake-for-tests", automatic: true)])
        let client = R2Client(rig.server); client.transient = true
        _ = try? Agent.runOnce(config: cfg, http: client); client.transient = false
        let retry = try? Agent.runOnce(config: cfg, http: client)
        expect(retry?.updates == 1 && client.attempts == 2, "R2-10 connection reset retries automatically on next run")
        client.corrupt = true
        // R5-1: a mismatch is retried (it may be a truncated transfer) until it repeats
        // Agent.maxDeliveryMismatches times in a row; then the server's copy is treated as bad.
        try! rig.publish("demo", "3.0.0", rig.artifact("b.bin", "abcd"))
        let before = client.attempts
        for _ in 0..<Agent.maxDeliveryMismatches { _ = try? Agent.runOnce(config: cfg, http: client) }
        expect(client.attempts == before + Agent.maxDeliveryMismatches, "R5-1 a signed SHA mismatch is retried on the next runs")
        let attempts = client.attempts
        let refused = try? Agent.runOnce(config: cfg, http: client)
        expect(refused?.commandsRun == 0 && client.attempts == attempts,
               "R2-10 a signed SHA mismatch repeated in a row is rejected and suppresses automatic retry")
        let operational = Rig("r2-copy-transport"); let tok = try! Enrolment.enrol(stateDir: operational.state, machine: "mac1")
        let recipe = RecipeRig("r2-copy-timeout")
        recipe.shell.dittoThrows = true
        try! operational.publish("demo", "1.2.3", operational.artifact("a.dmg", "abc"))
        let cfg2 = agentConfig(operational, token: tok, apps: ["demo": AppConfig(bundlePath: recipe.installed.path, automatic: true)])
        let client2 = R2Client(operational.server)
        let fake = FakeApp(installed: recipe.installed, running: false, healthy: ["1.2.3"])
        _ = try? Agent.runOnce(config: cfg2, http: client2, shell: recipe.shell, control: { _, _ in fake.control })
        let again = try? Agent.runOnce(config: cfg2, http: client2, shell: recipe.shell, control: { _, _ in fake.control })
        expect(again?.commandsRun == 1 && client2.attempts == 1,
               "R2-10 operational copy timeout does not reject the valid artifact, and the retry reuses it without downloading again")
    }
    run(11) {
        let rig = Rig("r2-old-artifact")
        try! rig.publish("demo", "1.0.0", rig.artifact("a.bin", "old"))
        let old = FeedPublisher.loadFeed(from: rig.feed)!.apps["demo"]!
        try! rig.publish("demo", "2.0.0", rig.artifact("a.bin", "new"))
        let response = rig.server.handleRequest(HTTPRequest(method: "GET", path: "/artifacts/\(old.file)"), remote: "127.0.0.1")
        var verified = false
        if case .file(let file, let size) = response.body { verified = (try? Signing.sha256Hex(fileAt: file).hex) == old.sha256 && size == old.bytes }
        expect(response.status == 200 && verified, "R2-11 republish still serves verified in-flight older artifact")
    }
    run(12) {
        let rig = RecipeRig("r2-config-change", installedVersion: nil)
        makeApp(rig.rollback, version: "1.0.0"); r2Journal(rig, phase: "moving")
        let other = makeApp(rig.apps.appendingPathComponent("Other.app"), version: "9.0.0")
        let wrong = FakeApp(installed: other, running: false, healthy: ["9.0.0"])
        let original = FakeApp(installed: rig.installed, running: false, healthy: ["1.0.0"])
        _ = try? Recipe.recover(installedPath: other.path, stateDir: rig.state.path, app: "foo", control: wrong.control,
                               controlForPath: { path in path == rig.installed.path ? original.control : wrong.control })
        expect(marker(rig.installed) == "1.0.0" && original.running && !wrong.running && marker(other) == "9.0.0",
               "R2-12 config change recovers and launches journal app using journal paths")
        let bad = RecipeRig("r2-wrong-rollback", installedVersion: nil)
        makeApp(bad.rollback, version: "9.0.0"); r2Journal(bad, phase: "moving")
        let app = FakeApp(installed: bad.installed, running: false, healthy: [])
        _ = try? Recipe.recover(installedPath: bad.installed.path, stateDir: bad.state.path, app: "foo", control: app.control)
        expect(!fm.fileExists(atPath: bad.installed.path) && fm.fileExists(atPath: bad.journal.path) && marker(bad.rollback) == "9.0.0",
               "R2-12 recovery refuses wrong-version fallback and keeps journal")
        let unknown = RecipeRig("r2-wrong-installed", installedVersion: "9.0.0"); r2Journal(unknown)
        let unknownApp = FakeApp(installed: unknown.installed, running: false, healthy: ["9.0.0"])
        _ = try? Recipe.recover(installedPath: unknown.installed.path, stateDir: unknown.state.path, app: "foo", control: unknownApp.control)
        expect(fm.fileExists(atPath: unknown.journal.path) && !unknownApp.running,
               "R2-12 unrelated installed version is never accepted as recovered")
        let legacy = RecipeRig("r2-unversioned", installedVersion: "9.0.0")
        try! AtomicFile.writeJSON(InstallJournal(phase: "promoted", installed: legacy.installed.path, staged: "", rollback: legacy.rollback.path,
                                                previousVersion: "1.0.0", wasRunning: true), to: legacy.journal)
        let legacyApp = FakeApp(installed: legacy.installed, running: false, healthy: ["9.0.0"])
        _ = try? Recipe.recover(installedPath: legacy.installed.path, stateDir: legacy.state.path, app: "foo", control: legacyApp.control)
        expect(fm.fileExists(atPath: legacy.journal.path) && !legacyApp.running,
               "R2-12 legacy journal without provable target cannot bless arbitrary installed version")
    }
    run(13) {
        let dir = tmpDir("r2-keygen-race"); let file = dir.appendingPathComponent("private.key")
        let gate = DispatchSemaphore(value: 0), group = DispatchGroup(), lock = NSLock()
        nonisolated(unsafe) var winners: [Data] = []
        for _ in 0..<8 {
            group.enter(); DispatchQueue.global().async {
                let key = Signing.generateKeyPair(); gate.wait()
                do { try Signing.savePrivateKey(key.privateKey, to: file); lock.lock(); winners.append(key.privateKey.rawRepresentation); lock.unlock() } catch {}
                group.leave()
            }
        }
        for _ in 0..<8 { gate.signal() }; group.wait()
        expect(winners.count == 1 && (try? Data(contentsOf: file)) == winners.first,
               "R2-13 concurrent keygen has exactly one successful stored key")
        let cli = try? SystemShell().run(URL(fileURLWithPath: "build/khu").standardizedFileURL.path, arguments: ["keygen", dir.path], timeout: 5)
        expect(cli?.exitCode == 1 && cli?.stdout.contains("public key:") == false,
               "R2-13 losing keygen prints no public key")
    }
    run(14) {
        let executable = URL(fileURLWithPath: "build/khu").standardizedFileURL.path
        let flags: [(String, [String])] = [("publish", ["--feed", "--key", "--app", "--version", "--artifact", "--kind"]),
                                          ("enrol", ["--state", "--machine"]), ("serve", ["--feed", "--state", "--key", "--bind", "--port"]),
                                          ("agent", ["--config"])]
        var safe = true
        for (command, options) in flags { for flag in options {
            let result = try? SystemShell().run(executable, arguments: [command, flag], timeout: 3)
            safe = safe && result?.exitCode == 64 && result?.stderr.contains("needs a value") == true
        } }
        for port in ["abc", "0", "-1", "65536", "999999999999999999999"] {
            let result = try? SystemShell().run(executable, arguments: ["serve", "--port", port], timeout: 3)
            safe = safe && result?.exitCode == 2 && result?.stderr.contains("1 to 65535") == true
        }
        expect(safe, "R2-14 all missing option values and invalid ports exit with diagnostics without crashing")
    }
    run(15) {
        let rig = Rig("r2-dedup"); let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        try! rig.publish("demo", "2.0.0", rig.artifact("a.bin", "abc"))
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: rig.root.appendingPathComponent("A.app").path, recipe: "fake-for-tests")])
        var memory = AgentMemory()
        memory.done["lost-ack"] = AgentMemory.Done(app: "demo", status: "updated", reason: "", at: "2020-01-01T00:00:00Z", sent: true)
        for n in 0..<200 { memory.done["new-\(n)"] = AgentMemory.Done(app: "demo", status: "updated", reason: "", at: "2026-01-01T00:00:00Z", sent: true) }
        let file = URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("agent-memory.json")
        try! AtomicFile.writeJSON(memory, to: file)
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]!.pending = [ServerCommand(id: "lost-ack", machine: "mac1", app: "demo")] }
        let client = R2Client(rig.server)
        let retained = r2Sign(CommandsReply(machine: "mac1", commands: [ServerCommand(id: "lost-ack", machine: "mac1", app: "demo")], automatic: [:]), rig.pair.privateKey)
        client.status = Data("{}".utf8)
        client.commands = retained
        let result = try? Agent.runOnce(config: cfg, http: client)
        let after = try! AtomicFile.readJSON(AgentMemory.self, from: file)!
        expect(result?.commandsRun == 0 && client.attempts == 0 && after.done["lost-ack"] != nil,
               "R2-15 pending done record survives trim before and after latest commands reply")
        let again = try? Agent.runOnce(config: cfg, http: client)
        expect(again?.commandsRun == 0 && client.attempts == 0,
               "R2-15 still-listed done order is re-reported without reinstalling")
    }
    run(16) {
        let rig = Rig("r2-outbox"); let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: [:]); let file = URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("agent-memory.json")
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]!.pending = [ServerCommand(id: "outbox", machine: "mac1", app: "demo")] }
        var memory = AgentMemory(); memory.done["outbox"] = AgentMemory.Done(app: "demo", status: "updated", reason: "", at: ISO.string(Date()), sent: false)
        try! AtomicFile.writeJSON(memory, to: file)
        _ = try? Agent.runOnce(config: cfg, http: R2Client(rig.server))
        let after = try! AtomicFile.readJSON(AgentMemory.self, from: file)!
        let state = try! StateStore.load(from: rig.state).machines["mac1"]!
        expect(after.done["outbox"]?.sent == true && state.pending.isEmpty && state.lastSeen != nil && state.lastResults?["demo"]?.status == "updated",
               "R2-16 missing feed does not block outbox or installed status delivery")
    }
    run(17) {
        let rig = Rig("r2-drip"); let listener = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0)
        let fd = try! listener.listen(); let port = FeedServer.boundPort(fd); let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { close(fd); finished.signal() }
            let c = accept(fd, nil, nil); guard c >= 0 else { return }; defer { close(c) }
            var yes: Int32 = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            _ = HTTP.readRequest(from: c, deadline: 1)
            _ = HTTP.writeAll(c, Data("HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n".utf8))
            for _ in 0..<16 { if !HTTP.writeAll(c, Data("x".utf8)) { break }; Thread.sleep(forTimeInterval: 0.08) }
        }
        var client = URLSessionHTTPClient(); client.timeout = 0.25; client.totalTimeout = 0.35
        let started = Mono.now(); let outcome = Result { try client.get(URL(string: "http://127.0.0.1:\(port)/drip")!, headers: [:]) }
        let elapsed = Mono.now() - started
        if case .failure(let error) = outcome {
            expect("\(error)".contains("did not finish") && elapsed < 1, "R2-17 steady drip is stopped by total transfer deadline")
        } else { expect(false, "R2-17 steady drip is stopped by total transfer deadline") }
        _ = finished.wait(timeout: .now() + 3)
    }
    run(18) {
        let rig = RecipeRig("r2-exe-link")
        let executable = rig.mount.appendingPathComponent("Foo.app/Contents/MacOS/Foo")
        try! Trash.move(executable, into: Trash.root(in: rig.root))
        try! fm.createSymbolicLink(atPath: executable.path, withDestinationPath: "/bin/sleep")
        let app = FakeApp(installed: rig.installed, healthy: ["1.2.3"])
        expect((try? rig.run(app).get()) == nil && app.events.isEmpty,
               "R2-18 symlinked executable refused before staging or quit")
        let ancestor = RecipeRig("r2-exe-parent-link")
        let macos = ancestor.mount.appendingPathComponent("Foo.app/Contents/MacOS")
        let outside = ancestor.root.appendingPathComponent("outside")
        try! fm.moveItem(at: macos, to: outside)
        try! fm.createSymbolicLink(atPath: macos.path, withDestinationPath: outside.path)
        let ancestorApp = FakeApp(installed: ancestor.installed, healthy: ["1.2.3"])
        expect((try? ancestor.run(ancestorApp).get()) == nil && ancestorApp.events.isEmpty,
               "R2-18 executable escaping through symlinked parent refused before quit")
        let alias = rig.root.appendingPathComponent("Alias.app"); try! fm.createSymbolicLink(atPath: alias.path, withDestinationPath: rig.installed.path)
        let cfg = AgentConfig(feedURL: "", publicKey: "", stateDir: rig.state.path, machine: "m", token: "",
                              apps: ["a": AppConfig(bundlePath: rig.installed.path), "b": AppConfig(bundlePath: alias.path)])
        expectThrows("R2-18 real-path aliases cannot configure duplicate apps") { try Agent.validate(cfg) }
        var caseCfg = cfg; caseCfg.apps["b"]?.bundlePath = rig.installed.path.replacingOccurrences(of: "Foo.app", with: "foo.app")
        if fm.fileExists(atPath: caseCfg.apps["b"]!.bundlePath) {
            expectThrows("R2-18 case aliases cannot configure duplicate apps") { try Agent.validate(caseCfg) }
        }
    }
    run(19) {
        let layout = StubLayout(base: tmpDir("r2-link-alias")); makeVersion(layout, "1.0.0", script: "exit 0")
        let binary = try! layout.binary(for: "1.0.0"); let alias = layout.base.appendingPathComponent("alias")
        try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: binary.path)
        try! fm.createSymbolicLink(atPath: alias.path, withDestinationPath: binary.path)
        try! fm.createSymbolicLink(atPath: layout.previousLink.path, withDestinationPath: alias.path)
        expect(StubSwitcher(layout: layout).usablePrevious() == nil && (try? StubSwitcher(layout: layout).switchBack()) == .some(nil),
               "R2-19 previous alias resolving to current binary is not a fallback")
    }
    run(20) {
        let dir = tmpDir("r2-names"); var accepted = true
        let boundary = String(repeating: "a", count: 196)
        do {
            let safe = try SafeName.component(boundary)
            let longest = "." + String(repeating: "b", count: 12) + "-" + safe + ".khu-tmp-" + UUID().uuidString
            accepted = longest.utf8.count <= 255
            _ = try AtomicFile.write(Data("x".utf8), to: dir.appendingPathComponent(String(repeating: "b", count: 12) + "-" + safe))
            let part = dir.appendingPathComponent(safe + ".part")
            try Data("x".utf8).write(to: part)
            accepted = accepted && part.lastPathComponent.utf8.count <= 255
        } catch { accepted = false }
        expect(accepted, "R2-20 maximum accepted name fits the longest atomic derived filename")
        expectThrows("R2-20 overlong wire name rejected before filesystem use") { _ = try SafeName.component(String(repeating: "a", count: 240)) }
        // R3-1: an attach with no mount point is detached by its device, never by the .dmg path.
        do {
            final class AttachNoMount: Shell, @unchecked Sendable {
                var calls: [[String]] = []
                func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
                    calls.append(arguments)
                    if arguments.first == "attach" {
                        let plist = """
                        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>system-entities</key><array>
                        <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
                        <dict><key>dev-entry</key><string>/dev/disk9s1</string></dict></array></dict></plist>
                        """
                        return ShellResult(exitCode: 0, stdout: plist, stderr: "")
                    }
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
            }
            let shell = AttachNoMount()
            expectThrows("R3-1 attach without a mount point fails", contains: "mount point") { _ = try Recipe.attach(shell, "/tmp/x.dmg") }
            let detaches = shell.calls.filter { $0.first == "detach" }
            expect(detaches == [["detach", "/dev/disk9"]], "R3-1 attach without a mount point detaches its whole-disk device, not the .dmg path")
            expect(!Recipe.detach(shell, "/Volumes/KH-STUDIO-ATLAS").isEmpty && shell.calls.filter { $0.first == "detach" } == detaches,
                   "DMG cleanup refuses an SSD volume path without invoking hdiutil")
        }
    }
}

// Owner rollback regressions. Every fixture is a real, ad-hoc-signed app bundle: an unsigned or
// altered bundle is exactly what a rollback must refuse, so the tests have to be able to tell the
// difference. The wire fixtures are raw JSON, so an order without `action` decodes as an update.
func r6App(_ url: URL, version: String, id: String = "com.example.foo", sign: Bool = true) {
    let contents = url.appendingPathComponent("Contents")
    try! fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": id, "CFBundleExecutable": "Foo"]
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let exe = contents.appendingPathComponent("MacOS/Foo")
    try! "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
    chmod(exe.path, 0o755)
    guard sign else { return }
    let signed = try! SystemShell().run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", url.path], timeout: 20)
    precondition(signed.exitCode == 0, "fixture could not be signed: \(signed.stderr)")
}
func r6Version(_ url: URL) -> String { (try? BundleInfo.read(url.path))?.version ?? "none" }

struct R6Rig {
    let rig: Rig
    let config: AgentConfig
    let client: InProcessClient
    let installed: URL
    let previous: URL
    let fake: FakeApp
    init(_ tag: String, kept: String? = "1.0.0", id: String = "com.example.foo", signed: Bool = true,
         recipe: String = "app-dmg", healthy: Set<String> = ["1.0.0", "2.0.0"], automatic: Bool = false) {
        rig = Rig("r6-" + tag)
        installed = rig.root.appendingPathComponent("Applications/Foo.app")
        r6App(installed, version: "2.0.0")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        config = agentConfig(rig, token: token, apps: ["foo": AppConfig(bundlePath: installed.path, recipe: recipe,
                                                                        automatic: automatic, bundleID: "com.example.foo")])
        previous = URL(fileURLWithPath: config.stateDir).appendingPathComponent("rollback-foo/Foo.app")
        if let kept { r6App(previous, version: kept, id: id, sign: signed) }
        try! rig.publish("foo", "2.0.0", rig.artifact("foo.dmg", "current-artifact"), kind: "app-dmg",
                         hold: "http://127.0.0.1:8790/api/maintenance/hold")
        client = InProcessClient(server: rig.server)
        fake = FakeApp(installed: installed, healthy: healthy)
    }
    var memoryFile: URL { URL(fileURLWithPath: config.stateDir).appendingPathComponent("agent-memory.json") }
    var journal: URL { Recipe.journalURL(stateDir: config.stateDir, app: "foo") }
    var control: AppControl {
        var c = fake.control
        c.healthSettle = 0.08; c.healthTimeout = 0.15; c.pollInterval = 0.01
        return c
    }
    /// Queue an order the way the publisher stores one — through the wire type, so the JSON shape
    /// is what an agent really receives.
    func order(_ action: String? = "rollback", app: String = "foo", id: String = UUID().uuidString) {
        var wire: [String: Any] = ["id": id, "machine": "mac1", "app": app, "createdAt": ISO.string(Date())]
        if let action { wire["action"] = action }
        var state = try! JSONSerialization.jsonObject(with: JSON.encode(try! StateStore.load(from: rig.state))) as! [String: Any]
        var machines = state["machines"] as! [String: Any]
        var mac = machines["mac1"] as! [String: Any]
        mac["pending"] = [wire]
        machines["mac1"] = mac
        state["machines"] = machines
        try! AtomicFile.write(JSONSerialization.data(withJSONObject: state), to: StateStore.stateFile(in: rig.state))
    }
    @discardableResult func run() -> AgentRunResult? {
        try? Agent.runOnce(config: config, http: client, shell: RecordingShell(mount: rig.root.appendingPathComponent("empty")),
                           control: { _, _ in control })
    }
    var last: CommandResult? { (try? StateStore.load(from: rig.state))?.machines["mac1"]?.lastResults?["foo"] }
    var memory: AgentMemory? { try? AtomicFile.readJSON(AgentMemory.self, from: memoryFile) }
}

func ownerRollbackTests() {
    // 1. The previous version goes back, through the settled health window, and the version it
    // replaced is kept as the fallback.
    do {
        let r = R6Rig("happy")
        r.order()
        let result = r.run()
        expect(result?.commandsRun == 1 && r.last?.status == "rolled_back_by_owner" && r6Version(r.installed) == "1.0.0"
               && r.control.healthy("1.0.0") && r.fake.events == ["quit", "stop", "launch"],
               "R6-1 owner rollback puts the previous version back and waits for health (\(r.last?.status ?? "none"))")
        expect(r6Version(r.previous) == "2.0.0" && !fm.fileExists(atPath: r.journal.path),
               "R6-1 the version rolled back from is kept as the fallback and the journal is acknowledged")
    }
    // 2. Everything the rollback needs is proven before anything running is touched.
    for (tag, kept, id, phrase) in [("absent", nil, "com.example.foo", "no previous version is kept on this Mac"),
                                    ("wrong-id", "1.0.0", "com.evil.other", "kept bundle is com.evil.other"),
                                    ("equal", "2.0.0", "com.example.foo", "is not older than"),
                                    ("newer", "3.0.0", "com.example.foo", "is not older than")] as [(String, String?, String, String)] {
        let r = R6Rig(tag, kept: kept, id: id)
        r.order()
        r.run()
        expect(r.last?.status == "refused" && r.last?.reason?.contains(phrase) == true && r.fake.events.isEmpty
               && r6Version(r.installed) == "2.0.0",
               "R6-2 \(tag) kept bundle refused before the running app is stopped (\(r.last?.reason ?? "none"))")
    }
    // 3. An unhealthy previous version: the version this Mac was running goes back and is healthy.
    do {
        let r = R6Rig("unhealthy", healthy: ["2.0.0"])
        r.order()
        r.run()
        expect(r.last?.status == "rollback_failed" && r6Version(r.installed) == "2.0.0" && r.control.healthy("2.0.0")
               && !fm.fileExists(atPath: r.journal.path),
               "R6-3 an unhealthy previous version restores the current one and settles (\(r.last?.status ?? "none"))")
    }
    // 4. One shot by id: the report is redelivered, the swap is not repeated.
    do {
        let r = R6Rig("redelivery")
        r.order(id: "r6-once")
        r.client.resultStatus = 500
        r.run()
        let events = r.fake.events
        r.client.resultStatus = nil
        let again = r.run()
        expect(again?.commandsRun == 0 && r.fake.events == events && r.last?.status == "rolled_back_by_owner"
               && r.memory?.done["r6-once"]?.sent == true,
               "R6-4 a redelivered order re-reports the stored result and never swaps twice")
    }
    // 5. An order signed before `action` existed still means update.
    do {
        let r = R6Rig("legacy")
        r.order(nil)
        r.run()
        let old = Data(#"{"id":"old","machine":"mac1","app":"foo","createdAt":"2026-10-25T00:00:00Z"}"#.utf8)
        let decoded = try! JSON.decode(ServerCommand.self, from: old)
        let encoded = try! JSONSerialization.jsonObject(with: JSON.encode(decoded)) as! [String: Any]
        expect(encoded["action"] as? String == "update" && r.last?.status == "current" && r.fake.events.isEmpty,
               "R6-5 an order without action decodes as update (\(r.last?.status ?? "none"))")
    }
    // 6. Automatic must not put the version the owner rolled away from straight back.
    do {
        let r = R6Rig("automatic", automatic: true)
        r.order()
        r.run()
        let sha = FeedPublisher.loadFeed(from: r.rig.feed)!.apps["foo"]!.sha256
        let next = r.run()
        expect(r.memory?.rejected["foo"] == sha && next?.commandsRun == 0 && r.client.downloads == 0
               && r6Version(r.installed) == "1.0.0", "R6-6 the rolled-back-from SHA suppresses Automatic")
        try! r.rig.publish("foo", "3.0.0", r.rig.artifact("foo.dmg", "new-artifact"), kind: "app-dmg")
        let mount = r.rig.root.appendingPathComponent("new-mount")
        makeApp(mount.appendingPathComponent("Foo.app"), version: "3.0.0")
        r.fake.healthyVersions.insert("3.0.0")
        let fresh = try? Agent.runOnce(config: r.config, http: r.client, shell: RecordingShell(mount: mount),
                                       control: { _, _ in r.control })
        expect(fresh?.updates == 1 && r6Version(r.installed) == "3.0.0", "R6-6 a new artifact lets Automatic install again")
    }
    do {
        let r = R6Rig("explicit-retry", automatic: true)
        r.order()
        r.run()
        r.order("update")
        let mount = r.rig.root.appendingPathComponent("retry-mount")
        makeApp(mount.appendingPathComponent("Foo.app"), version: "2.0.0")
        let retry = try? Agent.runOnce(config: r.config, http: r.client, shell: RecordingShell(mount: mount),
                                       control: { _, _ in r.control })
        expect(retry?.updates == 1 && r.memory?.rejected["foo"] == nil && r6Version(r.installed) == "2.0.0",
               "R6-6 an explicit update order clears the rollback rejection")
    }
    // 7. An app the live sources mark as updating itself, and the updater itself: refused, and the
    // app is not touched. A `status` recipe is only that while the feed's kind says so.
    do {
        let r = R6Rig("refuse-status", recipe: "status")
        try! r.rig.publish("foo", "2.1.0", r.rig.artifact("foo-status.dmg", "status-artifact"), kind: "status")
        r.order()
        r.run()
        expect(r.last?.status == "refused" && r.fake.events.isEmpty && r6Version(r.installed) == "2.0.0",
               "R6-7 a status kind refuses an owner rollback (\(r.last?.reason ?? "none"))")
        let upgraded = R6Rig("upgrade-status", recipe: "status")
        upgraded.order()
        upgraded.run()
        expect(upgraded.last?.status == "rolled_back_by_owner" && r6Version(upgraded.installed) == "1.0.0",
               "R6-7 a status recipe is upgraded when the feed offers the app, so its rollback really runs")
    }
    do {
        let r = R6Rig("refuse-updater", recipe: "updater")
        r.order()
        r.run()
        expect(r.last?.status == "refused" && r.fake.events.isEmpty && r6Version(r.installed) == "2.0.0"
               && r.last?.reason?.contains("stub") == true,
               "R6-7 updater refuses an owner rollback (\(r.last?.reason ?? "none"))")
    }
    // 8. An app this Mac does not run, and an action this build does not know: both refused.
    do {
        let r = R6Rig("unknown-app")
        r.order(app: "other")
        r.run()
        let done = r.memory?.done.values.first
        expect(done?.status == "refused" && done?.reason.contains("not configured") == true && r.fake.events.isEmpty,
               "R6-8 a rollback for an app this Mac does not run is refused")
        r.order("explode")
        r.run()
        expect(r.last?.status == "refused" && r.last?.reason?.contains("action") == true && r.fake.events.isEmpty,
               "R6-8 an unknown action fails closed")
        // An app whose earlier swap is still owed is not swapped again on top of it.
        let owed = R6Rig("unresolved")
        r6App(owed.installed, version: "1.0.0")     // the swap that landed before the kill
        r6App(owed.previous, version: "2.0.0")      // the fallback it still owes
        try! AtomicFile.writeJSON(InstallJournal(phase: "rolling_back", installed: owed.installed.path, staged: "",
                                                 rollback: owed.previous.path, previousVersion: "2.0.0",
                                                 wasRunning: true, version: "1.0.0"), to: owed.journal)
        owed.fake.quits = [false]                   // and a version that will not stop
        owed.order()
        owed.run()
        expect(owed.last?.status == "unresolved" && !owed.fake.events.contains("launch")
               && fm.fileExists(atPath: owed.journal.path) && r6Version(owed.installed) == "1.0.0",
               "R6-8 a rollback waits for the swap already owing work on that app (\(owed.last?.status ?? "none"))")
    }
    // 9. The owner route, and who is allowed to receive a rollback order at all.
    do {
        let r = R6Rig("auth")
        let good = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        let body = JSON.encode(["machine": "mac1", "app": "foo"])
        for (name, remote, headers) in [("a remote peer", "100.64.0.9", good),
                                       ("a foreign Host", "127.0.0.1", good.merging(["host": "evil.test"]) { _, b in b }),
                                       ("a foreign Origin", "127.0.0.1", good.merging(["origin": "http://evil.test"]) { _, b in b }),
                                       ("no Origin or Referer", "127.0.0.1", good.filter { $0.key != "origin" })] {
            let reply = r.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-rollback", headers: headers, body: body), remote: remote)
            expect(reply.status == 403, "R6-9 the rollback route refuses \(name)")
        }
        let reply = r.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-rollback", headers: good, body: body), remote: "127.0.0.1")
        expect(reply.status == 200, "R6-9 the owner can queue a rollback")
        func orders(_ suffix: String) -> CommandsReply? {
            let response = r.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=mac1" + suffix,
                headers: ["authorization": "Bearer \(r.config.token)"]), remote: "100.64.0.9")
            let signed = try? JSON.decode(SignedReply.self, from: response.data)
            guard let data = signed?.replyData, let sig = signed?.signatureData,
                  Signing.verify(data, signature: sig, publicKey: r.rig.pair.privateKey.publicKey) else { return nil }
            return try? JSON.decode(CommandsReply.self, from: data)
        }
        expect(orders("")?.commands.isEmpty == true && orders("&capabilities=owner-rollback-v1")?.commands.first?.action == "rollback",
               "R6-10 a rollback order is delivered only to an agent that understands one")
    }
    // 11. An unsigned, altered or unrunnable bundle is never what a rollback runs.
    do {
        let r = R6Rig("unsigned", signed: false)
        r.order()
        r.run()
        expect(r.last?.status == "refused" && r.fake.events.isEmpty && r6Version(r.installed) == "2.0.0",
               "R6-11 an unsigned kept bundle is refused before anything stops")
        let tampered = R6Rig("tampered")
        let exe = tampered.previous.appendingPathComponent("Contents/MacOS/Foo")
        try! ("#!/bin/sh\nexit 0\n# altered\n").write(to: exe, atomically: true, encoding: .utf8)
        tampered.order()
        tampered.run()
        expect(tampered.last?.status == "refused" && tampered.fake.events.isEmpty,
               "R6-11 an altered kept bundle is refused before anything stops")
        let noexe = R6Rig("noexe")
        try! Trash.move(noexe.previous.appendingPathComponent("Contents/MacOS/Foo"), into: Trash.root(in: noexe.rig.root))
        noexe.order()
        noexe.run()
        expect(noexe.last?.status == "refused" && noexe.fake.events.isEmpty, "R6-11 a kept bundle with no executable is refused")
    }
    // 12. Killed mid-swap: the next run finishes it from the journal, answers the same order, and
    // never swaps a second time.
    do {
        let r = R6Rig("kill")
        r.order(id: "r6-killed")
        let setup = r.rig.root.appendingPathComponent("child-config.json")
        try! AtomicFile.writeJSON(r.config, to: setup, permissions: 0o600)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        environment["R6_KILL_CONFIG"] = setup.path
        environment["R6_KILL_PUBLISHER"] = r.rig.root.path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try! child.run()
        child.waitUntilExit()
        expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM
               && fm.fileExists(atPath: r.journal.path),
               "R6-12 a run killed as the swapped bundle launched leaves the owner swap in the journal")
        r.run()
        expect(r6Version(r.installed) == "1.0.0" && r.control.healthy("1.0.0") && r.last?.status == "rolled_back_by_owner"
               && !fm.fileExists(atPath: r.journal.path),
               "R6-12 the next run finishes the interrupted swap and answers its order (\(r.last?.status ?? "none"))")
        let events = r.fake.events
        r.order(id: "r6-killed")
        r.run()
        expect(r.fake.events == events, "R6-12 the recovered order is never carried out a second time")
        // Killed BEFORE the swap: the journal is undone, and the order is answered with what really
        // happened rather than a claim that the previous version is back.
        let early = R6Rig("kill-early")
        early.order(id: "r6-kill-early")
        try! AtomicFile.writeJSON(InstallJournal(phase: "staged", installed: early.installed.path, staged: "",
                                                 rollback: early.previous.path, previousVersion: "2.0.0",
                                                 wasRunning: true, version: "1.0.0", order: "r6-kill-early",
                                                 intent: "owner_rollback"), to: early.journal)
        early.run()
        expect(early.last?.status == "rollback_failed" && r6Version(early.installed) == "2.0.0"
               && early.control.healthy("2.0.0") && !fm.fileExists(atPath: early.journal.path)
               && early.memory?.rejected["foo"] == nil,
               "R6-12 a swap interrupted before it ran is undone and reported as failed, not as done (\(early.last?.status ?? "none"))")
    }

    // === Defect fixes from independent adversarial review (7 findings) ===

    // F1 (major): A failed owner rollback must not mark the feed's current artifact rejected.
    do {
        let r = R6Rig("f1-fail-no-reject", healthy: ["2.0.0"]) // only current version is healthy
        // Publish a NEWER version 3.0.0 in the feed so we can test whether it gets suppressed
        try! r.rig.publish("foo", "3.0.0", r.rig.artifact("foo3.dmg", "artifact-3"), kind: "app-dmg")
        r.fake.healthyVersions.insert("3.0.0")
        r.order()
        r.run()
        // Rollback tried to go to 1.0.0 but failed (only 2.0.0 is healthy).
        expect(r.last?.status == "rollback_failed" && r6Version(r.installed) == "2.0.0",
               "F1 setup: rollback failed as intended (\(r.last?.status ?? "none"))")
        // The feed's current artifact (3.0.0) must NOT be marked rejected
        let feed3SHA = FeedPublisher.loadFeed(from: r.rig.feed)!.apps["foo"]!.sha256
        expect(r.memory?.rejected["foo"] != feed3SHA,
               "F1 failed rollback does NOT mark the feed's current (newer) artifact rejected")
        // Automatic should still be able to install 3.0.0
        var autoCfg = r.config; autoCfg.apps["foo"]?.automatic = true
        let mount3 = r.rig.root.appendingPathComponent("f1-mount")
        makeApp(mount3.appendingPathComponent("Foo.app"), version: "3.0.0")
        let autoRun = try? Agent.runOnce(config: autoCfg, http: r.client,
                                         shell: RecordingShell(mount: mount3),
                                         control: { _, _ in r.control })
        expect(autoRun?.updates == 1 && r6Version(r.installed) == "3.0.0",
               "F1 Automatic installs newer artifact after failed rollback (\(r6Version(r.installed)))")
    }

    // F2 (major): An installed bundle whose seal is broken must still allow rollback to a valid kept bundle.
    do {
        let r = R6Rig("f2-broken-seal")
        let exe = r.installed.appendingPathComponent("Contents/MacOS/Foo")
        try! ("#!/bin/sh\nexit 0\n# altered after signing\n").write(to: exe, atomically: true, encoding: .utf8)
        let verifyBroken = try! SystemShell().run("/usr/bin/codesign",
                                                  arguments: ["--verify", "--strict", r.installed.path], timeout: 20)
        expect(verifyBroken.exitCode != 0, "F2 setup: installed bundle seal is broken")
        r.order()
        r.run()
        expect(r.last?.status == "rolled_back_by_owner" && r6Version(r.installed) == "1.0.0",
               "F2 rollback succeeds when installed bundle has broken seal (\(r.last?.status ?? "none"), reason: \(r.last?.reason ?? "none"))")
    }

    // F2b: An altered KEPT bundle is still refused, with a message naming the kept bundle.
    do {
        let r = R6Rig("f2b-altered-kept")
        let keptExe = r.previous.appendingPathComponent("Contents/MacOS/Foo")
        try! ("#!/bin/sh\nexit 0\n# altered\n").write(to: keptExe, atomically: true, encoding: .utf8)
        r.order()
        r.run()
        expect(r.last?.status == "refused" && r.last?.reason?.contains("kept bundle") == true
               && r.last?.reason?.contains(r.previous.path) == true
               && r.fake.events.isEmpty && r6Version(r.installed) == "2.0.0",
               "F2b altered kept bundle refused with message naming kept path (\(r.last?.reason ?? "none"))")
    }

    // F3+F4 (minor): Recovery records the owed answer using journal.installed, before journal is trashed.
    do {
        let r = R6Rig("f3f4-recovery-early-record")
        r.order(id: "f3f4-order")
        try! AtomicFile.writeJSON(InstallJournal(phase: "promoted", installed: r.installed.path, staged: "",
                                                 rollback: r.previous.path, previousVersion: "2.0.0",
                                                 wasRunning: true, version: "1.0.0", order: "f3f4-order",
                                                 intent: "owner_rollback"), to: r.journal)
        r6App(r.installed, version: "1.0.0")
        r.run()
        expect(r.memory?.done["f3f4-order"]?.status == "rolled_back_by_owner",
               "F3 recovery records owed answer before journal is trashed (\(r.memory?.done["f3f4-order"]?.status ?? "none"))")
        let reason = r.memory?.done["f3f4-order"]?.reason ?? ""
        expect(!reason.contains("is running") || reason.contains("was verified") || reason.contains("found"),
               "F4 recovered answer states only what was verified: \(reason)")
    }

    // F5 (minor): A kill in the "moving" phase preserves the staged bundle for retry.
    do {
        let r = R6Rig("f5-kill-moving")
        r.order(id: "f5-order")
        let stagedURL = r.installed.deletingLastPathComponent().appendingPathComponent(".Foo.app.khu-staging")
        r6App(stagedURL, version: "1.0.0")
        r6App(r.previous, version: "2.0.0")
        try! fm.removeItem(at: r.installed)
        try! AtomicFile.writeJSON(InstallJournal(phase: "moving", installed: r.installed.path, staged: stagedURL.path,
                                                 rollback: r.previous.path, previousVersion: "2.0.0",
                                                 wasRunning: true, version: "1.0.0", order: "f5-order",
                                                 intent: "owner_rollback"), to: r.journal)
        r.run()
        let installedVersion = r6Version(r.installed)
        let stagedSurvived = fm.fileExists(atPath: stagedURL.path)
        let previousHas100 = r6Version(r.previous) == "1.0.0"
        expect(installedVersion == "1.0.0" || stagedSurvived || previousHas100,
               "F5 staged bundle preserved when killed in moving phase (installed=\(installedVersion), staged=\(stagedSurvived), prev=\(r6Version(r.previous)))")
    }

    // F6 (minor): Roll back button is hidden for updater and feed-only apps.
    do {
        let r = R6Rig("f6-updater-btn", recipe: "updater")
        let page = r.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: [:]), remote: "127.0.0.1")
        let html = String(data: page.data, encoding: .utf8) ?? ""
        let hasRollbackForm = html.contains("action=/api/request-rollback") && html.contains("name=app value=\"foo\"")
        let hasDisabledOrHidden = html.contains("disabled") && html.contains("Roll back")
        expect(!hasRollbackForm || hasDisabledOrHidden,
               "F6 Roll back button hidden or disabled for updater app (form=\(hasRollbackForm), disabled=\(hasDisabledOrHidden))")
    }

    // F7 (minor): Server page shows when an agent is too old for rollback. "Too old" means the
    // publisher has no evidence the agent understands a rollback order — which includes an agent
    // that advertises nothing at all, the shape every build before ServerCommand.action has, and
    // the shape of the Hub's own token probe (which must not edit the record, N3).
    do {
        let r = R6Rig("f7-old-agent")
        func requestRollback() {
            _ = r.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-rollback",
                                                       headers: ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790",
                                                                 "content-type": "application/json"],
                                                       body: JSON.encode(["machine": "mac1", "app": "foo"])), remote: "127.0.0.1")
        }
        func orders(_ query: String) -> HTTPResponse {
            r.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=mac1\(query)",
                                                   headers: ["authorization": "Bearer \(r.config.token)"]), remote: "100.64.0.9")
        }
        func warns() -> Bool {
            let page = r.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1:8790"]), remote: "127.0.0.1")
            let html = String(data: page.data, encoding: .utf8) ?? ""
            return html.contains("too old") || html.contains("does not support")
                || html.contains("not capable") || html.contains("upgrade")
                || html.contains("older agent") || html.contains("cannot roll back")
        }
        requestRollback()
        _ = orders("")
        expect((try? StateStore.load(from: r.rig.state))?.machines["mac1"]?.capabilities == nil && warns(),
               "F7 a rollback order is flagged while the agent has advertised nothing at all")
        _ = orders("&capabilities=some-other-capability")
        expect(warns(), "F7 it stays flagged when the agent advertises something else")
        _ = orders("&capabilities=\(AgentCapability.ownerRollback)")
        expect(!warns(), "F7 it clears once the agent says it understands a rollback")
    }
}

// MARK: - Network enrolment windows and removal (owner, 2026-10-25)

/// A publisher whose listener is on a Tailscale address: the one kind of address a Mac can enrol
/// against, and the address its reply has to name. Only the handler is driven — no socket is
/// opened and nothing leaves this Mac.
struct EnrolRig {
    let rig: Rig
    let bind: String
    let port: Int
    let attempts: Int
    let cap: Int
    init(_ tag: String, bind: String = "100.64.0.7", port: Int = 8790,
         attempts: Int = EnrolPolicy.attemptsPerMinute, cap: Int = EnrolPolicy.maxPerWindow) {
        rig = Rig("enrol-" + tag); self.bind = bind; self.port = port; self.attempts = attempts; self.cap = cap
    }
    var server: FeedServer {
        FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: bind, port: port, commandKey: rig.pair.privateKey,
                   maxEnrolmentsPerWindow: cap, enrolAttemptsPerMinute: attempts)
    }
    /// A server with no signing key, which therefore cannot enrol anybody.
    var keylessServer: FeedServer {
        FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: bind, port: port,
                   maxEnrolmentsPerWindow: cap, enrolAttemptsPerMinute: attempts)
    }
    var host: String { "127.0.0.1:\(port)" }
    var origin: String { "http://127.0.0.1:\(port)" }
    var ownerHeaders: [String: String] { ["host": host, "origin": origin, "content-type": "application/json"] }
    var stateBytes: Data { (try? Data(contentsOf: StateStore.stateFile(in: rig.state))) ?? Data() }
    var window: EnrolWindow? { (try? StateStore.load(from: rig.state))?.enrolWindow }
    var machines: [String: MachineState] { (try? StateStore.load(from: rig.state))?.machines ?? [:] }
    var removed: [RemovedMachine] { (try? StateStore.load(from: rig.state))?.removed ?? [] }
    func openWindow(_ minutes: Int) { try? EnrolmentWindow.open(stateDir: rig.state, minutes: minutes) }
}

func enrolNonce() -> String { String((0..<64).map { _ in "0123456789abcdef".randomElement()! }) }

/// The request the Hub makes: JSON body, and an X-Hub-Token header this publisher ignores because
/// nothing here can verify it.
func enrolPost(_ server: FeedServer, machine: String, nonce: String, remote: String = "100.64.0.9",
               hubToken: String? = "ignored-by-design", now: Date? = nil) -> HTTPResponse {
    var headers = ["content-type": "application/json"]
    if let hubToken { headers["x-hub-token"] = hubToken }
    let body = try! JSONSerialization.data(withJSONObject: ["machine": machine, "nonce": nonce])
    return server.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: headers, body: body),
                                remote: remote, now: now ?? Date())
}

/// The report a Mac's agent posts each run.
func enrolStatusPost(_ server: FeedServer, machine: String, token: String,
                     body: [String: Any]) -> HTTPResponse {
    server.handleRequest(HTTPRequest(method: "POST", path: "/status",
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()), remote: "100.64.0.9")
}

/// A result post, on either the order route or the automatic one.
func enrolResultPost(_ server: FeedServer, path: String, token: String, body: [String: Any]) -> HTTPResponse {
    server.handleRequest(HTTPRequest(method: "POST", path: path,
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()), remote: "100.64.0.9")
}

/// Verify a reply the way the Hub does and decode it.
func enrolReply(_ response: HTTPResponse, key: Curve25519.Signing.PrivateKey) -> EnrolReply? {
    guard let signed = try? JSON.decode(SignedReply.self, from: response.data),
          let body = signed.replyData, let signature = signed.signatureData,
          Signing.verify(body, signature: signature, publicKey: key.publicKey) else { return nil }
    return try? JSON.decode(EnrolReply.self, from: body)
}

func enrolOwnerPost(_ r: EnrolRig, _ path: String, _ fields: [String: String], headers: [String: String]? = nil,
                    remote: String = "127.0.0.1") -> HTTPResponse {
    r.server.handleRequest(HTTPRequest(method: "POST", path: path, headers: headers ?? r.ownerHeaders,
                                       body: JSON.encode(fields)), remote: remote)
}


final class CaptureShell: Shell, @unchecked Sendable {
    var calls: [[String]] = []
    var exitCode: Int32 = 0
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        calls.append([executable] + arguments)
        return ShellResult(exitCode: exitCode, stdout: "Agent installed and started.", stderr: exitCode == 0 ? "" : "launchctl said no")
    }
}

func launcherTests() {
    func feedWith(_ apps: [String: FeedApp]) -> Feed { Feed(published_at: ISO.string(Date()), apps: apps) }
    func entry(_ v: String, bundle: String? = nil) -> FeedApp {
        var e = FeedApp(version: v, file: "x.dmg", sha256: String(repeating: "a", count: 64), bytes: 1, kind: "app-dmg")
        e.bundleID = bundle; e.name = bundle.map { "Name of " + $0 }; return e
    }
    let root = tmpDir("ssd-root")
    func ssd(_ apps: [SSDApp]) -> SSDSource {
        for app in apps {
            if let file = app.file, !fm.fileExists(atPath: root.appendingPathComponent(file).path) {
                try! Data("x".utf8).write(to: root.appendingPathComponent(file))
            }
        }
        return SSDSource(volume: "KH-TEST", root: root, index: SSDIndex(apps: apps))
    }

    // L0. The display registry maps every app id to its approved visible name; an unknown id shows as itself.
    do {
        expect(AppNames.display("music-studio") == "Music Studio KH"
               && AppNames.display("hub") == "Hub Studio KH"
               && AppNames.display("gateway") == "Gateway Studio KH"
               && AppNames.display("story") == "Story Studio KH"
               && AppNames.display("updater") == "Studio Launcher KH Helper"
               && AppNames.display("kh-updater-app") == "Update Studio KH"
               && AppNames.display("media-studio") == "Media Studio KH"
               && AppNames.display("printer-studio") == "Printer Studio KH"
               && AppNames.display("no-such-app") == "no-such-app",
               "L0 the registry carries every canonical label (music-studio included) and an unknown id shows as itself")
    }

    // L1. Feed plus SSD, matched by bundle ID; the same version comes from the SSD, an older one does not.
    do {
        let feed = feedWith(["media": entry("0.1.102", bundle: "com.t.media"), "printer": entry("1.0.3", bundle: "com.t.printer")])
        let list = Catalog.build(feed: feed, ssd: [ssd([
            SSDApp(id: "media-ssd", name: "Media", version: "0.1.102", bundleID: "com.t.media", file: "m.dmg", sha256: String(repeating: "a", count: 64)),
            SSDApp(id: "printer", name: "Printer", version: "1.0.2", bundleID: "com.t.printer", file: "p.dmg", sha256: String(repeating: "c", count: 64)),
            SSDApp(id: "hub", name: "Hub Studio KH", version: "0.6.213", bundleID: "com.t.hub", updatesItself: true, setup: "1 Install Apps/Studio Hub"),
            SSDApp(id: "newapp", name: "New App", version: "2.0", bundleID: "com.t.new", file: "n.dmg", sha256: String(repeating: "d", count: 64), icon: ".apps-icons/com.t.new.png"),
        ])])
        let media = list.first { $0.id == "media" }, printer = list.first { $0.id == "printer" }
        let hub = list.first { $0.id == "hub" }, new = list.first { $0.id == "newapp" }
        expect(media?.ssd?.volume == "KH-TEST" && media?.source == "KH-TEST" && media?.name == "Name of com.t.media", "L1 the same version on feed and SSD installs from the SSD")
        expect(printer?.ssd == nil && printer?.source == "Feed" && printer?.available == "1.0.3", "L1 an older SSD copy loses to the feed")
        expect(hub?.updatesItself == true && hub?.ssd == nil && hub?.available == "0.6.213" && hub?.setupFolder?.hasSuffix("1 Install Apps/Studio Hub") == true,
               "L1 an app that updates itself has a version and a setup folder, and nothing to install")
        expect(new?.ssd != nil && new?.name == "New App" && new?.icon?.hasSuffix("com.t.new.png") == true, "L1 an app only on an SSD is listed with its name and icon, with no code change")
        expect(Catalog.build(feed: feedWith(["updater": FeedApp(version: "0.1.3", file: "khu", sha256: String(repeating: "a", count: 64), bytes: 1, kind: "updater")]), ssd: []).isEmpty,
               "L1 the helper itself is not an app on offer")
    }
    // L2. An app installed by hand is found by bundle ID and managed; one that updates itself is reported only.
    do {
        let rig = Rig("discover")
        let apps = rig.root.appendingPathComponent("Applications")
        _ = makeApp(apps.appendingPathComponent("Printer.app"), version: "1.0.2", id: "com.t.printer")
        _ = makeApp(apps.appendingPathComponent("Hub.app"), version: "0.6.213", id: "com.t.hub")
        _ = makeApp(apps.appendingPathComponent("Other.app"), version: "9.0", id: "com.t.unknown")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        try? rig.publish("printer", "1.0.3", rig.artifact("p.zip", "p"))
        let cfg = agentConfig(rig, token: token, apps: [:])
        let source = ssd([SSDApp(id: "printer", name: "Printer", version: "1.0.2", bundleID: "com.t.printer"),
                          SSDApp(id: "hub", name: "Hub", version: "0.6.213", bundleID: "com.t.hub", updatesItself: true)])
        let found = Catalog.discover(config: cfg, known: Catalog.known(in: URL(fileURLWithPath: cfg.stateDir), ssd: [source]), folders: [apps])
        expect(found["printer"]?.recipe == "app-dmg" && found["printer"]?.automatic == true && found["hub"]?.recipe == "status" && found.count == 2,
               "L2 a hand-installed app is managed with Automatic on; one that updates itself is status only; an unknown app is left alone")
        _ = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), ssd: [source], appFolders: [apps])
        let ms = (try? StateStore.load(from: rig.state))?.machines["mac1"]
        expect(ms?.installed["printer"] == "1.0.2" && ms?.installed["hub"] == "0.6.213", "L2 the found apps are reported to the page")
        let later = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), appFolders: [apps])
        expect(later?.apps.contains { $0.app == "printer" && $0.managed } == true, "L2 they stay recognised after the SSD is unplugged")
        // Discovery never hands the helper an app path: it is the binary the stub runs.
        let keptHelper = Catalog.adopting(["updater": AppConfig(bundlePath: "", recipe: "updater")],
                                          discovered: ["updater": AppConfig(bundlePath: apps.appendingPathComponent("Studio Launcher KH.app").path,
                                                                           recipe: "app-dmg")])
        expect(keptHelper["updater"]?.bundlePath == "" && keptHelper["updater"]?.recipe == "updater",
               "L2 the helper's saved recipe and empty path survive discovery of a Launcher app")
        let both = Catalog.discover(config: agentConfig(rig, token: token, apps: ["printer": AppConfig(bundlePath: apps.appendingPathComponent("Printer.app").path)]),
                                    known: Catalog.known(in: URL(fileURLWithPath: cfg.stateDir), ssd: []), folders: [apps])
        expect(both["printer"] == nil, "L2 an app already in the config is not added twice")
        // A renamed app (Studio Hub → Hub Studio KH) keeps its key and the owner's choices: only
        // the path follows the bundle id.
        let renamed = rig.root.appendingPathComponent("RenamedApps")
        _ = makeApp(renamed.appendingPathComponent("Hub Studio KH.app"), version: "0.6.228", id: "com.t.hub")
        let oldHub = AppConfig(bundlePath: apps.appendingPathComponent("Studio Hub.app").path, recipe: "status",
                               automatic: false, bundleID: "com.t.hub")
        let moved = Catalog.adopting(["hub": oldHub], discovered: Catalog.discover(
            config: agentConfig(rig, token: token, apps: [:]), known: Catalog.known(in: URL(fileURLWithPath: cfg.stateDir), ssd: [source]),
            folders: [renamed]))
        expect(moved["hub"]?.bundlePath == renamed.appendingPathComponent("Hub Studio KH.app").path
               && moved["hub"]?.automatic == false && moved["hub"]?.recipe == "status" && moved["hub"]?.bundleID == "com.t.hub",
               "L2b a renamed app is followed by its bundle id, keeping its key, recipe and Automatic choice")
        // That repair is not silent: the run names the missing path and the one it uses instead.
        var repairNotes: [String] = []
        _ = Catalog.adopting(["hub": oldHub], discovered: Catalog.discover(
            config: agentConfig(rig, token: token, apps: [:]), known: Catalog.known(in: URL(fileURLWithPath: cfg.stateDir), ssd: [source]),
            folders: [renamed]), repairs: &repairNotes)
        expect(repairNotes == ["hub: configured bundle path \(oldHub.bundlePath) is missing; using \(renamed.appendingPathComponent("Hub Studio KH.app").path)"],
               "L2b the repaired path is named in one line, with the old and the new path")
    }
    // L3. An SSD install checks the copy's SHA-256 first: a mismatch is refused and changes nothing.
    do {
        let rig = Rig("ssd-install")
        let app = makeApp(rig.root.appendingPathComponent("D.app"), version: "1.0.0", id: "com.t.demo")
        let dmg = rig.artifact("demo.dmg", "ssd-bytes")
        let good = try! Signing.sha256Hex(fileAt: dmg).hex
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "feed-bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests", bundleID: "com.t.demo")])
        func source(_ sha: String) -> SSDSource {
            SSDSource(volume: "KH-TEST", root: dmg.deletingLastPathComponent(),
                      index: SSDIndex(apps: [SSDApp(id: "demo", name: "Demo", version: "2.0.1", bundleID: "com.t.demo", file: "demo.dmg", sha256: sha)]))
        }
        let client = InProcessClient(server: rig.server)
        _ = try? Agent.runOnce(config: cfg, http: client, requested: ["demo"], ssd: [source(String(repeating: "0", count: 64))], appFolders: [])
        let bad = (try? StateStore.load(from: rig.state))?.machines["mac1"]?.lastResults?["demo"]
        expect(bad?.status == "refused" && (bad?.reason ?? "").contains("does not match its checksum") && client.downloads == 0,
               "L3 an SSD copy that does not match its checksum is refused, and nothing is downloaded or installed")
        _ = try? Agent.runOnce(config: cfg, http: client, requested: ["demo"], ssd: [source(good)], appFolders: [])
        let ok = (try? StateStore.load(from: rig.state))?.machines["mac1"]?.lastResults?["demo"]
        expect(ok?.status == "updated" && (ok?.reason ?? "").contains("KH-TEST") && client.downloads == 0, "L3 a matching SSD copy installs with no download")
    }
    // L4. The list shows apps this Mac does not have, from their own records.
    do {
        let rig = Rig("offer")
        try? rig.publish("other", "1.0.0", rig.artifact("o.zip", "o"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: [:])
        let r = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server),
                                   ssd: [ssd([SSDApp(id: "media", name: "Media Studio KH", version: "0.1.102", bundleID: "com.t.media", bundleName: "Media Studio KH.app", file: "m.dmg", sha256: String(repeating: "e", count: 64))])],
                                   appFolders: [])
        let media = r?.apps.first { $0.app == "media" }
        expect(media?.managed == false && media?.installed == nil && media?.available == "0.1.102" && media?.source == "KH-TEST" && media?.name == "Media Studio KH",
               "L4 an app on offer shows its name, newest version and source, and is not managed yet")
    }
    // L7. After the SSD is unplugged, what it said stays: "updates itself" and the icon; nothing becomes installable.
    do {
        let rig = Rig("seen")
        let apps = rig.root.appendingPathComponent("Applications")
        _ = makeApp(apps.appendingPathComponent("Gw.app"), version: "0.2.221", id: "com.t.gw")
        try! fm.createDirectory(at: root.appendingPathComponent(".apps-icons"), withIntermediateDirectories: true)
        try! Data("icon".utf8).write(to: root.appendingPathComponent(".apps-icons/com.t.gw.png"))
        try? rig.publish("other", "1.0.0", rig.artifact("o.zip", "o"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["gateway": AppConfig(bundlePath: apps.appendingPathComponent("Gw.app").path, recipe: "gateway", automatic: true)])
        let source = ssd([SSDApp(id: "gateway", name: "Gateway Studio KH", version: "0.2.223", bundleID: "com.t.gw", updatesItself: true, icon: ".apps-icons/com.t.gw.png"),
                          SSDApp(id: "story", name: "Story Studio KH", version: "1.4.374", bundleID: "com.t.story", updatesItself: true)])
        _ = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), ssd: [source], appFolders: [apps])
        let later = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), appFolders: [apps])
        let gw = later?.apps.first { $0.app == "gateway" }
        expect(gw?.statusOnly == true && gw?.name == "Gateway Studio KH" && gw?.icon?.hasSuffix("icons/com.t.gw.png") == true
               && gw.flatMap { $0.icon.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } } == Data("icon".utf8),
               "L7 with the SSD gone, an app it marked keeps updating itself, its name and its cached icon")
        expect(later?.apps.contains { $0.app == "story" } == false, "L7 an app only an unplugged SSD had is not listed: there is nothing to install")
    }
    // L8. Pause holds a real download where it is; resume finishes it; cancel stops it and rejects nothing.
    withPauseFixture { rig in
        let pauseListener = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0)
        let pauseSocket = try! pauseListener.listen()
        let url = URL(string: "http://127.0.0.1:\(FeedServer.boundPort(pauseSocket))/pause")!
        let pauseReady = DispatchSemaphore(value: 0), releaseBody = DispatchSemaphore(value: 0)
        Thread {
            let client = accept(pauseSocket, nil, nil)
            defer { if client >= 0 { close(client) }; close(pauseSocket) }
            guard client >= 0, HTTP.readRequest(from: client) != nil else { return }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let prefix = Data("HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\nConnection: close\r\n\r\nx".utf8)
            _ = prefix.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            pauseReady.signal()
            guard releaseBody.wait(timeout: .now() + 30) == .success else { return }
            Data(repeating: 120, count: 1 << 20).withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if count <= 0 { break }
                    offset += count
                }
            }
        }.start()
        let out = rig.root.appendingPathComponent("out.part")
        DownloadControl.pause(false)
        var status = 0, failure: Error?
        let done = DispatchSemaphore(value: 0)
        Thread {
            do { status = try URLSessionHTTPClient().download(url, headers: [:], to: out, limit: 1048577) } catch { failure = error }
            done.signal()
        }.start()
        expect(pauseReady.wait(timeout: .now() + 10) == .success, "L8 pause fixture holds an active incomplete download")
        DownloadControl.pause(true)
        releaseBody.signal()
        let size = { ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        let held = done.wait(timeout: .now() + 0.5) == .timedOut
        expect(held && size() <= 1, "L8 while paused the file stops growing before the controlled body is written")
        DownloadControl.pause(false)
        let finished = done.wait(timeout: .now() + 10) == .success
        expect(finished && status == 200 && failure == nil && size() == 1048577, "L8 resume finishes the download")
        // Hold an incomplete response so Cancel always reaches an active transfer, even from cache.
        let cancelListener = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0)
        let cancelSocket = try! cancelListener.listen()
        let cancelURL = URL(string: "http://127.0.0.1:\(FeedServer.boundPort(cancelSocket))/slow")!
        let responseReady = DispatchSemaphore(value: 0), releaseResponse = DispatchSemaphore(value: 0)
        Thread {
            let client = accept(cancelSocket, nil, nil)
            defer { if client >= 0 { close(client) }; close(cancelSocket) }
            guard client >= 0, HTTP.readRequest(from: client) != nil else { return }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let prefix = Data("HTTP/1.1 200 OK\r\nContent-Length: 419430400\r\nConnection: close\r\n\r\nx".utf8)
            _ = prefix.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            responseReady.signal()
            _ = releaseResponse.wait(timeout: .now() + 30)
        }.start()
        let second = rig.root.appendingPathComponent("out2.part")
        var cancelled: Error?
        let done2 = DispatchSemaphore(value: 0)
        Thread {
            do { _ = try URLSessionHTTPClient().download(cancelURL, headers: [:], to: second, limit: 400 << 20) } catch { cancelled = error }
            done2.signal()
        }.start()
        expect(responseReady.wait(timeout: .now() + 10) == .success, "L8 cancellation fixture has an active incomplete response")
        DownloadControl.cancel()
        let stopped = done2.wait(timeout: .now() + 10) == .success
        releaseResponse.signal()
        expect(stopped && "\(cancelled.map { "\($0)" } ?? "")".contains("cancelled on this Mac"), "L8 Cancel stops the download and says so")
        DownloadControl.pause(false)
    }
    // L9. What's New follows the version on offer; the control window shows only where it is installed.
    do {
        var feedApp = FeedApp(version: "1.0.2", file: "p.dmg", sha256: String(repeating: "a", count: 64), bytes: 1, kind: "app-dmg", notes: "- feed notes for 1.0.2")
        feedApp.bundleID = "com.t.p"
        var newer = SSDApp(id: "printer", name: "P", version: "1.0.3", bundleID: "com.t.p", file: "p3.dmg", sha256: String(repeating: "b", count: 64)); newer.notes = "- ssd notes for 1.0.3"
        var same = SSDApp(id: "printer", name: "P", version: "1.0.2", bundleID: "com.t.p", file: "p2.dmg", sha256: String(repeating: "a", count: 64)); same.notes = nil
        let feed = Feed(published_at: ISO.string(Date()), apps: ["printer": feedApp])
        expect(Catalog.build(feed: feed, ssd: [ssd([newer])]).first?.notes == "- ssd notes for 1.0.3", "L9 a newer SSD copy shows its own What's New")
        expect(Catalog.build(feed: feed, ssd: [ssd([same])]).first?.notes == "- feed notes for 1.0.2", "L9 the same version from an SSD keeps the feed's What's New")
        let readme = root.appendingPathComponent("README.md")
        try! "# P 1.0.3\n\n## What's new in 1.0.3\n- Adds A4\n- Shows mm and inches\n\n## Install\n- not this\n".write(to: readme, atomically: true, encoding: .utf8)
        expect(SSDIndexer.whatsNew(in: readme, version: "1.0.3") == "- Adds A4\n- Shows mm and inches" && SSDIndexer.whatsNew(in: readme, version: "1.0.2") == nil,
               "L9 the SSD index reads a folder README's What's new for that version only")
        let rig = Rig("main-only")
        try? rig.publish("other", "1.0.0", rig.artifact("o.zip", "o"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        var control = SSDApp(id: "kh-updater-app", name: "Update Studio KH", version: "1.0.4", bundleID: "com.t.ctl", bundleName: "U.app", file: "u.dmg", sha256: String(repeating: "d", count: 64))
        control.mainMacOnly = true
        let apps = rig.root.appendingPathComponent("Applications")
        let r1 = try? Agent.runOnce(config: agentConfig(rig, token: token, apps: [:]), http: InProcessClient(server: rig.server), ssd: [ssd([control])], appFolders: [apps])
        expect(r1 != nil && r1?.apps.contains { $0.app == "kh-updater-app" } == false, "L9 the control window is not offered on a Mac that does not have it")
        _ = makeApp(apps.appendingPathComponent("U.app"), version: "1.0.4", id: "com.t.ctl")
        let r2 = try? Agent.runOnce(config: agentConfig(rig, token: token, apps: [:]), http: InProcessClient(server: rig.server), ssd: [ssd([control])], appFolders: [apps])
        expect(r2 != nil && r2?.apps.contains { $0.app == "kh-updater-app" } == false,
               "L9 a retired app is removed from the Launcher list even when its bundle is still on disk")
    }
    // L5. Publishing records the app's own name, bundle ID and icon; a DMG of another version is refused.
    do {
        let rig = Rig("publish-meta")
        let meta: (String) throws -> AppMeta = { _ in AppMeta(name: "Media Studio KH", bundleID: "com.t.media", bundleName: "Media Studio KH.app", version: "1.0.0", iconPNG: Data("png".utf8)) }
        try? FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "media", version: "1.0.0", artifact: rig.artifact("m.dmg", "m"), kind: "app-dmg", allowSame: false, meta: meta)
        let e = (try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey))??.apps["media"]
        let iconFile = e?.icon.map { rig.feed.appendingPathComponent("artifacts").appendingPathComponent($0) }
        expect(e?.name == "Media Studio KH" && e?.bundleID == "com.t.media" && e?.bundleName == "Media Studio KH.app"
               && iconFile.flatMap { try? Signing.sha256Hex(fileAt: $0).hex } == e?.iconSha256 && e?.iconSha256 != nil,
               "L5 the feed carries the app's name, bundle ID, bundle name and a checked icon")
        expectThrows("L5 a DMG that holds another version is refused", contains: "holds version 1.0.0") {
            try FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "media", version: "1.0.1", artifact: rig.artifact("m2.dmg", "m2"), kind: "app-dmg", allowSame: false, meta: meta)
        }
        expectThrows("W1 a DMG that cannot be read is refused", contains: "cannot be read") {
            try FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "media", version: "1.0.2", artifact: rig.artifact("m6.dmg", "m6"), kind: "app-dmg", allowSame: false,
                                      meta: { _ in throw khuFail("unreadable") })
        }
        try? FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "media", version: "1.0.2", artifact: rig.artifact("m3.dmg", "m3"), kind: "app-dmg", allowSame: false, meta: nil)
        let kept = (try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey))??.apps["media"]
        let words = AppWords(tagline: "Photos and labels", description: "D", features: [AppFeature(title: "One library", text: "t")], accent: "#2a7")
        try? FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "media", version: "1.0.3", artifact: rig.artifact("m4.dmg", "m4"), kind: "app-dmg", allowSame: false,
                                   words: words, meta: nil)
        try? FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "media", version: "1.0.4", artifact: rig.artifact("m5.dmg", "m5"), kind: "app-dmg", allowSame: false, meta: nil)
        let worded = (try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey))??.apps["media"]
        expect(worded?.tagline == "Photos and labels" && worded?.features?.first?.title == "One library" && worded?.accent == "#2a7" && worded?.released != nil,
               "L5 a release's tagline, description, features and accent are stored, and carried to the next release that names none")
        let list = Catalog.build(feed: Feed(published_at: ISO.string(Date()), apps: ["media": worded!]), ssd: [])
        expect(list.first?.words.tagline == "Photos and labels", "L5 the Launcher's card reads those words from the feed")
        expect(kept?.version == "1.0.2" && kept?.bundleID == "com.t.media" && kept?.icon == e?.icon, "L5 a release with no DMG to read keeps the earlier name, ID and icon")
    }
    // W7. Labels never move identity; two Macs may have the same label.
    do {
        let rig = Rig("rename")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "old-mac")
        _ = try! Enrolment.enrol(stateDir: rig.state, machine: "taken-mac")
        let before = (try! StateStore.load(from: rig.state)).machines["old-mac"]!
        try! Enrolment.rename(stateDir: rig.state, machine: "old-mac", to: "taken-mac")
        try! Enrolment.rename(stateDir: rig.state, machine: "old-mac", to: "taken-mac")
        let machines = (try! StateStore.load(from: rig.state)).machines
        let renamed = machines["old-mac"]!
        expect(machines.count == 2 && renamed.machine == "old-mac" && renamed.name == "taken-mac"
               && renamed.tokenHash == Enrolment.sha256Hex(token) && renamed.pending == before.pending
               && renamed.enrolledAt == before.enrolledAt, "W7 rename keeps identity, token, enrolment and orders")
        expect(renamed.history?.count == 1 && renamed.history?.first?.reason == "Renamed from old-mac", "W7 rename history occurs once")
        expect(rig.server.statusHTML().contains("same name"), "W7 duplicate labels remain visible with a warning")
        let response = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"], body: Data(#"{"machine":"old-mac","installed":{}}"#.utf8)), remote: "100.64.0.9")
        expect(response.status == 200, "W7 the unchanged enrolment still reports after rename")
    }
    // W8. A reported rename follows the Mac; a page label survives unchanged reports.
    do {
        let rig = Rig("reported-name")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "stable-id")
        func report(_ name: String) -> Int {
            let body = try! JSONSerialization.data(withJSONObject: ["machine": "stable-id", "display_name": name])
            return rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"], body: body), remote: "100.64.0.9").status
        }
        expect(report("mac-one") == 200 && report("mac-one") == 200, "W8 repeated names report successfully")
        var ms = (try! StateStore.load(from: rig.state)).machines["stable-id"]!
        expect(ms.name == "mac-one" && ms.history?.count == 1, "W8 a reported rename appears once")
        try! Enrolment.rename(stateDir: rig.state, machine: "stable-id", to: "page-label")
        _ = report("mac-one")
        ms = (try! StateStore.load(from: rig.state)).machines["stable-id"]!
        expect(ms.name == "page-label", "W8 an unchanged report preserves a page label")
        _ = report("mac-two")
        ms = (try! StateStore.load(from: rig.state)).machines["stable-id"]!
        expect(ms.name == "mac-two" && ms.machine == "stable-id" && ms.tokenHash == Enrolment.sha256Hex(token), "W8 changing the Mac name keeps enrolment identity")
        let before = ms
        expect(report(String(repeating: "x", count: SafeName.maxBytes + 1)) == 400, "W8 an oversized reported name is refused")
        expect((try! StateStore.load(from: rig.state)).machines["stable-id"] == before, "W8 a refused report leaves the record intact")
        let home = rig.root.appendingPathComponent("home"), apps = rig.root.appendingPathComponent("Applications")
        let hub = apps.appendingPathComponent("Studio Hub.app")
        let settings = home.appendingPathComponent("Library/Application Support/StudioHub Standalone/hub/controller_settings.json")
        try! FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name") == "Computer Name", "W8 no Hub settings falls back to the computer name")
        try! Data(#"{"controller_id":"hub-machine-id"}"#.utf8).write(to: settings)
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name") == "hub-machine-id", "W8 a Hub Machine ID wins")
        try! Data(#"{"controller_id":"changed-hub-id"}"#.utf8).write(to: settings)
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name") == "changed-hub-id", "W8 the name is read live after a change")
        let labels = settings.deletingLastPathComponent().appendingPathComponent("machine_labels.json")
        try! Data(#"{"local":"Human Mac 1103","other-id":"Not this Mac"}"#.utf8).write(to: labels)
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name", expectedMachine: "changed-hub-id") == "Human Mac 1103",
               "W8 a matching Hub controller reports its local human label without replacing the connection ID")
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name", expectedMachine: "different-enrolment") == "changed-hub-id",
               "W8 a different controller cannot donate its human label to this enrolment")
        try! Data(#"{"local":"Human Mac 1409"}"#.utf8).write(to: labels)
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name", expectedMachine: "changed-hub-id") == "Human Mac 1409",
               "W8 Hub human-label edits are read live")
        try! Data(#"{"local":""}"#.utf8).write(to: labels)
        expect(MacName.current(home: home, applications: apps, computerName: "Computer Name", expectedMachine: "changed-hub-id", hostName: "short-host.local") == "short-host",
               "W8 a cleared alias uses Hub’s short-hostname fallback, separately from the computer name")
    }
    // W9. The owner route validates and escapes labels, and keeps the same token.
    do {
        let rig = Rig("owner-label")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "stable-id")
        let body = try! JSONSerialization.data(withJSONObject: ["machine": "stable-id", "name": "Sam's Mac <script>"])
        let good = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        var foreign = good; foreign["origin"] = "http://attacker.example"
        expect(rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/rename-machine", headers: foreign, body: body), remote: "127.0.0.1").status == 403, "W9 a foreign origin cannot rename a Mac")
        expect(rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/rename-machine", headers: good, body: body), remote: "100.64.0.9").status == 403, "W9 another Mac cannot rename labels")
        expect(rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/rename-machine", headers: good, body: body), remote: "127.0.0.1").status == 200, "W9 the local owner can rename a label")
        let page = rig.server.statusHTML()
        expect(page.contains("&lt;script&gt;") && !page.contains("Mac <script>"), "W9 labels are escaped in the row and input")
        let invalid = try! JSONSerialization.data(withJSONObject: ["machine": "stable-id", "name": "bad\nname"])
        expect(rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/rename-machine", headers: good, body: invalid), remote: "127.0.0.1").status == 400, "W9 control characters are refused")
        expect(!MacName.valid("a" + String(repeating: "\u{0301}", count: MacName.maxCharacters)), "W9 combining marks cannot evade the input length bound")
        expect(MacName.valid("ម៉ាក់របស់ខ្ញុំ") && MacName.valid("Sam's Mac") && !MacName.valid("") && !MacName.valid(String(repeating: "x", count: MacName.maxCharacters + 1)), "W9 Mac names support languages and punctuation within the visible bound")
        expect((try! StateStore.load(from: rig.state)).machines["stable-id"]?.tokenHash == Enrolment.sha256Hex(token), "W9 the owner route keeps the token")
    }
    // W. What's New has one source: each app's CHANGELOG. Publish refuses anything else.
    do {
        let rig = Rig("whats-new")
        func changelog(_ name: String, _ text: String) -> URL {
            let url = rig.root.appendingPathComponent(name)
            try! Data(text.utf8).write(to: url)
            return url
        }
        let good = changelog("good.md", "# Changelog\n\nIntro.\n\n## 1.2.0 — 2026-11-02\n\n- First\n\n- Second\n\n## 1.1.0 — 2026-10-01\n- Older\n")
        expect((try? ReleaseNotes.forRelease(changelog: good, version: "1.2.0", extra: nil)) == "- First\n- Second", "W2 the notes are the top entry's lines and no other's")
        expect((try? ReleaseNotes.forRelease(changelog: good, version: "1.2.0", extra: "Not tested on printer hardware")) == "- First\n- Second\n- Not tested on printer hardware",
               "W2 one optional extra line is added after them")
        expectThrows("W3 an entry for another version is refused", contains: "the top entry of") { _ = try ReleaseNotes.forRelease(changelog: good, version: "1.3.0", extra: nil) }
        expectThrows("W3 a heading with no date is refused", contains: "is not") {
            _ = try ReleaseNotes.forRelease(changelog: changelog("nodate.md", "## 1.2.0\n- x\n"), version: "1.2.0", extra: nil)
        }
        expectThrows("W3 another heading style is refused", contains: "is not") {
            _ = try ReleaseNotes.forRelease(changelog: changelog("style.md", "## [1.2.0] - November 2026\n- x\n"), version: "1.2.0", extra: nil)
        }
        expectThrows("W3 an entry with no lines is refused", contains: "has no") {
            _ = try ReleaseNotes.forRelease(changelog: changelog("empty.md", "## 1.2.0 — 2026-11-02\nProse only.\n"), version: "1.2.0", extra: nil)
        }
        expectThrows("W3 a missing changelog is refused", contains: "cannot read") {
            _ = try ReleaseNotes.forRelease(changelog: rig.root.appendingPathComponent("none.md"), version: "1.2.0", extra: nil)
        }
        let plain = changelog("plain.md", "## 2.0.0 — 2026-11-02\n\n### Studios come back\n\nProse.\n\n### Technical notes\n\n- **Internal**\n\n## 1.9.0 — 2026-11-01\n\n- Dash\n\n### Technical\n\n- Hidden\n")
        expect((try? ReleaseNotes.entries(of: plain).map(\.notes)) == ["- Studios come back", "- Dash"], "W2 plain headings count as lines, and technical notes stay out")
        let repo = rig.root.appendingPathComponent("repo")
        try! fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try! fm.copyItem(at: good, to: repo.appendingPathComponent("CHANGELOG.md"))
        expect((try? ReleaseNotes.entries(of: repo).first?.version) == "1.2.0", "W4 a repository folder means its CHANGELOG.md")
        expect((try? ReleaseNotes.entries(of: changelog("v.md", "## v1.4.374 — 2026-11-01\n- x\n")).first?.version) == "1.4.374", "W4 a leading v on the version is read")

        let khu = URL(fileURLWithPath: "build/khu").standardizedFileURL.path
        let art = rig.artifact("w.zip", "w").path
        func publish(_ more: [String]) -> ShellResult? {
            try? SystemShell().run(khu, arguments: ["publish", "--feed", rig.feed.path, "--key", rig.key.path, "--app", "w", "--version", "1.2.0", "--artifact", art, "--kind", "fake-for-tests", "--new-app"] + more, timeout: 10)
        }
        let quiet = publish([]), typed = publish(["--notes", "- typed"]), wrong = publish(["--changelog", changelog("old.md", "## 1.1.0 — 2026-10-01\n- Older\n").path])
        expect(quiet?.exitCode != 0 && quiet?.stderr.contains("needs --changelog") == true, "W5 publish with no changelog is refused")
        expect(typed?.exitCode != 0 && typed?.stderr.contains("--notes is gone") == true, "W5 free-typed notes are refused")
        expect(wrong?.exitCode != 0 && wrong?.stderr.contains("is 1.1.0, not 1.2.0") == true && FeedPublisher.loadFeed(from: rig.feed)?.apps["w"] == nil,
               "W5 a changelog on another version publishes nothing")
        let done = publish(["--changelog", good.path, "--note", "One extra"])
        expect(done?.exitCode == 0 && FeedPublisher.loadFeed(from: rig.feed)?.apps["w"]?.notes == "- First\n- Second\n- One extra", "W5 the right changelog is signed into the feed")

        // The SSD says what the feed says, and any other version says its own entry.
        let volume = rig.root.appendingPathComponent("ssd")
        func onSSD(_ version: String) { _ = makeApp(volume.appendingPathComponent("1 Install Apps/W/W.app"), version: version, id: "com.t.w") }
        let feed = FeedPublisher.loadFeed(from: rig.feed)
        onSSD("1.2.0")
        expect((try? SSDIndexer.index(volume: volume, feed: feed, changelogs: ["w": good]))?.apps.first?.notes == "- First\n- Second\n- One extra", "W6 the SSD's notes match the feed's for the same version")
        onSSD("1.1.0")
        expect((try? SSDIndexer.index(volume: volume, feed: feed, changelogs: ["w": good]))?.apps.first?.notes == "- Older", "W6 an SSD on another version shows that version's entry")
        onSSD("1.0.0")
        let noEntry = (try? SSDIndexer.index(volume: volume, feed: feed, changelogs: ["w": good]))?.apps.first
        expect(noEntry?.version == "1.0.0" && noEntry?.notes == nil, "W6 a version with no entry has no notes, not another version's")
    }
    // L6. The front door: wrong code refused with the publisher's reason; right code installs through the kit's own script.
    do {
        let r = EnrolRig("front-door")
        try! Enrolment.ensurePairingCode(stateDir: r.rig.state)
        let code = (try! StateStore.load(from: r.rig.state)).pairing!.code
        let kit = r.rig.root.appendingPathComponent("kit")
        try! fm.createDirectory(at: kit, withIntermediateDirectories: true)
        let pub = try! JSONSerialization.data(withJSONObject: ["feedURL": "http://\(r.bind):\(r.port)/release.json", "enrolURL": "http://\(r.bind):\(r.port)/enrol",
                                                              "publicKey": r.rig.pair.publicKeyBase64, "testAuthority": false])
        try! pub.write(to: kit.appendingPathComponent("publisher.json"))
        try! Data("#!/bin/bash\n".utf8).write(to: kit.appendingPathComponent("install-agent.sh"))
        func manifest() {
            var files: [String: Any] = [:]
            for n in ["publisher.json", "install-agent.sh"] { let d = try! Data(contentsOf: kit.appendingPathComponent(n)); files[n] = ["bytes": d.count, "sha256": Signing.sha256Hex(d)] }
            try! JSONSerialization.data(withJSONObject: ["files": files]).write(to: kit.appendingPathComponent("MANIFEST.json"))
        }
        manifest()
        let home = r.rig.root.appendingPathComponent("home")
        let client = InProcessClient(server: r.server), shell = CaptureShell()
        expectThrows("L6 a wrong code is refused with the publisher's own reason", contains: "pairing code is wrong") {
            _ = try Connect.run(kit: kit, home: home, machine: "new-mac", code: code == "000000" ? "000001" : "000000", http: client, shell: shell)
        }
        expect(shell.calls.isEmpty, "L6 nothing is installed after a refusal")
        _ = try? Connect.run(kit: kit, home: home, machine: "new-mac", code: code, http: client, shell: shell)
        let call = shell.calls.first ?? []
        expect(call.count == 4 && call[1].hasSuffix("install-agent.sh") && call[3] == home.path, "L6 the right code runs the kit's install-agent.sh for this home")
        expect(r.machines["new-mac"]?.enrolmentSource == MachineState.pairingSource, "L6 the Mac is enrolled by pairing")
        let leftover = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent("Library").path))?.filter { $0.hasPrefix(".khu-connect") && $0.hasSuffix(".json") } ?? ["?"]
        expect(leftover.isEmpty, "L6 the temporary config holding the token is moved to _trash, not left in Library")
        expect(fm.fileExists(atPath: home.appendingPathComponent("Library/.khu-connect.lock").path),
               "L6 the stable connection lock stays for concurrent retries")
        try! Data("#!/bin/bash\necho changed\n".utf8).write(to: kit.appendingPathComponent("install-agent.sh"))
        expectThrows("L6 a kit changed on the drive is refused before anything is sent", contains: "was changed") {
            _ = try Connect.run(kit: kit, home: r.rig.root.appendingPathComponent("home2"), machine: "other-mac", code: code, http: client, shell: shell)
        }
        expect(r.machines["other-mac"] == nil, "L6 a refused kit enrols nothing")
    }
}

func helperTests() {
    let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
    func setPage(_ rig: Rig, _ app: String, _ on: Bool) {
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/automatic", headers: owner,
            body: Data(#"{"machine":"mac1","app":"\#(app)","on":\#(on ? "true" : "false")}"#.utf8)), remote: "127.0.0.1")
    }
    func record(_ rig: Rig) -> MachineState? { (try? StateStore.load(from: rig.state))?.machines["mac1"] }
    func page(_ rig: Rig) -> String {
        String(data: rig.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1:8790"]), remote: "127.0.0.1").data, encoding: .utf8) ?? ""
    }
    func setup(_ tag: String, page: Bool? = nil) -> (Rig, AgentConfig, InProcessClient) {
        let rig = Rig("helper-" + tag)
        let app = makeApp(rig.root.appendingPathComponent("H.app"), version: "1.0.0")
        let hub = makeApp(rig.root.appendingPathComponent("Hub.app"), version: "0.6.213", id: "com.example.hub")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests"),
                                                         "hub": AppConfig(bundlePath: hub.path, recipe: "hub", automatic: true)])
        if let page { setPage(rig, "demo", page) }
        return (rig, cfg, InProcessClient(server: rig.server))
    }
    func local(_ cfg: AgentConfig, _ on: Bool, at: Date, paused: Date? = nil) {
        let dir = URL(fileURLWithPath: cfg.stateDir)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! HelperSettings(automatic: ["demo": .init(on: on, at: ISO.string(at))], pausedUntil: paused.map(ISO.string)).save(to: dir)
    }

    // H1. The later of the Mac's switch and the page's wins; a page value with no time is older.
    do {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(60)
        let mine = HelperSettings(automatic: ["a": .init(on: true, at: ISO.string(t1))])
        expect(mine.automatic("a", page: false, pageAt: ISO.string(t0), config: false)
               && !mine.automatic("a", page: false, pageAt: ISO.string(t1.addingTimeInterval(1)), config: true)
               && mine.automatic("a", page: false, pageAt: nil, config: false)
               && mine.automatic("a", page: nil, pageAt: nil, config: false)
               && mine.automatic("a", page: false, pageAt: ISO.string(t1), config: false)
               && !HelperSettings().automatic("a", page: nil, pageAt: nil, config: false)
               && HelperSettings().automatic("a", page: true, pageAt: nil, config: false),
               "H1 the later switch wins, a tie is the Mac's, a timeless page value counts as older, and the config is the fallback")
    }
    // H2. A switch on the Mac turns Automatic on, reaches the page in one report, and the reply carries its time.
    do {
        let (rig, cfg, client) = setup("h2", page: false)
        local(cfg, true, at: Date().addingTimeInterval(1))
        let r = try? Agent.runOnce(config: cfg, http: client)
        expect(r?.commandsRun == 1 && r?.updates == 1, "H2 a later switch on the Mac wins over the page's off and installs")
        let ms = record(rig)
        expect(ms?.automatic["demo"] == true && ms?.automaticSet?["demo"]?.byMac == true, "H2 the page has the Mac's switch after one report, marked as the Mac's")
        expect(page(rig).contains("changed on this Mac"), "H2 the page says the setting was changed on this Mac")
        let reply = rig.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=mac1", headers: ["authorization": "Bearer \(cfg.token)"]), remote: "100.64.0.9")
        let body = (try? JSONDecoder().decode(SignedReply.self, from: reply.data))?.replyData
        let orders = body.flatMap { try? JSONDecoder().decode(CommandsReply.self, from: $0) }
        expect(orders?.automatic["demo"] == true && orders?.automaticAt?["demo"] != nil, "H2 the signed reply says when the setting was made")
    }
    // H3. A later change on the page wins over an earlier switch on the Mac, there and on the Mac.
    do {
        let (rig, cfg, client) = setup("h3")
        local(cfg, true, at: Date().addingTimeInterval(-60))
        setPage(rig, "demo", false)
        let r = try? Agent.runOnce(config: cfg, http: client)
        expect(r?.commandsRun == 0 && r?.apps.first { $0.app == "demo" }?.automatic == false, "H3 the page's later off wins on the Mac")
        expect(record(rig)?.automatic["demo"] == false && record(rig)?.automaticSet?["demo"]?.byMac == false,
               "H3 the Mac's older switch does not overwrite the page's later change")
    }
    // H4. A pause holds Automatic; "Update now" from the menu still runs; the page shows the pause.
    do {
        let (rig, cfg, client) = setup("h4")
        local(cfg, true, at: Date(), paused: Date().addingTimeInterval(24 * 3600))
        let held = try? Agent.runOnce(config: cfg, http: client)
        expect(held?.commandsRun == 0, "H4 while paused nothing installs by itself")
        expect(record(rig)?.pausedUntil != nil && page(rig).contains("Automatic paused on this Mac until"),
               "H4 the pause reaches the publisher and the page says so")
        var seen: [String?] = []
        let now = try? Agent.runOnce(config: cfg, http: client, requested: ["demo"], installing: { seen.append($0) })
        expect(now?.updates == 1 && seen == ["demo", nil], "H4 Update now installs while paused, and says it is updating while it does")
        expect(record(rig)?.lastResults?["demo"]?.commandId.hasPrefix("auto-demo-menu-") == true, "H4 the result reaches the page as this Mac's own update")
        local(cfg, true, at: Date(), paused: Date().addingTimeInterval(-1))
        _ = try? Agent.runOnce(config: cfg, http: client)
        expect(record(rig)?.pausedUntil == nil, "H4 an ended pause is cleared on the page")
    }
    // H5. The menu shows each app's state; a legacy hub recipe is a managed app now, while an app
    // only the live sources mark as updating itself still has no switch.
    do {
        let (_, cfg, client) = setup("h5")
        let r = try? Agent.runOnce(config: cfg, http: client)
        let demo = r?.apps.first { $0.app == "demo" }, hub = r?.apps.first { $0.app == "hub" }
        expect(demo?.installed == "1.0.0" && demo?.available == "2.0.0" && demo?.status == HelperApp.updateAvailable && demo?.automatic == false,
               "H5 an app behind the feed is Update available")
        expect(hub?.statusOnly == false && hub?.automatic == true && hub?.status == HelperApp.notInFeed,
               "H5 a legacy hub recipe is a managed app with its switch, never a self-updating stub")
        let failed = HelperApp.status(installed: "1.0.0", available: "2.0.0", statusOnly: false, last: ("rolled_back", "not healthy"))
        let terminal = HelperApp.status(installed: "1.0.0", available: "2.0.0", statusOnly: false,
                                        last: ("rolled_back", "not healthy"), consecutiveFailures: HelperApp.failureCeiling)
        let current = HelperApp.status(installed: "2.0.0", available: "2.0.0", statusOnly: false, last: ("failed", "old"))
        expect(failed.0 == HelperApp.failed && failed.1 == "not healthy" && current.0 == HelperApp.upToDate && current.1 == nil
               && terminal.0 == HelperApp.needsAttention && terminal.1 == "not healthy"
               && HelperApp.status(installed: nil, available: nil, statusOnly: false, last: nil).0 == HelperApp.notInstalled,
               "H5 a failure shows with its reason until the app is current, and reaches Needs attention at the ceiling")
        var failedRow = HelperApp(app: "demo", installed: "1.0.0", available: "2.0.0", statusOnly: false, automatic: false, status: HelperApp.failed, reason: "boom")
        expect(HelperApp.updateAllEligible(failedRow), "H5b failed rows below ceiling count toward Update all")
        failedRow.status = HelperApp.needsAttention
        expect(!HelperApp.updateAllEligible(failedRow), "H5b terminal Needs attention rows do not count toward Update all")

        // H5c Agent.snapshot counts consecutive failures per offered version and resets on a new release,
        // and installUpdater refuses a direct downgrade.
        let rigC = Rig("ceiling")
        try? rigC.publish("demo", "2.0.0", rigC.artifact("d2.dmg", "d2"))
        let feedC = try! FeedPublisher.loadVerifiedFeed(from: rigC.feed, publicKey: rigC.pair.privateKey.publicKey)!
        var memC = AgentMemory()
        for idx in 1...HelperApp.failureCeiling {
            memC.done["cmd-\(idx)"] = AgentMemory.Done(app: "demo", status: "failed", reason: "attempt \(idx)",
                                                       at: "2026-11-18T00:0\(idx):00Z", sent: true, version: "2.0.0")
        }
        let cfgC = agentConfig(rigC, token: "unused", apps: ["demo": AppConfig(bundlePath: rigC.root.appendingPathComponent("D.app").path, recipe: "fake-for-tests")])
        _ = makeApp(URL(fileURLWithPath: cfgC.apps["demo"]!.bundlePath), version: "1.0.0", id: "com.example.demo")
        let snapTerminal = Agent.snapshot(config: cfgC, feed: feedC, catalog: [], orders: CommandsReply(machine: "mac1", commands: [], automatic: [:]),
                                          helper: HelperSettings(), memory: memC, executable: nil,
                                          http: InProcessClient(server: rigC.server), serverBase: URL(string: "http://pub.test")!,
                                          stateDir: URL(fileURLWithPath: cfgC.stateDir))
        expect(snapTerminal.first?.status == HelperApp.needsAttention, "H5c three consecutive failures put the row in Needs attention")
        try? rigC.publish("demo", "2.0.1", rigC.artifact("d21.dmg", "d21"))
        let feedC2 = try! FeedPublisher.loadVerifiedFeed(from: rigC.feed, publicKey: rigC.pair.privateKey.publicKey)!
        let snapNewer = Agent.snapshot(config: cfgC, feed: feedC2, catalog: [], orders: CommandsReply(machine: "mac1", commands: [], automatic: [:]),
                                       helper: HelperSettings(), memory: memC, executable: nil,
                                       http: InProcessClient(server: rigC.server), serverBase: URL(string: "http://pub.test")!,
                                       stateDir: URL(fileURLWithPath: cfgC.stateDir))
        expect(snapNewer.first?.status == HelperApp.failed && snapNewer.first.map(HelperApp.updateAllEligible) == true,
               "H5c a newer offered version resets the ceiling and the row is retryable again")
        let baseStub = rigC.root.appendingPathComponent("stub")
        let layoutStub = StubLayout(base: baseStub)
        let curBin = try! layoutStub.binary(for: "0.1.59")
        try! fm.createDirectory(at: curBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\nexit 0\n".write(to: curBin, atomically: true, encoding: .utf8)
        chmod(curBin.path, 0o755)
        try! StubSwitcher(layout: layoutStub).install(version: "0.1.59")
        var cfgStub = cfgC; cfgStub.stubBase = baseStub.path
        let olderEntry = FeedApp(version: "0.1.58", file: "khu", sha256: String(repeating: "a", count: 64), bytes: 1, kind: "updater")
        let downStub = try? Agent.installUpdater(olderEntry, artifact: curBin, config: cfgStub)
        expect(downStub?.status == "refused" && (downStub?.reason ?? "").contains("no downgrade"),
               "H5d installUpdater refuses a direct downgrade (\(downStub?.reason ?? "nil"))")
    }
    // H6. A report with too many switches is refused and changes nothing.
    do {
        let (rig, cfg, _) = setup("h6")
        let many = Dictionary(uniqueKeysWithValues: (0...ReportPolicy.maxApps).map { ("a\($0)", ["on": true, "at": ISO.string(Date())] as [String: Any]) })
        let reply = enrolStatusPost(rig.server, machine: "mac1", token: cfg.token, body: ["machine": "mac1", "automatic_local": many])
        expect(reply.status == 400 && record(rig)?.automatic.isEmpty == true, "H6 an unbounded list of switches is refused")
    }
    // H9. A row says where its Automatic value came from, in the one rule's own words, and carries a
    // drive's refusal reason through to the row that shows it. Nothing here decides a second policy.
    do {
        // (a) A switch on this Mac, later than the controller's, is the value, and the row says so.
        let (rig, cfg, client) = setup("h9a", page: false)
        local(cfg, true, at: Date().addingTimeInterval(1))
        let mine = try? Agent.runOnce(config: cfg, http: client)
        expect(mine?.apps.first { $0.app == "demo" }?.automatic == true
               && mine?.apps.first { $0.app == "demo" }?.automaticOrigin == HelperSettings.AutomaticOrigin.mac.words,
               "H9a the value is this Mac's later switch, and the row names it")
        // (b) A later change on the controller's page is the value, and the row says that instead.
        local(cfg, true, at: Date().addingTimeInterval(-60))
        setPage(rig, "demo", false)
        let theirs = try? Agent.runOnce(config: cfg, http: client)
        expect(theirs?.apps.first { $0.app == "demo" }?.automatic == false
               && theirs?.apps.first { $0.app == "demo" }?.automaticOrigin == HelperSettings.AutomaticOrigin.page.words,
               "H9b the value is the controller's later change, and the row names it")
        expect(theirs?.apps.first { $0.app == "hub" }?.automaticOrigin == HelperSettings.AutomaticOrigin.config.words,
               "H9c a legacy hub recipe is managed, and its value names this Mac's default")
        // (d) Neither has said anything: this Mac's own configured default, named in the same words.
        let (_, plain, plainClient) = setup("h9d")
        let fallback = try? Agent.runOnce(config: plain, http: plainClient)
        expect(fallback?.apps.first { $0.app == "demo" }?.automaticOrigin == HelperSettings.AutomaticOrigin.config.words,
               "H9d with neither rule having a value, the row names this Mac's default")
        let at = "2026-11-11T00:00:00Z"
        let echoed = HelperSettings(automatic: ["demo": .init(on: true, at: at)])
        let same = echoed.automaticDecision("demo", page: true, pageAt: at, config: false)
        let conflict = echoed.automaticDecision("demo", page: false, pageAt: at, config: true)
        expect(same.on && same.origin == .mac && conflict.on && conflict.origin == .mac,
               "H9e an echoed Mac switch keeps its origin; an equal-time page value is not provably later, so this Mac's switch wins")
        // (f) A drive's copy that cannot be used keeps its own reason on the row that shows it.
        let root = tmpDir("h9-ssd")
        let bytes = Data("demo installer bytes".utf8)
        try! bytes.write(to: root.appendingPathComponent("Demo.dmg"))
        let sha = Signing.sha256Hex(bytes)
        var copy = SSDApp(id: "demo", name: "Demo", version: "2.0.0", bundleID: "com.example.demo",
                          bundleName: "H.app", file: "Demo.dmg", sha256: sha)
        copy.bytes = Int64(bytes.count)
        var served = FeedApp(version: "2.0.0", file: "demo.zip", sha256: sha, bytes: Int64(bytes.count), kind: "app-dmg")
        served.bundleID = "com.example.demo"; served.bundleName = "H.app"
        let drive = SSDSource(volume: "ATLAS", root: root, index: SSDIndex(apps: [copy]))
        var wrongBytes = copy
        wrongBytes.sha256 = String(repeating: "0", count: 64)
        let refused = Catalog.build(feed: Feed(published_at: ISO.string(Date()), apps: ["demo": served]),
                                    ssd: [SSDSource(volume: "ATLAS", root: root, index: SSDIndex(apps: [wrongBytes]))])
            .first { $0.id == "demo" }
        expect(refused?.ssd == nil && refused?.ssdNote?.hasPrefix("The copy on ATLAS is not the bytes") == true,
               "H9f a copy that is not the signed bytes is refused with its reason in plain words")
        let used = Catalog.build(feed: Feed(published_at: ISO.string(Date()), apps: ["demo": served]), ssd: [drive])
        let rig9 = Rig("h9g")
        let cfg9 = agentConfig(rig9, token: "unused", apps: ["demo": AppConfig(bundlePath: root.appendingPathComponent("H.app").path, recipe: "fake-for-tests")])
        let rows = Agent.snapshot(config: cfg9, feed: Feed(published_at: ISO.string(Date()), apps: ["demo": served]),
                                  catalog: used, orders: try! JSONDecoder().decode(CommandsReply.self,
                                      from: Data(#"{"machine":"mac1","at":"2026-11-09T00:00:00Z","commands":[],"automatic":{}}"#.utf8)),
                                  helper: HelperSettings(), memory: AgentMemory(), executable: nil,
                                  http: InProcessClient(server: rig9.server),
                                  serverBase: URL(string: "http://pub.test/artifacts")!,
                                  stateDir: URL(fileURLWithPath: cfg9.stateDir))
        expect(rows.first { $0.app == "demo" }?.ssdNote == nil,
               "H9g a copy that can be used carries no refusal to show")
    }
    // H8. The apps that update themselves are listed under Apps & updates with the newest version a Mac has.
    do {
        let (rig, cfg, client) = setup("h8")
        _ = try? Agent.runOnce(config: cfg, http: client)
        let html = page(rig)
        expect(html.contains("Hub Studio KH</td><td class=num>0.6.213") && html.contains("<span class=sub>Updates itself</span></td></tr>"),
               "H8 Hub Studio KH is listed with the version its Mac has, and updates itself")
        expect(html.contains("Story Studio KH</td><td class=num>—") && html.contains("No connected Mac reports it"), "H8 Story Studio KH is listed even when no Mac reports it, and says so")
    }
    // H7. The helper's What's New comes from this changelog.
    expect(!WhatsNew.lines(for: "0.1.2").isEmpty && WhatsNew.lines(for: "9.9.9").isEmpty, "H7 the helper's What's New is its changelog entry")
}

func pairingTests() {
    func post(_ server: FeedServer, _ machine: String, _ code: Any, nonce: String = enrolNonce(), now: Date = Date()) -> HTTPResponse {
        let body = try! JSONSerialization.data(withJSONObject: ["machine": machine, "nonce": nonce, "code": code])
        return server.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: ["content-type": "application/json"], body: body),
                                    remote: "100.64.0.9", now: now)
    }
    func text(_ r: HTTPResponse) -> String { String(data: r.data, encoding: .utf8) ?? "" }
    func rig(_ tag: String) -> (EnrolRig, FeedServer, PairingCode) {
        let r = EnrolRig(tag)
        try! Enrolment.ensurePairingCode(stateDir: r.rig.state)
        return (r, r.server, (try! StateStore.load(from: r.rig.state)).pairing!)
    }
    func wrong(_ p: PairingCode) -> String { p.code == "000000" ? "000001" : "000000" }

    // PC1. The right code enrols at any time, with no window, with or without the dash.
    do {
        let (r, server, p) = rig("pc1")
        expect(p.code.count == 6 && p.shown.count == 7 && r.window == nil, "PC1 a publisher has a six-digit code and no window")
        let reply = post(server, "mac-a", p.shown)
        let signed = enrolReply(reply, key: r.rig.pair.privateKey)
        expect(reply.status == 200 && signed?.machine == "mac-a" && !(signed?.token ?? "").isEmpty, "PC1 the right code gets a signed token with no window")
        expect(r.machines["mac-a"]?.tokenHash == signed.map { Enrolment.sha256Hex($0.token) } && r.machines["mac-a"]?.enrolmentSource == MachineState.pairingSource,
               "PC1 only the token's hash is stored, and the record says it came by pairing")
        expect(post(server, "mac-b", p.code).status == 200, "PC1 the code works again, without the dash, for the next Mac")
        expect((try? Enrolment.ensurePairingCode(stateDir: r.rig.state)) != nil && (try! StateStore.load(from: r.rig.state)).pairing?.code == p.code,
               "PC1 restarting keeps the code")
    }
    // PC2. A wrong code is refused, makes no record and gets no token, with or without a window open.
    do {
        let (r, server, p) = rig("pc2")
        let reply = post(server, "mac-a", wrong(p))
        expect(reply.status == 403 && text(reply).contains("4 tries left") && r.machines.isEmpty, "PC2 a wrong code is refused and says how many tries are left")
        expect(post(server, "mac-a", 123456).status == 403 && r.machines.isEmpty, "PC2 a code that is not text is a wrong code")
        r.openWindow(30)
        expect(post(server, "mac-a", wrong(p)).status == 403 && r.machines.isEmpty, "PC2 a wrong code is refused even while a window is open")
    }
    // PC3. Five wrong codes lock it, the right code included, until the lock ends; a right code resets the count.
    do {
        let (r, server, p) = rig("pc3")
        let start = Date()
        for _ in 1...4 { _ = post(server, "mac-a", wrong(p), now: start) }
        expect(post(server, "mac-a", p.code, now: start).status == 200, "PC3 four wrong tries do not lock")
        for _ in 1...4 { _ = post(server, "mac-b", wrong(p), now: start) }
        let fifth = post(server, "mac-b", wrong(p), now: start)
        expect(fifth.status == 429 && r.machines["mac-b"] == nil, "PC3 the count restarted after the right code, and the fifth wrong try locks")
        let during = start.addingTimeInterval(Double(EnrolPolicy.pairingLockMinutes) * 60 - 1)
        expect(post(server, "mac-b", p.code, now: during).status == 429 && r.machines["mac-b"] == nil, "PC3 while locked even the right code is refused")
        let page = String(data: server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": r.host]), remote: "127.0.0.1").data, encoding: .utf8) ?? ""
        expect(page.contains("Pairing locked</span>") && page.contains("No code is accepted until then.")
               && !page.contains("Ready to connect</span>"), "PC3 both connection views show the active lock instead of a ready state")
        let after = start.addingTimeInterval(Double(EnrolPolicy.pairingLockMinutes) * 60 + 1)
        expect(post(server, "mac-b", p.code, now: after).status == 200, "PC3 the right code works when the lock ends")
    }
    // PC4. A valid pairing code replaces an existing enrolment (owner 2026-11-13): the old token
    // stops working, the new one reports, and the Mac's page keeps an audit line. A window claim
    // without a code is still refused, and a wrong code never says which ids are enrolled.
    do {
        let (r, server, p) = rig("pc4")
        let firstNonce = enrolNonce()
        let first = enrolReply(post(server, "mac-a", p.code, nonce: firstNonce), key: r.rig.pair.privateKey)
        _ = enrolStatusPost(server, machine: "mac-a", token: first!.token, body: ["machine": "mac-a"])
        let again = post(server, "mac-a", p.code, nonce: enrolNonce())
        let second = enrolReply(again, key: r.rig.pair.privateKey)
        expect(again.status == 200 && second?.token != first?.token
               && r.machines["mac-a"]?.tokenHash == second.map { Enrolment.sha256Hex($0.token) },
               "PC4 a valid pairing code replaces an existing enrolment with a new token")
        expect(enrolStatusPost(server, machine: "mac-a", token: first!.token, body: ["machine": "mac-a"]).status == 401,
               "PC4 the replaced token is revoked")
        expect(enrolStatusPost(server, machine: "mac-a", token: second!.token, body: ["machine": "mac-a"]).status == 200,
               "PC4 the new token reports normally")
        expect(r.machines["mac-a"]?.history?.contains { $0.status == "paired again" } == true,
               "PC4 the replacement is kept as an audit line on the Mac's page")
        // An open allow-a-Mac window enrols a NEW Mac; it must never take over one that is enrolled
        // (audit, 2026-11-18): anything on the tailnet reaches /enrol while a window is open.
        r.openWindow(30)
        let windowClaim = enrolPost(server, machine: "mac-a", nonce: enrolNonce())
        expect(windowClaim.status == 409,
               "PC4 an open window cannot replace an enrolled Mac")
        expect(enrolStatusPost(server, machine: "mac-a", token: second!.token, body: ["machine": "mac-a"]).status == 200,
               "PC4 the enrolled Mac keeps the token it had")
        expect(r.machines["mac-a"]?.history?.filter { $0.status == "paired again" }.count == 1,
               "PC4 only the code replacement is audited")
        expect(r.window?.enrolled == 0, "PC4 the refused claim spends no window slot")
        expect(post(server, "mac-c", wrong(p)).status == 403 && post(server, "mac-a", wrong(p)).status == 403,
               "PC4 a wrong code never says which ids are enrolled")
        // A lost reply can still be resent by the same claim before it reports.
        let (rr, rserver, _) = rig("pc4-resend")
        rr.openWindow(30)
        let nonce = enrolNonce()
        let a = enrolReply(enrolPost(rserver, machine: "mac-b", nonce: nonce), key: rr.rig.pair.privateKey)
        let b = enrolReply(enrolPost(rserver, machine: "mac-b", nonce: nonce), key: rr.rig.pair.privateKey)
        expect(a != nil && b != nil && a?.token != b?.token,
               "PC4 the same window claim resent before it reports gets a fresh token")
    }
    // PC5. No code and no window is refused; no code with a window works as before and spends the window.
    do {
        let (r, server, _) = rig("pc5")
        expect(enrolPost(server, machine: "hub-a", nonce: enrolNonce()).status == 403 && r.machines.isEmpty, "PC5 no code and no window is refused")
        r.openWindow(30)
        expect(enrolPost(server, machine: "hub-a", nonce: enrolNonce()).status == 200 && r.machines["hub-a"]?.enrolmentSource == MachineState.windowSource && r.window?.enrolled == 1,
               "PC5 Hub's bootstrap, with no code, still enrols through a window")
    }
    // PC6. The code shows on the owner's page only; New code replaces it and leaves Macs connected.
    do {
        let (r, server, p) = rig("pc6")
        let req = HTTPRequest(method: "GET", path: "/", headers: ["host": r.host])
        let page = String(data: server.handleRequest(req, remote: "127.0.0.1").data, encoding: .utf8) ?? ""
        expect(page.contains(p.shown) && page.contains("data-confirm=\"New code?") && !page.contains("/api/enrol-window"), "PC6 the page shows the code and New code asks first")
        let remote = server.handleRequest(req, remote: "100.64.0.9")
        expect(remote.status == 403 && !text(remote).contains(p.shown), "PC6 a device on the tailnet is not shown the code")
        expect(!text(post(server, "mac-x", wrong(p))).contains(p.code), "PC6 a refusal never repeats the code")
        expect(post(server, "mac-a", p.code).status == 200, "PC6 a Mac connects")
        expect(enrolOwnerPost(r, "/api/pairing-code", [:], remote: "100.64.0.9").status == 403
               && enrolOwnerPost(r, "/api/pairing-code", [:], headers: ["host": r.host, "origin": "http://evil.example"]).status == 403
               && (try! StateStore.load(from: r.rig.state)).pairing?.code == p.code, "PC6 New code is refused from the tailnet and from another site")
        expect(enrolOwnerPost(r, "/api/pairing-code", [:]).status == 200, "PC6 New code works from the page")
        let next = (try! StateStore.load(from: r.rig.state)).pairing!
        expect(next.code != p.code && post(server, "mac-b", p.code).status == 403 && post(server, "mac-b", next.code).status == 200 && r.machines["mac-a"] != nil,
               "PC6 the old code stops working, the new one works, and connected Macs stay")
        let mode = (try? FileManager.default.attributesOfItem(atPath: StateStore.stateFile(in: r.rig.state).path))?[.posixPermissions] as? Int
        expect(mode == 0o600, "PC6 the file holding the code is private")
    }
    // PC7. The signed reply names the address the Mac used: the tailnet host from its Host header,
    // the bind address when it reached that, and never a foreign host.
    do {
        let (r, server, p) = rig("pc7")
        func reply(host: String?) -> EnrolReply? {
            var headers = ["content-type": "application/json"]
            if let host { headers["host"] = host }
            let body = try! JSONSerialization.data(withJSONObject: ["machine": "mac-a", "nonce": enrolNonce(), "code": p.code])
            return enrolReply(server.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: headers, body: body), remote: "100.64.0.9"),
                              key: r.rig.pair.privateKey)
        }
        expect(reply(host: "host.tail1234.ts.net:8790")?.feedURL == "http://host.tail1234.ts.net:8790/release.json",
               "PC7 a Mac reaching the publisher by tailnet name gets that name in the signed reply")
        expect(reply(host: "100.64.0.7:8790")?.feedURL == "http://100.64.0.7:8790/release.json",
               "PC7 a Mac reaching the bind address gets the bind address")
        expect(reply(host: "evil.example:8790")?.feedURL == "http://100.64.0.7:8790/release.json",
               "PC7 a foreign Host is never echoed")
    }
}

func enrolWindowTests() {
    // E1. Closed is the default: a publisher nobody opened a window on enrols no one.
    do {
        let r = EnrolRig("e1-closed")
        let reply = enrolPost(r.server, machine: "mac1", nonce: enrolNonce())
        let text = String(data: reply.data, encoding: .utf8) ?? ""
        expect(reply.status == 403 && text.contains("window") && (try? JSON.decode(SignedReply.self, from: reply.data)) == nil,
               "E1 a refused /enrol is a plain sentence, never something that verifies (got \(reply.status))")
        expect(r.stateBytes.isEmpty && r.machines.isEmpty && r.window == nil,
               "E1 a publisher that has never had a window has no state to change")
    }

    // E2. An open window mints a token, and the reply is what the Mac needs.
    do {
        let r = EnrolRig("e2-mint")
        r.openWindow(30)
        let n = enrolNonce()
        let response = enrolPost(r.server, machine: "studio-new", nonce: n)
        let payload = enrolReply(response, key: r.rig.pair.privateKey)
        expect(response.status == 200 && payload != nil, "E2 an open window mints a token (\(response.status))")
        expect(payload?.machine == "studio-new" && payload?.nonce == n,
               "E2 the signed reply echoes the machine and the nonce it was asked about")
        expect(payload?.feedURL == "http://100.64.0.7:8790/release.json" && payload?.publicKey == r.rig.pair.publicKeyBase64,
               "E2 the reply names the feedURL and public key that publisher.json states")
        let issued = payload?.issuedAt ?? 0
        expect(abs(issued - Int(Date().timeIntervalSince1970)) <= 5, "E2 issuedAt is now, in unix seconds (\(issued))")
        expect((payload?.token.count ?? 0) >= 32 && response.data.count <= 16 * 1024,
               "E2 the token is at least 32 characters and the reply fits the Hub's 16 KiB (\(response.data.count) bytes)")
        let stored = r.machines["studio-new"]
        let text = String(data: r.stateBytes, encoding: .utf8) ?? ""
        expect(stored?.tokenHash == Enrolment.sha256Hex(payload?.token ?? "") && !text.contains(payload?.token ?? "!"),
               "E2 the token is stored as its sha256 only, never the token itself")
        expect(stored?.enrolmentSource == MachineState.windowSource && stored?.enrolledAt != nil && r.window?.enrolled == 1,
               "E2 the enrolment is recorded as a window enrolment with its time, and counted")
        let use = r.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(payload!.token)"], body: Data(#"{"machine":"studio-new"}"#.utf8)), remote: "100.64.0.9")
        expect(use.status == 200, "E2 the token the reply carried is the one the Mac now reports with (\(use.status))")
        expect(enrolPost(r.server, machine: "studio-2", nonce: enrolNonce(), hubToken: nil).status == 200,
               "E2 the X-Hub-Token header is ignored: a request without one enrols just the same")
    }

    // E3. Without a code or an open window an enrolled Mac is refused and its token is not rotated;
    // an open window enrols a NEW Mac and never takes over one that is already enrolled.
    do {
        let r = EnrolRig("e3-taken")
        let real = try! Enrolment.enrol(stateDir: r.rig.state, machine: "mac1")
        let hash = r.machines["mac1"]?.tokenHash
        let reply = enrolPost(r.server, machine: "mac1", nonce: enrolNonce())
        expect(reply.status == 403, "E3 an enrolled Mac with no code and no window is refused (\(reply.status))")
        expect(String(decoding: reply.data, as: UTF8.self).contains("open enrolment window"),
               "E3 reconnect refusal names the code or window recovery in plain words")
        expect(r.machines["mac1"]?.tokenHash == hash && r.window == nil,
               "E3 the refused Mac's token is NOT rotated and no window was counted")
        let use = r.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(real)"], body: Data(#"{"machine":"mac1"}"#.utf8)), remote: "100.64.0.9")
        expect(use.status == 200, "E3 the Mac's real token still works after a tailnet device tried to take its place")
        r.openWindow(30)
        let claim = enrolPost(r.server, machine: "mac1", nonce: enrolNonce())
        expect(claim.status == 409 && r.machines["mac1"]?.tokenHash == hash,
               "E3 an open window cannot take over the enrolled Mac (\(claim.status))")
        expect(enrolStatusPost(r.server, machine: "mac1", token: real, body: ["machine": "mac1"]).status == 200,
               "E3 the enrolled Mac keeps working through a window it did not ask for")
        expect(r.window?.enrolled == 0, "E3 the refused claim spends no window slot")
        expect(enrolPost(r.server, machine: "mac-new", nonce: enrolNonce()).status == 200,
               "E3 the same window still enrols a genuinely new Mac")
        _ = try? Enrolment.enrol(stateDir: r.rig.state, machine: "mac1")
        expect(r.machines["mac1"]?.tokenHash != hash,
               "E3 re-enrolment on the publisher itself is what rotates a token")
    }

    // E4. The window expires, and an end time that cannot be read is not an open window.
    do {
        let r = EnrolRig("e4-expiry")
        try! StateStore.update(in: r.rig.state) { state in
            state.enrolWindow = EnrolWindow(openedAt: ISO.string(Date().addingTimeInterval(-3600)),
                                            until: ISO.string(Date().addingTimeInterval(-1)), minutes: 30, enrolled: 3)
        }
        expect(enrolPost(r.server, machine: "mac1", nonce: enrolNonce()).status == 403, "E4 an expired window refuses /enrol")
        try! StateStore.update(in: r.rig.state) { $0.enrolWindow = EnrolWindow(openedAt: ISO.string(Date()), until: "not a date", minutes: 30) }
        expect(enrolPost(r.server, machine: "mac1", nonce: enrolNonce()).status == 403,
               "E4 an end time that cannot be read is closed, never open")
        r.openWindow(1)
        expect(r.window?.isOpen() == true && enrolPost(r.server, machine: "mac1", nonce: enrolNonce()).status == 200,
               "E4 a window opened for one minute is open")
        // The end time is what closes it, through the real route rather than a flag beside it.
        let timed = EnrolRig("e4-time")
        let timedServer = timed.server
        timed.openWindow(1)
        let late = enrolPost(timedServer, machine: "mac-late", nonce: enrolNonce(), now: Date().addingTimeInterval(61))
        expect(late.status == 403 && timed.machines.isEmpty,
               "E4 a window opened for one minute refuses a Mac that arrives after it (\(late.status))")
        expect(enrolPost(timedServer, machine: "mac-in-time", nonce: enrolNonce()).status == 200,
               "E4 the same window still enrols a Mac that arrives inside it")
        try! EnrolmentWindow.close(stateDir: r.rig.state)
        expect(r.window == nil && enrolPost(r.server, machine: "mac2", nonce: enrolNonce()).status == 403,
               "E4 closing drops the record and /enrol is refused again")
    }

    // E5. Machine ids, nonces and body sizes that are not what was agreed are refused.
    do {
        let r = EnrolRig("e5-inputs")
        r.openWindow(30)
        let before = r.stateBytes
        let ids = ["../evil", "", ".hidden", String(repeating: "a", count: 240), "mac/1"]
        let idStatuses = ids.map { enrolPost(r.server, machine: $0, nonce: enrolNonce()).status }
        expect(idStatuses.allSatisfy { $0 == 400 }, "E5 a machine id that is not a name is refused (\(idStatuses))")
        let nonces = ["short", String(repeating: "z", count: 64), "", String(repeating: "a", count: 63)]
        var nonceStatuses = nonces.map { enrolPost(r.server, machine: "mac1", nonce: $0).status }
        nonceStatuses.append(r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol",
            headers: ["content-type": "application/json"], body: Data(#"{"machine":"mac1"}"#.utf8)), remote: "100.64.0.9").status)
        expect(nonceStatuses.allSatisfy { $0 == 400 }, "E5 a nonce that is not 64 hex characters is refused (\(nonceStatuses))")
        let big = r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: [:],
                                                     body: Data(repeating: 32, count: 64 << 10)), remote: "100.64.0.9")
        let form = r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: [:],
                                                     body: Data("machine=mac1&nonce=\(enrolNonce())".utf8)), remote: "100.64.0.9")
        expect(big.status == 413 && form.status == 400,
               "E5 an oversize body and a body that is not JSON are refused (\(big.status), \(form.status))")
        let method = r.server.handleRequest(HTTPRequest(method: "GET", path: "/enrol?machine=mac1&nonce=\(enrolNonce())",
                                                         headers: [:]), remote: "100.64.0.9")
        expect(method.status == 404 && r.machines.isEmpty,
               "E5 /enrol is POST only: a browser tab or a probe cannot enrol by asking (\(method.status))")
        expect(r.stateBytes == before && r.machines.isEmpty && r.window?.enrolled == 0,
               "E5 every refusal above left the state exactly as it was")
    }

    // E6. The window's cap: a scripted flood cannot fill the state.
    do {
        let r = EnrolRig("e6-cap", cap: 2)
        r.openWindow(60)
        let statuses = ["mac1", "mac2", "mac3"].map { enrolPost(r.server, machine: $0, nonce: enrolNonce()).status }
        expect(statuses == [200, 200, 429], "E6 the window's cap refuses the Mac past it (\(statuses))")
        expect(r.machines.count == 2 && r.window?.enrolled == 2, "E6 a refused flood writes nothing into state")
        r.openWindow(60)
        expect(r.window?.enrolled == 0 && enrolPost(r.server, machine: "mac3", nonce: enrolNonce()).status == 200,
               "E6 a new window starts its own count")

        // Four Macs arriving at the same instant cannot get past a cap of one: the check and the
        // mint are one transaction under the state lock.
        let race = EnrolRig("e6-race", cap: 1)
        let raceServer = race.server
        race.openWindow(60)
        let group = DispatchGroup()
        let outcomes = NSLock()
        nonisolated(unsafe) var raced: [Int] = []
        for i in 0..<4 {
            group.enter()
            Thread.detachNewThread {
                let code = enrolPost(raceServer, machine: "racer\(i)", nonce: enrolNonce()).status
                outcomes.lock(); raced.append(code); outcomes.unlock()
                group.leave()
            }
        }
        group.wait()
        expect(raced.filter { $0 == 200 }.count == 1 && raced.filter { $0 == 429 }.count == 3
               && race.machines.count == 1 && race.window?.enrolled == 1,
               "E6 four simultaneous Macs get exactly one enrolment out of a cap of one (\(raced.sorted()))")
    }

    // E7. A publisher with no signing key cannot enrol anybody: it could not sign the reply.
    do {
        let r = EnrolRig("e7-nokey")
        r.openWindow(30)
        let before = r.stateBytes
        let reply = enrolPost(r.keylessServer, machine: "mac1", nonce: enrolNonce())
        expect(reply.status == 403 && (String(data: reply.data, encoding: .utf8) ?? "").contains("--key"),
               "E7 no --key means /enrol is refused, not answered unsignably (\(reply.status))")
        expect(r.stateBytes == before && r.machines.isEmpty, "E7 the refusal wrote nothing")
    }

    // E8. The owner's window route: loopback, Host, Origin/Referer — and the minutes.
    do {
        let r = EnrolRig("e8-owner")
        var refusals: [Int] = [enrolOwnerPost(r, "/api/enrol-window", ["minutes": "30"], remote: "100.64.0.9").status,
                               enrolOwnerPost(r, "/api/enrol-window", ["minutes": "30"],
                                              headers: r.ownerHeaders.merging(["host": "evil.test"]) { _, b in b }).status,
                               enrolOwnerPost(r, "/api/enrol-window", ["minutes": "30"],
                                              headers: r.ownerHeaders.merging(["origin": "http://evil.test"]) { _, b in b }).status,
                               enrolOwnerPost(r, "/api/enrol-window", ["minutes": "30"],
                                              headers: r.ownerHeaders.filter { $0.key != "origin" }).status]
        expect(refusals == [403, 403, 403, 403],
               "E8 the window route refuses a remote peer, a foreign Host, a foreign Origin and no Origin at all (\(refusals))")
        expect(r.window == nil, "E8 none of those refusals opened a window")
        let opened = enrolOwnerPost(r, "/api/enrol-window", ["minutes": "30"])
        expect(opened.status == 200 && r.window?.isOpen() == true && r.window?.minutes == 30,
               "E8 the owner opens a window of the minutes asked for")
        for bad in ["241", "abc", "", "0.5", "-1"] {
            let reply = enrolOwnerPost(r, "/api/enrol-window", ["minutes": bad])
            expect(reply.status == 400 && r.window?.minutes == 30,
                   "E8 minutes \(bad.isEmpty ? "(empty)" : bad) is refused and leaves the window alone (\(reply.status))")
        }
        var formHeaders = r.ownerHeaders
        formHeaders["content-type"] = "application/x-www-form-urlencoded"
        let form = r.server.handleRequest(HTTPRequest(method: "POST", path: "/api/enrol-window", headers: formHeaders,
                                                      body: Data("minutes=5".utf8)), remote: "127.0.0.1")
        expect(form.status == 303 && form.headers["Location"] == "/" && r.window?.minutes == 5,
               "E8 the page's own form opens a window and returns the owner to the page")
        expect(enrolOwnerPost(r, "/api/enrol-window", ["minutes": "0"]).status == 200 && r.window == nil,
               "E8 minutes 0 closes the window")
    }

    // E9. The CLI, which is what `publisher-init` and the owner's own hands use.
    do {
        let r = EnrolRig("e9-cli")
        let khu = URL(fileURLWithPath: "build/khu").standardizedFileURL.path
        func cli(_ arguments: [String]) -> ShellResult? { try? SystemShell().run(khu, arguments: arguments, timeout: 10) }
        let opened = cli(["enrol-window", "--state", r.rig.state.path, "--minutes", "5"])
        expect(opened?.exitCode == 0 && opened?.stdout.contains("open for 5 minutes") == true && r.window?.isOpen() == true,
               "E9 the CLI opens a window (\(opened?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no output"))")
        expect(enrolPost(r.server, machine: "mac-cli", nonce: enrolNonce()).status == 200,
               "E9 a Mac enrols during the window the CLI opened")
        let closed = cli(["enrol-window", "--state", r.rig.state.path, "--minutes", "0"])
        expect(closed?.exitCode == 0 && r.window == nil, "E9 the CLI closes the window")
        let bad = cli(["enrol-window", "--state", r.rig.state.path, "--minutes", "241"])
        expect(bad?.exitCode == 2 && bad?.stderr.contains("1 to \(EnrolPolicy.maxMinutes)") == true,
               "E9 an impossible window is refused with a diagnostic (\(bad?.exitCode ?? -1))")
        let missing = cli(["enrol-window", "--state", r.rig.state.path, "--minutes"])
        expect(missing?.exitCode == 64 && missing?.stderr.contains("needs a value") == true,
               "E9 --minutes with no value is a usage error, not a crash")
    }

    // E10. The modest per-address rate limit, which bounds the attempts a window's cap does not.
    do {
        let r = EnrolRig("e10-rate", attempts: 3, cap: 100)
        let s = r.server                       // one publisher, as a flood really meets: the limit lives in it
        r.openWindow(60)
        let statuses = (1...4).map { enrolPost(s, machine: "mac\($0)", nonce: enrolNonce()).status }
        expect(statuses == [200, 200, 200, 429], "E10 a flood from one address is refused past the limit (\(statuses))")
        expect(s.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: ["content-type": "application/json"],
                                           body: try! JSONSerialization.data(withJSONObject: ["machine": "mac8", "nonce": enrolNonce()])),
                               remote: "100.64.0.9").status == 429, "E10 the flooded address stays refused")
        expect(r.machines.count == 3, "E10 the refused attempts enrolled nothing")
        expect(enrolPost(s, machine: "mac9", nonce: enrolNonce(), remote: "100.64.0.10").status == 200,
               "E10 the limit is per address, so another Mac is not punished for one flooded address")
        // The limit is a rate, not a lifetime ban: the same address is welcome again a minute later.
        let later = enrolPost(s, machine: "mac0", nonce: enrolNonce(), now: Date().addingTimeInterval(61))
        expect(later.status == 200, "E10 a minute later the flooded address may enrol again (\(later.status))")
    }

    // E11. Every refusal, in one place: the state is byte for byte what it was.
    do {
        let r = EnrolRig("e11-unchanged")
        _ = try! Enrolment.enrol(stateDir: r.rig.state, machine: "taken")
        let closedBytes = r.stateBytes
        _ = enrolPost(r.server, machine: "mac1", nonce: enrolNonce())                       // no window
        _ = enrolPost(r.server, machine: "mac1", nonce: "short")                            // bad nonce
        _ = enrolPost(r.server, machine: "../x", nonce: enrolNonce())                       // bad id
        _ = enrolPost(r.keylessServer, machine: "mac1", nonce: enrolNonce())                // no key
        _ = r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol", headers: [:],
                                               body: Data(repeating: 32, count: 8192)), remote: "100.64.0.9")  // oversize
        _ = enrolOwnerPost(r, "/api/remove-machine", ["machine": "gone"])                   // nothing to remove
        _ = enrolOwnerPost(r, "/api/remove-machine", ["machine": "../etc"])                 // not a name
        expect(r.stateBytes == closedBytes, "E11 refusals while the window was closed changed nothing at all")
        r.openWindow(30)
        let openBytes = r.stateBytes
        _ = enrolPost(r.server, machine: "taken", nonce: "short")                           // bad nonce
        _ = enrolOwnerPost(r, "/api/enrol-window", ["minutes": "999"])                      // impossible window
        expect(r.stateBytes == openBytes && r.machines.count == 1 && r.removed.isEmpty,
               "E11 refusals while the window was open changed nothing either")
    }

    // E12. A bind that names no address a Mac can reach refuses enrolment rather than guessing one.
    do {
        let r = EnrolRig("e12-bind")
        r.openWindow(30)
        for (bind, port) in [("127.0.0.1", 8790), ("127.0.0.2", 8790), ("0.0.0.0", 8790), ("::1", 8790),
                             ("localhost", 8790), ("169.254.1.1", 8790), ("239.1.1.1", 8790), ("100.64.0.7", 0)] {
            let server = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: bind, port: port,
                                    commandKey: r.rig.pair.privateKey)
            let reply = enrolPost(server, machine: "mac1", nonce: enrolNonce())
            let text = String(data: reply.data, encoding: .utf8) ?? ""
            expect(reply.status == 403 && !text.contains("http://127.0.0.1") && !text.contains(":0/"),
                   "E12 a bind of \(bind):\(port) refuses enrolment instead of handing out an unusable feed URL (\(reply.status))")
        }
        let reachable = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: "100.64.0.7", port: 8790,
                                   commandKey: r.rig.pair.privateKey)
        expect(enrolReply(enrolPost(reachable, machine: "mac-lan", nonce: enrolNonce()), key: r.rig.pair.privateKey)?
            .feedURL == "http://100.64.0.7:8790/release.json",
               "E12 a Tailscale bind is what a Mac is told to use")
        expect(r.machines.keys.sorted() == ["mac-lan"], "E12 only the reachable bind enrolled anything")
    }

    // E13. The page: the window's state, its countdown, and who enrolled through it.
    do {
        let r = EnrolRig("e13-page")
        let page = { () -> (HTTPResponse, String) in
            let response = r.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": r.host]), remote: "127.0.0.1")
            return (response, String(data: response.data, encoding: .utf8) ?? "")
        }
        let closed = page().1
        expect(closed.contains("Connect a Mac") && !closed.contains("/api/enrol-window") && !closed.contains("Macs removed"),
               "E13 the page has no window steps while no window is open")
        r.openWindow(30)
        _ = enrolPost(r.server, machine: "fresh-mac", nonce: enrolNonce())
        let (response, html) = page()
        let nonce = (response.headers["Content-Security-Policy"] ?? "").split(separator: "'")
            .first { $0.hasPrefix("nonce-") }.map { String($0.dropFirst("nonce-".count)) } ?? ""
        expect(nonce.count > 10 && html.contains("nonce=\"\(nonce)\"") && response.headers["Content-Security-Policy"]?.contains("script-src 'nonce-") == true,
               "E13 the countdown script is allowed by its own nonce, with no 'unsafe-inline' for scripts")
        expect(html.contains("data-until=") && html.contains("of \(EnrolPolicy.maxPerWindow) new Macs enrolled in this window"),
               "E13 the open window is shown with a countdown and how much of its allowance is used")
        expect(html.contains("fresh-mac") && html.contains("Connected on "),
               "E13 the Mac enrolled through the window is listed as such")
        expect(html.contains("action=/api/remove-machine") && html.contains("Remove Mac"),
               "E13 each Mac has a Remove Mac button on the page")
        try! EnrolmentWindow.close(stateDir: r.rig.state)
        expect(!page().1.contains("data-until="), "E13 the page follows the window back to closed")
    }

    // E14. The reply is exactly what Studio Hub's client is written to accept.
    do {
        let r = EnrolRig("e14-hub")
        r.openWindow(30)
        let n = enrolNonce()
        let response = enrolPost(r.server, machine: "hub-mac", nonce: n)
        let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let raw = (object?["reply"] as? String).flatMap { Data(base64Encoded: $0) }
        let signature = (object?["signature"] as? String).flatMap { Data(base64Encoded: $0) }
        let payload = raw.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        expect(raw != nil && signature != nil && payload != nil
               && Signing.verify(raw!, signature: signature!, publicKey: r.rig.pair.privateKey.publicKey),
               "E14 the Hub's own steps — strict base64, ed25519 verify — accept the reply")
        let token = payload?["token"] as? String ?? ""
        expect(payload?["machine"] as? String == "hub-mac" && payload?["nonce"] as? String == n
               && payload?["feedURL"] as? String == "http://100.64.0.7:8790/release.json"
               && payload?["publicKey"] as? String == r.rig.pair.publicKeyBase64
               && abs((payload?["issuedAt"] as? Int ?? 0) - Int(Date().timeIntervalSince1970)) <= 300
               && token.count >= 32,
               "E14 the reply carries exactly the fields the Mac checks, and issuedAt is fresh enough")
        expect(Set(payload?.keys ?? [:].keys) == ["machine", "nonce", "feedURL", "publicKey", "issuedAt", "token"],
               "E14 the reply adds nothing the Mac did not ask for (\((payload?.keys).map { $0.sorted() } ?? []))")
        let longest = String(repeating: "a", count: SafeName.maxBytes)
        let longReply = enrolPost(r.server, machine: longest, nonce: enrolNonce())
        expect(longReply.status == 200 && longReply.data.count <= 16384,
               "E14 even the longest accepted id keeps the reply inside 16 KiB (\(longReply.data.count) bytes)")
    }

    // E15. Removing a Mac: the owner's reset day. Its token and orders go; it enrols again.
    do {
        let r = EnrolRig("e15-remove")
        let s = r.server
        let token = try! Enrolment.enrol(stateDir: r.rig.state, machine: "reset-me")
        let hash = r.machines["reset-me"]?.tokenHash
        _ = s.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"],
                                        body: Data(#"{"machine":"reset-me","installed":{"demo":"1.0.0"}}"#.utf8)), remote: "100.64.0.9")
        _ = enrolOwnerPost(r, "/api/request-update", ["machine": "reset-me", "app": "demo"])
        expect(r.machines["reset-me"]?.pending.count == 1, "E15 setup: the Mac has an order waiting")
        for (name, remote, headers) in [("a remote peer", "100.64.0.9", r.ownerHeaders),
                                        ("a foreign Host", "127.0.0.1", r.ownerHeaders.merging(["host": "evil.test"]) { _, b in b }),
                                        ("a foreign Origin", "127.0.0.1", r.ownerHeaders.merging(["origin": "http://evil.test"]) { _, b in b }),
                                        ("no Origin or Referer", "127.0.0.1", r.ownerHeaders.filter { $0.key != "origin" })] {
            let reply = enrolOwnerPost(r, "/api/remove-machine", ["machine": "reset-me"], headers: headers, remote: remote)
            expect(reply.status == 403, "E15 Remove Mac refuses \(name) (\(reply.status))")
        }
        expect(r.machines.count == 1 && r.removed.isEmpty, "E15 none of those refusals removed anything")
        let removed = enrolOwnerPost(r, "/api/remove-machine", ["machine": "reset-me"])
        let record = r.removed.first
        expect(removed.status == 200 && r.machines["reset-me"] == nil && r.removed.count == 1
               && record?.machine == "reset-me" && record?.droppedOrders.count == 1
               && record?.installed["demo"] == "1.0.0" && record.flatMap { ISO.date($0.removedAt) } != nil,
               "E15 Remove Mac drops the live record; its order moves into the removed list with a timestamp and what it reported")
        let text = String(data: r.stateBytes, encoding: .utf8) ?? ""
        let removedJSON = ((try? JSONSerialization.jsonObject(with: JSON.encode(record!))) as? [String: Any]) ?? [:]
        expect(removedJSON["tokenHash"] == nil && !text.contains(hash ?? "!"),
               "E15 the dropped token hash is nowhere in the state file any more")
        let reuse = s.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"],
                                                body: Data(#"{"machine":"reset-me"}"#.utf8)), remote: "100.64.0.9")
        let orders = s.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=reset-me",
                                                 headers: ["authorization": "Bearer \(token)"]), remote: "100.64.0.9")
        expect(reuse.status == 401 && orders.status == 401,
               "E15 the removed Mac's old token cannot report or fetch orders (\(reuse.status), \(orders.status))")
        expect(enrolOwnerPost(r, "/api/remove-machine", ["machine": "reset-me"]).status == 404,
               "E15 removing a Mac that is not enrolled is a 404, not a second removal record")
        // The point of the day: it enrols itself again, through an open window, with a fresh token.
        r.openWindow(60)
        let again = enrolPost(s, machine: "reset-me", nonce: enrolNonce())
        let fresh = enrolReply(again, key: r.rig.pair.privateKey)?.token ?? ""
        expect(again.status == 200 && fresh.count >= 32 && fresh != token,
               "E15 a removed Mac enrols again through an open window with a fresh token (\(again.status))")
        expect(r.machines["reset-me"]?.tokenHash == Enrolment.sha256Hex(fresh) && r.machines["reset-me"]?.enrolmentSource == MachineState.windowSource
               && r.removed.count == 1,
               "E15 the removal record stays while the Mac is enrolled again")
        let html = String(data: s.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": r.host]), remote: "127.0.0.1").data,
                          encoding: .utf8) ?? ""
        expect(html.contains("Macs removed") && html.contains("reset-me") && html.contains("enrolled again since"),
               "E15 the page shows the removal and that the Mac has enrolled again since")
    }

    // E16. Removal is one read-modify-write under the state lock, from the page and the CLI alike.
    do {
        let r = EnrolRig("e16-atomic")
        for i in 0..<6 { _ = try! Enrolment.enrol(stateDir: r.rig.state, machine: "m\(i)") }
        let group = DispatchGroup()
        for i in 0..<6 {
            group.enter()
            Thread.detachNewThread { _ = try? Enrolment.remove(stateDir: r.rig.state, machine: "m\(i)"); group.leave() }
        }
        group.wait()
        expect(r.machines.isEmpty && r.removed.count == 6,
               "E16 six concurrent removals all land, one read-modify-write at a time (\(r.removed.count) of 6)")

        let mixed = EnrolRig("e16-mixed")
        for i in 0..<4 { _ = try! Enrolment.enrol(stateDir: mixed.rig.state, machine: "keep\(i)") }
        let race = DispatchGroup()
        race.enter()
        Thread.detachNewThread { _ = try? Enrolment.remove(stateDir: mixed.rig.state, machine: "keep0"); race.leave() }
        race.enter()
        Thread.detachNewThread { _ = try? Enrolment.enrol(stateDir: mixed.rig.state, machine: "fresh"); race.leave() }
        race.wait()
        expect(mixed.machines.count == 4 && mixed.machines["fresh"] != nil && mixed.machines["keep0"] == nil && mixed.removed.count == 1,
               "E16 a removal and an enrolment at the same moment never lose each other")

        let khu = URL(fileURLWithPath: "build/khu").standardizedFileURL.path
        func cli(_ arguments: [String]) -> ShellResult? { try? SystemShell().run(khu, arguments: arguments, timeout: 10) }
        let done = cli(["remove", "--state", mixed.rig.state.path, "--machine", "keep1"])
        expect(done?.exitCode == 0 && done?.stdout.contains("removed keep1") == true && mixed.machines["keep1"] == nil,
               "E16 the CLI removes a Mac")
        let gone = cli(["remove", "--state", mixed.rig.state.path, "--machine", "keep1"])
        expect(gone?.exitCode == 1 && gone?.stderr.contains("no enrolled Mac") == true,
               "E16 removing a Mac that is not enrolled fails with a diagnostic, not a crash")
        let unsafe = cli(["remove", "--state", mixed.rig.state.path, "--machine", "../etc"])
        expect(unsafe?.exitCode == 1 && unsafe?.stderr.contains("unsafe") == true,
               "E16 the CLI refuses a machine id that is not a name")
        let missing = cli(["remove", "--state", mixed.rig.state.path, "--machine"])
        expect(missing?.exitCode == 64 && missing?.stderr.contains("needs a value") == true,
               "E16 `remove --machine` with no value is a usage error, not a crash")
    }

    // E17. `/enrol` is reached through the real listener, not only through the handler: a socket
    // gets the same refusals, and the transport's own body cap is what stops the largest bodies.
    do {
        let r = EnrolRig("e17-socket")
        r.openWindow(30)
        let server = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: "127.0.0.1", port: 0,
                                commandKey: r.rig.pair.privateKey)
        let fd = try! server.listen()
        let port = FeedServer.boundPort(fd)
        Thread.detachNewThread { try? server.serve(on: fd) }
        func overSocket(_ body: Data) -> (Int, String) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/enrol")!)
            request.httpMethod = "POST"; request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("ignored", forHTTPHeaderField: "X-Hub-Token")
            request.httpBody = body
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var code = -1
            nonisolated(unsafe) var text = ""
            URLSession.shared.dataTask(with: request) { data, response, _ in
                code = (response as? HTTPURLResponse)?.statusCode ?? 0
                text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 6)
            return (code, text)
        }
        let refused = overSocket(try! JSONSerialization.data(withJSONObject: ["machine": "mac-over-socket", "nonce": enrolNonce()]))
        expect(refused.0 == 403 && refused.1.contains("address a Mac can reach") && r.machines.isEmpty,
               "E17 a real connection reaches /enrol and is refused on a bind no Mac can use (\(refused.0))")
        let banned = overSocket(Data(repeating: 32, count: 2 << 20))
        expect(banned.0 == 400 && r.machines.isEmpty,
               "E17 a body past the transport's 1 MiB cap is refused before it is read in (\(banned.0))")
        let oversize = overSocket(Data(repeating: 32, count: 64 << 10))
        expect(oversize.0 == 413 && r.machines.isEmpty, "E17 a body past the request's own cap is a 413 (\(oversize.0))")
    }

    // E18. A state file written by a publisher from BEFORE network enrolment and Remove Mac existed
    // still decodes. The delivered defect: `removed` was non-optional with a synthesized decoder, so
    // `{"machines":{…}}` threw, `StateStore.load` reported it, and EVERY route answered 503 for ever
    // — an upgrade would have silenced the whole fleet with no way back but a hand-edited file.
    do {
        let r = EnrolRig("e18-oldstate")
        let token = "T2xkU3RhdGVUb2tlblR3ZW50eVR3b0J5dGVzMTIzNDU="
        let hash = Enrolment.sha256Hex(token)
        // The literal shape `2eaae0c` wrote: no `removed`, no `enrolWindow`, and no MachineState
        // field added since (`enrolledAt`, `enrolmentSource`, `enrolNonceHash`).
        let old = """
        {"machines":{"old-mac":{"machine":"old-mac","tokenHash":"\(hash)","installed":{"demo":"1.2.3"},"health":{"demo":"healthy"},"lastSeen":"2026-10-24T10:00:00.000Z","pending":[],"automatic":{}}}}
        """
        try! Data(old.utf8).write(to: StateStore.stateFile(in: r.rig.state))
        let loaded = try? StateStore.load(from: r.rig.state)
        expect(loaded?.machines["old-mac"]?.installed["demo"] == "1.2.3"
               && loaded?.machines["old-mac"]?.tokenHash == hash
               && loaded?.machines["old-mac"]?.enrolmentSource == nil
               && loaded?.removed.isEmpty == true && loaded?.enrolWindow == nil,
               "E18 a state file written before `removed` existed decodes, with its Macs and fields intact")
        let s = r.server
        let status = enrolStatusPost(s, machine: "old-mac", token: token,
                                     body: ["machine": "old-mac", "installed": ["demo": "1.2.4"]])
        expect(status.status == 200, "E18 /status works against that old state (\(status.status))")
        let orders = s.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=old-mac",
                                                 headers: ["authorization": "Bearer \(token)"]), remote: "100.64.0.9")
        expect(orders.status == 200, "E18 /commands answers too (\(orders.status))")
        let page = s.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": r.host]), remote: "127.0.0.1")
        expect(page.status == 200 && (String(data: page.data, encoding: .utf8) ?? "").contains("old-mac"),
               "E18 the owner's page renders the old MachineState (\(page.status))")
        expect(r.machines["old-mac"]?.installed["demo"] == "1.2.4" && r.removed.isEmpty,
               "E18 the rewrite keeps the Mac and writes the new fields with their empty defaults")
        // The window too: absent in the old file, present and readable once it is opened.
        r.openWindow(5)
        expect(r.window?.minutes == 5 && r.window?.enrolled == 0,
               "E18 a state written without an `enrolWindow` gains one, and its Mac survives the write")
        // And the same rule for the other records: a removed Mac and a window written by a build
        // with fewer fields decode with their empty values instead of making the file unreadable.
        let sparse = #"{"machines":{},"removed":[{"machine":"gone"}],"enrolWindow":{"until":"2099-01-01T00:00:00.000Z"}}"#
        try! Data(sparse.utf8).write(to: StateStore.stateFile(in: r.rig.state))
        let loose = try? StateStore.load(from: r.rig.state)
        expect(loose?.removed.first?.machine == "gone" && loose?.removed.first?.droppedOrders.isEmpty == true
               && loose?.enrolWindow?.enrolled == 0 && loose?.enrolWindow?.minutes == 0,
               "E18 a removed record and a window written with fewer fields decode with their empty values")
        // `machines` is REQUIRED. `{}` is not an empty fleet, and answering an empty fleet would
        // silently orphan every Mac that believes it is enrolled.
        try! Data("{}".utf8).write(to: StateStore.stateFile(in: r.rig.state))
        expect((try? StateStore.load(from: r.rig.state)) == nil,
               "E18 a state file without `machines` is an error, never an empty fleet")
        let noFleet = enrolPost(r.server, machine: "mac-with-no-fleet", nonce: enrolNonce())
        expect(noFleet.status == 503,
               "E18 the routes say 503 against such a file instead of serving an empty fleet (\(noFleet.status))")
    }

    // E19. A Mac — possibly one that claimed a token through a window and has never been inspected —
    // cannot grow state.json without limit through /status or the result routes. Every report is a
    // whole-file rewrite under the one lock every other Mac waits on.
    do {
        let r = EnrolRig("e19-bounds")
        let token = try! Enrolment.enrol(stateDir: r.rig.state, machine: "reporting")
        // Generous on purpose: this half of E19 is about the entry and value bounds, and the rate
        // limit has its own server below.
        let s = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: "100.64.0.7", port: 8790,
                           commandKey: r.rig.pair.privateKey, reportPostsPerMinute: 1000)
        let apps = Dictionary(uniqueKeysWithValues: (0..<ReportPolicy.maxApps).map { ("app\($0)", "1.0.0") })
        expect(enrolStatusPost(s, machine: "reporting", token: token,
                               body: ["machine": "reporting", "installed": apps]).status == 200,
               "E19 a report with exactly the allowed number of apps is accepted")
        var over = apps; over["one-more"] = "1.0.0"
        var longName = apps; longName[String(repeating: "n", count: ReportPolicy.maxNameCharacters + 1)] = "1.0.0"
        var longVersion = apps; longVersion["app0"] = String(repeating: "v", count: ReportPolicy.maxVersionCharacters + 1)
        let health = Dictionary(uniqueKeysWithValues: (0..<ReportPolicy.maxApps).map { ("app\($0)", "healthy") })
        var longHealth = health; longHealth["app0"] = String(repeating: "h", count: ReportPolicy.maxHealthCharacters + 1)
        var defaults = Dictionary(uniqueKeysWithValues: (0..<ReportPolicy.maxApps).map { ("app\($0)", true) })
        defaults["one-more"] = true
        let before = r.stateBytes
        let refusals = [enrolStatusPost(s, machine: "reporting", token: token, body: ["machine": "reporting", "installed": over]),
                        enrolStatusPost(s, machine: "reporting", token: token, body: ["machine": "reporting", "installed": longName]),
                        enrolStatusPost(s, machine: "reporting", token: token, body: ["machine": "reporting", "installed": longVersion]),
                        enrolStatusPost(s, machine: "reporting", token: token, body: ["machine": "reporting", "health": longHealth]),
                        enrolStatusPost(s, machine: "reporting", token: token, body: ["machine": "reporting", "automatic_default": defaults])].map { $0.status }
        expect(refusals == [400, 400, 400, 400, 400], "E19 an oversized report is refused before it is stored (\(refusals))")
        expect(r.stateBytes == before && r.machines["reporting"]?.installed.count == ReportPolicy.maxApps,
               "E19 the refused reports wrote nothing: the state and its report are what the last accepted one left")
        // A result is kept for at most one entry per app and at most maxApps apps: a Mac that keeps
        // naming new apps evicts the oldest instead of growing the file for ever.
        for i in 0..<ReportPolicy.maxApps {
            _ = enrolResultPost(s, path: "/automatic/auto-\(i)/result", token: token,
                                body: ["machine": "reporting", "app": "invented\(i)", "status": "installed"])
        }
        expect((r.machines["reporting"]?.lastResults ?? [:]).count == ReportPolicy.maxApps,
               "E19 the map holds exactly its allowance of apps (\((r.machines["reporting"]?.lastResults ?? [:]).count))")
        let overCap = enrolResultPost(s, path: "/automatic/auto-new/result", token: token,
                                      body: ["machine": "reporting", "app": "one-more", "status": "installed"])
        let capped = r.machines["reporting"]?.lastResults ?? [:]
        expect(overCap.status == 200 && capped.count == ReportPolicy.maxApps && capped["one-more"] != nil,
               "E19 one more app is stored and the OLDEST entry goes: the map never grows past its bound (\(capped.count))")
        expect(r.stateBytes.count < 64 * 1024,
               "E19 the whole state a Mac can write that way stays small (\(r.stateBytes.count) bytes)")
        for _ in 0..<3 {
            _ = enrolResultPost(s, path: "/automatic/auto-invented5/result", token: token,
                                body: ["machine": "reporting", "app": "invented5", "status": "installed"])
        }
        expect((r.machines["reporting"]?.lastResults ?? [:]).count == ReportPolicy.maxApps
               && r.machines["reporting"]?.lastResults?["invented5"]?.commandId == "auto-invented5",
               "E19 three reports for the same app leave ONE entry: the map is keyed by app, never appended")
        let longId = enrolResultPost(s, path: "/automatic/auto-\(String(repeating: "i", count: ReportPolicy.maxCommandIdCharacters))/result",
                                     token: token, body: ["machine": "reporting", "app": "app0", "status": "installed"])
        expect(longId.status == 404, "E19 an order id past its bound is a 404, which the agent reads as no such order (\(longId.status))")
        let long = [enrolResultPost(s, path: "/automatic/auto-x/result", token: token,
                                    body: ["machine": "reporting", "app": "app1", "status": String(repeating: "s", count: ReportPolicy.maxStatusCharacters + 1)]),
                    enrolResultPost(s, path: "/automatic/auto-y/result", token: token,
                                    body: ["machine": "reporting", "app": "app1", "status": "failed",
                                           "reason": String(repeating: "r", count: ReportPolicy.maxReasonCharacters + 1)])].map { $0.status }
        expect(long == [400, 400], "E19 a status or reason past its bound is refused (\(long))")
        // A loop is bounded too, and the bound is per Mac.
        let other = try! Enrolment.enrol(stateDir: r.rig.state, machine: "other-2")
        let limited = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: "100.64.0.7", port: 8790,
                                 commandKey: r.rig.pair.privateKey, reportPostsPerMinute: 3)
        let codes = (0..<4).map { _ in
            enrolStatusPost(limited, machine: "reporting", token: token, body: ["machine": "reporting"]).status
        }
        expect(codes == [200, 200, 200, 429], "E19 one Mac may report three times a minute and is refused past it (\(codes))")
        let shared = enrolResultPost(limited, path: "/automatic/auto-z/result", token: token,
                                     body: ["machine": "reporting", "app": "app1", "status": "installed"])
        expect(shared.status == 429, "E19 the same limit covers the result routes (\(shared.status))")
        expect(enrolStatusPost(limited, machine: "other-2", token: other, body: ["machine": "other-2"]).status == 200,
               "E19 the limit is per machine: one Mac's loop does not silence another")
    }

    // E20. /enrol cannot be driven by a web page. A `text/plain` POST is a "simple request" a
    // browser sends cross-site without a preflight, and any browser that sends one also sends
    // Origin or Referer — which a Mac's own agent never does.
    do {
        let r = EnrolRig("e20-csrf")
        r.openWindow(30)
        let n = enrolNonce()
        let json = try! JSONSerialization.data(withJSONObject: ["machine": "csrf-mac", "nonce": n])
        let plain = r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol",
            headers: ["content-type": "text/plain", "origin": "http://evil.test"], body: json), remote: "100.64.0.9")
        expect(plain.status == 403 && r.machines.isEmpty,
               "E20 a text/plain fetch from a page is refused (\(plain.status))")
        let form = r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol",
            headers: ["content-type": "application/x-www-form-urlencoded", "referer": "http://evil.test/x"],
            body: Data("machine=csrf-mac&nonce=\(n)".utf8)), remote: "100.64.0.9")
        expect(form.status == 403 && r.machines.isEmpty,
               "E20 a form post from a page is refused before its body is parsed (\(form.status))")
        expect(enrolPost(r.server, machine: "csrf-mac", nonce: n).status == 200,
               "E20 the same machine and nonce enrol when no Origin or Referer is present: the agent's own request")
    }

    // E21. A record that never reported is dropped only when a NEW window opens and it is older than
    // the abandonment age — never on close. A Mac handed a token seconds ago has not run its agent
    // yet; deleting its record leaves it answering 401 with a token it was legitimately given.
    // A Mac that HAS reported is never dropped this way.
    do {
        let r = EnrolRig("e21-prune")
        r.openWindow(60)
        let claimed = enrolReply(enrolPost(r.server, machine: "claimed", nonce: enrolNonce()),
                                 key: r.rig.pair.privateKey)?.token ?? ""
        let reported = enrolReply(enrolPost(r.server, machine: "reported", nonce: enrolNonce()),
                                  key: r.rig.pair.privateKey)?.token ?? ""
        _ = enrolStatusPost(r.server, machine: "reported", token: reported, body: ["machine": "reported"])
        expect(r.machines.keys.sorted() == ["claimed", "reported"], "E21 setup: one Mac that has not reported yet, one that has")
        try! EnrolmentWindow.close(stateDir: r.rig.state)
        expect(r.machines.keys.sorted() == ["claimed", "reported"] && r.window == nil,
               "E21 closing the window drops NO record: the Mac it just enrolled has not reported yet")
        expect(enrolStatusPost(r.server, machine: "claimed", token: claimed,
                               body: ["machine": "claimed"]).status == 200,
               "E21 the token that closed window delivered still reports")
        // The page's own Close behaves the same way.
        r.openWindow(60)
        _ = enrolPost(r.server, machine: "claimed2", nonce: enrolNonce())
        _ = enrolPost(r.server, machine: "abandoned", nonce: enrolNonce())
        _ = enrolOwnerPost(r, "/api/enrol-window", ["minutes": "0"])
        expect(r.machines["claimed2"] != nil && r.machines["abandoned"] != nil && r.window == nil,
               "E21 the page's own Close drops nothing either")
        // Opening a NEW window drops an abandoned claim once it is older than the age — and only then.
        func backdate(_ machine: String, _ age: String) {
            try! StateStore.update(in: r.rig.state) { $0.machines[machine]?.enrolledAt = age }
        }
        backdate("abandoned", ISO.string(Date().addingTimeInterval(-20 * 60)))
        r.openWindow(60)
        expect(r.machines["abandoned"] == nil && r.machines["claimed2"] != nil
               && r.machines["reported"] != nil && r.machines["claimed"] != nil,
               "E21 a new window drops a claim older than fifteen minutes and keeps everything younger")
        expect(enrolStatusPost(r.server, machine: "reported", token: reported,
                               body: ["machine": "reported"]).status == 200,
               "E21 a Mac that has reported is never dropped by a new window")
        // An age that cannot be read keeps the record: "I could not work out how old this is" must
        // never delete a Mac's token.
        backdate("claimed2", "not a date")
        r.openWindow(60)
        expect(r.machines["claimed2"] != nil,
               "E21 a record whose age cannot be read is kept, never guessed away")
        // An id a squatter abandoned is freed by the same age rule, so the real Mac can take it.
        let slot = EnrolRig("e21-slot", cap: 1)
        slot.openWindow(60)
        _ = enrolPost(slot.server, machine: "squatter", nonce: enrolNonce())
        try! StateStore.update(in: slot.rig.state) {
            $0.machines["squatter"]?.enrolledAt = ISO.string(Date().addingTimeInterval(-20 * 60))
        }
        slot.openWindow(60)
        expect(slot.machines["squatter"] == nil
               && enrolPost(slot.server, machine: "squatter", nonce: enrolNonce()).status == 200,
               "E21 the id an abandoned claim held is free again after a new window")
    }

    // E22. A Mac whose signed reply was lost resends the SAME machine and nonce and gets a fresh
    // token, instead of a 409 that would strand it until the owner removed it by hand.
    do {
        let r = EnrolRig("e22-retry", cap: 1)
        r.openWindow(60)
        let n = enrolNonce()
        let first = enrolPost(r.server, machine: "retry-mac", nonce: n)
        let firstToken = enrolReply(first, key: r.rig.pair.privateKey)?.token ?? ""
        let again = enrolPost(r.server, machine: "retry-mac", nonce: n)
        let againToken = enrolReply(again, key: r.rig.pair.privateKey)?.token ?? ""
        expect(first.status == 200 && again.status == 200 && againToken.count >= 32 && againToken != firstToken,
               "E22 a resend of the same machine and nonce gets a fresh signed reply (\(again.status))")
        expect(r.machines["retry-mac"]?.tokenHash == Enrolment.sha256Hex(againToken) && r.window?.enrolled == 1,
               "E22 the stored hash is the token this Mac now holds, and the resend spent no second slot")
        expect(enrolStatusPost(r.server, machine: "retry-mac", token: againToken,
                               body: ["machine": "retry-mac"]).status == 200, "E22 the re-minted token reports")
        expect(enrolStatusPost(r.server, machine: "retry-mac", token: firstToken,
                               body: ["machine": "retry-mac"]).status == 401,
               "E22 the token only the lost reply carried no longer works")
        // Audit 2026-11-18: a window enrols a new Mac; it cannot re-mint an enrolled one.
        let third = enrolPost(r.server, machine: "retry-mac", nonce: enrolNonce())
        expect(third.status == 409,
               "E22 with the window open a different nonce is refused, not re-minted")
        expect(enrolStatusPost(r.server, machine: "retry-mac", token: againToken,
                               body: ["machine": "retry-mac"]).status == 200,
               "E22 the Mac keeps the token it already holds")
        try! EnrolmentWindow.close(stateDir: r.rig.state)
        expect(enrolPost(r.server, machine: "retry-mac", nonce: n).status == 403,
               "E22 with the window closed nothing is re-minted")
        let owned = EnrolRig("e22-owner")
        _ = try! Enrolment.enrol(stateDir: owned.rig.state, machine: "owner-mac")
        expect(enrolPost(owned.server, machine: "owner-mac", nonce: enrolNonce()).status == 403,
               "E22 an owner-enrolled Mac with no window and no code is refused")
    }

    // E23. /enrol is the one route anything on the tailnet may reach, so it says nothing about this
    // Mac: no state path, no decoder text, no bind, no port. The detail stays where the owner reads it.
    do {
        let r = EnrolRig("e23-generic")
        r.openWindow(30)
        try! Data("{not json".utf8).write(to: StateStore.stateFile(in: r.rig.state))
        let broken = enrolPost(r.server, machine: "mac1", nonce: enrolNonce())
        let brokenText = String(data: broken.data, encoding: .utf8) ?? ""
        expect(broken.status == 503 && !brokenText.contains(r.rig.state.path) && !brokenText.contains("state.json")
               && !brokenText.lowercased().contains("decode"),
               "E23 an unreadable state file is a 503 with a sentence, never the path or the decoder's words (\(broken.status): \(brokenText))")
        let page = r.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": r.host]), remote: "127.0.0.1")
        expect((String(data: page.data, encoding: .utf8) ?? "").contains("state.json"),
               "E23 the owner's own page still names the file it could not read")
        try? fm.removeItem(at: StateStore.stateFile(in: r.rig.state))
        r.openWindow(30)
        let unroutable = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: "127.0.0.1", port: 8790,
                                    commandKey: r.rig.pair.privateKey)
        let bindText = String(data: enrolPost(unroutable, machine: "mac1", nonce: enrolNonce()).data, encoding: .utf8) ?? ""
        expect(!bindText.contains("127.0.0.1") && !bindText.contains("8790") && !bindText.contains("0.0.0.0"),
               "E23 the unroutable-bind refusal does not echo the bind or the port (\(bindText))")
    }

    // E24. One window constructor, and one address range. `EnrolWindow.starting` is what the route
    // and the CLI both store, so the window the page shows and the server enforces cannot drift;
    // and /enrol names only the Tailscale range the Hub's own `publisher_config` accepts, because a
    // LAN feed URL would be one the Mac's Hub refuses to adopt.
    do {
        let now = Date()
        let made = EnrolWindow.starting(minutes: 7, now: now)
        expect(made.minutes == 7 && made.enrolled == 0
               && abs((made.untilDate?.timeIntervalSince(now) ?? 0) - 420) < 1,
               "E24 EnrolWindow.starting is the one constructor: seven minutes, none enrolled")
        let r = EnrolRig("e24-window")
        _ = enrolOwnerPost(r, "/api/enrol-window", ["minutes": "7"])
        let opened = r.window
        let span = opened?.untilDate?.timeIntervalSince(opened.flatMap { ISO.date($0.openedAt) } ?? now) ?? 0
        expect(opened?.minutes == 7 && abs(span - 420) < 1,
               "E24 the owner route stores a window of exactly seven minutes from its own openedAt (\(span) s)")
        let accepted = ["100.64.0.0", "100.64.0.7", "100.127.255.255"]
        let refused = ["192.168.1.5", "10.0.0.7", "172.16.0.7", "100.63.255.255", "100.128.0.0",
                       "127.0.0.1", "0.0.0.0", "169.254.1.1"]
        expect(accepted.allSatisfy { FeedServer.isTailnet($0) } && refused.allSatisfy { !FeedServer.isTailnet($0) },
               "E24 only the Tailscale range the Hub accepts counts as reachable")
        r.openWindow(30)
        for bind in ["192.168.1.5", "10.0.0.7"] {
            let server = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: bind, port: 8790,
                                    commandKey: r.rig.pair.privateKey)
            expect(enrolPost(server, machine: "lan-mac", nonce: enrolNonce()).status == 403,
                   "E24 a LAN bind of \(bind) refuses enrolment instead of naming a URL the Hub refuses")
        }
        expect(r.machines.isEmpty, "E24 no LAN bind enrolled anything")
    }

    // E25. `GET /commands`: what an agent advertises is bounded and counted against the Mac's report
    // budget, and a request that names no capabilities changes NOTHING — the Hub asks this route with
    // a stored token to learn whether the publisher still honours it, and a probe must not edit the
    // record it is asking about (a /status probe would refresh lastSeen and make a dead Mac look alive).
    do {
        let r = EnrolRig("e25-commands")
        let token = try! Enrolment.enrol(stateDir: r.rig.state, machine: "probe-me")
        let s = FeedServer(feedDir: r.rig.feed, stateDir: r.rig.state, bind: "100.64.0.7", port: 8790,
                           commandKey: r.rig.pair.privateKey, reportPostsPerMinute: 3)
        func fetch(_ query: String) -> HTTPResponse {
            s.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=probe-me\(query)",
                                        headers: ["authorization": "Bearer \(token)"]), remote: "100.64.0.9")
        }
        _ = fetch("&capabilities=owner-rollback-v1")
        expect(r.machines["probe-me"]?.capabilities == ["owner-rollback-v1"],
               "E25 the capabilities an agent advertises are recorded")
        let before = r.stateBytes
        let probe = fetch("")
        expect(probe.status == 200 && r.stateBytes == before
               && r.machines["probe-me"]?.lastSeen == nil
               && r.machines["probe-me"]?.capabilities == ["owner-rollback-v1"],
               "E25 a probe that names no capabilities answers 200 and changes nothing at all (\(probe.status))")
        let many = (0...ReportPolicy.maxCapabilities).map { "c\($0)" }.joined(separator: ",")
        let long = String(repeating: "c", count: ReportPolicy.maxCapabilityCharacters + 1)
        let huge = String(repeating: "c", count: ReportPolicy.maxCapabilitiesQueryBytes + 1)
        let refused = [fetch("&capabilities=\(many)").status, fetch("&capabilities=\(long)").status,
                       fetch("&capabilities=\(huge)").status]
        expect(refused == [400, 400, 400], "E25 an unbounded capabilities list is refused (\(refused))")
        expect(r.machines["probe-me"]?.capabilities == ["owner-rollback-v1"],
               "E25 a refused capabilities list is not stored")
        let limited = (0..<3).map { _ in fetch("&capabilities=").status }
        expect(limited == [200, 429, 429],
               "E25 the command route is under the Mac's report limit, so it cannot be looped for free (\(limited))")
    }

    // E26. A web page's refusal must not spend the Mac's allowance: the Origin/Referer check runs
    // before the per-address rate limit.
    do {
        let r = EnrolRig("e26-csrf-budget", attempts: 2)
        r.openWindow(30)
        let s = r.server
        let body = try! JSONSerialization.data(withJSONObject: ["machine": "budget-mac", "nonce": enrolNonce()])
        let fromPage = (0..<5).map { _ in
            s.handleRequest(HTTPRequest(method: "POST", path: "/enrol",
                headers: ["content-type": "text/plain", "origin": "http://evil.test"], body: body),
                remote: "100.64.0.9").status
        }
        expect(fromPage == [403, 403, 403, 403, 403], "E26 every request a page makes is refused (\(fromPage))")
        let real = (0..<3).map { enrolPost(s, machine: "budget-\($0)", nonce: enrolNonce()).status }
        expect(real == [200, 200, 429],
               "E26 the refused page requests spent none of this address's two attempts (\(real))")
    }
}

@main
struct RunnerMain {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)  // a crash must not swallow the lines before it
        if ProcessInfo.processInfo.environment["KHU_SERVICE_PROOF"] != nil {
            runLiveServiceProof()
        }
        if let record = ProcessInfo.processInfo.environment["KHU_NATIVE_UI_FIXTURE"] {
            serveNativePreview(record: record)
            return
        }
        if let record = ProcessInfo.processInfo.environment["KHU_PREVIEW_FIXTURE_RECORD"] {
            makePreviewFixture(record: record)
            return
        }
        if let portPath = ProcessInfo.processInfo.environment["R2_GATEWAY_PORT"] {
            let server = FeedServer(feedDir: fm.temporaryDirectory, stateDir: fm.temporaryDirectory, bind: "127.0.0.1", port: 0)
            let fd = try! server.listen()
            try! String(FeedServer.boundPort(fd)).write(toFile: portPath, atomically: true, encoding: .utf8)
            while true {
                let c = accept(fd, nil, nil); if c < 0 { exit(1) }
                _ = HTTP.readRequest(from: c, deadline: 1)
                HTTP.send(c, HTTPResponse(200, "application/json", "{\"pid\":\(getpid())}"))
                close(c)
            }
        }
        if ProcessInfo.processInfo.environment["R2_GATEWAY_MENU"] == "1" { while true { Thread.sleep(forTimeInterval: 1) } }
        if let file = ProcessInfo.processInfo.environment["R6_KILL_CONFIG"],
           let root = ProcessInfo.processInfo.environment["R6_KILL_PUBLISHER"] {
            let config = try! JSON.decode(AgentConfig.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            let base = URL(fileURLWithPath: root)
            let key = try! Signing.loadPrivateKey(from: base.appendingPathComponent("private.key"))
            let server = FeedServer(feedDir: base.appendingPathComponent("feed"), stateDir: base.appendingPathComponent("state"),
                                    bind: "127.0.0.1", port: 8790, commandKey: key)
            let ctl = AppControl(isRunning: { true }, quit: { true }, launch: { kill(getpid(), SIGTERM) }, healthy: { _ in false }, healthSettle: 0)
            _ = try? Agent.runOnce(config: config, http: InProcessClient(server: server), control: { _, _ in ctl })
            exit(2)
        }
        if ProcessInfo.processInfo.environment["FEED_NETWORK_ONLY"] == "1" {
            feedNetworkTests()
            controllerHandoffTests()
            feedMirrorTests()
            feedHostRuntimeTests()
            feedHostTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["STANDALONE_ONLY"] == "1" {
            standaloneLauncherTests()
            catalogSelectionTests()
            connectionFlowTests()
            setupSourceTests()
            downloadProgressTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["HOLD_WORK_ONLY"] == "1" {
            updateHoldWorkTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["HOLD_LIVE_ONLY"] == "1" {
            updateHoldLiveTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["AGENT_CORE_ONLY"] == "1" {
            agentAndServerTests()
            downloadResumeTests()
            repairedPathTests()
            oneShotLockTests()
            ownedServiceTests()
            updateHoldTests()
            orderQueueTests()
            statusOrdersTests()
            downloadDeadlineTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["DELTA_ONLY"] == "1" {
            artifactDeltaTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["TRANSFER_ONLY"] == "1" {
            recycleTests()
            transferLeakTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["STUB_ONLY"] == "1" {
            supportTests()
            stubTests()
            stubPruneTests()
            reportTests()
            helperRenameTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        dmgAttachmentTests()
        if ProcessInfo.processInfo.environment["DMG_ATTACH_ONLY"] == "1" {
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["LAUNCHER_ONLY"] == "1" {
            launcherTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["SSD_VENDOR_ONLY"] == "1" {
            ssdUpdateTests()
            vendorInstallerTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["SSD_UPDATE_ONLY"] == "1" {
            ssdUpdateTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["HELPER_RETIREMENT_ONLY"] == "1" {
            helperRetirementTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["SSD_HELPER_ONLY"] == "1" {
            ssdHelperTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        pauseFixtureCleanupTests()
        if ProcessInfo.processInfo.environment["PAUSE_FIXTURE_ONLY"] == "1" {
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["R6_ONLY"] == "1" {
            ownerRollbackTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["IDENTITY_ONLY"] == "1" {
            installedIdentityTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["E_ONLY"] == "1" {
            enrolWindowTests()
            pairingTests()
            helperTests()
            helperSwitchTests()
            launcherTests()
            connectionFlowTests()
            setupSourceTests()
            downloadProgressTests()
            installedIdentityTests()
            publisherRetentionTests()
            connectionReloadTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        standaloneLauncherTests()
        catalogSelectionTests()
        feedNetworkTests()
        controllerHandoffTests()
        feedMirrorTests()
        mirrorExportTests()
        neutralPublisherTests()
        pinnedKeyTests()
        feedHostRuntimeTests()
        // Signing basics stay covered.
        let key = Signing.generateKeyPair()
        let data = Data("hello".utf8)
        let sig = try! Signing.sign(data, with: key.privateKey)
        expect(Signing.verify(data, signature: sig, publicKey: key.privateKey.publicKey), "sig good")
        var tampered = data; tampered[0] ^= 1
        expect(!Signing.verify(tampered, signature: sig, publicKey: key.privateKey.publicKey), "sig tampered")
        expect(!Signing.verify(data, signature: sig, publicKey: Signing.generateKeyPair().privateKey.publicKey), "sig wrong key")
        expectThrows("traversal refused") { _ = try SafeName.component("../etc", what: "x") }

        if ProcessInfo.processInfo.environment["CC_ONLY"] != nil {
            copyCompletenessTests()
            rollbackRetirementTests()
            mirrorOnlyTests()
            mirrorFeedTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["MX_ONLY"] != nil {
            mirrorExportTests()
            neutralPublisherTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["PK_ONLY"] != nil {
            pinnedKeyTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["MF_ONLY"] != nil {
            mirrorFeedTests()
        mirrorOnlyTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        if let only = ProcessInfo.processInfo.environment["R2_ONLY"] {
            round2Tests(only: Int(only))
            if only == "28" { r28MonotonicWait() }
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        // The space patch's own tests, alone: a focused run never needs the whole suite.
        if ProcessInfo.processInfo.environment["SPACE_ONLY"] != nil {
            spaceFlowTests()
            spaceReclaimTests()
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        recipeTests()
        supportTests()
        gatewayIdentityTests()
        stubTests()
        stubPruneTests()
        reportTests()
        feedHostTests()
        publisherTests()
        agentAndServerTests()
        socketTests()
        r28MonotonicWait()
r41HealthMustHold()
        round2Tests()
        ownerRollbackTests()
        enrolWindowTests()
        pairingTests()
        helperTests()
        helperSwitchTests()
        launcherTests()
        connectionFlowTests()
        setupSourceTests()
        downloadProgressTests()
        downloadResumeTests()
        repairedPathTests()
        oneShotLockTests()
        ownedServiceTests()
        helperRenameTests()
        updateHoldTests()
        orderQueueTests()
        statusOrdersTests()
        downloadDeadlineTests()
        recycleTests()
        transferLeakTests()
        artifactDeltaTests()
        installedIdentityTests()
        publisherRetentionTests()
        connectionReloadTests()
        toolbarTests()
        inventoryTests()
        helperRetirementTests()
        ssdUpdateTests()
        ssdHelperTests()
        vendorCatalogTests()
        vendorOrderTests()
        vendorInstallerTests()
        vendorPublisherTests()
        vendorExecutionTests()
        spaceFlowTests()
        spaceReclaimTests()
        launchOrderTests()
        healthRequirementTests()
        mirrorFeedTests()
        copyCompletenessTests()
        rollbackRetirementTests()
        print("TESTS: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
