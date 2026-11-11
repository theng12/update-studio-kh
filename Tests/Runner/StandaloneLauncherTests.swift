import Foundation

/// Real filesystem staging/rollback with mount, signatures and process control supplied by fixtures.
private final class StandaloneShell: Shell, @unchecked Sendable {
    let root: URL
    var mount: URL
    var refused = false
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
                                   kind: "app-dmg", allowSame: false, meta: { _ in
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
        try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "bad", version: "1.0", artifact: rig.artifact("bad.dmg", "legacy metadata missing"), kind: "app-dmg", allowSame: false, meta: nil)
        let result = try? Agent.runOnce(config: cfg, http: http, shell: shell, control: { _, _ in control }, requested: ["bad", id], appFolders: [folder])
        expect(result?.commandsRun == 2 && result?.apps.first(where: { $0.app == id })?.installed == "2.0" && http.downloads == 1,
               "SL7 one refused first install does not stop the next app")
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
}
