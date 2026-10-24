import Foundation
import CryptoKit

public struct AgentRunResult: Sendable, Equatable {
    public var statusPosted: Bool
    public var commandsRun: Int
    public var updates: Int
    public var restartRequested = false
    public var notes: [String] = []
    public init(statusPosted: Bool = false, commandsRun: Int = 0, updates: Int = 0) {
        self.statusPosted = statusPosted; self.commandsRun = commandsRun; self.updates = updates
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int)
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int)
    /// Stream a GET into `file`, refusing more than `limit` bytes. Returns the HTTP status.
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int
}

public struct URLSessionHTTPClient: HTTPClient {
    /// Feed, status and command replies are small; anything bigger is refused, not buffered.
    public var smallLimit = 8 << 20
    public var timeout: TimeInterval = 60
    public init() {}

    public func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        try send("GET", url, headers: headers, body: nil)
    }
    public func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        try send("POST", url, headers: headers, body: body)
    }

    private func send(_ method: String, _ url: URL, headers: [String: String], body: Data?) throws -> (Data, Int) {
        let sink = try transfer(method, url, headers: headers, body: body, handle: nil, limit: Int64(smallLimit))
        return (sink.buffer, sink.status)
    }

    public func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw khuFail("cannot write \(file.path)") }
        defer { try? handle.close() }
        return try transfer("GET", url, headers: headers, body: nil, handle: handle, limit: limit).status
    }

    private func transfer(_ method: String, _ url: URL, headers: [String: String], body: Data?,
                          handle: FileHandle?, limit: Int64) throws -> StreamSink {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let sink = StreamSink(handle: handle, limit: limit)
        let session = URLSession(configuration: .ephemeral, delegate: sink, delegateQueue: nil)
        session.dataTask(with: request).resume()
        sink.done.wait()
        session.finishTasksAndInvalidate()
        if let error = sink.error { throw error }
        return sink
    }
}

