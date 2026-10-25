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

struct ArtifactFailure: Error, CustomStringConvertible {
    let description: String
}

public struct URLSessionHTTPClient: HTTPClient {
    /// Feed, status and command replies are small; anything bigger is refused, not buffered.
    public var smallLimit = 8 << 20
    /// No data for this long ends the transfer (URLRequest's own timeout).
    public var timeout: TimeInterval = 60
    /// ...and no transfer takes longer than this IN TOTAL, however steadily the peer drips: an
    /// inactivity timeout alone lets a stalled or malicious peer hold a run open for ever.
    public var totalTimeout: TimeInterval = 600
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
        let task = session.dataTask(with: request)
        task.resume()
        // The deadline is ours to keep, not the peer's to reset.
        let finished = sink.done.wait(timeout: .now() + totalTimeout) == .success
        if !finished {
            task.cancel()
            _ = sink.done.wait(timeout: .now() + 5)
        }
        session.finishTasksAndInvalidate()
        guard finished else { throw khuFail("\(url.path) did not finish within \(Int(totalTimeout)) s; it was stopped") }
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
            error = ArtifactFailure(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        guard received <= limit else {
            error = ArtifactFailure(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
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
    public var observedStubRollbacks: Int?
    public var updaterArtifacts: [String: String]?
    public var feedPublishedAt: String?
    public var feedSHA256: String?
    public init() {}

    /// `protected` is what the publisher still lists as an order for this Mac. Those id keep their
    /// stored result however old they are: it is the only acknowledgement that order will ever get,
    /// and forgetting it makes a finished order look like one that has still to run.
    mutating func trim(keep: Int = 200, protecting protected: Set<String> = []) {
        guard done.count > keep else { return }
        let droppable = done.filter { !protected.contains($0.key) && $0.value.sent }
            .sorted { $0.value.at < $1.value.at }
        for (id, _) in droppable.prefix(done.count - keep) { done[id] = nil }
    }
}

public enum Agent {
    /// Recipes that never install from KH Updater in v1: those apps keep their own updaters, which
    /// let running work finish first.
    static let statusOnly: Set<String> = ["story", "hub", "status"]
    static let knownRecipes: Set<String> = statusOnly.union(["app-dmg", "gateway", "updater", "fake-for-tests"])
    /// A future-dated feed is refused rather than allowed to become a high-water mark nobody can pass.
    static let futureSlack: TimeInterval = 24 * 3600
    /// How old a signed order reply may be, in either direction, before it is treated as a replay.
    static let orderFreshness: TimeInterval = 10 * 60

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
            let key = bundleKey(cfg.bundlePath)
            if let other = seen[key] { throw khuFail("\(app) and \(other) both name \(key); one app per bundle") }
            seen[key] = app
        }
    }

    /// Which bundle a configured path really names. Process identity is the kernel's own spelling
    /// of a path, so two entries differing only by a symlink, an alias, or — on a case-insensitive
    /// volume — by case are one bundle, and one app per bundle is the rule.
    static func bundleKey(_ path: String) -> String {
        let real = LiveControl.realPath(path)
        guard let caseSensitive = (try? URL(fileURLWithPath: real)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames else { return real }
        return caseSensitive ? real : real.lowercased()
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
                          control: @escaping (String, AppConfig) -> AppControl, executable: String?, now: Date) throws -> AgentRunResult {
        guard let feedURL = URL(string: config.feedURL) else { throw khuFail("feedURL is not a URL") }
        let serverBase = feedURL.deletingLastPathComponent()
        let memoryFile = stateDir.appendingPathComponent("agent-memory.json")
        var memory = try AtomicFile.readJSON(AgentMemory.self, from: memoryFile) ?? AgentMemory()
        // Ids the publisher still lists as orders for this Mac, from the reply read below.
        var reportedIDs: Set<String>?
        func remember() throws {
            if let reportedIDs { memory.trim(protecting: reportedIDs) }
            try AtomicFile.writeJSON(memory, to: memoryFile)
        }
        var result = AgentRunResult()

        // 0. Finish or undo any install a killed run left half done, before anything else.
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key }) where ["app-dmg", "gateway"].contains(cfg.recipe) {
            let note = try Recipe.recover(installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app,
                                          control: control(app, cfg), controlForPath: { path in
                var original = cfg; original.bundlePath = path
                return control(app, original)
            })
            if !note.isEmpty { result.notes.append("\(app): \(note)") }
        }

        // 1. What is installed and running here — none of this needs the feed.
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
            if Recipe.isUnresolved(stateDir: stateDir.path, app: app) { health[app] = "unresolved install" }
        }
        if let mine = selfVersion(config: config, executable: executable) { installed["updater"] = mine; health["updater"] = "running" }

