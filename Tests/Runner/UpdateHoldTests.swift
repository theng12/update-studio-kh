import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A real loopback hold endpoint that takes `delay` seconds to answer, so a test can measure what
/// the client actually waits for instead of what it claims to.
private final class SlowHoldServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    var endpoint: URL? {
        URL(string: "http://127.0.0.1:\(port)/api/maintenance/hold")
    }
    init(delay: TimeInterval, body: String) {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        fd = sock
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { Darwin.bind(sock, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size)) }
        _ = Darwin.listen(sock, 4)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { getsockname(sock, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &len) }
        port = Int(UInt16(bigEndian: bound.sin_port))
        Thread { [sock, body] in
            let client = Darwin.accept(sock, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            _ = Darwin.read(client, &buffer, buffer.count)
            Thread.sleep(forTimeInterval: delay)
            let payload = Data(body.utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
            response.append(payload)
            response.withUnsafeBytes { _ = Darwin.write(client, $0.baseAddress, $0.count) }
            Darwin.close(client)
        }.start()
    }
    func stop() { Darwin.close(fd) }
}


private final class HoldClient: HTTPClient, @unchecked Sendable {
    let inner: InProcessClient
    var artifacts: [String: Data] = [:]
    /// One reply per POST, consumed in order; an empty script answers 500.
    var replies: [(status: Int, data: Data)] = []
    var calls: [String] = []
    /// When set, the hold POST fails like a transport error instead of answering from the script.
    var postError: URLError?
    var lastHeaders: [String: String] = [:]
    /// When set, the endpoint checks the presented token like a gated app would; a mismatch is a 401.
    var validator: ((String?) -> Bool)?
    var seenTokens: [String?] = []
    let lock = NSLock()
    init(_ inner: InProcessClient) { self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { try inner.get(url, headers: headers) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        guard url.host == "127.0.0.1" else { return try inner.post(url, headers: headers, body: body) }
        if let postError { throw postError }
        if let validator, !validator(headers["X-Hub-Token"]) {
            lock.lock(); lastHeaders = headers; seenTokens.append(headers["X-Hub-Token"]); calls.append("hold"); lock.unlock()
            return (Data(#"{"error":"no credential"}"#.utf8), 401)
        }
        lock.lock(); lastHeaders = headers; seenTokens.append(headers["X-Hub-Token"]); calls.append("hold"); let reply = replies.isEmpty ? (status: 500, data: Data()) : replies.removeFirst(); lock.unlock()
        return (reply.data, reply.status)
    }
    func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        guard url.host == "127.0.0.1" else { return (Data(), 404) }
        lock.lock(); calls.append("resume"); lock.unlock()
        return (Data(), 200)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        lock.lock(); calls.append("artifact"); lock.unlock()
        guard let data = artifacts[url.lastPathComponent] else { return 404 }
        try data.write(to: file)
        return 200
    }
    var count: (String) -> Int {
        { needle in self.lock.lock(); defer { self.lock.unlock() }; return self.calls.filter { $0 == needle }.count }
    }
}

/// Records the exact script an idle check is run with, and answers it as a scripted Mac would.
private final class ScriptSpy: Shell, @unchecked Sendable {
    var scripts: [String] = []
    let answer: ShellResult
    init(answer: ShellResult) { self.answer = answer }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        scripts.append(arguments.last ?? "")
        return answer
    }
}

/// Answers an idle check as a scripted Mac would, without running it, and hands everything else to
/// the real recording shell. Lets a test decide what the app's check says on this machine.
private struct ProbeShell: Shell {
    let inner: RecordingShell
    let probeExit: Int32
    let probeOut: String
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/bin/sh" { return ShellResult(exitCode: probeExit, stdout: probeOut, stderr: "") }
        return try inner.run(executable, arguments: arguments, timeout: timeout)
    }
}

