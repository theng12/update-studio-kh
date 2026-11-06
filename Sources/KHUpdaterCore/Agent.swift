import Foundation
import SystemConfiguration
import CryptoKit

public struct AgentRunResult: Sendable, Equatable {
    public var statusPosted: Bool
    public var commandsRun: Int
    public var updates: Int
    public var restartRequested = false
    public var notes: [String] = []
    /// Each app as the menu-bar icon shows it, from what is on disk after the run.
    public var apps: [HelperApp] = []
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

/// Bytes that arrived but do not match the signed size or SHA-256. One mismatch may be a dropped
/// or truncated transfer; the same mismatch several runs in a row means the server's copy is bad.
struct DeliveryMismatch: Error, CustomStringConvertible {
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
    /// Vendor downloads and page lookups must stay on the catalog's official HTTPS hosts.
    public var officialHosts: [String]?
    public init() {}

    static func officialURL(_ url: URL, hosts: [String]) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && hosts.contains(url.host?.lowercased() ?? "")
    }

    static func allowsRedirect(original: URLRequest?, destination: URL, officialHosts: [String]?) -> Bool {
        guard let original, original.value(forHTTPHeaderField: "Authorization") == nil else { return false }
        return officialHosts.map { officialURL(destination, hosts: $0) } ?? true
    }

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
        if let officialHosts, !Self.officialURL(url, hosts: officialHosts) {
            throw khuFail("download refused: URL is outside the vendor's official HTTPS hosts")
        }
        let sink = StreamSink(handle: handle, limit: limit, officialHosts: officialHosts)
        let session = URLSession(configuration: .ephemeral, delegate: sink, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        // The deadline is ours to keep, not the peer's to reset. A download the person paused from
        // the Launcher is held where it is and its paused time does not count; Cancel stops it.
        var finished = false, spent: TimeInterval = 0, suspended = false, cancelled = false
        if handle != nil { DownloadControl.reset() }
        while spent < totalTimeout {
            if sink.done.wait(timeout: .now() + 0.5) == .success { finished = true; break }
            if handle != nil {
                if DownloadControl.cancelled { cancelled = true; break }
                // The sink holds the data while paused; here paused time just does not count.
                suspended = DownloadControl.paused
                if suspended { continue }
            }
            spent += 0.5
        }
        if !finished {
            task.cancel()
            _ = sink.done.wait(timeout: .now() + 5)
        }
        session.finishTasksAndInvalidate()
        if cancelled { throw khuFail("cancelled on this Mac; nothing was changed") }
        guard finished else { throw khuFail("\(url.path) did not finish within \(Int(totalTimeout)) s; it was stopped") }
        if let error = sink.error { throw error }
        return sink
    }
}