/// Takes a response as it arrives — into a file, or memory for small replies — and cancels it the
/// moment it passes its limit, so nothing larger than expected is ever held.
private final class StreamSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let handle: FileHandle?
    var buffer = Data()
    let limit: Int64
    let done = DispatchSemaphore(value: 0)
    var received: Int64 = 0
    var status = 0
    var error: Error?

    init(handle: FileHandle?, limit: Int64) { self.handle = handle; self.limit = limit }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > limit {
            error = khuFail("\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        guard received <= limit else {
            error = khuFail("\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
            dataTask.cancel()
            return
        }
        guard let handle else { buffer.append(data); return }
        do { try handle.write(contentsOf: data) } catch { self.error = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if self.error == nil, let error { self.error = error }
        done.signal()
    }
}

/// What this Mac remembers between runs: results not yet delivered, commands already carried out
/// (so a redelivered one is reported again, not run again), versions that failed here, and the
/// newest feed seen.
public struct AgentMemory: Codable, Sendable, Equatable {
    public struct Done: Codable, Sendable, Equatable {
        public var app: String
        public var status: String
        public var reason: String
        public var at: String
        public var sent: Bool
    }
    public var done: [String: Done] = [:]
    /// app → sha256 of an artifact that failed or was rolled back here; Automatic skips it until
    /// the artifact changes or the owner asks for it explicitly.
    public var rejected: [String: String] = [:]
    public var feedPublishedAt: String?
    public var feedSHA256: String?
    public init() {}

    mutating func trim(keep: Int = 200) {
        guard done.count > keep else { return }
        let sent = done.filter { $0.value.sent }.sorted { $0.value.at < $1.value.at }
        for (id, _) in sent.prefix(done.count - keep) { done[id] = nil }
    }
}

public enum Agent {
    /// Recipes that never install from KH Updater in v1: those apps keep their own updaters, which
    /// let running work finish first.
    static let statusOnly: Set<String> = ["story", "hub", "status"]
    static let knownRecipes: Set<String> = statusOnly.union(["app-dmg", "gateway", "updater", "fake-for-tests"])
    /// A future-dated feed is refused rather than allowed to become a high-water mark nobody can pass.
    static let futureSlack: TimeInterval = 24 * 3600

    static func get(_ http: HTTPClient, _ url: URL, headers: [String: String] = [:]) throws -> Data {
        let (data, code) = try http.get(url, headers: headers)
        guard code == 200 else { throw khuFail("GET \(url.path) answered \(code)") }
        return data
    }

    /// The version of the `khu` running now: `<v>` when it runs from `<stubBase>/versions/<v>/khu`.
    public static func selfVersion(config: AgentConfig, executable: String? = Bundle.main.executablePath) -> String? {
        if let base = config.stubBase, let executable {
            let real = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            let versions = URL(fileURLWithPath: base).appendingPathComponent("versions").resolvingSymlinksInPath().path + "/"
            if real.path.hasPrefix(versions), real.lastPathComponent == "khu" {
                let version = real.deletingLastPathComponent().lastPathComponent
                if VersionCompare.isValid(version) { return version }
            }
        }
        return config.updaterVersion
    }

    static func validate(_ config: AgentConfig) throws {
        _ = try SafeName.component(config.machine, what: "machine id")
        var seen: [String: String] = [:]
        for (app, cfg) in config.apps {
            _ = try SafeName.component(app, what: "app id")
            guard knownRecipes.contains(cfg.recipe) else { throw khuFail("\(app): unknown recipe \(cfg.recipe)") }
            if cfg.recipe == "updater" { continue }
            let path = URL(fileURLWithPath: cfg.bundlePath).standardizedFileURL.path
            if let other = seen[path] { throw khuFail("\(app) and \(other) both name \(path); one app per bundle") }
            seen[path] = app
        }
    }

    public static func runOnce(config: AgentConfig, http: HTTPClient = URLSessionHTTPClient(), shell: Shell = SystemShell(),
                               control: ((String, AppConfig) -> AppControl)? = nil,
                               executable: String? = Bundle.main.executablePath, now: Date = Date()) throws -> AgentRunResult {
        try validate(config)
        let stateDir = URL(fileURLWithPath: config.stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // One agent at a time per Mac: a second one (or a manual --once) refuses instead of racing.
        return try FileLock.withExclusive(stateDir.appendingPathComponent("agent.lock"), wait: false) {
            try runLocked(config: config, stateDir: stateDir, http: http, shell: shell,
                          control: control ?? { liveControl($1, shell: shell) }, executable: executable, now: now)
        }
    }

    static func liveControl(_ cfg: AppConfig, shell: Shell) -> AppControl {
        cfg.recipe == "gateway" ? LiveControl.gateway(cfg.bundlePath, shell: shell) : LiveControl.appDmg(cfg.bundlePath, shell: shell)
    }

    static func runLocked(config: AgentConfig, stateDir: URL, http: HTTPClient, shell: Shell,
                          control: (String, AppConfig) -> AppControl, executable: String?, now: Date) throws -> AgentRunResult {
        guard let feedURL = URL(string: config.feedURL) else { throw khuFail("feedURL is not a URL") }
        let serverBase = feedURL.deletingLastPathComponent()
        let memoryFile = stateDir.appendingPathComponent("agent-memory.json")
        var memory = try AtomicFile.readJSON(AgentMemory.self, from: memoryFile) ?? AgentMemory()
        func remember() throws { memory.trim(); try AtomicFile.writeJSON(memory, to: memoryFile) }
        var result = AgentRunResult()

        // 0. Finish or undo any install a killed run left half done, before anything else.
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key }) where ["app-dmg", "gateway"].contains(cfg.recipe) {
            let note = try Recipe.recover(installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app, control: control(app, cfg))
            if !note.isEmpty { result.notes.append("\(app): \(note)") }
        }

        // 1. The feed: signed, understood, and not older than one already seen.
        let feed = try verifiedFeed(http: http, serverBase: serverBase, config: config, memory: &memory, now: now)
        try remember()

        // 2. What is installed and running here.
        var installed: [String: String] = [:]
        var health: [String: String] = [:]
        for (app, cfg) in config.apps {
            if cfg.recipe == "updater" { continue }
            if let info = try? BundleInfo.read(cfg.bundlePath) {
                installed[app] = info.version
                switch LiveControl.isRunning(cfg.bundlePath) {
                case true?: health[app] = "running"
                case false?: health[app] = "not running"
                case nil: health[app] = "unknown"
                }
            } else {
                health[app] = "not installed"
            }
        }
        if let mine = selfVersion(config: config, executable: executable) { installed["updater"] = mine; health["updater"] = "running" }

        let headers = ["Authorization": "Bearer \(config.token)"]
        func post(_ commandID: String, _ done: AgentMemory.Done) -> Bool {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "machine": config.machine, "app": done.app, "status": done.status, "reason": done.reason,
            ])) ?? Data()
            let url = serverBase.appendingPathComponent("commands").appendingPathComponent(commandID).appendingPathComponent("result")
            return (try? http.post(url, headers: headers, body: body))?.1 == 200
        }

        // 3. Results that could not be delivered last time go first.
        for (id, done) in memory.done where !done.sent {
            if post(id, done) { memory.done[id]?.sent = true }
        }
        try remember()

        // 4. Status, with this Mac's own Automatic defaults so the page shows what will really happen.
        let statusBody = try JSONSerialization.data(withJSONObject: [
            "machine": config.machine, "installed": installed, "health": health,
            "automatic_default": config.apps.mapValues { $0.automatic },
        ])
        let (_, statusCode) = try http.post(serverBase.appendingPathComponent("status"), headers: headers, body: statusBody)
        guard statusCode == 200 else { throw khuFail("status was refused (\(statusCode))") }
        result.statusPosted = true

        // 5. Orders. The server keeps each one until its result arrives.
        let reply = try get(http, serverBase.appendingPathComponent("commands").appendingQuery("machine", config.machine), headers: headers)
        let orders = try JSON.decode(CommandsReply.self, from: reply)

        var todo: [(app: String, id: String, explicit: Bool)] = []
        for command in orders.commands where command.machine == config.machine {
            if let done = memory.done[command.id] {
                // Already carried out; only the report was lost.
                if post(command.id, done) { memory.done[command.id]?.sent = true }
                continue
            }
            if !todo.contains(where: { $0.app == command.app }) { todo.append((command.app, command.id, true)) }
        }
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key })
        where (orders.automatic[app] ?? cfg.automatic) && !statusOnly.contains(cfg.recipe) {
            guard !todo.contains(where: { $0.app == app }), let entry = feed.apps[app] else { continue }
            guard memory.rejected[app] != entry.sha256 else { continue }  // failed here before: wait for a new artifact
            let current = installed[app]
            if current == nil || VersionCompare.isNewer(entry.version, than: current!) {
                todo.append((app, "auto-\(app)-\(UUID().uuidString)", false))
            }
        }
        try remember()

        // 6. One install at a time; a failure is reported and the next app still runs.
        for item in todo {
            let res: RecipeResult
            if item.explicit { memory.rejected[item.app] = nil }  // the owner asked: try it again
            do {
                res = try install(app: item.app, feed: feed, installed: installed[item.app], config: config,
                                  serverBase: serverBase, stateDir: stateDir, http: http, shell: shell, control: control)
            } catch {
                res = RecipeResult(status: "failed", reason: "\(error)")
            }
            if ["failed", "rolled_back", "rollback_failed", "rollback_unhealthy", "rollback_blocked"].contains(res.status),
               let sha = feed.apps[item.app]?.sha256 {
                memory.rejected[item.app] = sha
            }
            let done = AgentMemory.Done(app: item.app, status: res.status, reason: res.reason ?? "", at: ISO.string(Date()), sent: false)
            memory.done[item.id] = done
            try remember()  // recorded before it is reported: a crash here re-reports, never re-installs
            if post(item.id, done) { memory.done[item.id]?.sent = true; try remember() }
            result.commandsRun += 1
            if ["updated", "switched"].contains(res.status) { result.updates += 1 }
            if res.status == "switched" { result.restartRequested = true; break }  // the rest wait for the new version
        }
        return result
    }

    static func verifiedFeed(http: HTTPClient, serverBase: URL, config: AgentConfig, memory: inout AgentMemory, now: Date) throws -> Feed {
        let releaseData = try get(http, serverBase.appendingPathComponent("release.json"))
        let release = try JSON.decode(Release.self, from: releaseData)
        let pub = try Signing.loadPublicKey(base64: config.publicKey)
        guard let feedData = release.feedData, let signature = release.signatureData,
              Signing.verify(feedData, signature: signature, publicKey: pub) else { throw khuFail("invalid feed signature") }
        let feed = try JSON.decode(Feed.self, from: feedData).validated()
        let published = feed.publishedAt!
        let sha = Signing.sha256Hex(feedData)
        guard published <= now.addingTimeInterval(futureSlack) else {
            throw khuFail("feed is dated \(feed.published_at), in the future; refused (check the publisher's clock)")
        }
        if let seen = memory.feedPublishedAt.flatMap(ISO.date) {
            if published < seen { throw khuFail("feed rollback refused: published_at is older than one already seen") }
            if published == seen, let seenSHA = memory.feedSHA256, seenSHA != sha {
                throw khuFail("feed refused: a different feed carries the same published_at as one already seen")
            }
        }
        memory.feedPublishedAt = feed.published_at
        memory.feedSHA256 = sha
        return feed
    }

    static func install(app: String, feed: Feed, installed: String?, config: AgentConfig, serverBase: URL, stateDir: URL,
                        http: HTTPClient, shell: Shell, control: (String, AppConfig) -> AppControl) throws -> RecipeResult {
        guard let cfg = config.apps[app] else { throw khuFail("\(app) is not configured on this Mac") }
        if statusOnly.contains(cfg.recipe) { return RecipeResult(status: "status_only", reason: "updated by its own updater") }
        guard let entry = feed.apps[app] else { throw khuFail("the feed has no \(app)") }
        if let installed {
            guard let order = VersionCompare.compare(entry.version, installed) else {
                return RecipeResult(status: "refused", reason: "\(installed) here and \(entry.version) in the feed cannot be compared")
            }
            if order == 0 { return RecipeResult(status: "current", reason: "\(installed) is already installed") }
            if order < 0 { return RecipeResult(status: "refused", reason: "the feed has \(entry.version), older than \(installed) here; no downgrade") }
        }

        let artifact = try download(entry, app: app, serverBase: serverBase, stateDir: stateDir, http: http)
        switch cfg.recipe {
        case "app-dmg", "gateway":
            return try Recipe.appDmg(shell: shell, installedPath: cfg.bundlePath, artifactPath: artifact.path, feedVersion: entry.version,
                                     expectedBundleID: cfg.bundleID, stateDir: stateDir.path, app: app, control: control(app, cfg))
        case "updater":
            return try installUpdater(entry, artifact: artifact, config: config)
        case "fake-for-tests":
            return RecipeResult(status: "updated")
        default:
            throw khuFail("unknown recipe \(cfg.recipe)")
        }
    }

    /// Stream the artifact to `downloads/<app>/`, checked against the signed size and SHA-256
    /// before any recipe sees it. The previous download for the app goes to `_trash`.
    static func download(_ entry: FeedApp, app: String, serverBase: URL, stateDir: URL, http: HTTPClient) throws -> URL {
        let name = try SafeName.component(entry.file, what: "artifact name")
        let dir = stateDir.appendingPathComponent("downloads").appendingPathComponent(app)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { try Trash.move(dir, into: Trash.root(in: stateDir)) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent(name + ".part")
        let code = try http.download(serverBase.appendingPathComponent("artifacts").appendingPathComponent(name),
                                     headers: [:], to: part, limit: entry.bytes)
        guard code == 200 else { throw khuFail("artifact download answered \(code); nothing was changed") }
        let (sha, bytes) = try Signing.sha256Hex(fileAt: part)
        guard bytes == entry.bytes else { throw khuFail("artifact size mismatch; nothing was changed") }
        guard sha == entry.sha256 else { throw khuFail("artifact sha256 mismatch; nothing was changed") }
        let artifact = dir.appendingPathComponent(name)
        try fm.moveItem(at: part, to: artifact)
        return artifact
    }

    /// Self-update: the verified binary becomes `versions/<v>/khu` (never overwritten once there),
    /// and the stub switches to it. Already running that version is a no-op.
    static func installUpdater(_ entry: FeedApp, artifact: URL, config: AgentConfig) throws -> RecipeResult {
        guard let base = config.stubBase else { throw khuFail("no stub layout is configured on this Mac") }
        let layout = StubLayout(base: URL(fileURLWithPath: base))
        let binary = try layout.binary(for: entry.version)
        let fm = FileManager.default
        if fm.fileExists(atPath: binary.path) {
            guard try Signing.sha256Hex(fileAt: binary).hex == entry.sha256 else {
                throw khuFail("\(binary.path) already holds different bytes for \(entry.version); move that folder to _trash to replace it")
            }
        } else {
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = binary.deletingLastPathComponent().appendingPathComponent(".khu.khu-tmp-\(UUID().uuidString)")
            try fm.copyItem(at: artifact, to: staging)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            try fm.moveItem(at: staging, to: binary)
        }
        let moved = try FileLock.withExclusive(layout.switchLock) { try StubSwitcher(layout: layout).install(version: entry.version) }
        guard moved else { return RecipeResult(status: "current", reason: "\(entry.version) is already running") }
        return RecipeResult(status: "switched", reason: "the stub starts \(entry.version) next and rolls back if it misbehaves")
    }
}

public struct CommandsReply: Codable, Sendable, Equatable {
    public var commands: [ServerCommand]
    public var automatic: [String: Bool]
}

extension URL {
    func appendingQuery(_ name: String, _ value: String) -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? self
    }
}
