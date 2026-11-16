import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A feed client that answers the app's update-hold endpoint from a script and records the order of
/// hold, artifact and resume calls, so a test can prove the hold really precedes any byte.
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

    func rig(_ tag: String, hold: String?, recipe: String = "fake-for-tests", running: Bool = true)
        -> (rig: Rig, feed: Feed, entry: FeedApp, cfg: AgentConfig, client: HoldClient, app: FakeApp, state: URL, mount: URL) {
        let r = Rig(tag)
        let installed = makeApp(r.root.appendingPathComponent("Demo.app"), version: "1.0.0", id: "com.example.demo")
        try! FeedPublisher.publish(feedDir: r.feed, keyFile: r.key, app: "demo", version: "2.0.0",
                                   artifact: r.artifact("demo.dmg", "dmg bytes"), kind: recipe == "fake-for-tests" ? "fake-for-tests" : "app-dmg",
                                   allowSame: false, meta: { _ in AppMeta(name: "Demo", bundleID: "com.example.demo", bundleName: "Demo.app", version: "2.0.0", iconPNG: Data()) },
                                   holdURL: hold)
        let feed = try! FeedPublisher.loadVerifiedFeed(from: r.feed, publicKey: r.pair.privateKey.publicKey)!
        let state = r.root.appendingPathComponent("state")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        let client = HoldClient(InProcessClient(server: r.server))
        client.artifacts[feed.apps["demo"]!.file] = Data("dmg bytes".utf8)
        var cfg = agentConfig(r, token: "unused", apps: ["demo": AppConfig(bundlePath: installed.path, recipe: recipe, automatic: true)])
        cfg.stateDir = state.path
        let app = FakeApp(installed: installed, running: running, quits: [true], healthy: ["2.0.0"])
        let mount = r.root.appendingPathComponent("mount")
        makeApp(mount.appendingPathComponent("Demo.app"), version: "2.0.0", id: "com.example.demo")
        return (r, feed, feed.apps["demo"]!, cfg, client, app, state, mount)
    }

    // UH2 a safe hold is taken before the artifact and resumed after the install.
    do {
        let f = rig("hold-safe", hold: holdURL)
        f.client.replies = [safeReply(inFlight: 2)]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "updated" && f.client.calls == ["hold", "artifact", "resume"],
               "UH2 a safe hold comes before any byte and is resumed after the install (\(f.client.calls))")
        expect((result?.reason ?? "").contains("held (2 jobs in flight; new work paused 120 s)"),
               "UH2 the result says how much work was held (\(result?.reason ?? "nil"))")
    }

    // UH3 an unsafe reply is retried once and then refused: nothing is downloaded, the app is resumed.
    do {
        let f = rig("hold-unsafe", hold: holdURL)
        f.client.replies = [unsafeReply(["render-7"]), unsafeReply(["render-7", "tts-3"])]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && (result?.reason ?? "").contains("render-7")
               && (result?.reason ?? "").contains("tts-3") && !f.client.calls.contains("artifact"),
               "UH3 an unsafe reply is refused with the unsettled names and nothing is downloaded")
        expect(f.client.calls == ["hold", "hold", "resume"], "UH3 the retry and the resume are the only calls (\(f.client.calls))")
    }

    // UH4 an app that does not answer is refused and resumed, never installed over.
    do {
        let f = rig("hold-unreachable", hold: holdURL)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && !f.client.calls.contains("artifact") && f.client.calls.last == "resume",
               "UH4 an unreachable hold refuses the install and resumes (\(f.client.calls))")
    }

    // UH5 a running app with no hold endpoint is unsupported: refused before any byte, no quit.
    do {
        let f = rig("hold-unsupported", hold: nil, recipe: "app-dmg")
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && (result?.reason ?? "").contains("does not name an update-hold endpoint")
               && f.client.calls.isEmpty && !f.app.events.contains("quit"),
               "UH5 an app the feed gives no endpoint is refused before any byte and never quit")
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
        expect(f.client.calls == ["hold", "artifact", "hold", "resume"],
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
               && !f.client.calls.contains("artifact") && !f.app.events.contains("quit"),
               "UH25 a missing token stops before download, quit or replace (\(result?.reason ?? "nil"))")
        setenv("KHU_HOLD_TOKEN_FILE", tokenPath, 1)
    }
    do { // UH26 a wrong token is refused by the endpoint, before any byte.
        let f = gated("hold-wrong-token", token: String(repeating: "a", count: 64), accept: { $0 == String(repeating: "b", count: 64) })
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "refused" && !f.client.calls.contains("artifact") && f.app.events.isEmpty,
               "UH26 a wrong token stops before any download or quit")
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
        expect(result?.status == "refused" && !f.client.calls.contains("artifact") && f.app.events.isEmpty,
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
               && f.client.calls == ["hold", "artifact", "hold", "resume"],
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

    // UH32 Gateway's exact admin drain is a real consumer flow, and a query on it is refused.
    do {
        let adminURL = "http://127.0.0.1:8787/admin/api/maintenance/drain"
        let f = rig("hold-admin-drain", hold: adminURL, recipe: "app-dmg", running: true)
        f.client.replies = [safeReply(inFlight: 1), safeReply(inFlight: 1)]
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        expect(result?.status == "updated" && f.client.calls.first == "hold",
               "UH32 the exact admin drain holds before the byte (\(f.client.calls))")
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
        expect(result?.status == "refused" && reason.contains("no update-hold endpoint")
               && reason.contains("one normal install") && !f.client.calls.contains("artifact"),
               "UH19 an absent endpoint names the bootstrap install (\(reason))")
    }

    // UH20 a slow endpoint stays a timeout: the bootstrap wording is only for a refused connection.
    do {
        let f = rig("hold-timeout", hold: holdURL, recipe: "app-dmg", running: true)
        f.client.postError = URLError(.timedOut)
        let result = try? Agent.install(app: "demo", feed: f.feed, installed: "1.0.0", config: f.cfg,
                                        serverBase: URL(string: "http://pub.test")!, stateDir: f.state,
                                        http: f.client, shell: RecordingShell(mount: f.mount),
                                        control: { _, _ in f.app.control })
        let reason = result?.reason ?? ""
        expect(result?.status == "refused" && !reason.contains("no update-hold endpoint"),
               "UH20 a timeout is not reported as an absent endpoint (\(reason))")
    }

    // UH11 the hold request is bounded by the contract's 30 s window, not the client's 60 s.
    do {
        final class SlowClient: HTTPClient, @unchecked Sendable {
            var seen: TimeInterval = 0
            func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { (Data(), 200) }
            func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { (Data(), 500) }
            func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws -> (Data, Int) {
                seen = timeout
                return (Data(), 500)
            }
            func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int) { (Data(), 200) }
            func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { 500 }
        }
        let client = SlowClient()
        let endpoint = UpdateHold.trusted(holdURL)!
        let started = Date()
        _ = try? UpdateHold.begin(endpoint, http: client, deadline: Date().addingTimeInterval(UpdateHold.ceiling))
        expect(client.seen > 0 && client.seen <= UpdateHold.ceiling && Date().timeIntervalSince(started) < 2,
               "UH11 the hold POST carries a bounded deadline (\(client.seen) s)")
        UpdateHold.resume(endpoint, http: client)
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
        expect(result?.status == "updated" && f.client.calls == ["hold", "artifact", "resume"],
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
}