/// The Launcher's Pause and Cancel for the download in progress. One download runs at a time.
public enum DownloadControl {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = (paused: false, cancelled: false)
    public static var paused: Bool { lock.lock(); defer { lock.unlock() }; return state.paused }
    public static var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return state.cancelled }
    public static func pause(_ on: Bool) { lock.lock(); state.paused = on; lock.unlock() }
    public static func cancel() { lock.lock(); state.cancelled = true; state.paused = false; lock.unlock() }
    static func reset() { lock.lock(); state = (false, false); lock.unlock() }
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

    let officialHosts: [String]?
    init(handle: FileHandle?, limit: Int64, officialHosts: [String]?) {
        self.handle = handle; self.limit = limit; self.officialHosts = officialHosts
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url.map({ URLSessionHTTPClient.allowsRedirect(original: task.originalRequest, destination: $0, officialHosts: officialHosts) }) != true {
            error = khuFail("redirect refused: authenticated requests stay on their controller and vendor requests stay on official HTTPS hosts")
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > limit {
            error = DeliveryMismatch(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        guard received <= limit else {
            error = DeliveryMismatch(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
            dataTask.cancel()
            return
        }
        guard let handle else { buffer.append(data); return }
        // Paused from the Launcher: hold this delivery, so the connection backs up and the sender
        // waits. Suspending the task alone lets data already in flight keep arriving.
        while DownloadControl.paused && !DownloadControl.cancelled { usleep(100_000) }
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
    public struct Mismatch: Codable, Sendable, Equatable { public var sha256: String; public var count: Int }
    /// app → consecutive downloads of the same signed artifact whose bytes did not match it.
    public var deliveryMismatches: [String: Mismatch]?
    public var observedStubRollbacks: Int?
    public var updaterArtifacts: [String: String]?
    public var feedPublishedAt: String?
    public var feedSHA256: String?
    public var feedNetwork: FeedNetwork?
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
    /// Mismatched downloads of one artifact in a row before it is rejected like a bad artifact.
    static let maxDeliveryMismatches = 3

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
        _ = try config.network?.validated()
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
                               executable: String? = Bundle.main.executablePath, now: Date = Date(),
                               requested: Set<String> = [], installing: ((String?) -> Void)? = nil,
                               ssd: [SSDSource] = [], appFolders: [URL] = Catalog.applicationFolders,
                               connectionFile: URL? = nil) throws -> AgentRunResult {
        // Apps installed by hand since this Mac was set up are found by bundle ID and managed too.
        let stateURL = URL(fileURLWithPath: config.stateDir)
        var config = config
        config.apps.merge(Catalog.discover(config: config, known: Catalog.known(in: stateURL, ssd: ssd), folders: appFolders)) { a, _ in a }
        try validate(config)
        let stateDir = URL(fileURLWithPath: config.stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // One agent at a time per Mac: a second one (or a manual --once) refuses instead of racing.
        return try FileLock.withExclusive(stateDir.appendingPathComponent("agent.lock"), wait: false) {
            try runLocked(config: config, stateDir: stateDir, http: http, shell: shell,
                          control: control ?? { liveControl($1, shell: shell) }, executable: executable, now: now,
                          requested: requested, installing: installing ?? { _ in }, ssd: ssd, connectionFile: connectionFile)
        }
    }

    static func liveControl(_ cfg: AppConfig, shell: Shell) -> AppControl {
        cfg.recipe == "gateway" ? LiveControl.gateway(cfg.bundlePath, shell: shell) : LiveControl.appDmg(cfg.bundlePath, shell: shell)
    }

    static func runLocked(config: AgentConfig, stateDir: URL, http: HTTPClient, shell: Shell,
                          control: @escaping (String, AppConfig) -> AppControl, executable: String?, now: Date,
                          requested asked: Set<String> = [], installing: (String?) -> Void = { _ in }, ssd: [SSDSource] = [],
                          connectionFile: URL? = nil) throws -> AgentRunResult {
        var config = config
        let vendors = try AtomicFile.readJSON([String: AppConfig].self, from: stateDir.appendingPathComponent("vendor-apps.json")) ?? [:]
        config.apps.merge(vendors) { configured, _ in configured }
        // From the Launcher: "<app>" installs or updates, "reinstall:<app>" installs the same
        // version again, "rollback:<app>" puts back the version this Mac kept.
        let reinstall = Set(asked.filter { $0.hasPrefix("reinstall:") }.map { String($0.dropFirst("reinstall:".count)) })
        let rollbacks = Set(asked.filter { $0.hasPrefix("rollback:") }.map { String($0.dropFirst("rollback:".count)) })
        let requested = Set(asked.filter { !$0.contains(":") }).union(reinstall)
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
        var interruptedOrders: [String: (app: String, journal: InstallJournal)] = [:]
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key }) where ["app-dmg", "gateway"].contains(cfg.recipe) {
            let before = try? AtomicFile.readJSON(InstallJournal.self, from: Recipe.journalURL(stateDir: stateDir.path, app: app))
            let note = try Recipe.recover(installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app,
                                          control: control(app, cfg), controlForPath: { path in
                var original = cfg; original.bundlePath = path
                return control(app, original)
            })
            if !note.isEmpty { result.notes.append("\(app): \(note)") }
            // A swap the owner ordered is the recovery's own business too: the order it belonged to
            // is answered from what is on disk, not run a second time.
            if let journal = before, journal.intent == "owner_rollback", let order = journal.order {
                interruptedOrders[order] = (app, journal)
            }
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
        let hostStatusFile = stateDir.appendingPathComponent("feed-host-status.json")
        if FileManager.default.fileExists(atPath: hostStatusFile.path) {
            var host = (try? AtomicFile.readJSON([String: String].self, from: hostStatusFile)) ?? [:]
            if host["error"] == nil, let old = host["status"], old.hasPrefix("failed:") { host["error"] = old }
            let observed = FeedHostRuntime.status(shell: shell)
            let status = observed + (host["error"] == nil ? "" : "; setup failed")
            host["status"] = status
            host["checked_at"] = ISO.string(now)
            try AtomicFile.writeJSON(host, to: hostStatusFile)
            health["feed-host"] = status
        }

        let headers = ["Authorization": "Bearer \(config.token)"]
        var publisherAvailable = true
        /// The status a result post answered with, or nil when it could not be made at all.
        func post(_ commandID: String, _ done: AgentMemory.Done) -> Int? {
            guard publisherAvailable else { return nil }
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

        // 3. Status, with this Mac's own Automatic defaults so the page shows what will really happen,
        // and what the person at this Mac set from the menu-bar icon.
        let helper = HelperSettings.load(from: stateDir)
        var report: [String: Any] = [
            "machine": config.machine, "installed": installed, "health": health,
            "automatic_default": config.apps.mapValues { $0.automatic },
            "automatic_local": helper.automatic.mapValues { ["on": $0.on, "at": $0.at] as [String: Any] },
        ]
        if let name = MacName.current(expectedMachine: config.machine) { report["display_name"] = name }
        if let until = helper.pausedUntil, helper.paused(at: now) { report["paused_until"] = until }
        // A read-only snapshot of this Mac's own hardware, addresses and installed apps, bounded
        // like every other report. Fields that could not be read stay absent; the machine's name
        // is never used as hardware, and the installed managed-app maps above are untouched.
        if let inventory = MacInventory.collect(now: now, shell: shell).asJSONObject() {
            report["inventory"] = inventory
        }
        let statusBody = try JSONSerialization.data(withJSONObject: report)
        let network = memory.feedNetwork ?? config.network
        let statusCode: Int?
        do { statusCode = try http.post(serverBase.appendingPathComponent("status"), headers: headers, body: statusBody).1 }
        catch {
            guard network?.feedURLs.isEmpty == false else { throw error }
            statusCode = nil; publisherAvailable = false
            result.notes.append("publisher unavailable; local installs may use the signed mirror, remote orders and Automatic wait")
        }
        if let statusCode {
            guard statusCode == 200 else { throw khuFail("status was refused (\(statusCode))") }
            result.statusPosted = true
        }
        // Keep result delivery before feed processing, without retrying every result against an offline publisher.
        for (id, done) in memory.done where !done.sent {
            if delivered(post(id, done)) { memory.done[id]?.sent = true }
        }
        try remember()
        if result.statusPosted, let base = config.stubBase, let executable {
            do {
                let retired = try HelperRetirement.observe(layout: StubLayout(base: URL(fileURLWithPath: base)),
                    stateDir: stateDir, executable: URL(fileURLWithPath: executable), now: now,
                    maximumReportGap: Double(max(1, config.intervalMinutes)) * 60 + 60)
                if !retired.isEmpty { result.notes.append("older helper versions moved to _trash: " + retired.joined(separator: ", ")) }
            } catch { result.notes.append("helper version cleanup did not finish: \(error)") }
        }

        // 4. The feed: signed, understood, and not older than one already seen.
        let selected = try selectFeed(http: http, serverBase: serverBase, config: config, memory: &memory, now: now)
        let feed = selected.feed
        let artifactBase = selected.base
        memory.feedNetwork = feed.network ?? config.network
        let artifactFallbacks = try feedSources(config: config, memory: memory, serverBase: serverBase)
            .map { $0.deletingLastPathComponent() }.filter { $0 != artifactBase }
        try remember()
        let role = memory.feedNetwork?.hosts[config.machine]
        if role?.enabled == true || FileManager.default.fileExists(atPath: stateDir.appendingPathComponent("feed-host-status.json").path) {
            do {
                if role?.enabled == true {
                    _ = try FeedMirror.sync(releaseData: selected.release, sourceBase: artifactBase,
                        root: FeedHostRole.feedDirectory(in: stateDir), publicKey: config.publicKey, http: http, now: now)
                }
                let hostExecutable = FeedHostRuntime.executable(stubBase: config.stubBase, fallback: executable)
                let status = try FeedHostRuntime.reconcile(role: role, stateDir: stateDir, executable: hostExecutable, shell: shell)
                try AtomicFile.writeJSON(["status": status, "checked_at": ISO.string(now)], to: hostStatusFile)
                result.notes.append("feed host: " + status)
            } catch {
                let reason = "failed: " + String(String(describing: error).prefix(160))
                try? AtomicFile.writeJSON(["status": "setup failed", "error": reason, "checked_at": ISO.string(now)], to: hostStatusFile)
                result.notes.append("feed host " + reason)
            }
        }
        Catalog.remember(ssd, feed: feed, in: stateDir)
        let catalog = Catalog.build(feed: feed, ssd: ssd, seen: Catalog.seen(in: stateDir), icons: stateDir.appendingPathComponent("icons"))
        // Install from the Launcher's list: an app this Mac does not have yet goes to /Applications.
        for app in requested where config.apps[app] == nil {
            guard let entry = catalog.first(where: { $0.id == app }), !entry.updatesItself, let bundle = entry.bundleName else { continue }
            config.apps[app] = AppConfig(bundlePath: "/Applications/" + bundle, recipe: "app-dmg", automatic: true, bundleID: entry.bundleID)
        }
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

        // 4b. An owner rollback this Mac was killed in the middle of: the recovery above has now
        // finished it (or undone it), so the order it belonged to is answered from what is on disk.
        for (order, entry) in interruptedOrders.sorted(by: { $0.key < $1.key }) where memory.done[order] == nil {
            // Still unresolved: nothing is claimed, and the order stays pending for the next run.
            guard !Recipe.isUnresolved(stateDir: stateDir.path, app: entry.app) else { continue }
            let installedNow = (try? BundleInfo.read(entry.journal.installed))?.version
            let done: AgentMemory.Done
            if let target = entry.journal.version, installedNow == target {
                done = AgentMemory.Done(app: entry.app, status: "rolled_back_by_owner",
                                        reason: "an interrupted rollback was finished on this run; \(target) was found installed",
                                        at: ISO.string(Date()), sent: false)
                if let sha = rejectRolledBackFrom(app: entry.app, displaced: entry.journal.previousVersion, feed: feed, memory: &memory) {
                    result.notes.append("\(entry.app): \(entry.journal.previousVersion ?? "the version rolled back from") is rejected (\(sha.prefix(12)))")
                }
            } else {
                done = AgentMemory.Done(app: entry.app, status: "rollback_failed",
                                        reason: "an interrupted rollback of \(entry.app) left \(installedNow ?? "nothing") installed, not "
                                        + "\(entry.journal.version ?? "the kept version")", at: ISO.string(Date()), sent: false)
            }
            memory.done[order] = done
            try remember()
            if delivered(post(order, done)) { memory.done[order]?.sent = true; try remember() }
            result.commandsRun += 1
        }

        // 5. Orders, signed by the publisher's key and naming this Mac and the moment it signed.
        // This Mac says which order actions it can carry out; the publisher withholds the rest, so
        // an agent that does not understand a rollback is never handed one to misread.
        var orders = CommandsReply(machine: config.machine, commands: [], automatic: [:])
        if publisherAvailable {
            let response: (Data, Int)?
            do {
                response = try http.get(serverBase.appendingPathComponent("commands")
                    .appendingQuery("machine", config.machine).appendingQuery("capabilities", AgentCapability.ownerRollback + "," + AgentCapability.vendorInstall), headers: headers)
            } catch {
                guard memory.feedNetwork?.feedURLs.isEmpty == false else { throw error }
                response = nil; publisherAvailable = false
                result.notes.append("publisher orders unavailable; only local requests can run")
            }
            if let response {
                guard response.1 == 200 else { throw khuFail("orders were refused (\(response.1))") }
                let signed = try JSON.decode(SignedReply.self, from: response.0)
                let publisherKey = try Signing.loadPublicKey(base64: config.publicKey)
                guard let ordersBody = signed.replyData, let signature = signed.signatureData,
                      Signing.verify(ordersBody, signature: signature, publicKey: publisherKey) else {
                    throw khuFail("the orders were not signed by this publisher's key; refused")
                }
                orders = try JSON.decode(CommandsReply.self, from: ordersBody)
                guard orders.machine == config.machine else { throw khuFail("orders for \(orders.machine), not \(config.machine); refused") }
                guard let signedAt = ISO.date(orders.at), abs(signedAt.timeIntervalSince(now)) <= orderFreshness else {
                    throw khuFail("orders signed at \(orders.at) are not fresh; refused (a replayed order is not an order)")
                }
                reportedIDs = Set(orders.commands.map { $0.id })
            }
        }

        var todo: [(app: String, id: String, action: String, explicit: Bool)] = []
        for command in orders.commands where command.machine == config.machine {
            if let done = memory.done[command.id] {
                // Already carried out; only the report was lost.
                if delivered(post(command.id, done)) { memory.done[command.id]?.sent = true }
                continue
            }
            if !todo.contains(where: { $0.app == command.app || $0.id == command.id }) {
                todo.append((command.app, command.id, command.action, true))
            }
        }
        // "Update now" from the menu-bar icon is this Mac's own order: it runs even while paused.
        for app in requested.sorted() where config.apps[app] != nil && !todo.contains(where: { $0.app == app }) {
            todo.append((app, "auto-\(app)-menu-\(UUID().uuidString)", ServerCommand.update, true))
        }
        for app in rollbacks.sorted() where config.apps[app] != nil && !todo.contains(where: { $0.app == app }) {
            todo.append((app, "auto-\(app)-menu-\(UUID().uuidString)", ServerCommand.rollback, true))
        }
        // A pause from the menu holds Automatic only; the owner's orders and "Update now" still run.
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key })
        where publisherAvailable && !helper.paused(at: now) && helper.installsAutomatically && !statusOnly.contains(cfg.recipe)
            && helper.automatic(app, page: orders.automatic[app], pageAt: orders.automaticAt?[app], config: cfg.automatic) {
            guard !todo.contains(where: { $0.app == app }), let entry = feed.apps[app] else { continue }
            guard memory.rejected[app] != entry.sha256 else { continue }  // failed here before: wait for a new artifact
            let current = installed[app]
            if current == nil || VersionCompare.isNewer(entry.version, than: current!) {
                todo.append((app, "auto-\(app)-\(UUID().uuidString)", ServerCommand.update, false))
            }
        }
        try remember()

        // 6. One install at a time; a failure is reported and the next app still runs.
        for item in todo {
            var res: RecipeResult
            // An order to update is the owner asking for that artifact again, so what failed here
            // before is cleared. A rollback is not: it puts the version he rejected back on purpose.
            if item.explicit && item.action == ServerCommand.update {
                memory.rejected[item.app] = nil; memory.deliveryMismatches?[item.app] = nil
            }
            if config.apps[item.app]?.recipe == "updater", let entry = feed.apps[item.app] {
                memory.updaterArtifacts = (memory.updaterArtifacts ?? [:]).merging([entry.version: entry.sha256]) { _, new in new }
                try remember()
            }
            installing(item.app)
            defer { installing(nil) }
            do {
                switch item.action {
                case ServerCommand.update:
                    // A click in the Launcher installs the SSD copy when it is at least as new as the feed's.
                    let local = requested.contains(item.app) ? catalog.first { $0.id == item.app }?.ssd : nil
                    res = try install(app: item.app, feed: feed, installed: installed[item.app], config: config,
                                      serverBase: artifactBase, stateDir: stateDir, http: http, shell: shell, control: control, local: local,
                                      force: reinstall.contains(item.app), artifactFallbacks: artifactFallbacks)
                case ServerCommand.vendorInstall:
                    guard let command = orders.commands.first(where: { $0.id == item.id && $0.machine == config.machine }) else {
                        throw khuFail("vendor install requires an explicit signed order for this Mac")
                    }
                    res = try installVendor(command, config: config, stateDir: stateDir, http: http, shell: shell, control: control)
                case ServerCommand.rollback:
                    res = try orderedRollback(app: item.app, order: item.id, installed: installed[item.app], config: config,
                                              stateDir: stateDir, shell: shell, control: control)
                default:
                    res = RecipeResult(status: "refused", reason: "this Mac does not know the order action \"\(item.action)\"; refused")
                }
            } catch let error as ArtifactFailure {
                res = RecipeResult(status: "failed", reason: "\(error)")
            } catch {
                res = RecipeResult(status: "install_failed", reason: "\(error)")
            }
            if res.status == "download_mismatch", let sha = feed.apps[item.app]?.sha256 {
                let previous = memory.deliveryMismatches?[item.app]
                let count = (previous?.sha256 == sha ? previous!.count : 0) + 1
                memory.deliveryMismatches = (memory.deliveryMismatches ?? [:]).merging([item.app: .init(sha256: sha, count: count)]) { _, new in new }
                res = RecipeResult(status: count >= maxDeliveryMismatches ? "failed" : "download_failed",
                                   reason: "\(res.reason ?? "") (mismatched download \(count) of \(maxDeliveryMismatches) in a row)")
            } else if res.status != "download_failed" {
                memory.deliveryMismatches?[item.app] = nil
            }
            // A version the owner just rolled back FROM must not be reinstalled by Automatic on the
            // next run: it is remembered rejected by the SHA the feed names for it, exactly like a
            // version that failed here. A new artifact, or an update order, clears it.
            if res.status == "rolled_back_by_owner" {
                if let sha = rejectRolledBackFrom(app: item.app, displaced: res.version, feed: feed, memory: &memory) {
                    result.notes.append("\(item.app): rolled back by the owner; \(res.version ?? "the version rolled back from") is rejected (\(sha.prefix(12))) until a new artifact arrives")
                } else {
                    result.notes.append("\(item.app): rolled back by the owner; the feed does not name \(res.version ?? "the version rolled back from"), so no artifact was marked rejected")
                }
            }
            // Only an artifact that is unusable *itself* is remembered as rejected. A download or
            // transport failure says nothing about the artifact, so the next run tries it again.
            // A rollback order that fails must NOT mark the feed's current artifact rejected:
            // that artifact may be a newer release this Mac never tried, and suppressing it
            // silently breaks Automatic. Only rolled_back_by_owner marks the displaced version.
            if item.action == ServerCommand.update,
               ["failed", "rolled_back", "rollback_failed", "rollback_unhealthy", "rollback_blocked"].contains(res.status),
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
        result.apps = snapshot(config: config, feed: feed, catalog: catalog, orders: orders, helper: helper, memory: memory,
                               executable: executable, http: http, serverBase: artifactBase, stateDir: stateDir)
        let vendorApps = vendorRows(stateDir: stateDir)
        result.apps.removeAll { row in vendorApps.contains { $0.app == row.app } }
        result.apps += vendorApps
        if feed.network?.controller != nil, let connectionFile {
            do {
                if try followControllerHandoff(release: selected.release, config: config, memory: memory,
                                               file: connectionFile, http: http, now: now) {
                    result.notes.append("controller connection moved; this Mac's enrolment and app choices were kept")
                }
            } catch { result.notes.append("controller move did not finish: \(error)") }
        }
        return result
    }

    /// Each app as it stands on disk now, for the menu-bar icon.
    static func snapshot(config: AgentConfig, feed: Feed, catalog: [CatalogEntry], orders: CommandsReply, helper: HelperSettings,
                         memory: AgentMemory, executable: String?, http: HTTPClient, serverBase: URL, stateDir: URL) -> [HelperApp] {
        let ids = Set(config.apps.keys).union(catalog.map(\.id))
        return ids.map { app -> HelperApp in
            let cfg = config.apps[app]
            let entry = catalog.first { $0.id == app }
            let installed = cfg?.recipe == "updater" ? selfVersion(config: config, executable: executable)
                : cfg.flatMap { try? BundleInfo.read($0.bundlePath) }?.version
            let last = memory.done.values.filter { $0.app == app }.max { $0.at < $1.at }.map { ($0.status, $0.reason) }
            // An app its SSD marks as updating itself is shown that way, whatever this Mac's recipe.
            let only = (cfg.map { statusOnly.contains($0.recipe) } ?? false) || (entry?.updatesItself ?? false)
            let available = cfg?.recipe == "updater" ? feed.apps[app]?.version : (entry?.available ?? feed.apps[app]?.version)
            let (status, reason) = HelperApp.status(installed: installed, available: only ? nil : available, statusOnly: only, last: last)
            var row = HelperApp(app: app, installed: installed, available: available, statusOnly: only,
                                automatic: !only && cfg != nil && helper.automatic(app, page: orders.automatic[app], pageAt: orders.automaticAt?[app], config: cfg!.automatic),
                                status: status, reason: reason)
            row.name = cfg?.recipe == "updater" ? "Studio Launcher KH" : (entry?.name ?? feed.apps[app]?.name ?? AppNames.display(app))
            row.source = entry?.source
            row.notes = entry?.notes ?? feed.apps[app]?.notes
            row.setupFolder = entry?.setupFolder
            row.managed = cfg != nil
            row.words = entry?.words ?? AppWords()
            // The helper is not an app on offer, but its own words come from its SSD entry.
            if cfg?.recipe == "updater", let mine = Catalog.seen(in: stateDir).first(where: { $0.id == "updater" }) { row.words = mine.words }
            row.released = entry?.released ?? feed.apps[app]?.released
            row.bytes = entry?.ssd == nil ? feed.apps[app]?.bytes : entry?.bytes
            row.fromSSD = entry?.ssd?.volume
            if let cfg, installed != nil, cfg.recipe != "updater" {
                row.installedAt = ((try? FileManager.default.attributesOfItem(atPath: cfg.bundlePath))?[.modificationDate] as? Date).map(ISO.string)
                row.canRollBack = FileManager.default.fileExists(atPath: Recipe.Paths(installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app).rollback.path)
            }
            if let cfg, installed != nil, cfg.recipe != "updater" { row.bundlePath = cfg.bundlePath }
            // The icon read from the app's own bundle (cached from an SSD or the feed), else the installed copy's.
            row.icon = entry?.icon ?? feedIcon(feed.apps[app], http: http, serverBase: serverBase, stateDir: stateDir) ?? row.bundlePath
            return row
        }.filter { row in
            // Offered only where it can be installed; the control window only where it already is.
            (row.managed || row.available != nil) && !(row.installed == nil && catalog.first { $0.id == row.app }?.mainMacOnly == true)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The feed's icon for an app this Mac does not have, kept under `state/icons/` once its
    /// signed SHA-256 matches. Nil (a plain placeholder) when there is none or it does not match.
    static func feedIcon(_ entry: FeedApp?, http: HTTPClient, serverBase: URL, stateDir: URL) -> String? {
        guard let name = entry?.icon, let sha = entry?.iconSha256, let safe = try? SafeName.component(name, what: "icon") else { return nil }
        let file = stateDir.appendingPathComponent("icons").appendingPathComponent(safe)
        if (try? Signing.sha256Hex(fileAt: file).hex) == sha { return file.path }
        guard let (data, code) = try? http.get(serverBase.appendingPathComponent("artifacts").appendingPathComponent(safe), headers: [:]),
              code == 200, data.count < 1 << 20, Signing.sha256Hex(data) == sha else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return file.path
    }

    static func verifiedFeed(http: HTTPClient, serverBase: URL, config: AgentConfig, memory: inout AgentMemory, now: Date) throws -> Feed {
        try selectFeed(http: http, serverBase: serverBase, config: config, memory: &memory, now: now).feed
    }

    static func checkedFeed(_ releaseData: Data, config: AgentConfig, memory: inout AgentMemory, now: Date) throws -> Feed {
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

    /// The owner's rollback order: the version this Mac kept goes back through the same journaled,
    /// health-settled path an install uses. Nothing is downloaded and the feed is not consulted —
    /// what runs is the bundle already on this Mac, verified before anything is stopped.
    static func orderedRollback(app: String, order: String, installed: String?, config: AgentConfig, stateDir: URL,
                                shell: Shell, control: (String, AppConfig) -> AppControl) throws -> RecipeResult {
        guard let cfg = config.apps[app] else {
            return RecipeResult(status: "refused", reason: "\(app) is not configured on this Mac")
        }
        if statusOnly.contains(cfg.recipe) {
            return RecipeResult(status: "refused", reason: "\(app) is updated by its own updater; KH Updater will not roll it back")
        }
        switch cfg.recipe {
        case "app-dmg", "gateway":
            guard installed != nil || FileManager.default.fileExists(atPath: cfg.bundlePath) else {
                return RecipeResult(status: "refused", reason: "\(app) is not installed at \(cfg.bundlePath), so there is nothing to roll back from")
            }
            return try Recipe.ownerRollback(shell: shell, installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app,
                                            expectedBundleID: cfg.bundleID, order: order, control: control(app, cfg))
        case "updater":
            // The stub is the updater's own fallback, and it only puts back a version it saw fail.
            return RecipeResult(status: "refused", reason: "KH Updater does not roll itself back in this version: "
                               + "the stub only restores a previous version after a probation, so there is no order for it here")
        default:
            return RecipeResult(status: "refused", reason: "the \(cfg.recipe) recipe cannot be rolled back")
        }
    }

    /// The artifact this Mac rolled back FROM, marked rejected by its signed SHA. Only the feed can
    /// say which bytes a version is, so when it does not name that version nothing is marked: an
    /// invented SHA would suppress an artifact nobody identified.
    static func rejectRolledBackFrom(app: String, displaced: String?, feed: Feed, memory: inout AgentMemory) -> String? {
        guard let sha = feed.apps[app].flatMap({ $0.version == displaced ? $0.sha256 : nil }) else { return nil }
        memory.rejected[app] = sha
        return sha
    }

    static func install(app: String, feed: Feed, installed: String?, config: AgentConfig, serverBase: URL, stateDir: URL,
                        http: HTTPClient, shell: Shell, control: (String, AppConfig) -> AppControl,
                        local: CatalogEntry.Local? = nil, force: Bool = false, artifactFallbacks: [URL] = []) throws -> RecipeResult {
        guard let cfg = config.apps[app] else { throw khuFail("\(app) is not configured on this Mac") }
        if statusOnly.contains(cfg.recipe) { return RecipeResult(status: "status_only", reason: "updated by its own updater") }
        if let local { return try installLocal(local, app: app, installed: force ? nil : installed, cfg: cfg, stateDir: stateDir, shell: shell, control: control) }
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
            if order == 0 && !force { return RecipeResult(status: "current", reason: "\(installed) is already installed") }
            if order < 0 { return RecipeResult(status: "refused", reason: "the feed has \(entry.version), older than \(installed) here; no downgrade") }
        }

        let artifact: URL
        do {
            artifact = try download(entry, app: app, serverBase: serverBase, stateDir: stateDir, http: http, fallbacks: artifactFallbacks)
        } catch let error as ArtifactFailure {
            return RecipeResult(status: "failed", reason: "\(error)")
        } catch let error as DeliveryMismatch {
            return RecipeResult(status: "download_mismatch", reason: "\(error)")
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

    /// An install from an SSD: the copy must match the SHA-256 its `apps.json` names before
    /// anything is touched, then it takes the same journaled app-dmg path, with rollback, as a
    /// download does.
    static func installLocal(_ local: CatalogEntry.Local, app: String, installed: String?, cfg: AppConfig, stateDir: URL,
                             shell: Shell, control: (String, AppConfig) -> AppControl) throws -> RecipeResult {
        if let installed, !VersionCompare.isNewer(local.version, than: installed) {
            return RecipeResult(status: "current", reason: "\(installed) is already installed; \(local.volume) has \(local.version)")
        }
        guard let sha = try? Signing.sha256Hex(fileAt: URL(fileURLWithPath: local.file)).hex else {
            return RecipeResult(status: "refused", reason: "the copy on \(local.volume) could not be read; nothing was changed")
        }
        guard sha == local.sha256 else {
            return RecipeResult(status: "refused", reason: "the copy on \(local.volume) does not match its checksum; nothing was changed")
        }
        switch cfg.recipe {
        case "app-dmg", "gateway":
            return try Recipe.appDmg(shell: shell, installedPath: cfg.bundlePath, artifactPath: local.file, feedVersion: local.version,
                                     expectedBundleID: cfg.bundleID, stateDir: stateDir.path, app: app, control: control(app, cfg))
        case "fake-for-tests":
            return RecipeResult(status: "updated", reason: "from \(local.volume)")
        default:
            return RecipeResult(status: "refused", reason: "the \(cfg.recipe) recipe does not install from an SSD")
        }
    }

    /// Stream the artifact to `downloads/<app>/`, checked against the signed size and SHA-256
    /// before any recipe sees it. The previous download for the app goes to `_trash`.
    static func download(_ entry: FeedApp, app: String, serverBase: URL, stateDir: URL, http: HTTPClient, fallbacks: [URL] = []) throws -> URL {
        let name = try SafeName.component(entry.file, what: "artifact name")
        let dir = stateDir.appendingPathComponent("downloads").appendingPathComponent(app)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { try Trash.move(dir, into: Trash.root(in: stateDir)) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent(name + ".part")
        do {
            let code = try http.download(serverBase.appendingPathComponent("artifacts").appendingPathComponent(name),
                                         headers: [:], to: part, limit: entry.bytes)
            guard code == 200 else { throw khuFail("artifact download answered \(code); nothing was changed") }
            let (sha, bytes) = try Signing.sha256Hex(fileAt: part)
            guard bytes == entry.bytes else { throw DeliveryMismatch(description: "artifact size mismatch; nothing was changed") }
            guard sha == entry.sha256 else { throw DeliveryMismatch(description: "artifact sha256 mismatch; nothing was changed") }
            let artifact = dir.appendingPathComponent(name)
            try fm.moveItem(at: part, to: artifact)
            return artifact
        } catch {
            do { try Trash.move(part, into: Trash.root(in: stateDir)) }
            catch { throw khuFail("download failed and its partial file could not be moved to _trash: \(error)") }
            if let next = fallbacks.first {
                return try download(entry, app: app, serverBase: next, stateDir: stateDir, http: http, fallbacks: Array(fallbacks.dropFirst()))
            }
            throw error
        }
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
    /// When each `automatic` value was last set, so a later switch on the Mac can win. Absent from
    /// older publishers, and for values set before it existed: those count as older than any switch.
    public var automaticAt: [String: String]?

    public init(machine: String, at: String = ISO.string(Date()), commands: [ServerCommand], automatic: [String: Bool],
                automaticAt: [String: String]? = nil) {
        self.machine = machine; self.at = at; self.commands = commands; self.automatic = automatic; self.automaticAt = automaticAt
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

/// Read Hub’s local human label only when its controller matches this enrolment.
public enum MacName {
    public static let maxCharacters = 128
    public static func valid(_ name: String) -> Bool {
        !name.isEmpty && name.utf16.count <= maxCharacters && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               applications: URL = URL(fileURLWithPath: "/Applications"),
                               computerName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?,
                               expectedMachine: String? = nil,
                               hostName: String = ProcessInfo.processInfo.hostName) -> String? {
        let fm = FileManager.default
        let settings = home.appendingPathComponent("Library/Application Support/StudioHub Standalone/hub/controller_settings.json")
        var candidates: [URL] = []
        for folder in [applications, home.appendingPathComponent("Applications")] {
            for app in ["Studio Hub.app", "Hub Studio KH.app"] where fm.fileExists(atPath: folder.appendingPathComponent(app).path) {
                let voice = folder.appendingPathComponent(app).appendingPathComponent("Contents/Resources/voice")
                candidates += [settings, voice.appendingPathComponent("components/controller_settings.json"), voice.appendingPathComponent("controller_settings.json")]
            }
        }
        for path in candidates {
            guard let data = try? Data(contentsOf: path),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = value["controller_id"] as? String,
                  valid(name) else { continue }
            if let expectedMachine, name == expectedMachine {
                let labels = path.deletingLastPathComponent().appendingPathComponent("machine_labels.json")
                if let data = try? Data(contentsOf: labels),
                   let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let label = values["local"] as? String, valid(label) { return label }
                if let shortHost = hostName.split(separator: ".").first.map(String.init), valid(shortHost) { return shortHost }
            }
            return name
        }
        return computerName.flatMap { valid($0) ? $0 : nil }
    }
}
