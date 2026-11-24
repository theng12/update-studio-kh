import Foundation

/// Real filesystem staging/rollback with mount, signatures and process control supplied by fixtures.
private final class StandaloneShell: Shell, @unchecked Sendable {
    let root: URL
    var mount: URL
    var refused = false
    /// How many staging copies `stage()` has actually run, so a fixture can let the app come up half
    /// way through an install the way a person does.
    var dittoRuns = 0
    init(root: URL, mount: URL) { self.root = root; self.mount = mount }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/usr/bin/hdiutil", arguments.first == "attach" {
            if refused { return ShellResult(exitCode: 1, stdout: "", stderr: "fixture attach failure") }
            let data = try PropertyListSerialization.data(fromPropertyList: ["system-entities": [["mount-point": mount.path, "dev-entry": "/dev/disk999s1"]]], format: .xml, options: 0)
            return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        if executable == "/usr/bin/codesign", arguments.first == "-dvv",
           let path = arguments.last, let info = try? BundleInfo.read(path) {
            return ShellResult(exitCode: 0, stdout: "Identifier=\(info.identifier)\nTeamIdentifier=FIXTURE\n", stderr: "")
        }
        if executable == "/usr/bin/ditto" {
            guard arguments.allSatisfy({ $0.hasPrefix(root.path + "/") }) else { throw khuFail("fixture ditto escaped its root") }
            dittoRuns += 1
            return try SystemShell().run(executable, arguments: arguments, timeout: timeout)
        }
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private final class StandaloneHTTP: HTTPClient, @unchecked Sendable {
    var server: FeedServer?
    var refusal: Int?
    var badRelease = false
    var feedFailure: URLError?
    var downloads = 0
    init(_ server: FeedServer? = nil) { self.server = server }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        if let feedFailure { throw feedFailure }
        guard let server else { throw URLError(.cannotConnectToHost) }
        if badRelease && url.lastPathComponent == "release.json" { return (Data("unsigned".utf8), 200) }
        return try InProcessClient(server: server).get(url, headers: headers)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if let refusal { return (Data(), refusal) }
        guard let server else { throw URLError(.cannotConnectToHost) }
        return try InProcessClient(server: server).post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        downloads += 1
        guard let server else { throw URLError(.cannotConnectToHost) }
        return try InProcessClient(server: server).download(url, headers: headers, to: file, limit: limit)
    }
}

/// Counts what a hand install of a running Production app is never allowed to do.
private final class HandActions: @unchecked Sendable {
    var quits = 0, stops = 0, launches = 0
}

/// The hand route's early looks get a quiet answer; the third read is promotion's own, taken where
/// the app would be stopped, and it finds the app running.
private final class PromotionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Bool] = []
    var quits = 0, stops = 0, launches = 0
    func running() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let answer = log.count >= 2      // the third read is promotion's own
        log.append(answer)
        return answer
    }
    var answers: [Bool] { lock.lock(); defer { lock.unlock() }; return log }
}

