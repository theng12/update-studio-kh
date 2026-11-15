import Foundation

/// A feed client that answers the app's update-hold endpoint from a script and records the order of
/// hold, artifact and resume calls, so a test can prove the hold really precedes any byte.
private final class HoldClient: HTTPClient, @unchecked Sendable {
    let inner: InProcessClient
    var artifacts: [String: Data] = [:]
    /// One reply per POST, consumed in order; an empty script answers 500.
    var replies: [(status: Int, data: Data)] = []
    var calls: [String] = []
    let lock = NSLock()
    init(_ inner: InProcessClient) { self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { try inner.get(url, headers: headers) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        guard url.host == "127.0.0.1" else { return try inner.post(url, headers: headers, body: body) }
        lock.lock(); calls.append("hold"); let reply = replies.isEmpty ? (status: 500, data: Data()) : replies.removeFirst(); lock.unlock()
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

    // UH1 the trusted endpoint is this Mac's loopback, the contract's two paths and nothing else.
    expect(UpdateHold.trusted(holdURL) != nil && UpdateHold.trusted("http://127.0.0.1:8799/api/maintenance/drain") != nil,
           "UH1 the contract's loopback hold and drain endpoints are trusted")
    let untrusted = ["https://127.0.0.1:8799/api/maintenance/hold", "http://10.0.0.5:8799/api/maintenance/hold",
                     "http://127.0.0.1/api/maintenance/hold", "http://127.0.0.1:8799/api/other",
                     "http://user:pass@127.0.0.1:8799/api/maintenance/hold"]
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
        expect(result?.status == "refused" && (result?.reason ?? "").contains("does not offer an update hold")
               && f.client.calls.isEmpty && !f.app.events.contains("quit"),
               "UH5 an app with no hold endpoint is refused before any byte and never quit")
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
