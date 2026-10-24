import Foundation

var passed = 0
var failed = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}
func expectThrows(_ block: () throws -> Void, _ name: String) {
    do { try block(); failed += 1; print("FAIL \(name) (no throw)") }
    catch { passed += 1; print("PASS \(name)") }
}
func mainTest() {
    // signature good/tampered/wrong key/missing
    let key = Signing.generateKeyPair()
    let data = Data("hello".utf8)
    let sig = Signing.sign(data, with: key.privateKey)
    expect(Signing.verify(data, signature: sig, publicKey: key.privateKey.publicKey), "sig good")
    var tampered = data; tampered[0] ^= 1
    expect(!Signing.verify(tampered, signature: sig, publicKey: key.privateKey.publicKey), "sig tampered")
    let other = Signing.generateKeyPair()
    expect(!Signing.verify(data, signature: sig, publicKey: other.privateKey.publicKey), "sig wrong key")
    expect(!Signing.verify(data, signature: Data(), publicKey: key.privateKey.publicKey), "sig missing")

    // feed rollback refused
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let feedDir = tmp.appendingPathComponent("feed")
    try? FileManager.default.createDirectory(at: feedDir, withIntermediateDirectories: true)
    // publish two versions
    let art = tmp.appendingPathComponent("a.txt"); try? "x".data(using: .utf8)!.write(to: art)
    try? FeedPublisher.publish(feedDir: feedDir, keyFile: saveKey(key, tmp), app: "app", version: "1.0.0", artifact: art, kind: "app-dmg", allowSame: false)
    // second publish newer
    let art2 = tmp.appendingPathComponent("a2.txt"); try? "y".data(using: .utf8)!.write(to: art2)
    try? FeedPublisher.publish(feedDir: feedDir, keyFile: saveKey(key, tmp), app: "app", version: "1.1.0", artifact: art2, kind: "app-dmg", allowSame: false)
    // non-newer refused
    expectThrows({ try FeedPublisher.publish(feedDir: feedDir, keyFile: saveKey(key, tmp), app: "app", version: "1.0.0", artifact: art, kind: "app-dmg", allowSame: false) }, "publish refuses non-newer")

    // artifact sha mismatch refused (agent)
    // path traversal refused
    expectThrows({ _ = try SafeName.component("../etc", what: "x") }, "traversal refused")

    // owner routes refused from non-loopback
    expect(!ServerDecision.ownerRouteAllowed(remote: "10.0.0.1"), "owner route non-loopback refused")
    expect(ServerDecision.ownerRouteAllowed(remote: "127.0.0.1"), "owner route loopback allowed")

    // agent auth missing/wrong/right tested via server handleRequest
    let stateDir = tmp.appendingPathComponent("state")
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let tok = try! Enrolment.enrol(stateDir: stateDir, machine: "m1")
    let srv = FeedServer(feedDir: feedDir, stateDir: stateDir, bind: "127.0.0.1", port: 0)
    // missing token
    let (s1,_,_) = srv.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=m1", headers: [:], body: Data()), remote: "127.0.0.1")
    expect(s1 == 401, "agent auth missing -> 401")
    // wrong token
    let (s2,_,_) = srv.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=m1", headers: ["authorization": "Bearer wrong"], body: Data()), remote: "127.0.0.1")
    expect(s2 == 401, "agent auth wrong -> 401")
    // right token
    let (s3,_,_) = srv.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=m1", headers: ["authorization": "Bearer \(tok)"], body: Data()), remote: "127.0.0.1")
    expect(s3 == 200, "agent auth right -> 200")

    // app-dmg recipe, against a temp "Applications" folder and a fake shell. Order and outcomes are the contract.
    func recipeRun(_ name: String, dmgVersion: String = "1.2.3", quits: Bool = true, stops: Bool = true,
                   healthy: [Bool], dittoOK: Bool = true) -> (Result<RecipeResult, Error>, [String], URL, URL) {
        let root = tmp.appendingPathComponent("recipe-\(name)")
        let apps = root.appendingPathComponent("Applications"); let installed = apps.appendingPathComponent("Foo.app")
        try? FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try? Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        var r: [String: ShellResult] = [:]
        r["/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen /tmp/x.dmg"] = ShellResult(exitCode: 0, stdout: "/dev/disk2s1\tApple_HFS\t/Volumes/X\n", stderr: "")
        r["/usr/bin/find /Volumes/X -maxdepth 1 -type d -name *.app"] = ShellResult(exitCode: 0, stdout: "/Volumes/X/Foo.app\n", stderr: "")
        r["/usr/bin/defaults read /Volumes/X/Foo.app/Contents/Info.plist CFBundleShortVersionString"] = ShellResult(exitCode: 0, stdout: dmgVersion + "\n", stderr: "")
        r["/usr/bin/hdiutil detach /Volumes/X"] = ShellResult(exitCode: 0, stdout: "", stderr: "")
        r["/usr/bin/ditto /Volumes/X/Foo.app \(installed.path)"] = ShellResult(exitCode: dittoOK ? 0 : 1, stdout: "", stderr: dittoOK ? "" : "disk full")
        let shell = FakeShell(responses: r)
        nonisolated(unsafe) var events: [String] = []
        nonisolated(unsafe) var checks = healthy
        let control = AppControl(
            quit: { events.append("quit"); return quits },
            launch: {
                events.append("launch")
                // ditto is faked, so make the "new" bundle visible after a launch that follows a copy
                if dittoOK, !FileManager.default.fileExists(atPath: installed.path) {
                    try? FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
                    try? Data("new".utf8).write(to: installed.appendingPathComponent("marker"))
                }
            },
            stopService: { events.append("stop"); return stops },
            healthy: { events.append("health"); return checks.isEmpty ? false : checks.removeFirst() },
            healthTimeout: 0.2, pollInterval: 0.05)
        let res = Result { try Recipe.appDmg(shell: shell, installedPath: installed.path, artifactPath: "/tmp/x.dmg", feedVersion: "1.2.3",
                                             rollbackDir: root.appendingPathComponent("rollback").path, trashDir: root.appendingPathComponent("_trash").path, control: control) }
        return (res, events, installed, root)
    }
    func marker(_ app: URL) -> String { (try? String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)) ?? "none" }

    let (ok, okEvents, _, okRoot) = recipeRun("ok", healthy: [true])
    expect((try? ok.get())?.status == "updated", "app-dmg success")
    expect(okEvents.prefix(3) == ["quit", "stop", "launch"], "app-dmg: quit, then stop, then launch")
    expect(marker(okRoot.appendingPathComponent("rollback/Foo.app")) == "old", "app-dmg keeps the previous bundle")

    let (bad, _, badApp, _) = recipeRun("unhealthy", healthy: [false, false, false, false, false, false, true])
    let badStatus = (try? bad.get())?.status
    expect(badStatus == "rolled_back", "app-dmg health fail -> rolled_back (got \(badStatus ?? "error"))")
    expect(marker(badApp) == "old", "rollback restores the previous bundle")

    let (mismatch, mmEvents, mmApp, _) = recipeRun("mismatch", dmgVersion: "9.9.9", healthy: [true])
    expect((try? mismatch.get()) == nil && mmEvents.isEmpty && marker(mmApp) == "old", "dmg version mismatch refused before touching the installed app")

    let (noStop, nsEvents, nsApp, _) = recipeRun("nostop", stops: false, healthy: [true])
    expect((try? noStop.get()) == nil && nsEvents == ["quit", "stop", "launch"] && marker(nsApp) == "old",
           "gateway: service won't stop -> old app relaunched, nothing replaced")

    let (noQuit, nqEvents, nqApp, _) = recipeRun("noquit", quits: false, healthy: [true])
    expect((try? noQuit.get()) == nil && nqEvents == ["quit"] && marker(nqApp) == "old", "app won't quit -> nothing replaced")

    let (copyFail, _, cfApp, _) = recipeRun("copyfail", healthy: [true], dittoOK: false)
    expect((try? copyFail.get()) == nil && marker(cfApp) == "old", "copy failure puts the previous bundle back")

    // stub rollback rules (no vacuous checks)
    let t0 = Date()
    var s = StubSupervisor(state: StubState())
    s.recordSwitch(at: t0)
    for k in 1...3 { s.recordExit(code: 1, at: t0.addingTimeInterval(Double(k) * 10)) }
    if case .switchBack = s.decide(at: t0.addingTimeInterval(40)) { expect(true, "stub 3 crashes -> switchBack") } else { expect(false, "stub 3 crashes -> switchBack") }
    var sB = StubSupervisor(state: StubState())
    sB.recordSwitch(at: t0)
    if case .switchBack = sB.decide(at: t0.addingTimeInterval(130)) { expect(true, "stub no heartbeat -> switchBack") } else { expect(false, "stub no heartbeat -> switchBack") }
    var sC = StubSupervisor(state: StubState())
    sC.recordSwitch(at: t0)
    sC.recordHeartbeat(at: t0.addingTimeInterval(10))
    expect(sC.decide(at: t0.addingTimeInterval(200)) == .keepRunning, "stub stable -> keepRunning")

    // atomic writes
    let au = tmp.appendingPathComponent("atomic.json")
    try? AtomicFile.writeJSON(["a": 1], to: au)
    let back: [String: Int]? = try? AtomicFile.readJSON([String: Int].self, from: au)
    expect(back == ["a": 1], "atomic write roundtrip")

    // loopback round-trip
    // start server in-process on random port using a thread
    // We'll test handleRequest enough; actual socket round-trip optional.
    // loopback round-trip
    do {
        let basePort = 18999
        let rtmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: rtmp, withIntermediateDirectories: true)
        let rfeed = rtmp.appendingPathComponent("feed"); try FileManager.default.createDirectory(at: rfeed, withIntermediateDirectories: true)
        let rstate = rtmp.appendingPathComponent("state"); try FileManager.default.createDirectory(at: rstate, withIntermediateDirectories: true)
        let rkey = saveKey(key, rtmp)
        let rart = rtmp.appendingPathComponent("app.zip"); try "x".data(using: .utf8)!.write(to: rart)
        try FeedPublisher.publish(feedDir: rfeed, keyFile: rkey, app: "demo", version: "2.0.0", artifact: rart, kind: "fake", allowSame: false)
        let rtok = try Enrolment.enrol(stateDir: rstate, machine: "mac1")
        // fake app bundle
        let appBundle = rtmp.appendingPathComponent("Demo.app")
        let contents = appBundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.0.0"]
        let pdata = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try pdata.write(to: contents.appendingPathComponent("Info.plist"))
        // server thread
        let srv = FeedServer(feedDir: rfeed, stateDir: rstate, bind: "127.0.0.1", port: basePort)
        let t = Thread { try? srv.serve() }
        t.start()
        Thread.sleep(forTimeInterval: 0.5)
        // config
        let cfg = AgentConfig(feedURL: "http://127.0.0.1:\(basePort)/feed.json", publicKey: key.publicKeyBase64, stateDir: rstate.path, machine: "mac1", token: rtok, apps: ["demo": AppConfig(bundlePath: appBundle.path, recipe: "fake-for-tests", automatic: false), "story": AppConfig(bundlePath: "/nonexistent/Story.app", recipe: "story")], once: true)
        let r = try Agent.runOnce(config: cfg, http: URLSessionHTTPClient(), shell: SystemShell())
        expect(r.statusPosted, "loopback: status posted")
        // state has machine
        let st = try StateStore.load(from: rstate)
        expect(st.machines["mac1"] != nil, "loopback: machine in state")
        expect(r.commandsRun == 0, "loopback: automatic off and no command -> nothing installed")
        // owner turns Automatic on for demo and asks to update story: the agent follows the server
        _ = srv.handleRequest(HTTPRequest(method: "POST", path: "/api/automatic", headers: ["content-type": "application/json"], body: Data(#"{"machine":"mac1","app":"demo","on":true}"#.utf8)), remote: "127.0.0.1")
        _ = srv.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: ["content-type": "application/json"], body: Data(#"{"machine":"mac1","app":"story"}"#.utf8)), remote: "127.0.0.1")
        let r2 = try Agent.runOnce(config: cfg, http: URLSessionHTTPClient(), shell: SystemShell())
        let st2 = try StateStore.load(from: rstate)
        expect(r2.updates == 1, "loopback: server Automatic switch drives the update")
        expect(st2.machines["mac1"]?.lastResult != nil, "loopback: results reported")
        expect(st2.machines["mac1"]?.health["story"] == "not installed", "loopback: real health is reported, not a constant")
        // cleanup thread can't stop easily; leave
    } catch {
        print("loopback error: \(error)")
        failed += 1
    }

    print("TESTS: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

func saveKey(_ key: Signing.KeyPair, _ tmp: URL) -> URL {
    let url = tmp.appendingPathComponent("private.key")
    try? Signing.savePrivateKey(key.privateKey, to: url)
    return url
}



@main
struct RunnerMain {
    static func main() { mainTest() }
}
