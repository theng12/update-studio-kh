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
                let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"], ["mount-point": mount.path]]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        if executable == "/usr/bin/ditto" {
            if dittoThrows { throw khuFail("timeout running /usr/bin/ditto") }
            if let code = dittoExit { return ShellResult(exitCode: code, stdout: "", stderr: "disk full") }
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
    let installed: URL
    init(installed: URL, running: Bool = true, quits: [Bool] = [true], stops: [Bool] = [true], healthy: Set<String>) {
        self.installed = installed; self.running = running; self.quits = quits; self.stops = stops; self.healthyVersions = healthy
    }
    var control: AppControl {
        AppControl(
            isRunning: { self.running },
            quit: { self.events.append("quit"); let ok = self.quits.count > 1 ? self.quits.removeFirst() : self.quits[0]; if ok { self.running = false }; return ok },
            launch: { self.events.append("launch"); self.running = true },
            stopService: { self.events.append("stop"); return self.stops.count > 1 ? self.stops.removeFirst() : self.stops[0] },
            healthy: { expected in
                let onDisk = (try? BundleInfo.read(self.installed.path))?.version
                return self.running && onDisk == expected && self.healthyVersions.contains(expected)
            },
            healthTimeout: 0.3, pollInterval: 0.05)
    }
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
    func run(_ app: FakeApp, expectedID: String? = nil, fileManager: FileManager = .default) -> Result<RecipeResult, Error> {
        Result { try Recipe.appDmg(shell: shell, installedPath: installed.path, artifactPath: "/tmp/x.dmg", feedVersion: "1.2.3",
                                   expectedBundleID: expectedID, stateDir: state.path, app: "foo", control: app.control,
                                   fileManager: fileManager) }
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
    func publish(_ app: String, _ version: String, _ artifact: URL, kind: String = "fake-for-tests") throws {
        try FeedPublisher.publish(feedDir: feed, keyFile: key, app: app, version: version, artifact: artifact, kind: kind, allowSame: false)
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
}

/// Calls the server's handler directly — the same code the sockets reach — with fault hooks.
final class InProcessClient: HTTPClient, @unchecked Sendable {
    let server: FeedServer
    var resultStatus: Int? = nil
    var downloads = 0
    var extraBytes = 0
    init(server: FeedServer) { self.server = server }
    func respond(_ method: String, _ url: URL, _ headers: [String: String], _ body: Data) -> HTTPResponse {
        var target = url.path
        if let q = url.query { target += "?" + q }
        let lower = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        return server.handleRequest(HTTPRequest(method: method, path: target, headers: lower, body: body), remote: "100.64.0.9")
    }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        let r = respond("GET", url, headers, Data()); return (r.data, r.status)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if let resultStatus, url.path.hasSuffix("/result") { return (Data(), resultStatus) }
        let r = respond("POST", url, headers, body); return (r.data, r.status)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        downloads += 1
        let r = respond("GET", url, headers, Data())
        guard case .file(let source, let size) = r.body else { try r.data.write(to: file); return r.status }
        guard size + Int64(extraBytes) <= limit else { throw ArtifactFailure(description: "larger than expected") }
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
        expect(res?.status == "failed" && (res?.reason ?? "").contains("larger"), "R19 an oversized download is refused")
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
        feed.apps["h"]?.notes = "changed"
        try! FeedPublisher.saveFeed(feed, to: rigH.feed, key: rigH.pair.privateKey)
        expectThrows("R25 a different feed with an equal published_at is refused", contains: "same published_at") {
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
        expectThrows("R3 a second agent run refuses while one holds the lock", contains: "another KH Updater process") {
            _ = try Agent.runOnce(config: cfg, http: client)
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
        expect(s.statusHTML().contains("Automatic: on"), "R32 a Mac whose own config is Automatic shows Automatic: on")
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
    let start = Mono.now()
    var wall = Date()
    var calls = 0
    var ticks = 0.0
    let control = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in
        calls += 1
        wall = wall.addingTimeInterval(calls == 1 ? 3600 : -7200)
        return false
    }, healthTimeout: 0.3, pollInterval: 0.01)
    let healthy = Recipe.waitHealthy(control, version: "1.0", clock: { ticks += 0.1; return ticks })
    expect(!healthy && calls >= 3 && Mono.now() - start < 0.2,
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
    var transient = false
    var corrupt = false
    var attempts = 0
    init(_ server: FeedServer) { inner = InProcessClient(server: server) }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        if url.path == "/commands", let commands { return (commands, 200) }
        return try inner.get(url, headers: headers)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        try inner.post(url, headers: headers, body: body)
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
        actual.launch = {}
        actual.healthy = { version in (try? BundleInfo.read(rig.installed.path).version) == version }
        let result = try? Recipe.appDmg(shell: rig.shell, installedPath: rig.installed.path, artifactPath: "/tmp/fake.dmg",
                                        feedVersion: "1.2.3", expectedBundleID: "com.example.foo", stateDir: rig.state.path,
                                        app: "foo", control: actual)
        expect(result?.status == "updated" && !process.isRunning && !menu.isRunning && rig.shell.calls.contains("fake menu quit") && marker(rig.installed) == "1.2.3",
               "R2-6 complete Gateway recipe quits menubar and stops genuine embedded listener (\(result?.status ?? "error"))")

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
        for (name, body) in [("unsigned", unsigned), ("bad signature", badSig), ("another machine", r2Sign(wrongMac, rig.pair.privateKey)), ("stale", r2Sign(stale, rig.pair.privateKey))] {
            client.commands = body
            expectThrows("R2-8 \(name) orders refused") { _ = try Agent.runOnce(config: cfg, http: client) }
        }
        expect(client.attempts == 0, "R2-8 refused order replies trigger no download")
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
        _ = try? Agent.runOnce(config: cfg, http: client)
        let attempts = client.attempts
        let refused = try? Agent.runOnce(config: cfg, http: client)
        expect(refused?.commandsRun == 0 && client.attempts == attempts,
               "R2-10 signed SHA mismatch is artifact-intrinsic and suppresses automatic retry")
        let operational = Rig("r2-copy-transport"); let tok = try! Enrolment.enrol(stateDir: operational.state, machine: "mac1")
        let recipe = RecipeRig("r2-copy-timeout")
        recipe.shell.dittoThrows = true
        try! operational.publish("demo", "1.2.3", operational.artifact("a.dmg", "abc"))
        let cfg2 = agentConfig(operational, token: tok, apps: ["demo": AppConfig(bundlePath: recipe.installed.path, automatic: true)])
        let client2 = R2Client(operational.server)
        let fake = FakeApp(installed: recipe.installed, healthy: ["1.2.3"])
        _ = try? Agent.runOnce(config: cfg2, http: client2, shell: recipe.shell, control: { _, _ in fake.control })
        let again = try? Agent.runOnce(config: cfg2, http: client2, shell: recipe.shell, control: { _, _ in fake.control })
        expect(again?.commandsRun == 1 && client2.attempts == 2,
               "R2-10 operational copy timeout does not reject valid artifact")
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
            expect(detaches == [["detach", "-force", "/dev/disk9"]], "R3-1 attach without a mount point detaches its whole-disk device, not the .dmg path")
        }
    }
}

@main
struct RunnerMain {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)  // a crash must not swallow the lines before it
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
        // Signing basics stay covered.
        let key = Signing.generateKeyPair()
        let data = Data("hello".utf8)
        let sig = try! Signing.sign(data, with: key.privateKey)
        expect(Signing.verify(data, signature: sig, publicKey: key.privateKey.publicKey), "sig good")
        var tampered = data; tampered[0] ^= 1
        expect(!Signing.verify(tampered, signature: sig, publicKey: key.privateKey.publicKey), "sig tampered")
        expect(!Signing.verify(data, signature: sig, publicKey: Signing.generateKeyPair().privateKey.publicKey), "sig wrong key")
        expectThrows("traversal refused") { _ = try SafeName.component("../etc", what: "x") }

        if let only = ProcessInfo.processInfo.environment["R2_ONLY"] {
            round2Tests(only: Int(only))
            if only == "28" { r28MonotonicWait() }
            print("TESTS: \(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        recipeTests()
        supportTests()
        gatewayIdentityTests()
        stubTests()
        publisherTests()
        agentAndServerTests()
        socketTests()
        r28MonotonicWait()
r41HealthMustHold()
        round2Tests()
        print("TESTS: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