        let headers = ["Authorization": "Bearer \(config.token)"]
        /// The status a result post answered with, or nil when it could not be made at all.
        func post(_ commandID: String, _ done: AgentMemory.Done) -> Int? {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "machine": config.machine, "app": done.app, "status": done.status, "reason": done.reason,
            ])) ?? Data()
            let url = serverBase.appendingPathComponent(commandID.hasPrefix("auto-") ? "automatic" : "commands").appendingPathComponent(commandID).appendingPathComponent("result")
            guard let (_, code) = try? http.post(url, headers: headers, body: body) else { return nil }
            return code
        }
        /// Taken, or the publisher no longer has that order (404): either way there is nothing left
        /// to report, and re-posting an order it does not know about for ever is not a retry.
        func delivered(_ code: Int?) -> Bool { code == 200 || code == 404 }

        // 2. Results that could not be delivered last time go first — before the feed, so that a
        // publisher which cannot be reached for one is still told what happened on this Mac.
        for (id, done) in memory.done where !done.sent {
            if delivered(post(id, done)) { memory.done[id]?.sent = true }
        }
        try remember()

        // 3. Status, with this Mac's own Automatic defaults so the page shows what will really happen.
        let statusBody = try JSONSerialization.data(withJSONObject: [
            "machine": config.machine, "installed": installed, "health": health,
            "automatic_default": config.apps.mapValues { $0.automatic },
        ])
        let (_, statusCode) = try http.post(serverBase.appendingPathComponent("status"), headers: headers, body: statusBody)
        guard statusCode == 200 else { throw khuFail("status was refused (\(statusCode))") }
        result.statusPosted = true

        // 4. The feed: signed, understood, and not older than one already seen.
        let feed = try verifiedFeed(http: http, serverBase: serverBase, config: config, memory: &memory, now: now)
        try remember()
        // A self-update the stub rolled back is a failure this Mac has already seen: those bytes
        // must not be installed again on every run. A new artifact (a different SHA-256) or an
        // explicit order clears it, exactly as for any other version that failed here.
        if let base = config.stubBase,
           let stub = try AtomicFile.readJSON(StubState.self, from: StubLayout(base: URL(fileURLWithPath: base)).stateFile),
           stub.rollbacks != memory.observedStubRollbacks {
            if let version = stub.rolledBack,
               let sha = memory.updaterArtifacts?[version]
                ?? feed.apps["updater"].flatMap({ $0.version == version ? $0.sha256 : nil }) {
                memory.rejected["updater"] = sha
                result.notes.append("the stub rolled updater \(version) back; those bytes are rejected")
            }
            memory.observedStubRollbacks = stub.rollbacks
            try remember()
        }

        // 5. Orders, signed by the publisher's key and naming this Mac and the moment it signed.
        let reply = try get(http, serverBase.appendingPathComponent("commands").appendingQuery("machine", config.machine), headers: headers)
        let signed = try JSON.decode(SignedReply.self, from: reply)
        let publisherKey = try Signing.loadPublicKey(base64: config.publicKey)
        guard let ordersBody = signed.replyData, let signature = signed.signatureData,
              Signing.verify(ordersBody, signature: signature, publicKey: publisherKey) else {
            throw khuFail("the orders were not signed by this publisher's key; refused")
        }
        let orders = try JSON.decode(CommandsReply.self, from: ordersBody)
        guard orders.machine == config.machine else { throw khuFail("orders for \(orders.machine), not \(config.machine); refused") }
        guard let signedAt = ISO.date(orders.at), abs(signedAt.timeIntervalSince(now)) <= orderFreshness else {
            throw khuFail("orders signed at \(orders.at) are not fresh; refused (a replayed order is not an order)")
        }
        reportedIDs = Set(orders.commands.map { $0.id })

        var todo: [(app: String, id: String, explicit: Bool)] = []
        for command in orders.commands where command.machine == config.machine {
            if let done = memory.done[command.id] {
                // Already carried out; only the report was lost.
                if delivered(post(command.id, done)) { memory.done[command.id]?.sent = true }
                continue
            }
            if !todo.contains(where: { $0.app == command.app || $0.id == command.id }) {
                todo.append((command.app, command.id, true))
            }
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
            if config.apps[item.app]?.recipe == "updater", let entry = feed.apps[item.app] {
                memory.updaterArtifacts = (memory.updaterArtifacts ?? [:]).merging([entry.version: entry.sha256]) { _, new in new }
                try remember()
            }
            do {
                res = try install(app: item.app, feed: feed, installed: installed[item.app], config: config,
                                  serverBase: serverBase, stateDir: stateDir, http: http, shell: shell, control: control)
            } catch let error as ArtifactFailure {
                res = RecipeResult(status: "failed", reason: "\(error)")
            } catch {
                res = RecipeResult(status: "install_failed", reason: "\(error)")
            }
            // Only an artifact that is unusable *itself* is remembered as rejected. A download or
            // transport failure says nothing about the artifact, so the next run tries it again.
            if ["failed", "rolled_back", "rollback_failed", "rollback_unhealthy", "rollback_blocked"].contains(res.status),
               let sha = feed.apps[item.app]?.sha256 {
                memory.rejected[item.app] = sha
            }
            let done = AgentMemory.Done(app: item.app, status: res.status, reason: res.reason ?? "", at: ISO.string(Date()), sent: false)
            memory.done[item.id] = done
            try remember()  // recorded before it is reported: a crash here re-reports, never re-installs
            if delivered(post(item.id, done)) { memory.done[item.id]?.sent = true; try remember() }
            result.commandsRun += 1
            if ["updated", "switched"].contains(res.status) { result.updates += 1 }
            if res.status == "switched" {
                result.restartRequested = true; break
            }  // the rest wait for the new version
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
        // An install this Mac could not finish or undo is not a settled app: an order for it must
        // not be answered "current" while a rollback is still owed. The next run picks it up.
        if Recipe.isUnresolved(stateDir: stateDir.path, app: app) {
            return RecipeResult(status: "unresolved", reason: "an earlier install of \(app) could not be finished or undone; "
                               + "\(Recipe.journalURL(stateDir: stateDir.path, app: app).path) is kept and the next run tries it again")
        }
        guard let entry = feed.apps[app] else { throw khuFail("the feed has no \(app)") }
        if let installed {
            guard let order = VersionCompare.compare(entry.version, installed) else {
                return RecipeResult(status: "refused", reason: "\(installed) here and \(entry.version) in the feed cannot be compared")
            }
            if order == 0 { return RecipeResult(status: "current", reason: "\(installed) is already installed") }
            if order < 0 { return RecipeResult(status: "refused", reason: "the feed has \(entry.version), older than \(installed) here; no downgrade") }
        }

        let artifact: URL
        do {
            artifact = try download(entry, app: app, serverBase: serverBase, stateDir: stateDir, http: http)
        } catch let error as ArtifactFailure {
            return RecipeResult(status: "failed", reason: "\(error)")
        } catch {
            // Transport, not artifact: nothing here says the bytes are bad, so it is not a version
            // this Mac has rejected — the next run downloads it again.
            return RecipeResult(status: "download_failed", reason: "\(error)")
        }
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
        guard bytes == entry.bytes else { throw ArtifactFailure(description: "artifact size mismatch; nothing was changed") }
        guard sha == entry.sha256 else { throw ArtifactFailure(description: "artifact sha256 mismatch; nothing was changed") }
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
                throw ArtifactFailure(description: "\(binary.path) already holds different bytes for \(entry.version); move that folder to _trash to replace it")
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

/// What `GET /commands` answers with, inside `SignedReply`: the orders for one Mac and the
/// Automatic setting to follow. It names that Mac and the moment it was signed, and both are part
/// of the signed bytes — so an order cannot be moved to another Mac nor replayed later.
public struct CommandsReply: Codable, Sendable, Equatable {
    public var machine: String
    public var at: String
    public var commands: [ServerCommand]
    public var automatic: [String: Bool]

    public init(machine: String, at: String = ISO.string(Date()), commands: [ServerCommand], automatic: [String: Bool]) {
        self.machine = machine; self.at = at; self.commands = commands; self.automatic = automatic
    }
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