func standaloneLauncherTests() {
    let id = "new-kh-app", bundleID = "com.fixture.new-kh-app"
    func setup(_ tag: String) -> (Rig, AgentConfig, URL, URL, StandaloneShell, StandaloneHTTP) {
        let rig = Rig("standalone-" + tag)
        let folder = rig.root.appendingPathComponent("Applications")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let mount = rig.root.appendingPathComponent("mount")
        _ = makeApp(mount.appendingPathComponent("New KH.app"), version: "2.0", id: bundleID)
        let artifact = rig.artifact("New KH.dmg", "signed installer target bytes")
        try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: id, version: "2.0", artifact: artifact,
                                   kind: "app-dmg", allowSame: false,
                                   url: "https://github.com/theng12/new-kh/releases/download/2.0/New.KH-2.0.dmg",
                                   meta: { _ in
            AppMeta(name: "New KH", bundleID: bundleID, bundleName: "New KH.app", version: "2.0", iconPNG: nil)
        })
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: [:])
        var settings = HelperSettings(); settings.autoInstall = false
        try! settings.save(to: URL(fileURLWithPath: cfg.stateDir))
        return (rig, cfg, folder, artifact, StandaloneShell(root: rig.root, mount: mount), StandaloneHTTP(rig.server))
    }
    func source(_ rig: Rig, bytes: Data, version: String) -> SSDSource {
        let ssd = rig.root.appendingPathComponent("SSD")
        try! fm.createDirectory(at: ssd, withIntermediateDirectories: true)
        let file = ssd.appendingPathComponent("New KH.dmg")
        try! bytes.write(to: file)
        var app = SSDApp(id: id, name: "New KH", version: version, bundleID: bundleID, bundleName: "New KH.app", file: file.lastPathComponent, sha256: Signing.sha256Hex(bytes))
        app.bytes = Int64(bytes.count)
        return SSDSource(volume: "Fixture SSD", root: ssd, index: SSDIndex(apps: [app]))
    }
    let control = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true }, healthSettle: 0)
    // A new published app requires no hard-coded app registry or separately installed helper UI.
    do {
        let (rig, cfg, folder, _, shell, http) = setup("fresh-online")
        let appData = rig.root.appendingPathComponent("app-data.json")
        try! Data("owner-data-kept".utf8).write(to: appData)
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], appFolders: [folder])
        expect(result?.apps.first(where: { $0.app == id })?.installed == "2.0" && http.downloads == 1, "SL1 fresh feed-only app installs through the existing safe recipe")
        let registered = try? AtomicFile.readJSON([String: AppConfig].self, from: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("launcher-apps.json"))
        expect(registered?[id]?.bundlePath == folder.appendingPathComponent("New KH.app").path, "SL1 first install is registered for recovery before staging")
        expect((try? String(contentsOf: appData, encoding: .utf8)) == "owner-data-kept", "SL1 app data is preserved")
        expect(cfg.apps.isEmpty, "SL1 connection config and saved app choices are not rewritten")
    }
    // Older local bytes are a first-install choice; the next explicit update uses the newer server.
    do {
        let (rig, cfg, folder, _, shell, http) = setup("older-ssd")
        let ssd = source(rig, bytes: Data("older SSD installer".utf8), version: "1.0")
        let oldMount = rig.root.appendingPathComponent("old-mount")
        _ = makeApp(oldMount.appendingPathComponent("New KH.app"), version: "1.0", id: bundleID)
        let newMount = shell.mount; shell.mount = oldMount
        let first = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: ["ssd:" + id], ssd: [ssd], appFolders: [folder])
        let row = first?.apps.first { $0.app == id }
        expect(row?.installed == "1.0" && row?.available == "2.0" && row?.status == HelperApp.updateAvailable && http.downloads == 0, "SL2 older SSD first install keeps the newer server update available")
        shell.mount = newMount
        let second = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], ssd: [ssd], appFolders: [folder])
        expect(second?.apps.first(where: { $0.app == id })?.installed == "2.0" && http.downloads == 1, "SL2 subsequent server update installs the newer version")
        expect((try? BundleInfo.read(URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("rollback-\(id)/New KH.app").path).version) == "1.0", "SL2 previous working app remains available for rollback")
        expect(HelperSettings.load(from: URL(fileURLWithPath: cfg.stateDir)).autoInstall == false, "SL2 manual update setting stays off")
        // The fourth appearance choice is gone: a stored "default" from before reads as System.
        let legacyDir = tmpDir("legacy-appearance")
        var legacy = HelperSettings(); legacy.appearance = "default"
        try? legacy.save(to: legacyDir)
        expect(HelperSettings.load(from: legacyDir).appearance == "system",
               "SL2 a stored Default appearance reads as System")
        var kept = HelperSettings(); kept.appearance = "dark"
        try? kept.save(to: legacyDir)
        expect(HelperSettings.load(from: legacyDir).appearance == "dark",
               "SL2 a real choice is left alone")
        let offline = try? Agent.runOnce(config: cfg, http: StandaloneHTTP(), shell: shell, control: { _, _ in control }, requested: ["rollback:" + id], appFolders: [folder])
        expect(offline?.commandsRun == 1 && offline?.apps.first(where: { $0.app == id })?.installed == "1.0", "SL2 explicit rollback works offline and has a visible result")
        var automatic = HelperSettings.load(from: URL(fileURLWithPath: cfg.stateDir))
        automatic.autoInstall = true
        try! automatic.save(to: URL(fileURLWithPath: cfg.stateDir))
        let reconnected = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
        expect(reconnected?.commandsRun == 0 && reconnected?.apps.first(where: { $0.app == id })?.installed == "1.0" && http.downloads == 1,
               "SL2 reconnect reconciles offline rollback before Automatic can reinstall the rejected version")
    }
    do {
        let (rig, cfg, folder, artifact, shell, http) = setup("current-ssd")
        let ssd = source(rig, bytes: try! Data(contentsOf: artifact), version: "2.0")
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], ssd: [ssd], appFolders: [folder])
        expect(result?.apps.first(where: { $0.app == id })?.installed == "2.0" && http.downloads == 0, "SL3 current matching SSD avoids the server artifact download")
    }
    // A disconnected host never converts an invalid signed feed or an HTTP refusal into offline permission.
    do {
        let (rig, cfg, folder, artifact, shell, _) = setup("offline")
        let ssd = source(rig, bytes: try! Data(contentsOf: artifact), version: "2.0")
        let http = StandaloneHTTP()
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], ssd: [ssd], appFolders: [folder])
        let row = result?.apps.first { $0.app == id }
        expect(result?.feedError != nil && row?.installed == "2.0" && row?.serverVersion == nil && !result!.statusPosted, "SL4 offline explicit SSD install reports unknown server state")
        let empty = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
        expect(empty?.feedError != nil && empty?.commandsRun == 0, "SL4 offline with no SSD never starts Automatic or remote orders")
    }
    for refused in [false, true] {
        let (rig, cfg, folder, artifact, shell, http) = setup(refused ? "refusal" : "bad-feed")
        let ssd = source(rig, bytes: try! Data(contentsOf: artifact), version: "2.0")
        if refused { http.refusal = 401 } else { http.badRelease = true }
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], ssd: [ssd], appFolders: [folder])
        expect(result == nil && !fm.fileExists(atPath: folder.appendingPathComponent("New KH.app").path), "SL5 invalid feed/HTTP refusal does not silently fall back or install")
    }
    do {
        let (_, cfg, folder, _, shell, http) = setup("failed-first")
        shell.refused = true
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], appFolders: [folder])
        let saved = try? AtomicFile.readJSON([String: AppConfig].self, from: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("launcher-apps.json"))
        expect(result?.apps.first(where: { $0.app == id })?.status == HelperApp.failed && saved?[id] != nil
               && !fm.fileExists(atPath: folder.appendingPathComponent("New KH.app").path), "SL6 interrupted first setup retains its recovery registration without a partial installed app")
        shell.refused = false
        let retried = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], appFolders: [folder])
        expect(retried?.apps.first(where: { $0.app == id })?.installed == "2.0", "SL6 retry resumes from the preserved first-install registration")
    }
    do {
        let (_, cfg, folder, _, shell, http) = setup("different-existing-app")
        let existing = makeApp(folder.appendingPathComponent("New KH.app"), version: "1.0", id: "com.fixture.unrelated")
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], appFolders: [folder])
        expect(result?.commandsRun == 1 && result?.apps.first(where: { $0.app == id })?.status == HelperApp.failed
               && (try? BundleInfo.read(existing.path).identifier) == "com.fixture.unrelated" && http.downloads == 0,
               "SL6 a named path containing a different app is never treated as a fresh install")
    }
    do {
        let (rig, cfg, folder, _, shell, http) = setup("batch-registration")
        try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "bad", version: "1.0", artifact: rig.artifact("bad.dmg", "legacy metadata missing"), kind: "app-dmg", allowSame: false, url: "https://example.test/fixture.dmg", meta: nil)
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: ["bad", id], appFolders: [folder])
        expect(result?.commandsRun == 2 && result?.apps.first(where: { $0.app == id })?.installed == "2.0" && http.downloads == 1,
               "SL7 one refused first install does not stop the next app")
        expect(result?.apps.first { $0.app == "bad" }?.installable == false,
               "SL7 an offer with no app identity is drawn without an Install the agent could not run")
        let memory = try? AtomicFile.readJSON(AgentMemory.self, from: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("agent-memory.json"))
        expect(memory?.done.values.contains(where: { $0.app == "bad" && $0.status == "refused" }) == true,
               "SL7 per-app registration failure has a durable visible result")
    }
    do {
        let (_, original, folder, _, shell, http) = setup("saved-alias")
        let target = makeApp(folder.appendingPathComponent("New KH.app"), version: "1.0", id: bundleID)
        var cfg = original
        cfg.apps[id] = AppConfig(bundlePath: target.path, bundleID: bundleID)
        let saved = URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("launcher-apps.json")
        try! AtomicFile.writeJSON(["old-alias": cfg.apps[id]!], to: saved)
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
        expect(result?.statusPosted == true && result?.notes.contains(where: { $0.contains("old-alias") && $0.contains("skipped") }) == true,
               "SL8 stale saved alias does not block the configured app or helper")
        expect(fm.fileExists(atPath: saved.path) && marker(target) == "1.0", "SL8 skipped registration and installed app stay recoverable")
    }
    do {
        let (rig, cfg, folder, artifact, shell, http) = setup("status-then-offline")
        let ssd = source(rig, bytes: try! Data(contentsOf: artifact), version: "2.0")
        http.feedFailure = URLError(.networkConnectionLost)
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [id], ssd: [ssd], appFolders: [folder])
        expect(result?.statusPosted == true && result?.feedError != nil && result?.apps.first(where: { $0.app == id })?.installed == "2.0",
               "SL9 feed outage preserves an already successful status post")
        for code in [URLError.Code.secureConnectionFailed, .cancelled] {
            let (_, other, apps, _, fixtureShell, fixtureHTTP) = setup("refused-transport")
            fixtureHTTP.feedFailure = URLError(code)
            let refused = try? Agent.runOnce(config: other, http: fixtureHTTP, shell: fixtureShell, control: { _, _ in control }, requested: [id], appFolders: [apps])
            expect(refused == nil, "SL9 TLS and cancellation failures do not grant offline installation")
        }
        expect(Agent.transportUnavailable(NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)),
               "SL9 URLSession NSError transport failures are recognised")
    }
    // Corruption, cancellation and downgrade preserve the installed app and all app data.
    do {
        let (rig, cfg, folder, artifact, shell, _) = setup("local-failures")
        let ssd = source(rig, bytes: try! Data(contentsOf: artifact), version: "2.0")
        let target = makeApp(folder.appendingPathComponent("New KH.app"), version: "1.0", id: bundleID)
        let appCfg = AppConfig(bundlePath: target.path, bundleID: bundleID)
        let local = Catalog.build(feed: nil, ssd: [ssd]).first!.ssd!
        DownloadControl.cancel()
        let cancelled = try? Agent.installLocal(local, app: id, installed: "1.0", cfg: appCfg, stateDir: URL(fileURLWithPath: cfg.stateDir), shell: shell, control: { _, _ in control })
        expect(cancelled == nil && marker(target) == "1.0", "SL6 cancellation before promotion leaves the installed app intact")
        DownloadControl.reset()
        try! Data("corrupt".utf8).write(to: URL(fileURLWithPath: local.file))
        let corrupt = try? Agent.installLocal(local, app: id, installed: "1.0", cfg: appCfg, stateDir: URL(fileURLWithPath: cfg.stateDir), shell: shell, control: { _, _ in control })
        expect(corrupt?.status == "refused" && marker(target) == "1.0", "SL6 corrupt SSD bytes never reach promotion")
        let older = CatalogEntry.Local(volume: "Fixture SSD", file: local.file, sha256: local.sha256, version: "0.5")
        let down = try? Agent.installLocal(older, app: id, installed: "1.0", cfg: appCfg, stateDir: URL(fileURLWithPath: cfg.stateDir), shell: shell, control: { _, _ in control }, force: true)
        expect(down?.status == "current" && marker(target) == "1.0", "SL6 reinstall cannot turn into an SSD downgrade")
    }
    // An app the live sources mark as updating itself: the person at this Mac may install or update
    // it by choosing it, and nothing else may. The feed's own `status` kind is that marker now —
    // Story and Hub publish as `app-dmg` and install like every other app.
    do {
        let appID = "story", storyBundle = "com.fixture.story", storyName = "Story Studio KH.app"
        func storySetup(_ tag: String, version: String = "2.0", app: String = appID, bundle: String = storyBundle,
                        name: String = storyName, label: String = "Story Studio KH", kind: String = "status",
                        bytes: String = "story installer bytes") -> (Rig, AgentConfig, URL, StandaloneShell, StandaloneHTTP) {
            let rig = Rig("standalone-" + tag)
            let folder = rig.root.appendingPathComponent("Applications")
            try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let mount = rig.root.appendingPathComponent("mount")
            _ = makeApp(mount.appendingPathComponent(name), version: version, id: bundle)
            let artifact = rig.artifact("\(label).dmg", bytes)
            try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: app, version: version, artifact: artifact,
                                       kind: kind, allowSame: false, url: "https://example.test/fixture.dmg", meta: { _ in
                AppMeta(name: label, bundleID: bundle, bundleName: name, version: version, iconPNG: nil)
            })
            let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
            let cfg = agentConfig(rig, token: token, apps: [:])
            var settings = HelperSettings(); settings.autoInstall = true
            try! settings.save(to: URL(fileURLWithPath: cfg.stateDir))
            return (rig, cfg, folder, StandaloneShell(root: rig.root, mount: mount), StandaloneHTTP(rig.server))
        }
        func storySSD(_ rig: Rig, _ bytes: Data, version: String, mainOnly: Bool = false, app: String = appID,
                      bundle: String = storyBundle, name: String = storyName) -> SSDSource {
            let ssd = rig.root.appendingPathComponent("SSD-" + UUID().uuidString.prefix(4))
            try! fm.createDirectory(at: ssd, withIntermediateDirectories: true)
            let file = ssd.appendingPathComponent("\(name).dmg")
            try! bytes.write(to: file)
            var entry = SSDApp(id: app, name: name, version: version, bundleID: bundle, bundleName: name,
                               file: file.lastPathComponent, sha256: Signing.sha256Hex(bytes), updatesItself: true)
            entry.bytes = Int64(bytes.count); entry.mainMacOnly = mainOnly
            return SSDSource(volume: "Fixture SSD", root: ssd, index: SSDIndex(apps: [entry]))
        }
        let control = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true }, healthSettle: 0)
        // A fresh Mac with only the remote Updater: the app is offered, and installed by hand.
        do {
            let (rig, cfg, folder, shell, http) = storySetup("story-feed-only")
            let offer = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            let row = offer?.apps.first { $0.app == appID }
            expect(row?.statusOnly == true && row?.manuallyInstallable == true && row?.status == HelperApp.notInstalled
                   && row?.installed == nil && offer?.commandsRun == 0,
                   "SL10 an app that updates itself is offered on a Mac that does not have it, and nothing installs by itself")
            let installed = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], appFolders: [folder])
            expect(installed?.apps.first { $0.app == appID }?.installed == "2.0" && http.downloads == 1,
                   "SL10 the person chooses it: it installs from the signed feed")
            // Automatic is on for everything else, and still leaves this app alone.
            try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: appID, version: "3.0",
                                       artifact: rig.artifact("Story 3.dmg", "story three bytes"), kind: "status",
                                       allowSame: false, url: "https://example.test/fixture.dmg", meta: { _ in
                AppMeta(name: "Story Studio KH", bundleID: storyBundle, bundleName: storyName, version: "3.0", iconPNG: nil)
            })
            let automatic = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(automatic?.commandsRun == 0 && automatic?.apps.first { $0.app == appID }?.installed == "2.0" && http.downloads == 1,
                   "SL10 Automatic leaves an app that updates itself alone, and offers the newer version instead")
            expect(automatic?.notes.contains { $0.hasPrefix("\(appID): skipped") && $0.contains("updating itself") } == true,
                   "SL10 a skipped app says why in the run's notes, never only as updates=0")
            // The publisher's own order is not the person's choice: it never installs it.
            let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
            _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                                     body: Data(#"{"machine":"mac1","app":"story"}"#.utf8)), remote: "127.0.0.1")
            let ordered = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(ordered?.apps.first { $0.app == appID }?.installed == "2.0" && http.downloads == 1,
                   "SL10 a remote order never installs an app that updates itself")
        }
        // The SSD copy of the same version installs from there, with no download.
        do {
            let (rig, cfg, folder, shell, http) = storySetup("story-current-ssd")
            // The copy on the SSD has to be the bytes the server signed for that version, or the
            // catalog refuses it as "not the bytes the server signed".
            let signed = try! FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey)
            let published = try! Data(contentsOf: rig.feed.appendingPathComponent("artifacts/\(signed!.apps[appID]!.file)"))
            let ssd = storySSD(rig, published, version: "2.0")
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], ssd: [ssd], appFolders: [folder])
            expect(result?.apps.first { $0.app == appID }?.installed == "2.0" && http.downloads == 0,
                   "SL11 an app that updates itself installs from the SSD copy, with no download")
        }
        // An older SSD copy is an explicit first install; the newer server version stays available.
        do {
            let (rig, cfg, folder, shell, http) = storySetup("story-older-ssd")
            let ssd = storySSD(rig, Data("older story bytes".utf8), version: "1.0")
            let oldMount = rig.root.appendingPathComponent("old-mount")
            _ = makeApp(oldMount.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            shell.mount = oldMount
            let first = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: ["ssd:" + appID], ssd: [ssd], appFolders: [folder])
            let row = first?.apps.first { $0.app == appID }
            expect(row?.installed == "1.0" && row?.available == "2.0" && http.downloads == 0,
                   "SL12 an older SSD copy is an explicit first install, and the newer server version stays available")
            shell.mount = rig.root.appendingPathComponent("mount")
            let second = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], ssd: [ssd], appFolders: [folder])
            expect(second?.apps.first { $0.app == appID }?.installed == "2.0" && http.downloads == 1,
                   "SL12 the next explicit choice installs the newer version over the older one")
        }
        // A running app is kept: this route proves no quiet point.
        do {
            let (_, cfg, folder, shell, http) = storySetup("story-running")
            let running = AppControl(isRunning: { true }, quit: { true }, launch: {}, healthy: { _ in true }, healthSettle: 0)
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in running }, requested: [appID], appFolders: [folder])
            let row = result?.apps.first { $0.app == appID }
            expect(row?.status == HelperApp.failed && row?.reason?.contains("No quiet point was proved") == true
                   && http.downloads == 0 && !fm.fileExists(atPath: folder.appendingPathComponent(storyName).path),
                   "SL13 a running app that updates itself is kept, and the refusal says why")
        }
        // An app only the main Mac may install stays off this Mac.
        do {
            let (rig, cfg, folder, shell, http) = storySetup("story-main-mac")
            let ssd = storySSD(rig, Data("story installer bytes".utf8), version: "2.0", mainOnly: true)
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], ssd: [ssd], appFolders: [folder])
            expect(result?.commandsRun == 0 && !fm.fileExists(atPath: folder.appendingPathComponent(storyName).path),
                   "SL14 an app marked for the main Mac is not installed here")
        }
        // An older copy is never put over a newer installed app.
        do {
            let (rig, cfg, folder, shell, http) = storySetup("story-downgrade")
            let ssd = storySSD(rig, Data("older story bytes".utf8), version: "1.0")
            _ = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], appFolders: [folder])
            let oldMount = rig.root.appendingPathComponent("old-mount")
            _ = makeApp(oldMount.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            shell.mount = oldMount
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: ["ssd:" + appID], ssd: [ssd], appFolders: [folder])
            expect(result?.apps.first { $0.app == appID }?.installed == "2.0"
                   && marker(folder.appendingPathComponent(storyName)) == "2.0",
                   "SL15 an older SSD copy never replaces a newer installed app")
        }
        // An interrupted first install keeps its registration, and the next run finishes it.
        do {
            let (_, cfg, folder, shell, http) = storySetup("story-interrupted")
            shell.refused = true
            let failed = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], appFolders: [folder])
            let saved = try? AtomicFile.readJSON([String: AppConfig].self, from: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("launcher-apps.json"))
            expect(failed?.apps.first { $0.app == appID }?.status == HelperApp.failed && saved?[appID] != nil
                   && !fm.fileExists(atPath: folder.appendingPathComponent(storyName).path),
                   "SL16 an interrupted first install keeps its recovery registration and leaves no partial app")
            shell.refused = false
            let retried = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: [appID], appFolders: [folder])
            expect(retried?.apps.first { $0.app == appID }?.installed == "2.0",
                   "SL16 the retry resumes from the preserved first-install registration")
        }
        // An install a killed run left half done is finished or undone for this app too.
        do {
            let (rig, base, folder, shell, http) = storySetup("story-recovery")
            let installed = makeApp(folder.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            var cfg = base
            cfg.apps[appID] = AppConfig(bundlePath: installed.path, recipe: "status", bundleID: storyBundle)
            let journal = InstallJournal(phase: "staged", installed: installed.path, staged: installed.path + ".staged",
                                         rollback: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("rollback-story/Story Studio KH.app").path,
                                         previousVersion: "1.0", wasRunning: false, version: "2.0")
            try! AtomicFile.writeJSON(journal, to: Recipe.journalURL(stateDir: cfg.stateDir, app: appID))
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(result?.notes.contains(where: { $0.contains("interrupted install was undone") }) == true
                   && !fm.fileExists(atPath: Recipe.journalURL(stateDir: cfg.stateDir, app: appID).path),
                   "SL17 an interrupted install of an app that updates itself is undone, and its journal is settled")
            _ = rig
        }
        // A Mac configured by an earlier kit carries the app's own recipe name (`story`, `hub`).
        // That is an ordinary installable recipe now: Automatic updates it through the same safe
        // route, and recovery reads its journal too.
        for own in [(app: "story", bundle: storyBundle, name: storyName, label: "Story Studio KH", feedKind: "app-dmg"),
                    (app: "hub", bundle: "com.fixture.hub", name: "Studio Hub.app", label: "Studio Hub", feedKind: "hub")] {
            let (_, base, folder, shell, http) = storySetup("own-recipe-\(own.app)", app: own.app, bundle: own.bundle,
                                                            name: own.name, label: own.label, kind: own.feedKind,
                                                            bytes: "\(own.app) installer bytes")
            let target = makeApp(folder.appendingPathComponent(own.name), version: "1.0", id: own.bundle)
            var cfg = base
            cfg.apps[own.app] = AppConfig(bundlePath: target.path, recipe: own.app, automatic: true, bundleID: own.bundle)
            let automatic = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(automatic?.commandsRun == 1 && automatic?.updates == 1 && http.downloads == 1 && marker(target) == "2.0",
                   "SL19 an existing \(own.app)-recipe config is managed: Automatic installs the feed's newer version")
        }
        // A registration an older kit wrote as `status` for an app the feed now offers is upgraded,
        // so the Update the page draws is one the agent will really run.
        do {
            let (_, base, folder, shell, http) = storySetup("status-upgrade", kind: "app-dmg")
            let target = makeApp(folder.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            var cfg = base
            cfg.apps[appID] = AppConfig(bundlePath: target.path, recipe: "status", automatic: false, bundleID: storyBundle)
            let state = URL(fileURLWithPath: cfg.stateDir)
            try! fm.createDirectory(at: state, withIntermediateDirectories: true)
            try! AtomicFile.writeJSON([appID: cfg.apps[appID]!], to: state.appendingPathComponent("launcher-apps.json"))
            let run = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control },
                                         requested: [appID], appFolders: [folder])
            let saved = try? AtomicFile.readJSON([String: AppConfig].self, from: state.appendingPathComponent("launcher-apps.json"))
            expect(run?.apps.first { $0.app == appID }?.installed == "2.0" && saved?[appID]?.recipe == "app-dmg"
                   && saved?[appID]?.automatic == false,
                   "SL19b an old status registration is upgraded once the feed offers the app, and the update installs")
        }
        // The same repair when discovery already adopted the app: the saved file is repaired even
        // though the effective recipe for this run came from discovery.
        do {
            let (_, base, folder, shell, http) = storySetup("status-upgrade-saved", kind: "app-dmg")
            _ = makeApp(folder.appendingPathComponent(storyName), version: "2.0", id: storyBundle)
            let state = URL(fileURLWithPath: base.stateDir)
            try! fm.createDirectory(at: state, withIntermediateDirectories: true)
            let registered = AppConfig(bundlePath: folder.appendingPathComponent(storyName).path, recipe: "status",
                                       automatic: false, bundleID: storyBundle)
            try! AtomicFile.writeJSON([appID: registered], to: state.appendingPathComponent("launcher-apps.json"))
            try! AtomicFile.writeJSON([storyBundle: SSDApp(id: appID, name: "Story Studio KH", version: "2.0",
                                                           bundleID: storyBundle, bundleName: storyName)],
                                      to: Catalog.seenFile(in: state))
            _ = try? Agent.runOnce(config: base, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            let saved = try? AtomicFile.readJSON([String: AppConfig].self, from: state.appendingPathComponent("launcher-apps.json"))
            expect(saved?[appID]?.recipe == "app-dmg" && saved?[appID]?.automatic == false,
                   "SL19b a saved status registration is repaired even when discovery already manages the app")
        }
        // A killed install under a legacy recipe name is undone by the same recovery loop.
        for own in [(app: "story", bundle: storyBundle, name: storyName, label: "Story Studio KH"),
                    (app: "hub", bundle: "com.fixture.hub", name: "Studio Hub.app", label: "Studio Hub")] {
            let (_, base, folder, shell, http) = storySetup("own-recovery-\(own.app)", app: own.app, bundle: own.bundle,
                                                            name: own.name, label: own.label, bytes: "\(own.app) installer bytes")
            let target = makeApp(folder.appendingPathComponent(own.name), version: "1.0", id: own.bundle)
            var cfg = base
            cfg.apps[own.app] = AppConfig(bundlePath: target.path, recipe: own.app, automatic: false, bundleID: own.bundle)
            let journal = InstallJournal(phase: "staged", installed: target.path, staged: target.path + ".staged",
                                         rollback: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("rollback-\(own.app)/\(own.name)").path,
                                         previousVersion: "1.0", wasRunning: false, version: "2.0")
            try! AtomicFile.writeJSON(journal, to: Recipe.journalURL(stateDir: cfg.stateDir, app: own.app))
            let recovered = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(recovered?.notes.contains(where: { $0.contains(own.app) && $0.contains("interrupted install was undone") }) == true
                   && !Recipe.isUnresolved(stateDir: cfg.stateDir, app: own.app) && marker(target) == "1.0",
                   "SL19 a killed \(own.app)-recipe install is undone by the same recovery loop")
        }
        // The app coming up half way through the install is caught before anything is stopped:
        // the guard at the door only proved it was quiet before the download started.
        do {
            let (_, cfg, folder, shell, http) = storySetup("story-late-start")
            let target = makeApp(folder.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            let done = HandActions()
            let late = AppControl(isRunning: { shell.dittoRuns > 0 },
                                  quit: { done.quits += 1; return true },
                                  launch: { done.launches += 1 },
                                  stopService: { done.stops += 1; return true },
                                  healthy: { _ in true }, healthSettle: 0)
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in late },
                                            requested: [appID], appFolders: [folder])
            let row = result?.apps.first { $0.app == appID }
            expect(shell.dittoRuns > 0 && row?.status == HelperApp.failed && row?.reason?.contains("is running now") == true,
                   "SL20 an app that started while its installer was staged is refused, visibly")
            expect(done.quits == 0 && done.stops == 0 && done.launches == 0 && marker(target) == "1.0",
                   "SL20 the late refusal quits nothing, stops no service and leaves the installed app alone")
            expect(!Recipe.isUnresolved(stateDir: cfg.stateDir, app: appID)
                   && !fm.fileExists(atPath: folder.appendingPathComponent(".\(storyName).khu-staging").path),
                   "SL20 nothing is left half done: no journal, and the staged copy went to _trash")
        }
        // An app an SSD marks as updating itself keeps that policy even under an older config that
        // still says `app-dmg`, whatever it was — a remote order cannot talk it into an install.
        do {
            let (rig, base, folder, shell, http) = storySetup("ssd-flag-app-dmg", app: "notes", bundle: "com.fixture.notes",
                                                              name: "Notes KH.app", label: "Notes KH", bytes: "notes installer bytes")
            let target = makeApp(folder.appendingPathComponent("Notes KH.app"), version: "1.0", id: "com.fixture.notes")
            var cfg = base
            cfg.apps["notes"] = AppConfig(bundlePath: target.path, recipe: "app-dmg", automatic: true, bundleID: "com.fixture.notes")
            let signed = try! FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey)
            let bytes = try! Data(contentsOf: rig.feed.appendingPathComponent("artifacts/\(signed!.apps["notes"]!.file)"))
            let ssd = storySSD(rig, bytes, version: "2.0", app: "notes", bundle: "com.fixture.notes", name: "Notes KH.app")
            let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
            _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner,
                                                     body: Data(#"{"machine":"mac1","app":"notes"}"#.utf8)), remote: "127.0.0.1")
            let ordered = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, ssd: [ssd], appFolders: [folder])
            let row = ordered?.apps.first { $0.app == "notes" }
            let answer = try? AtomicFile.readJSON(AgentMemory.self, from: URL(fileURLWithPath: cfg.stateDir)
                                                    .appendingPathComponent("agent-memory.json"))
            expect(http.downloads == 0 && marker(target) == "1.0" && row?.statusOnly == true && row?.manuallyInstallable == true
                   && answer?.done.values.first { $0.app == "notes" }?.status == "status_only",
                   "SL21 a remote order never installs an app its SSD marks as updating itself, whatever its config recipe")
            let automatic = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, ssd: [ssd], appFolders: [folder])
            expect(automatic?.commandsRun == 0 && http.downloads == 0 && marker(target) == "1.0",
                   "SL21 Automatic honours the live SSD policy for an existing app-dmg config too")
            let hand = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control },
                                          requested: ["notes"], ssd: [ssd], appFolders: [folder])
            expect(hand?.apps.first { $0.app == "notes" }?.installed == "2.0" && marker(target) == "2.0" && http.downloads == 0,
                   "SL21 the person at this Mac still installs it by hand, from the SSD copy")
        }
        // Both early looks answer quietly and promotion's own read then finds the app running: the
        // decision that matters is the one taken where the app would actually be stopped.
        do {
            let (_, cfg, folder, shell, http) = storySetup("story-promotion-race")
            let target = makeApp(folder.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            let race = PromotionRace()
            let racing = AppControl(isRunning: { race.running() },
                                    quit: { race.quits += 1; return true },
                                    launch: { race.launches += 1 },
                                    stopService: { race.stops += 1; return true },
                                    healthy: { _ in true }, healthSettle: 0)
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in racing },
                                            requested: [appID], appFolders: [folder])
            let row = result?.apps.first { $0.app == appID }
            expect(race.answers == [false, false, true] && shell.dittoRuns > 0
                   && row?.status == HelperApp.failed && row?.reason?.contains("is running now") == true,
                   "SL22 the promotion read is the one that sees the app running and refuses the swap")
            expect(race.quits == 0 && race.stops == 0 && race.launches == 0 && marker(target) == "1.0",
                   "SL22 a newly started app is never quit, stopped, replaced or relaunched at promotion")
            expect(!Recipe.isUnresolved(stateDir: cfg.stateDir, app: appID)
                   && !fm.fileExists(atPath: folder.appendingPathComponent(".\(storyName).khu-staging").path),
                   "SL22 the refusal leaves no journal for recovery and retires the staged copy recoverably")
        }
        // Slack in the promotion look must not matter: on the manual route the swap still asks
        // nothing to stop, even though the app was quiet at that read and stays quiet throughout.
        do {
            let (_, cfg, folder, shell, http) = storySetup("story-quiet-hand")
            let target = makeApp(folder.appendingPathComponent(storyName), version: "1.0", id: storyBundle)
            let done = HandActions()
            let quiet = AppControl(isRunning: { false },
                                   quit: { done.quits += 1; return true },
                                   launch: { done.launches += 1 },
                                   stopService: { done.stops += 1; return true },
                                   healthy: { _ in true }, healthSettle: 0)
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in quiet },
                                            requested: [appID], appFolders: [folder])
            expect(result?.apps.first { $0.app == appID }?.installed == "2.0" && marker(target) == "2.0",
                   "SL23 a quiet explicit self-updating install still installs")
            expect(done.quits == 0 && done.stops == 0 && done.launches == 0,
                   "SL23 the hand route asks nothing to stop and leaves the quiet app stopped")
            expect(!Recipe.isUnresolved(stateDir: cfg.stateDir, app: appID)
                   && !fm.fileExists(atPath: folder.appendingPathComponent(".\(storyName).khu-staging").path),
                   "SL23 the quiet hand install leaves no journal or staged copy")
        }
        // A configured path that no longer exists is repaired by bundle ID from the feed's own
        // bundle name, said out loud once, and the install goes ahead instead of skipping.
        do {
            let (_, cfg, folder, _, shell, http) = setup("stale-path")
            _ = makeApp(folder.appendingPathComponent("New KH.app"), version: "1.0", id: bundleID)
            var local = cfg
            local.apps[id] = AppConfig(bundlePath: folder.appendingPathComponent("Old KH.app").path, recipe: "app-dmg",
                                       automatic: true, bundleID: bundleID)
            let result = try? Agent.runOnce(config: local, http: http, shell: shell, control: { _, _ in control },
                                            requested: [id], appFolders: [folder])
            expect(result?.notes.contains { $0.contains("\(id): configured bundle path") && $0.contains("is missing; using")
                   && $0.contains(folder.appendingPathComponent("New KH.app").path) } == true,
                   "SL24 a missing configured path is repaired from the feed's bundle name, and the run says so")
            expect(result?.apps.first { $0.app == id }?.installed == "2.0" && http.downloads == 1,
                   "SL24 the repaired app updates from the feed")
        }
        // A Mac enrolled with only the helper adopts every installed app the signed feed names,
        // by bundle ID, on its first run — and updates it.
        do {
            let (_, cfg, folder, _, shell, http) = setup("sparse-adopt")
            _ = makeApp(folder.appendingPathComponent("New KH.app"), version: "1.0", id: bundleID)
            try! HelperSettings().save(to: URL(fileURLWithPath: cfg.stateDir))
            let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(cfg.apps.isEmpty && result?.notes.contains { $0.hasPrefix("\(id): adopted") } == true
                   && result?.apps.first { $0.app == id }?.installed == "2.0" && http.downloads == 1,
                   "SL25 a first run with only the helper adopts the installed app by bundle ID and updates it")
            let saved = try? AtomicFile.readJSON([String: AppConfig].self,
                                                 from: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("launcher-apps.json"))
            expect(saved?[id]?.bundlePath == folder.appendingPathComponent("New KH.app").path,
                   "SL25 the adopted app is registered, so the next run starts with it")
            let again = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(again?.notes.contains { $0.hasPrefix("\(id): adopted") } == false,
                   "SL25 the adoption line is said once, not on every cycle")
        }
        // A skipped app names the rule that stopped it, in that rule's own words.
        do {
            let (_, cfg, folder, _, shell, http) = setup("skip-reason")
            _ = makeApp(folder.appendingPathComponent("New KH.app"), version: "1.0", id: bundleID)
            try! HelperSettings().save(to: URL(fileURLWithPath: cfg.stateDir))
            var local = cfg
            local.apps[id] = AppConfig(bundlePath: folder.appendingPathComponent("New KH.app").path, recipe: "app-dmg",
                                       automatic: false, bundleID: bundleID)
            let result = try? Agent.runOnce(config: local, http: http, shell: shell, control: { _, _ in control }, appFolders: [folder])
            expect(result?.notes.contains("\(id): skipped — automatic is off (\(HelperSettings.AutomaticOrigin.config.words))") == true
                   && http.downloads == 0,
                   "SL26 a skipped app says which rule stopped it, with that rule's own words")
        }
    }
}
