import Foundation

/// A Mac on the public mirror must still update itself: automatic updates depend on the feed, not
/// on a publisher. These four checks are the owner's question — "can a GitHub Mac auto-update at
/// all?" — turned into tests.
private final class SweepHTTP: HTTPClient, @unchecked Sendable {
    let feed: Data
    let inner: InProcessClient
    private(set) var posts: [String] = []
    init(feed: Data, inner: InProcessClient) { self.feed = feed; self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        url.host == "theng12.github.io" ? (feed, 200) : try inner.get(url, headers: headers)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        posts.append(url.path)
        return try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        try inner.download(url, headers: headers, to: file, limit: limit)
    }
}

func publicFeedSweepTests() {
    /// A feed published by this rig, served as the public mirror, with one older app installed here.
    func fixture(_ tag: String, app: String) -> (rig: Rig, cfg: AgentConfig, client: SweepHTTP)? {
        let rig = Rig(tag)
        try? rig.publish(app, "2.0.0", rig.artifact("\(app).zip", "\(app)-bytes"))
        guard let feedBytes = try? Data(contentsOf: rig.feed.appendingPathComponent("release.json")) else { return nil }
        let appURL = makeApp(tmpDir(tag + "-app").appendingPathComponent("Demo.app"), version: "1.0.0")
        var cfg = agentConfig(rig, token: "", apps: [app: AppConfig(bundlePath: appURL.path, recipe: "fake-for-tests")])
        cfg.feedURL = Connect.publicFeedURL
        return (rig, cfg, SweepHTTP(feed: feedBytes, inner: InProcessClient(server: rig.server)))
    }

    // SW1. Public feed, older app installed, this Mac's Automatic on: the sweep attempts the app's
    // update, and the run posts nothing anywhere — no status, no result, no order.
    do {
        guard let f = fixture("sweep-public", app: "demo") else { expect(false, "SW1 fixture"); return }
        let shell = CaptureShell()
        let run = try? Agent.runOnce(config: f.cfg, http: f.client, shell: shell, appFolders: [])
        expect(run != nil && !shell.calls.isEmpty,
               "SW1 a Mac on the public feed updates an installed app automatically (calls \(shell.calls.count))")
        expect(f.client.posts.isEmpty, "SW1 a public-feed run posts nothing anywhere (\(f.client.posts))")
    }

    // SW2. This Mac's own switch off: nothing is installed, and the note names that switch — never
    // "no publisher" as the reason for not updating.
    do {
        guard let f = fixture("sweep-off", app: "demo") else { expect(false, "SW2 fixture"); return }
        let state = URL(fileURLWithPath: f.cfg.stateDir)
        try? fm.createDirectory(at: state, withIntermediateDirectories: true)
        try? #"{"automatic":{"demo":false}}"#.write(to: state.appendingPathComponent("helper.json"),
                                                     atomically: true, encoding: .utf8)
        let shell = CaptureShell()
        let run = try? Agent.runOnce(config: f.cfg, http: f.client, shell: shell, appFolders: [])
        expect(run?.updates == 0, "SW2 with this Mac's own Automatic off, nothing is installed")
        expect(run?.notes.contains { $0.contains("demo") && $0.contains("Mac") } == true,
               "SW2 the skip note names this Mac's own switch (\(run?.notes ?? []))")
        expect(run?.notes.contains { $0.contains("publisher is unavailable") } != true,
               "SW2 no note blames a missing publisher on a public feed")
    }

    // SW3. A publisher-fed Mac keeps today's behaviour exactly: it updates, and it reports.
    do {
        let rig = Rig("sweep-publisher")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let appURL = makeApp(tmpDir("sweep-pub-app").appendingPathComponent("Demo.app"), version: "1.0.0")
        let token = (try? Enrolment.enrol(stateDir: rig.state, machine: "mac1")) ?? ""
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: appURL.path, recipe: "fake-for-tests")])
        let shell = CaptureShell()
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), shell: shell, appFolders: [])
        expect(run != nil && !shell.calls.isEmpty, "SW3 a publisher-fed Mac updates exactly as before")
    }

    // SW4. The updater's own entry updates from the public feed.
    do {
        guard let f = fixture("sweep-updater", app: "updater") else { expect(false, "SW4 fixture"); return }
        let shell = CaptureShell()
        let run = try? Agent.runOnce(config: f.cfg, http: f.client, shell: shell, appFolders: [])
        expect(run != nil && !shell.calls.isEmpty, "SW4 the updater's own entry updates from the public feed")
        expect(f.client.posts.isEmpty, "SW4 the updater update posts nothing")
    }
}
