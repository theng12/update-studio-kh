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
                                                 previousVersion: "1.0.0", wasRunning: false), to: rig2.journal)
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
    // The real one: a process running from inside the bundle is stopped, and the port must go quiet.
    let own = startInBundle(bundle)
    server.pid = own.processIdentifier
    let stopped = control.stopService()
    expect(!own.isRunning, "R5 the Gateway's own process is stopped by its pid")
    expect(stopped == false, "R5 but a port that keeps answering (a respawn) is not 'stopped'")
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
    var server: FeedServer { FeedServer(feedDir: feed, stateDir: state, bind: "127.0.0.1", port: 8790) }
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
        guard size + Int64(extraBytes) <= limit else { throw khuFail("larger than expected") }
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
        return (try? JSONDecoder().decode(CommandsReply.self, from: r.data))?.commands ?? []
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

@main
struct RunnerMain {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)  // a crash must not swallow the lines before it
        // Signing basics stay covered.
        let key = Signing.generateKeyPair()
        let data = Data("hello".utf8)
        let sig = try! Signing.sign(data, with: key.privateKey)
        expect(Signing.verify(data, signature: sig, publicKey: key.privateKey.publicKey), "sig good")
        var tampered = data; tampered[0] ^= 1
        expect(!Signing.verify(tampered, signature: sig, publicKey: key.privateKey.publicKey), "sig tampered")
        expect(!Signing.verify(data, signature: sig, publicKey: Signing.generateKeyPair().privateKey.publicKey), "sig wrong key")
        expectThrows("traversal refused") { _ = try SafeName.component("../etc", what: "x") }

        recipeTests()
        supportTests()
        gatewayIdentityTests()
        stubTests()
        publisherTests()
        agentAndServerTests()
        socketTests()
        print("TESTS: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