private func safeReply(inFlight: Int = 2) -> (status: Int, data: Data) {
    (200, Data(#"{"safe":true,"unsettled":[],"dispatch_paused_s":120,"in_flight":\#(inFlight)}"#.utf8))
}
private func unsafeReply(_ names: [String]) -> (status: Int, data: Data) {
    (200, Data(#"{"safe":false,"unsettled":["\#(names.joined(separator: "\",\""))"],"dispatch_paused_s":120,"in_flight":2}"#.utf8))
}

func updateHoldTests() {
    let holdURL = "http://127.0.0.1:8799/api/maintenance/hold"
    // Tests must never write the real helper state: point the Launcher token at a temp file.
    let tokenPath = tmpDir("hold-token").appendingPathComponent("hold-token").path
    setenv("KHU_HOLD_TOKEN_FILE", tokenPath, 1)

    // UH1 the trusted endpoint is this Mac's loopback, the contract's two paths and nothing else.
    expect(UpdateHold.trusted(holdURL) != nil
           && UpdateHold.trusted("http://127.0.0.1:8799/api/maintenance/drain") != nil
           && UpdateHold.trusted("http://127.0.0.1:8787/admin/api/maintenance/drain") != nil,
           "UH1 the contract's loopback hold and drain endpoints and Gateway's exact admin drain are trusted")
    let untrusted = ["https://127.0.0.1:8799/api/maintenance/hold", "http://10.0.0.5:8799/api/maintenance/hold",
                     "http://127.0.0.1/api/maintenance/hold", "http://127.0.0.1:8799/api/other",
                     "http://user:pass@127.0.0.1:8799/api/maintenance/hold",
                     "http://127.0.0.1:8787/admin/api/maintenance/hold",
                     "http://127.0.0.1:8787/admin/api/maintenance/drain/extra",
                     "http://127.0.0.1:8787/admin/drain",
                     "http://127.0.0.1:8787/admin/api/maintenance/drain?x=1",
                     "http://127.0.0.1:8787/admin/api/maintenance/drain#frag"]
    expect(untrusted.allSatisfy { UpdateHold.trusted($0) == nil }, "UH1 a remote, wrong-path or credentialled URL is not trusted")

    // The installed 1.0.0 serves the hold unless a test says otherwise (holdSince: nil records it at 2.0.0).
    func rig(_ tag: String, hold: String?, recipe: String = "fake-for-tests", running: Bool = true, holdSince: String? = "1.0.0",
             id: String = "demo")
        -> (rig: Rig, feed: Feed, entry: FeedApp, cfg: AgentConfig, client: HoldClient, app: FakeApp, state: URL, mount: URL) {
        let r = Rig(tag)
        let installed = makeApp(r.root.appendingPathComponent("Demo.app"), version: "1.0.0", id: "com.example.demo")
        try! FeedPublisher.publish(feedDir: r.feed, keyFile: r.key, app: id, version: "2.0.0",
                                   artifact: r.artifact("demo.dmg", "dmg bytes"), kind: recipe == "fake-for-tests" ? "fake-for-tests" : "app-dmg",
                                   allowSame: false, meta: { _ in AppMeta(name: "Demo", bundleID: "com.example.demo", bundleName: "Demo.app", version: "2.0.0", iconPNG: Data()) },
                                   holdURL: hold, holdSince: hold == nil ? nil : holdSince)
        let feed = try! FeedPublisher.loadVerifiedFeed(from: r.feed, publicKey: r.pair.privateKey.publicKey)!
        let state = r.root.appendingPathComponent("state")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        let client = HoldClient(InProcessClient(server: r.server))
        client.artifacts[feed.apps[id]!.file] = Data("dmg bytes".utf8)
        var cfg = agentConfig(r, token: "unused", apps: [id: AppConfig(bundlePath: installed.path, recipe: recipe, automatic: true)])
        cfg.stateDir = state.path
        let app = FakeApp(installed: installed, running: running, quits: [true], healthy: ["2.0.0"])
        let mount = r.root.appendingPathComponent("mount")
        makeApp(mount.appendingPathComponent("Demo.app"), version: "2.0.0", id: "com.example.demo")
        return (r, feed, feed.apps[id]!, cfg, client, app, state, mount)
    }

    // UH2 the bytes are fetched first, the app is only held for the swap itself, and it is resumed
    // after the install. Nothing is replaced by a download, so the hold still comes before any byte
    // of the install.
    do {
        let f = rig("hold-safe", hold: holdURL)
        f.client.replies = [safeReply(inFlight: 2)]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "updated" && f.client.calls == ["artifact", "hold", "resume"],
               "UH2 the download precedes the hold, which still precedes the swap, and the hold is resumed (\(f.client.calls))")
        expect((result?.reason ?? "").contains("held (2 jobs in flight; new work paused 120 s)"),
               "UH2 the result says how much work was held (\(result?.reason ?? "nil"))")
    }

    // UH3 an unsafe reply is retried once and then refused: nothing is installed, the app is resumed.
    // The bytes were already fetched: a download replaces nothing, and refusing it now answers the
    // order before anything is paused.
    do {
        let f = rig("hold-unsafe", hold: holdURL)
        f.client.replies = [unsafeReply(["render-7"]), unsafeReply(["render-7", "tts-3"])]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == Agent.waitingForClose && (result?.reason ?? "").contains("render-7")
               && (result?.reason ?? "").contains("tts-3") && !f.app.events.contains("quit"),
               "UH3 an unsafe reply waits for close with the unsettled names, and the app is never quit")
        expect(f.client.calls == ["artifact", "hold", "hold", "resume"], "UH3 the retry and the resume are the only hold calls (\(f.client.calls))")
    }

    // UH4 an app that does not answer is refused and resumed, never installed over.
    do {
        let f = rig("hold-unreachable", hold: holdURL)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && !f.app.events.contains("quit") && f.client.calls.last == "resume",
               "UH4 an unreachable hold refuses the install and resumes (\(f.client.calls))")
    }

    // UH5 a running app with no hold endpoint is unsupported: refused before the swap, no quit.
    do {
        let f = rig("hold-unsupported", hold: nil, recipe: "app-dmg")
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && (result?.reason ?? "").contains("does not name an update-hold endpoint")
               && !f.client.calls.contains("hold") && !f.app.events.contains("quit"),
               "UH5 an app the feed gives no endpoint is refused before the swap and never quit")
    }

    // UH6 an app that is not running needs no hold.
    do {
        let f = rig("hold-not-running", hold: holdURL, running: false)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "updated" && !f.client.calls.contains("hold") && !f.client.calls.contains("resume"),
               "UH6 an app that is not running takes no hold (\(f.client.calls))")
    }

    // UH7 a hold that expires during staging is renewed at the boundary; if it is no longer safe the
    // swap never happens and the app is resumed.
    do {
        let f = rig("hold-expiry", hold: holdURL, recipe: "app-dmg")
        f.client.replies = [safeReply(), unsafeReply(["story-14"])]
        var refusedSwap = ""
        do {
            _ = try Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                  serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                  http: f.client, shell: RecordingShell(mount: f.mount),
                                  control: { _, _ in f.app.control })
        } catch { refusedSwap = "\(error)" }
        expect(refusedSwap.contains("no longer safe") && refusedSwap.contains("story-14"),
               "UH7 an expired hold refuses the swap at the mutation boundary (\(refusedSwap))")
        expect(!f.app.events.contains("quit") && f.client.calls.last == "resume",
               "UH7 the app was never quit and is resumed (\(f.client.calls))")
    }

    // UH8 a refused quit resumes the hold; the app keeps running.
    do {
        let f = rig("hold-abort", hold: holdURL, recipe: "app-dmg")
        f.app.quits = [false]
        f.client.replies = [safeReply(), safeReply()]
        var quitFailure = ""
        do {
            _ = try Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                  serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                  http: f.client, shell: RecordingShell(mount: f.mount),
                                  control: { _, _ in f.app.control })
        } catch { quitFailure = "\(error)" }
        expect(quitFailure.contains("did not quit"), "UH8 a refused quit aborts the install (\(quitFailure))")
        expect(f.client.calls == ["artifact", "hold", "hold", "resume"],
               "UH8 the hold is renewed at the boundary and resumed after the abort (\(f.client.calls))")
    }

    // UH17 a duplicate-bundle sweep never retires the app that was just installed, whatever path
    // spelling or extra root it is reached through.
    do {
        let root = tmpDir("retire-target")
        let apps = root.appendingPathComponent("Applications")
        let userApps = root.appendingPathComponent("UserApplications")
        try! fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try! fm.createDirectory(at: userApps, withIntermediateDirectories: true)
        let installed = makeApp(apps.appendingPathComponent("Studio Launcher KH.app"), version: "0.1.37", id: "com.khupdater.launcher")
        _ = makeApp(userApps.appendingPathComponent("Studio Launcher KH copy.app"), version: "0.1.37", id: "com.khupdater.launcher")
        let link = root.appendingPathComponent("linked-Applications")
        try! fm.createSymbolicLink(at: link, withDestinationURL: apps)
        let trash = root.appendingPathComponent("trash")
        try! fm.createDirectory(at: trash, withIntermediateDirectories: true)
        Recipe.retireDuplicateBundles(bundleID: "com.khupdater.launcher", keeping: installed.path + "/", trash: trash,
                                      roots: [apps, userApps, link])
        expect(fm.fileExists(atPath: installed.path), "UH17 the installed app survives the duplicate sweep")
        let trashed = (fm.enumerator(at: trash, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        expect(trashed.contains { $0.lastPathComponent.contains("copy") }, "UH17 the real duplicate is retired")
        let missing = root.appendingPathComponent("Gone.app")
        Recipe.retireDuplicateBundles(bundleID: "com.khupdater.launcher", keeping: missing.path, trash: trash,
                                      roots: [apps, userApps])
        expect(fm.fileExists(atPath: installed.path), "UH17 an unreadable target retires nothing")
    }

    // UH18 an order already satisfied at the target path is not reinstalled.
    do {
        let f = rig("hold-current", hold: holdURL, recipe: "app-dmg", running: false)
        _ = makeApp(URL(fileURLWithPath: f.cfg.apps["demo"]!.bundlePath), version: "2.0.0", id: "com.example.demo")
        f.client.replies = [safeReply()]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "2.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "current" && f.client.calls.isEmpty && !f.client.calls.contains("artifact"),
               "UH18 an already-current target is not reinstalled (\(f.client.calls))")
    }

    // UH16 a missing or corrupt staged app is refused before anything is stopped or moved: the
    // installed app stays exactly where it is.
    do {
        let r = Rig("hold-corrupt-stage")
        let installed = makeApp(r.root.appendingPathComponent("Demo.app"), version: "1.0.0", id: "com.example.demo")
        let mount = r.root.appendingPathComponent("mount")
        makeApp(mount.appendingPathComponent("Demo.app"), version: "2.0.0", id: "com.example.demo")
        let state = r.root.appendingPathComponent("state")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        let app = FakeApp(installed: installed, running: false, healthy: ["2.0.0"])
        let result = try? Recipe.appDmg(shell: RecordingShell(mount: mount), installedPath: installed.path,
                                        artifactPath: mount.appendingPathComponent("Demo.app").path,
                                        feedVersion: "2.0.0", expectedBundleID: "com.example.demo",
                                        stateDir: state.path, app: "demo", control: app.control,
                                        verifyStaged: { staged in try? fm.removeItem(atPath: staged) })
        let journal = Recipe.journalURL(stateDir: state.path, app: "demo")
        expect(result?.status == "install_failed" && (result?.reason ?? "").contains("missing or unreadable")
               && (try? BundleInfo.read(installed.path))?.version == "1.0.0" && !fm.fileExists(atPath: journal.path),
               "UH16 a missing staged app leaves the installed app untouched (\(result?.status ?? "nil"), \(result?.reason ?? ""))")
    }

    // UH25-UH29 the consumer side of a gated hold: no token, wrong token, rotation, refusal, positive.
    func gated(_ tag: String, token: String?, accept: @escaping (String?) -> Bool) -> (rig: Rig, feed: Feed, entry: FeedApp, cfg: AgentConfig, client: HoldClient, app: FakeApp, state: URL, mount: URL) {
        let f = rig(tag, hold: holdURL, recipe: "app-dmg", running: true)
        if let token { try? Data(token.utf8).write(to: URL(fileURLWithPath: tokenPath), options: .atomic) }
        else { try? fm.removeItem(atPath: tokenPath) }
        f.client.validator = accept
        return f
    }
    do { // UH25 no usable token file: creation fails, no header, the endpoint refuses, nothing moves.
        let f = rig("hold-no-token", hold: holdURL, recipe: "app-dmg", running: true)
        setenv("KHU_HOLD_TOKEN_FILE", "/tmp/khu-token-dir-is-a-file/token", 1)
        try? Data("x".utf8).write(to: URL(fileURLWithPath: "/tmp/khu-token-dir-is-a-file"))
        f.client.validator = { token in token != nil }
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && (result?.reason ?? "").contains("credential")
               && !f.app.events.contains("quit"),
               "UH25 a missing token stops before quit or replace (\(result?.reason ?? "nil"))")
        setenv("KHU_HOLD_TOKEN_FILE", tokenPath, 1)
    }
    do { // UH26 a wrong token is refused by the endpoint, before any byte.
        let f = gated("hold-wrong-token", token: String(repeating: "a", count: 64), accept: { $0 == String(repeating: "b", count: 64) })
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && f.app.events.isEmpty,
               "UH26 a wrong token stops before any quit")
    }
    do { // UH27 rotation mid-run: the next request reads the new file value and is accepted.
        let f = rig("hold-rotate-mid", hold: holdURL, recipe: "app-dmg", running: true)
        try? Data(String(repeating: "a", count: 64).utf8).write(to: URL(fileURLWithPath: tokenPath), options: .atomic)
        var posts = 0
        f.client.validator = { token in
            posts += 1
            if posts == 1 {
                _ = UpdateHold.rotateToken()   // rotates while the install is running
                return token == String(repeating: "a", count: 64)
            }
            return token == UpdateHold.localToken()
        }
        f.client.replies = [safeReply(), safeReply()]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "updated" && f.client.seenTokens.count == 2
               && f.client.seenTokens[0] != f.client.seenTokens[1],
               "UH27 rotation mid-run is picked up per request (\(f.client.seenTokens.map { $0?.prefix(4) }))")
    }
    do { // UH28 the old value stops being accepted after a rotation.
        let f = rig("hold-old-token", hold: holdURL, recipe: "app-dmg", running: true)
        try? Data(String(repeating: "a", count: 64).utf8).write(to: URL(fileURLWithPath: tokenPath), options: .atomic)
        let old = String(repeating: "a", count: 64)
        _ = UpdateHold.rotateToken()
        f.client.validator = { $0 == old }
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && f.app.events.isEmpty,
               "UH28 a rotated-away token is no longer accepted, and the install stops")
    }
    do { // UH29 positive: the current token is accepted; safe, quit, replace, relaunch, resume.
        let f = rig("hold-positive", hold: holdURL, recipe: "app-dmg", running: true)
        _ = UpdateHold.localToken()
        f.client.validator = { $0 == UpdateHold.localToken() }
        f.client.replies = [safeReply(inFlight: 2), safeReply(inFlight: 2)]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, manual: true)
        expect(result?.status == "updated" && f.app.events.contains("quit") && f.app.events.contains("launch")
               && f.client.calls == ["artifact", "hold", "hold", "resume"],
               "UH29 the held install quits, replaces and relaunches (\(f.client.calls), \(f.app.events))")
        expect((result?.reason ?? "").contains("held (2 jobs in flight"),
               "UH29 the reply's in-flight work is named (\(result?.reason ?? "nil"))")
    }

    // UH23 the Launcher's hold credential is its own 0600 file and is presented on every hold call.
    do {
        let f = rig("hold-token", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.replies = [safeReply()]
        _ = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                               serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                               http: f.client, shell: RecordingShell(mount: f.mount),
                               control: { _, _ in f.app.control })
        let attrs = try? fm.attributesOfItem(atPath: tokenPath)
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue
        let token = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        expect(mode == 0o600 && (token?.count ?? 0) == 64,
               "UH23 the Launcher hold token is a 64-hex 0600 file (\(mode ?? -1), \(token?.count ?? -1))")
        expect(f.client.lastHeaders["X-Hub-Token"] == token
               && f.client.lastHeaders["Authorization"] == "Bearer \(token ?? "")",
               "UH23 the hold presents the Launcher token (\(f.client.lastHeaders.keys.sorted()))")
    }

    // UH24 rotation replaces the credential atomically and leaves no temp file behind.
    do {
        let before = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rotated = UpdateHold.rotateToken()
        let after = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = (try? fm.attributesOfItem(atPath: tokenPath))?[.posixPermissions] as? NSNumber
        let temps = (try? fm.contentsOfDirectory(atPath: (tokenPath as NSString).deletingLastPathComponent))?
            .filter { $0.hasPrefix(".hold-token.") } ?? []
        expect(rotated != nil && rotated == after && after != before && (after?.count ?? 0) == 64
               && mode?.intValue == 0o600 && temps.isEmpty,
               "UH24 rotation is atomic, 0600 and leaves no temp (temps: \(temps))")
        expect(UpdateHold.localToken() == after, "UH24 the rotated token is the one presented next")
    }

    // UH24b a token already on disk as 0644 must come out 0600: `replaceItemAt` keeps the replaced
    // file's own mode and throws the temp's away, so the mode has to be set on the final path.
    // Library 0.7.25 refuses a hold whose token file is not 0600 (`maintenance.go:237`) — 401.
    do {
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenPath)
        _ = UpdateHold.rotateToken()
        let mode = (try? fm.attributesOfItem(atPath: tokenPath))?[.posixPermissions] as? NSNumber
        expect(mode?.intValue == 0o600, "UH24b rotation turns an inherited 0644 token into 0600 (\(mode?.intValue ?? -1))")
    }

    // UH32 Gateway's exact admin drain is a real consumer flow, and a query on it is refused.
    do {
        let adminURL = "http://127.0.0.1:8787/admin/api/maintenance/drain"
        let f = rig("hold-admin-drain", hold: adminURL, recipe: "app-dmg", running: true)
        f.client.replies = [safeReply(inFlight: 1), safeReply(inFlight: 1)]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "updated" && f.client.calls.first == "artifact" && f.client.calls.contains("hold"),
               "UH32 the exact admin drain holds before the swap (\(f.client.calls))")
    }

    // UH35 the feed records the first version that published a hold address and carries it on.
    do {
        let f = rig("hold-since", hold: holdURL, holdSince: nil)
        try! FeedPublisher.publish(feedDir: f.rig.feed, keyFile: f.rig.key, app: "demo", version: "2.0.1",
                                   artifact: f.rig.artifact("demo2.dmg", "dmg bytes 2"), kind: "fake-for-tests", allowSame: false,
                                   meta: { _ in AppMeta(name: "Demo", bundleID: "com.example.demo", bundleName: "Demo.app", version: "2.0.1", iconPNG: Data()) })
        let carried = try! FeedPublisher.loadVerifiedFeed(from: f.rig.feed, publicKey: f.rig.pair.privateKey.publicKey)!.apps["demo"]
        try! FeedPublisher.publish(feedDir: f.rig.feed, keyFile: f.rig.key, app: "demo", version: "2.0.2",
                                   artifact: f.rig.artifact("demo3.dmg", "dmg bytes 3"), kind: "fake-for-tests", allowSame: false,
                                   meta: { _ in AppMeta(name: "Demo", bundleID: "com.example.demo", bundleName: "Demo.app", version: "2.0.2", iconPNG: Data()) },
                                   holdSince: "1.5.0")
        let named = try! FeedPublisher.loadVerifiedFeed(from: f.rig.feed, publicKey: f.rig.pair.privateKey.publicKey)!.apps["demo"]
        expect(f.entry.holdSince == "2.0.0" && carried?.holdSince == "2.0.0" && named?.holdSince == "1.5.0",
               "UH35 holdSince starts at the first hold publish, is carried, and --hold-since sets it (\(f.entry.holdSince ?? "nil"), \(carried?.holdSince ?? "nil"), \(named?.holdSince ?? "nil"))")
    }

    // UH36 a build older than holdSince answering 401 needs one install while closed, said once;
    // a build at or past holdSince answering 401 is still a real credential refusal.
    do {
        func attempt(_ tag: String, installed: String) -> RecipeResult? {
            let f = rig(tag, hold: holdURL, recipe: "app-dmg", running: true)
            var feed = f.feed
            feed.apps["demo"]?.holdSince = "0.6.240"
            f.client.replies = [(status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8))]
            return try? Agent.install(app: "demo", feed: feed, installed: installed, config: f.cfg,
                                      serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                      http: f.client, shell: RecordingShell(mount: f.mount),
                                      control: { _, _ in f.app.control })
        }
        let old = attempt("hold-since-old", installed: "0.6.235")
        let current = attempt("hold-since-current", installed: "0.6.242")
        var memory = AgentMemory()
        let lines = [old, old].compactMap { $0.flatMap { Agent.refusalNote(app: "demo", version: "0.6.242", result: $0, memory: &memory) } }
        let oldReason = old?.reason ?? "", currentReason = current?.reason ?? ""
        expect(old?.status == Agent.waitingForClose && oldReason.contains("0.6.235") && oldReason.contains("0.6.240")
               && oldReason.contains("one normal install while demo is closed") && !oldReason.contains("credential")
               && lines.count == 1,
               "UH36 0.6.235 below holdSince 0.6.240 with a 401 takes the one-install path, logged once (\(oldReason); \(lines.count) lines)")
        expect(current?.status == "refused" && currentReason.contains("credential") && !currentReason.contains("predates"),
               "UH36 0.6.242 with a 401 is still a credential refusal (\(currentReason))")
    }

    // UH37 an owner's order for a running build with no hold waits: it stays pending, the page
    // says why, and it installs on the first run that finds the app closed. One order is enough.
    do {
        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        func order(_ f: (rig: Rig, feed: Feed, entry: FeedApp, cfg: AgentConfig, client: HoldClient, app: FakeApp, state: URL, mount: URL),
                   days: Int?) -> (AgentConfig, () -> [String: Any]?) {
            f.client.postError = URLError(.cannotConnectToHost)
            var cfg = f.cfg
            cfg.token = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
            cfg.waitForCloseDays = days
            cfg.quitOldBuilds = false   // the switch off: the order waits for the app to close
            _ = f.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                                       body: Data(#"{"machine":"mac1","app":"demo"}"#.utf8)), remote: "127.0.0.1")
            return (cfg, { () -> [String: Any]? in
                let r = try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                                           control: { _, _ in f.app.control }, appFolders: [])
                return r.map { ["notes": $0.notes] }
            })
        }
        let f = rig("hold-wait-order", hold: holdURL, recipe: "app-dmg", running: true)
        let (_, run) = order(f, days: nil)
        let machine = { (try? StateStore.load(from: f.rig.state))?.machines["mac1"] }
        let notes1 = (run()?["notes"] as? [String] ?? []).filter { $0.contains("Waiting for demo to close") }
        let pending1 = machine()?.pending.count
        let notes2 = (run()?["notes"] as? [String] ?? []).filter { $0.contains("Waiting for demo to close") }
        let page = String(decoding: f.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: owner), remote: "127.0.0.1").data, as: UTF8.self)
        let shown = machine()?.waiting?["demo"] ?? ""
        expect(notes1.count == 1 && notes2.isEmpty && pending1 == 1 && machine()?.pending.count == 1
               && machine()?.lastResults?["demo"] == nil && shown.hasPrefix("Waiting for demo to close")
               && page.contains("to close</span>") && page.contains(shown.prefix(40)),
               "UH37 a waiting order stays pending, is logged once and the page says why (notes \(notes1.count)/\(notes2.count), pending \(pending1 ?? -1))")
        f.app.running = false
        _ = run()
        let landed = machine()?.lastResults?["demo"]?.status ?? "none"
        expect(machine()?.pending.isEmpty == true && landed != "refused" && landed != Agent.waitingForClose && f.client.calls.contains("artifact"),
               "UH37 the same order installs once the app is closed (\(landed))")

        // The wait has its own ceiling: past it the order is answered refused, terminal.
        let g = rig("hold-wait-ceiling", hold: holdURL, recipe: "app-dmg", running: true)
        let (_, runG) = order(g, days: 0)
        _ = runG(); _ = runG()
        let ended = (try? StateStore.load(from: g.rig.state))?.machines["mac1"]
        expect(ended?.pending.isEmpty == true && ended?.lastResults?["demo"]?.status == "refused"
               && (ended?.lastResults?["demo"]?.reason ?? "").contains("waited 0 days for demo to close"),
               "UH37 past its ceiling the wait ends refused with the reason (\(ended?.lastResults?["demo"]?.reason ?? "nil"))")
    }

    // UH53 the 0.1.60 change, end to end and with Automatic off: the bytes are fetched while the app
    // keeps working, the row reads Downloaded with what it waits for, and the very next run installs
    // it once the app is closed — no second request, and the same bytes are never fetched again.
    do {
        let f = rig("wait-download-first", hold: holdURL, recipe: "app-dmg", running: true)
        var cfg = f.cfg
        cfg.token = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
        cfg.apps["demo"]?.automatic = false
        f.client.replies = [unsafeReply(["render-7"]), unsafeReply(["render-7"])]
        let run = { (requested: Set<String>) -> AgentRunResult? in
            try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                               control: { _, _ in f.app.control }, requested: requested, appFolders: [])
        }
        let first = run(["demo"])
        let row = first?.apps.first { $0.app == "demo" }
        expect(row?.status == HelperApp.downloaded && (row?.reason ?? "").contains("waiting for demo to close"),
               "UH53 a finished download with its app open reads Downloaded, not failed (\(row?.status ?? "nil"); \(row?.reason ?? ""))")
        expect(f.client.count("artifact") == 1 && f.client.calls.first == "artifact" && f.app.running,
               "UH53 the bytes come first and the app is never quit (\(f.client.calls))")
        f.app.running = false
        let second = run([])
        expect(second?.updates == 1 && f.client.count("artifact") == 1,
               "UH53 the next run installs the downloaded update without fetching it again (\(f.client.calls))")
        expect((try? BundleInfo.read(f.app.installed.path))?.version == "2.0.0" && f.app.events.contains("launch"),
               "UH53 the app on disk is the new version and was reopened (\(f.app.events))")
    }

    // UH54 the wait has the same ceiling when nothing is left to re-issue it: past it the wait ends
    // quietly and the row is a plain update again, never a stuck Downloaded row.
    do {
        let f = rig("wait-ceiling", hold: holdURL, recipe: "app-dmg", running: true)
        var cfg = f.cfg
        cfg.token = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
        cfg.apps["demo"]?.automatic = false
        cfg.waitForCloseDays = 0
        f.client.replies = [unsafeReply(["render-7"]), unsafeReply(["render-7"])]
        let first = try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                                       control: { _, _ in f.app.control }, requested: ["demo"], appFolders: [])
        let firstRow = first?.apps.first { $0.app == "demo" }
        expect(firstRow?.status == HelperApp.downloaded,
               "UH54 the first run leaves a downloaded update waiting (\(firstRow?.status ?? "nil"); \(firstRow?.reason ?? ""))")
        // A minute later than the first run, so a zero-day ceiling is unambiguously past, whatever
        // the machine's load does to how fast the two runs follow each other.
        let again = try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                                       control: { _, _ in f.app.control }, now: Date().addingTimeInterval(60),
                                       appFolders: [])
        let row = again?.apps.first { $0.app == "demo" }
        expect(again?.notes.contains { $0.contains("the wait has ended") } == true
               && row?.status == HelperApp.updateAvailable && f.app.running,
               "UH54 past the ceiling the wait ends and the row is a plain update again (\(row?.status ?? "nil"); notes \(again?.notes ?? []); running \(f.app.running))")
    }

    // UH55 a download that fails never leaves a waiting row: nothing was downloaded, so nothing waits.
    do {
        let f = rig("wait-download-fails", hold: holdURL, recipe: "app-dmg", running: true)
        var cfg = f.cfg
        cfg.token = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
        cfg.apps["demo"]?.automatic = false
        f.client.artifacts[f.entry.file] = nil   // the artifact is not on the publisher
        let run = try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                                     control: { _, _ in f.app.control }, requested: ["demo"], appFolders: [])
        let row = run?.apps.first { $0.app == "demo" }
        expect(row?.status != HelperApp.downloaded && !f.client.calls.contains("hold") && f.app.running,
               "UH55 a failed download leaves no waiting row and never holds the app (\(row?.status ?? "nil"); \(f.client.calls))")
    }

    // UH38 end to end: a feed entry published with holdSince, a running build below it answering
    // 401. The order waits, this Mac's log and the owner page's row say "waiting for close", and
    // nothing anywhere calls it a credential refusal.
    do {
        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        let f = rig("hold-since-e2e", hold: holdURL, recipe: "app-dmg", running: true, holdSince: "1.5.0")
        f.client.replies = Array(repeating: (status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8)), count: 4)
        var cfg = f.cfg
        cfg.token = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
        cfg.quitOldBuilds = false
        _ = f.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                                   body: Data(#"{"machine":"mac1","app":"demo"}"#.utf8)), remote: "127.0.0.1")
        let run = { (try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, appFolders: []))?.notes ?? [] }
        let notes = run() + run()
        let machine = (try? StateStore.load(from: f.rig.state))?.machines["mac1"]
        let page = String(decoding: f.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: owner), remote: "127.0.0.1").data, as: UTF8.self)
        let waitNotes = notes.filter { $0.contains("waiting_for_close") && $0.contains("first in 1.5.0") }
        expect(f.entry.holdSince == "1.5.0" && machine?.pending.count == 1 && machine?.lastResults?["demo"] == nil
               && waitNotes.count == 1 && !notes.contains { $0.contains("(credential)") }
               && page.contains("Waiting for demo to close</span>") && page.contains("predates its update hold (first in 1.5.0)")
               && !page.contains("refused the update hold (credential)") && f.app.events.isEmpty,
               "UH38 a build below the published holdSince answering 401 reads waiting for close on the Mac and the page, never credential (notes \(waitNotes.count), pending \(machine?.pending.count ?? -1))")
    }

    // UH39 default on: an owner's order for a running build with no hold route quits it the way
    // updates worked before holds, installs, relaunches it, and logs one line saying so.
    do {
        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        let f = rig("legacy-quit-order", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.cannotConnectToHost)
        var cfg = f.cfg
        cfg.token = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
        cfg.apps["demo"]?.idleProbe = "exit 0"   // Hub's owner: nothing running or queued
        _ = f.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                                   body: Data(#"{"machine":"mac1","app":"demo"}"#.utf8)), remote: "127.0.0.1")
        let notes = (try? Agent.runOnce(config: cfg, http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, appFolders: []))?.notes ?? []
        let machine = (try? StateStore.load(from: f.rig.state))?.machines["mac1"]
        let lines = notes.filter { $0.contains("predates its update hold, asked to quit without one") }
        let quitAt = f.app.events.firstIndex(of: "quit"), launchAt = f.app.events.lastIndex(of: "launch")
        expect(machine?.pending.isEmpty == true && machine?.lastResults?["demo"]?.status == "updated"
               && lines.count == 1 && lines[0].contains("quit cleanly and was updated")
               && quitAt != nil && launchAt != nil && quitAt! < launchAt! && f.client.calls.contains("artifact")
               && (try? BundleInfo.read(f.app.installed.path))?.version == "2.0.0"
               && notes.contains { $0.contains("idle check exited 0") }
               && notes.contains { $0.contains("quit: the app exited after") }
               && notes.contains { $0.contains("services: started") }
               && notes.contains { $0.contains("the app came back as 2.0.0") },
               "UH39 a build with no hold route is quit, installed and relaunched by one order, with the check, the quit, the services and the return all logged (\(lines); events \(f.app.events))")
    }

    // UH40 the hold path is unchanged for a build at or past holdSince: a 401 stays a credential
    // refusal (nothing quit), and a safe hold is still taken before the byte.
    do {
        let f = rig("legacy-quit-current", hold: holdURL, recipe: "app-dmg", running: true)
        var feed = f.feed
        feed.apps["demo"]?.holdSince = "0.6.240"
        f.client.replies = [(status: 401, data: Data(#"{"error":"unauthorized"}"#.utf8))]
        let refused = try? Agent.install(app: "demo", feed: feed, installed: "0.6.242", config: f.cfg,
                                         serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                         http: f.client, shell: RecordingShell(mount: f.mount),
                                         control: { _, _ in f.app.control }, quitOldBuild: true)
        let g = rig("legacy-quit-held", hold: holdURL, recipe: "app-dmg", running: true)
        g.client.replies = [safeReply(inFlight: 1), safeReply(inFlight: 1)]
        let held = try? Agent.install(app: "demo", feed: g.feed, installed: "1.0.0", config: g.cfg,
                                      serverBase: URL(string: "http://pub.test")!, stateDir: g.state,
                                      http: g.client, shell: RecordingShell(mount: g.mount),
                                      control: { _, _ in g.app.control }, quitOldBuild: true)
        expect(refused?.status == "refused" && (refused?.reason ?? "").contains("credential") && refused?.quitWithoutHold == false
               && !f.app.events.contains("quit")
               && held?.status == "updated" && g.client.calls.first == "artifact" && held?.quitWithoutHold == false,
               "UH40 at or past holdSince the hold path is unchanged (\(refused?.reason ?? "nil"); \(g.client.calls))")
    }

    // UH41 an old build that will not quit within its ceiling is refused with the reason; nothing
    // is swapped, it keeps running, and nothing is killed.
    do {
        let f = rig("legacy-quit-refuses", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.cannotConnectToHost)
        f.app.quits = [false]
        var idle = f.cfg
        idle.apps["demo"]?.idleProbe = "exit 0"
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: idle,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, quitOldBuild: true)
        expect(result?.status == "refused" && (result?.reason ?? "").contains("did not quit within its time limit")
               && result?.quitWithoutHold == true && f.app.running
               && (result?.quitTrace ?? []).contains { $0.contains("its own ceiling was reached") }
               && (result?.quitTrace ?? []).contains { $0.contains("idle check exited 0") }
               && (try? BundleInfo.read(f.app.installed.path))?.version == "1.0.0" && !f.app.events.contains("launch"),
               "UH41 a build that will not quit is refused and left as it was, and the log says the ceiling was reached (\(result?.quitTrace ?? []); events \(f.app.events))")
    }

    // UH42 the off switch: `quitOldBuilds: false` means this Mac's orders never quit an app, and
    // the order keeps waiting for it to close. That is the only thing that stops the force path.
    do {
        let f = rig("legacy-quit-switched-off", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.cannotConnectToHost)
        var cfg = f.cfg
        cfg.quitOldBuilds = false
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, quitOldBuild: false)
        expect(result?.status == Agent.waitingForClose && result?.quitWithoutHold == false
               && !f.app.events.contains("quit") && !f.app.events.contains("launch") && f.app.running,
               "UH42 quitOldBuilds: false means no quit and the order keeps waiting (\(result?.status ?? "nil"))")
    }

    // UH43 the check is obeyed: a pre-hold build whose check refuses (or never answers) is not quit.
    // The 2026-11-16 force path ignored it and quit Story with nine jobs running (2026-11-19).
    do {
        let f = rig("legacy-busy-probe", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.cannotConnectToHost)
        var busy = f.cfg
        busy.apps["demo"]?.idleProbe = "echo '2 jobs queued'; exit 3"
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: busy,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, quitOldBuild: true)
        let silent = Agent.idleRefusal(app: "demo", probe: "sleep 5", shell: RecordingShell(mount: f.mount), timeout: 1).said
        expect(result?.status == Agent.waitingForClose && result?.quitWithoutHold == false
               && (result?.reason ?? "").contains("exited 3 (2 jobs queued)")
               && (result?.reason ?? "").contains("tries again")
               && !f.app.events.contains("quit")
               && (try? BundleInfo.read(f.app.installed.path))?.version == "1.0.0"
               && silent.contains("did not answer within 1 s"),
               "UH43 a refusing check stops the quit and the wait says why (\(result?.status ?? "nil"); \(silent))")
    }

    // UH44 Hub's idle command is a shell string with quotes and `$HOME` in it: it must survive a
    // config round-trip untouched, and an app with no probe must still decode (old configs work).
    do {
        let hub = "test -r \"$HOME/Library/Application Support/StudioHub Standalone/hub/hub.db\" && [ \"$(sqlite3 -readonly \"$HOME/Library/Application Support/StudioHub Standalone/hub/hub.db\" \"select count(*) from batches\" 2>/dev/null)\" = 0 ]"
        var cfg = AgentConfig(feedURL: "http://100.64.0.7/release.json", publicKey: "k", stateDir: "/tmp/s",
                              machine: "mac1", token: "t")
        cfg.apps = ["hub": AppConfig(bundlePath: "/Applications/Hub Studio KH.app", recipe: "hub",
                                     automatic: true, bundleID: "local.studiohub.standalone", idleProbe: hub),
                    "story": AppConfig(bundlePath: "/Applications/Story.app", recipe: "story")]
        let back = try? JSON.decode(AgentConfig.self, from: JSON.encode(cfg))
        expect(back?.apps["hub"]?.idleProbe == hub && back?.apps["story"]?.idleProbe == nil,
               "UH44 an idle check survives a config round-trip byte for byte, and an app without one decodes to nil")
    }

    // UH45 Hub's check ships with the helper, so no Mac has to be visited to arm it. The Mac's own
    // setting still wins, an explicit empty string turns it off there, and any other app with no
    // setting gets no check at all.
    do {
        let bare = AppConfig(bundlePath: "/Applications/Hub Studio KH.app", recipe: "hub")
        let own = AppConfig(bundlePath: "/Applications/Hub Studio KH.app", recipe: "hub", idleProbe: "exit 0")
        let off = AppConfig(bundlePath: "/Applications/Hub Studio KH.app", recipe: "hub", idleProbe: "  ")
        let other = AppConfig(bundlePath: "/Applications/Story.app", recipe: "story")
        let offSaid = Agent.idleRefusal(app: "hub", probe: Agent.idleProbe(app: "hub", cfg: off),
                                        shell: RecordingShell(mount: tmpDir("uh45"))).skip
        expect(Agent.idleProbe(app: "hub", cfg: bare) == Agent.builtInIdleProbes["hub"]
               && (Agent.builtInIdleProbes["hub"] ?? "").contains("hub.db")
               && Agent.idleProbe(app: "hub", cfg: own) == "exit 0"
               && Agent.idleProbe(app: "hub", cfg: off) == "  " && offSaid != nil
               && Agent.idleProbe(app: "story", cfg: other) == nil
               && Agent.idleRefusal(app: "story", probe: Agent.idleProbe(app: "story", cfg: other),
                                    shell: RecordingShell(mount: tmpDir("uh45"))).skip != nil,
               "UH45 Hub's idle check is built in, a Mac's own setting wins, an empty one turns it off (\(offSaid ?? "nil"))")
    }

    // UH46 the built-in check really decides Hub's legacy quit end to end, with no Mac setting at
    // all: idle → quit, install, relaunch; not idle → the order keeps waiting and says what the
    // check saw. The probe is never run here; only its answer is scripted.
    do {
        let idle = rig("builtin-probe-idle", hold: holdURL, recipe: "app-dmg", running: true, id: "hub")
        idle.client.postError = URLError(.cannotConnectToHost)
        let done = try? Agent.install(app: "hub", feed: idle.feed, installed: "1.0.0", config: idle.cfg,
                                      serverBase: URL(string: "http://pub.test")!, stateDir: idle.state,
                                      http: idle.client,
                                      shell: ProbeShell(inner: RecordingShell(mount: idle.mount), probeExit: 0, probeOut: ""),
                                      control: { _, _ in idle.app.control }, quitOldBuild: true)
        let busy = rig("builtin-probe-busy", hold: holdURL, recipe: "app-dmg", running: true, id: "hub")
        busy.client.postError = URLError(.cannotConnectToHost)
        let waited = try? Agent.install(app: "hub", feed: busy.feed, installed: "1.0.0", config: busy.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: busy.state,
                                        http: busy.client,
                                        shell: ProbeShell(inner: RecordingShell(mount: busy.mount), probeExit: 3,
                                                          probeOut: "7 items queued\n"),
                                        control: { _, _ in busy.app.control }, quitOldBuild: true)
        expect(done?.status == "updated" && done?.quitWithoutHold == true && idle.app.events.contains("quit")
               && (try? BundleInfo.read(idle.app.installed.path))?.version == "2.0.0",
               "UH46 Hub's built-in check runs with no Mac setting, and an idle Hub is updated (\(done?.status ?? "nil"))")
        // The check decides: a Hub with queued items keeps running and is never asked to quit. The
        // force path that ignored this check quit Story with nine jobs running (2026-11-19).
        expect(waited?.status == Agent.waitingForClose && !busy.app.events.contains("quit")
               && (waited?.reason ?? "").contains("idle check exited 3 (7 items queued)")
               && (waited?.reason ?? "").contains("tries again")
               && (try? BundleInfo.read(busy.app.installed.path))?.version == "1.0.0",
               "UH46 a Hub with queued items is not quit; the wait says why and is retried (\(waited?.status ?? "nil"), \(waited?.reason ?? "nil"))")
    }

    // UH47 a launch agent's environment is not an interactive shell's: the check is run with the
    // user's real HOME and a fixed PATH exported, quotes and spaces in the path intact, and Hub's
    // check calls /usr/bin/sqlite3 rather than whatever a PATH happens to find.
    do {
        let spy = ScriptSpy(answer: ShellResult(exitCode: 0, stdout: "", stderr: ""))
        _ = Agent.idleRefusal(app: "hub", probe: "true", shell: spy,
                              home: URL(fileURLWithPath: "/Users/a b/Mac"))
        let script = spy.scripts.first ?? ""
        expect(script.contains("HOME='/Users/a b/Mac'\nexport HOME")
               && script.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH")
               && Agent.shellWord("x'y") == "'x'\\''y'"
               && (Agent.builtInIdleProbes["hub"] ?? "").contains("/usr/bin/sqlite3")
               && !(Agent.builtInIdleProbes["hub"] ?? "").contains("$(sqlite3"),
               "UH47 the check runs with an explicit HOME and PATH and an absolute sqlite3 (\(script.prefix(60)))")
    }

    // UH48 a refusing Hub check says why: a missing folder is named, and a file that is not a
    // database gives sqlite's own words, instead of the bare "exited 1 (no output)" that hid the
    // difference between an unreadable database, a missing sqlite3 and a genuinely busy Hub.
    do {
        let empty = tmpDir("uh48-home")
        let missing = Agent.idleRefusal(app: "hub", probe: "exit 1", shell: RecordingShell(mount: tmpDir("uh48")),
                                        home: empty)
        let db = empty.appendingPathComponent(Agent.hubDatabase)
        try? fm.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not a database".utf8).write(to: db)
        let foreign = Agent.idleRefusal(app: "hub", probe: "exit 1", shell: RecordingShell(mount: tmpDir("uh48")),
                                        home: empty)
        expect((missing.skip ?? "").contains("no database at ")
               && (foreign.skip ?? "").lowercased().contains("not a database")
               && !(missing.skip ?? "").contains("(no output)") && !(foreign.skip ?? "").contains("(no output)"),
               "UH48 a refusing Hub check says why (\(missing.said) | \(foreign.said))")
    }

    // UH49 a pre-hold build with no idle check at all is NOT quit: no check means no proof it is
    // idle, so the order keeps waiting and says so. (The force path used to quit it.)
    do {
        let f = rig("force-no-probe", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.cannotConnectToHost)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "0.6.235", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control }, quitOldBuild: true)
        // One expect per condition: the runner prints only the description of a red line, so an ANDed
        // assertion hides which part failed. Keep every condition, and let each name itself.
        expect(result?.status == Agent.waitingForClose, "UH49a a pre-hold build with no check waits (\(result?.status ?? "nil") \(result?.reason ?? "nil"))")
        expect(result?.quitWithoutHold == false, "UH49b the result says nothing was quit")
        expect(!f.app.events.contains("quit"), "UH49c the app was not asked to quit (events \(f.app.events))")
        expect(!f.app.events.contains("launch") && (try? BundleInfo.read(f.app.installed.path))?.version == "1.0.0",
               "UH49d the app keeps running as it was (events \(f.app.events))")
        expect((result?.reason ?? "").contains("no idle check configured") && (result?.reason ?? "").contains("tries again"),
               "UH49e the reason says no check exists and that it is retried (\(result?.reason ?? "nil"))")
        expect((result?.quitTrace ?? []).contains { $0.contains("idle check: none configured") },
               "UH49f with no check configured the trace says exactly that (trace \(result?.quitTrace ?? []))")
        expect((try? BundleInfo.read(f.app.installed.path))?.version == "1.0.0",
               "UH49g the installed bundle is untouched (\((try? BundleInfo.read(f.app.installed.path))?.version ?? "nil"))")
    }

    // UH21 a gated endpoint and a wrong address are named separately from an absent endpoint.
    do {
        let f = rig("hold-401", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.replies = [(status: 401, data: Data(#"{"error":"no credential"}"#.utf8))]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        let reason = result?.reason ?? ""
        expect(result?.status == "refused" && reason.contains("credential") && !reason.contains("no update-hold endpoint"),
               "UH21 a 401 names the credential, not a missing endpoint (\(reason))")
        // UH34 that refusal reaches this Mac's own log once per app, version and reason.
        var memory = AgentMemory()
        let refused = result ?? RecipeResult(status: "missing")
        let first = Agent.refusalNote(app: "demo", version: "1.1.0", result: refused, memory: &memory)
        let again = Agent.refusalNote(app: "demo", version: "1.1.0", result: refused, memory: &memory)
        let newer = Agent.refusalNote(app: "demo", version: "1.2.0", result: refused, memory: &memory)
        _ = Agent.refusalNote(app: "demo", version: "1.2.0", result: RecipeResult(status: "updated"), memory: &memory)
        let afterSuccess = Agent.refusalNote(app: "demo", version: "1.2.0", result: refused, memory: &memory)
        expect(first?.hasPrefix("demo 1.1.0: refused — ") == true && first?.contains("credential") == true
               && again == nil && newer != nil && afterSuccess != nil,
               "UH34 a refused attempt is logged locally once per version and reason, and again after a success (\(first ?? "nil"))")
    }
    do {
        let f = rig("hold-404", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.replies = [(status: 404, data: Data())]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        let reason = result?.reason ?? ""
        expect(result?.status == "refused" && reason.contains("feed's address") && !reason.contains("credential"),
               "UH22 a 404 names the feed address, not a credential (\(reason))")
    }

    // UH19 an installed build with no hold endpoint gets a named bootstrap step, not a bare -1004.
    do {
        let f = rig("hold-absent", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.cannotConnectToHost)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        let reason = result?.reason ?? ""
        expect(result?.status == Agent.waitingForClose && reason.contains("no update-hold endpoint")
               && reason.contains("one normal install"),
               "UH19 an absent endpoint names the bootstrap install (\(reason))")
    }

    // UH20 a slow endpoint names its hold timeout: never reported as an absent endpoint or a generic error.
    do {
        let f = rig("hold-timeout", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.timedOut)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        let reason = result?.reason ?? ""
        expect(result?.status == "refused" && !reason.contains("no update-hold endpoint")
               && reason.contains("did not answer its update hold within 35 s")
               && reason.contains("asked to settle for 20 s"),
               "UH20 a timeout names the update-hold timeout and both numbers, not an absent endpoint (\(reason))")
    }

    // UH30/UH31 a build that predates its hold is quit only when its own idle check passes. The
    // 2026-11-16 force path skipped that check; on macmini-angkor a quit with nine jobs running
    // left a "quit anyway?" sheet and an update waiting for a person.
    do {
        let f = rig("pre-hold-busy", hold: holdURL, recipe: "app-dmg", holdSince: "1.5.0")
        f.client.replies = [(404, Data("no hold route".utf8))]
        var cfg = f.cfg
        cfg.apps["demo"]?.idleProbe = "probe-idle"
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: ProbeShell(inner: RecordingShell(mount: f.mount), probeExit: 1, probeOut: "9 jobs running\n"),
                                        control: { _, _ in f.app.control }, quitOldBuild: true)
        let reason = result?.reason ?? ""
        expect(!f.app.events.contains("quit"),
               "UH30 an app with work running is never asked to quit, even without a hold endpoint (\(f.app.events))")
        expect(result?.status == Agent.waitingForClose && reason.contains("9 jobs running")
               && reason.contains("tries again"),
               "UH30 the refusal is a wait that says why and is retried by the next check (\(result?.status ?? "nil"), \(reason))")
    }
    do {
        let f = rig("pre-hold-idle", hold: holdURL, recipe: "app-dmg", holdSince: "1.5.0")
        f.client.replies = [(404, Data("no hold route".utf8))]
        var cfg = f.cfg
        cfg.apps["demo"]?.idleProbe = "probe-idle"
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: ProbeShell(inner: RecordingShell(mount: f.mount), probeExit: 0, probeOut: "idle\n"),
                                        control: { _, _ in f.app.control }, quitOldBuild: true)
        expect(result?.status == "updated" && f.app.events.contains("quit"),
               "UH31 an app whose own idle check passes is still updated without a hold (\(result?.status ?? "nil"), \(f.app.events))")
        expect((result?.reason ?? "").contains("idle check passed"),
               "UH31 the result says the idle check is what allowed the quit (\(result?.reason ?? "nil"))")
    }

    // UH11 the hold request is allowed the settle window plus its answer margin — never clamped
    // back to the app's own 20 s, which is the race that lost a real 20.2 s refusal.
    do {
        final class SlowClient: HTTPClient, @unchecked Sendable {
            var seen: TimeInterval = 0
            var seenURL: URL?
            func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { (Data(), 200) }
            func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { (Data(), 500) }
            func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws -> (Data, Int) {
                seen = timeout; seenURL = url
                return (Data(), 500)
            }
            func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int) { (Data(), 200) }
            func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { 500 }
        }
        let client = SlowClient()
        let endpoint = UpdateHold.trusted(holdURL)!
        let started = Date()
        _ = try? UpdateHold.begin(endpoint, http: client, deadline: Date().addingTimeInterval(UpdateHold.answerAllowance))
        expect(client.seen > UpdateHold.settleWindow && client.seen <= UpdateHold.answerAllowance
               && Date().timeIntervalSince(started) < 2,
               "UH11 the hold POST carries the settle window plus its margin, not the window (\(client.seen) s)")
        // A renew (timeout_s=0) asks for no settle but stays bounded the same way.
        _ = try? UpdateHold.begin(endpoint, http: client, timeoutS: 0)
        expect(client.seenURL?.query?.contains("timeout_s=0") == true && client.seen <= UpdateHold.answerAllowance,
               "UH11 a renew sends timeout_s=0 and is still bounded (\(client.seenURL?.query ?? "nil"))")
        UpdateHold.resume(endpoint, http: client)
    }

    // UH51 a real endpoint that settles for 20.2 s and refuses reaches the caller as the app's own
    // answer: the client's allowance sits above the app's window, so the refusal is not lost to -1001.
    do {
        // The Launcher's own credential lives in this Mac's state; a test never writes there.
        let tokenFile = tmpDir("uh51-token").appendingPathComponent("hold-token").path
        setenv("KHU_HOLD_TOKEN_FILE", tokenFile, 1)
        defer { unsetenv("KHU_HOLD_TOKEN_FILE") }
        let server = SlowHoldServer(delay: 20.2, body: #"{"safe":false,"unsettled":["job-a","job-b"]}"#)
        let endpoint = server.endpoint!
        defer { server.stop() }
        let reply = try? UpdateHold.begin(endpoint, http: URLSessionHTTPClient(),
                                          deadline: Date().addingTimeInterval(UpdateHold.answerAllowance))
        expect(reply?.safe == false && reply?.unsettled == ["job-a", "job-b"],
               "UH51 a 20.2 s refusal arrives whole instead of timing out (\(reply?.unsettled ?? []))")
    }

    // UH52 an endpoint that never answers ends as the typed timeout, at the allowance and not before.
    do {
        let tokenFile = tmpDir("uh52-token").appendingPathComponent("hold-token").path
        setenv("KHU_HOLD_TOKEN_FILE", tokenFile, 1)
        defer { unsetenv("KHU_HOLD_TOKEN_FILE") }
        let server = SlowHoldServer(delay: 36, body: #"{"safe":true}"#)
        let endpoint = server.endpoint!
        defer { server.stop() }
        let started = Date()
        var timedOut = false
        do {
            _ = try UpdateHold.begin(endpoint, http: URLSessionHTTPClient(),
                                     deadline: Date().addingTimeInterval(UpdateHold.answerAllowance))
        } catch { timedOut = UpdateHold.timedOut(error) }
        let took = Date().timeIntervalSince(started)
        expect(timedOut && took >= UpdateHold.settleWindow && took < UpdateHold.answerAllowance + 5,
               "UH52 a silent endpoint ends as the typed timeout at the allowance (\(Int(took)) s)")
    }

    // UH12 an app opened while the installer was prepared is refused at the boundary when it has no
    // endpoint: no byte, no quit, no journal and no staged copy.
    do {
        let f = rig("hold-flip-refuse", hold: nil, recipe: "app-dmg", running: false)
        var calls = 0
        let flips = AppControl(isRunning: { calls += 1; return calls > 1 }, quit: { false }, launch: {},
                               stopService: { true }, healthy: { _ in true }, healthTimeout: 0.2, pollInterval: 0.02)
        var failure = ""
        do {
            _ = try Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                  serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                  http: f.client, shell: RecordingShell(mount: f.mount), control: { _, _ in flips })
        } catch { failure = "\(error)" }
        let journal = Recipe.journalURL(stateDir: f.state.path, app: "demo")
        let staged = f.cfg.apps["demo"]!.bundlePath + ".khu-staging"
        expect(failure.contains("does not name an update-hold endpoint") && !fm.fileExists(atPath: journal.path)
               && !fm.fileExists(atPath: staged),
               "UH12 an app opened mid-update is refused before the journal (\(failure))")
    }

    // UH13 the same flip with an endpoint: the hold is taken at the boundary and the app is updated.
    do {
        let f = rig("hold-flip-hold", hold: holdURL, recipe: "app-dmg", running: false)
        var calls = 0
        let flips = AppControl(isRunning: { calls += 1; return calls > 1 }, quit: { true }, launch: {},
                               stopService: { true }, healthy: { _ in true }, healthTimeout: 0.2, pollInterval: 0.02)
        f.client.replies = [safeReply(), safeReply()]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount), control: { _, _ in flips })
        expect(result?.status == "updated" && f.client.calls == ["artifact", "hold", "hold", "resume"],
               "UH13 an app opened mid-update is held at the boundary (\(f.client.calls))")
    }

    // UH14 an app that exited while the installer downloaded needs no renewal: it cannot be
    // interrupted, so the swap goes ahead with a single hold.
    do {
        let f = rig("hold-exit", hold: holdURL, recipe: "app-dmg", running: true)
        var calls = 0
        let exits = AppControl(isRunning: { calls += 1; return calls == 1 }, quit: { true }, launch: {},
                               stopService: { true }, healthy: { _ in true }, healthTimeout: 0.2, pollInterval: 0.02)
        f.client.replies = [safeReply()]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount), control: { _, _ in exits })
        expect(result?.status == "updated" && f.client.calls == ["artifact", "hold", "resume"],
               "UH14 an app that exited needs no boundary renewal (\(f.client.calls))")
        expect(!f.app.events.contains("quit"), "UH14 a non-running app is not quit")
    }

    // UH15 an owner rollback is a swap too: a running app is held first, or refused without an endpoint.
    do {
        let r = R6Rig("hold-rollback")
        let holdFeed = try? FeedPublisher.loadVerifiedFeed(from: r.rig.feed, publicKey: r.rig.pair.privateKey.publicKey)
        let holdURL = holdFeed?.apps["foo"]?.holdURL
        let client = HoldClient(InProcessClient(server: r.rig.server))
        client.replies = [safeReply(), safeReply()]
        let rolled = try? Agent.orderedRollback(app: "foo", order: "o1", installed: "2.0.0", config: r.config,
                                                stateDir: URL(fileURLWithPath: r.config.stateDir),
                                                shell: RecordingShell(mount: r.rig.root.appendingPathComponent("empty")),
                                                control: { _, _ in r.control }, holdURL: holdURL, http: client)
        expect(rolled?.status == "rolled_back_by_owner" && client.calls == ["hold", "hold", "resume"],
               "UH15 a rollback holds the running app, renews at the boundary and resumes (\(client.calls))")
        let refused = try? Agent.orderedRollback(app: "foo", order: "o2", installed: "2.0.0", config: r.config,
                                                 stateDir: URL(fileURLWithPath: r.config.stateDir),
                                                 shell: RecordingShell(mount: r.rig.root.appendingPathComponent("empty")),
                                                 control: { _, _ in r.control }, holdURL: nil, http: client)
        expect(refused?.status == "refused" && (refused?.reason ?? "").contains("does not name an update-hold endpoint"),
               "UH15 a rollback without an endpoint is refused while the app runs")
    }

    // UH10 the updater's own Launcher updates while running: it has no work queue to hold.
    do {
        let r = Rig("hold-self")
        let installed = makeApp(r.root.appendingPathComponent("Launcher.app"), version: "1.0.0", id: "com.khupdater.launcher")
        try! FeedPublisher.publish(feedDir: r.feed, keyFile: r.key, app: "launcher", version: "2.0.0",
                                   artifact: r.artifact("launcher.dmg", "launcher bytes"), kind: "app-dmg", allowSame: false,
                                   meta: { _ in AppMeta(name: "Studio Launcher KH", bundleID: "com.khupdater.launcher", bundleName: "Launcher.app", version: "2.0.0", iconPNG: Data()) })
        let feed = try! FeedPublisher.loadVerifiedFeed(from: r.feed, publicKey: r.pair.privateKey.publicKey)!
        let state = r.root.appendingPathComponent("state")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        let client = HoldClient(InProcessClient(server: r.server))
        client.artifacts[feed.apps["launcher"]!.file] = Data("launcher bytes".utf8)
        var cfg = agentConfig(r, token: "unused", apps: ["launcher": AppConfig(bundlePath: installed.path, recipe: "app-dmg", automatic: false)])
        cfg.stateDir = state.path
        let app = FakeApp(installed: installed, running: true, quits: [true], healthy: ["2.0.0"])
        let mount = r.root.appendingPathComponent("mount")
        makeApp(mount.appendingPathComponent("Launcher.app"), version: "2.0.0", id: "com.khupdater.launcher")
        let result = try? Agent.install(app: "launcher", feed: feed, installed: "1.0.0", config: cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: state,
                                        http: client, shell: RecordingShell(mount: mount),
                                        control: { _, _ in app.control })
        expect(result?.status == "updated" && !client.calls.contains("hold"),
               "UH10 the updater's own Launcher updates while running, with no hold (\(client.calls))")
    }

    // UH33 the signed feed keeps Gateway's exact admin drain and drops near-misses.
    do {
        func validatedHoldURL(_ raw: String) -> String? {
            var feed = Feed(published_at: ISO.string(Date()), apps: [:])
            var entry = FeedApp(version: "1.0.0", file: "a.dmg", sha256: String(repeating: "a", count: 64), bytes: 4, kind: "app-dmg")
            entry.holdURL = raw
            feed.apps["a"] = entry
            return (try? feed.validated())?.apps["a"]?.holdURL
        }
        expect(validatedHoldURL("http://127.0.0.1:8787/admin/api/maintenance/drain")
               == "http://127.0.0.1:8787/admin/api/maintenance/drain",
               "UH33 the exact admin drain survives feed validation")
        expect(validatedHoldURL("http://127.0.0.1:8787/admin/api/maintenance/drain?x=1") == nil
               && validatedHoldURL("http://127.0.0.1:8787/admin/api/maintenance/hold") == nil
               && validatedHoldURL("http://127.0.0.1:8787/admin/api/maintenance/drain/extra") == nil,
               "UH33 a query, another admin path or a longer path is dropped")
    }

    // UH9 a feed that names a remote endpoint loses it: the app is unsupported, not interrupted.
    do {
        var feed = Feed(published_at: ISO.string(Date()), apps: [:])
        var entry = FeedApp(version: "1.0.0", file: "a.dmg", sha256: String(repeating: "a", count: 64), bytes: 4, kind: "app-dmg")
        entry.holdURL = "http://10.0.0.5:8799/api/maintenance/hold"
        feed.apps["a"] = entry
        let validated = try? feed.validated()
        expect(validated?.apps["a"]?.holdURL == nil, "UH9 a remote hold endpoint is dropped from the signed feed")
    }

    // UH50 the Fleet page counts how many enrolled Macs are still below holdSince.
    do {
        let f = rig("fleet-hold-count", hold: holdURL, recipe: "app-dmg", running: false, holdSince: "0.6.240")
        _ = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac1")
        _ = try! Enrolment.enrol(stateDir: f.rig.state, machine: "mac2")
        try! StateStore.update(in: f.rig.state) { st in
            st.machines["mac1"]?.installed["demo"] = "0.6.235"
            st.machines["mac2"]?.installed["demo"] = "0.6.240"
        }
        let htmlBefore = f.rig.server.statusHTML()
        expect(htmlBefore.contains("1 Mac below hold (0.6.240; each updates when it is idle)"),
               "UH50 Fleet counts Macs still below holdSince, and says each updates when idle")
        try! StateStore.update(in: f.rig.state) { st in
            st.machines["mac1"]?.installed["demo"] = "0.6.240"
        }
        let htmlAfter = f.rig.server.statusHTML()
        expect(htmlAfter.contains("0 Macs below hold (0.6.240)"),
               "UH50 Fleet says when zero Macs remain below holdSince")
    }
}
