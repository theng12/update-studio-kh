import Foundation
import SystemConfiguration
import CryptoKit

public struct AgentRunResult: Sendable, Equatable {
    public var statusPosted: Bool
    public var commandsRun: Int
    public var updates: Int
    public var restartRequested = false
    public var notes: [String] = []
    /// No fresh verified server feed was available; SSD offers do not claim server currency.
    public var feedError: String?
    /// Each app as the menu-bar icon shows it, from what is on disk after the run.
    public var apps: [HelperApp] = []
    public init(statusPosted: Bool = false, commandsRun: Int = 0, updates: Int = 0) {
        self.statusPosted = statusPosted; self.commandsRun = commandsRun; self.updates = updates
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int)
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int)
    /// The same POST with a caller's own deadline, for the update hold's 30 s contract window.
    func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws -> (Data, Int)
    /// DELETE, used to resume an app's update hold. A client without it simply lets the pause expire.
    func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int)
    /// The same DELETE with a caller's own deadline.
    func delete(_ url: URL, headers: [String: String], timeout: TimeInterval) throws -> (Data, Int)
    /// Stream a GET into `file`, refusing more than `limit` bytes. Returns the HTTP status.
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int
    /// The same download under a named phase, so the Launcher can say what is happening:
    /// "delta-downloading" for a patch, "downloading" for a whole artifact.
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64, phase: String) throws -> Int
}

extension HTTPClient {
    public func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        throw khuFail("this client cannot send DELETE")
    }
    public func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws -> (Data, Int) {
        try post(url, headers: headers, body: body)
    }
    public func delete(_ url: URL, headers: [String: String], timeout: TimeInterval) throws -> (Data, Int) {
        try delete(url, headers: headers)
    }
    /// A client that does not name phases still downloads: the phase is set around the transfer.
    public func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64, phase: String) throws -> Int {
        DownloadControl.updateProgress(phase)
        return try download(url, headers: headers, to: file, limit: limit)
    }
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
    /// No data for this long ends the transfer (URLRequest's own timeout). This is silence detection:
    /// a peer that stops sending at all. The transfer deadline below is a different job — it bounds
    /// a slow-but-alive link by the bytes that still have to move.
    public var timeout: TimeInterval = 60
    /// ...and no small request (feed, status, hold) takes longer than this IN TOTAL, however steadily
    /// the peer drips: an inactivity timeout alone lets a stalled or malicious peer hold a run open
    /// for ever. Artifact downloads use a size-derived deadline instead; see transferDeadline.
    public var totalTimeout: TimeInterval = 600
    /// The rate the deadline assumes, from what the fleet actually does: a 1.48 GB artifact has been
    /// taking ~1,500 s, i.e. about 1 MB/s. It is a CONSTANT, never measured from the transfer — a
    /// rate read off a stalled pull would divide by ~0 and hand back an unbounded deadline.
    public var assumedBytesPerSecond: Double = 1_000_000
    /// The old flat ceiling is now the FLOOR, not the bar to beat: no artifact may be given less time
    /// than it had before, so this change can only ever lengthen an allowance.
    static let transferFloor: TimeInterval = 600
    /// Cap: four hours covers any artifact the signed feed will ever name (1.5 GB at 1 MB/s is
    /// 1,500 s), and nothing may outlast it however the numbers move.
    static let transferCap: TimeInterval = 14_400
    /// The time `bytes` are allowed at `rate`, floored at the old ceiling and capped. `rate` is a
    /// constant, so this can never be unbounded; a rate of zero or less answers the cap rather than
    /// dividing by it. A dead link is ended by the 60 s inactivity timeout, not by this number.
    static func transferDeadline(bytes: Int64, rate: Double) -> TimeInterval {
        guard rate > 0 else { return transferCap }
        return min(max(Double(bytes) / rate, transferFloor), transferCap)
    }
    /// Shorten-only timeout for non-download requests: the hold's window and small feed/status calls
    /// cap at totalTimeout and may only be made shorter, never extended. Downloads use transferDeadline
    /// instead; keeping them apart means nobody can merge the two paths by accident.
    static func requestTimeout(total: TimeInterval, override: TimeInterval?) -> TimeInterval {
        min(total, override ?? total)
    }
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
    public func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws -> (Data, Int) {
        try send("POST", url, headers: headers, body: body, timeout: timeout)
    }
    public func delete(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        try send("DELETE", url, headers: headers, body: nil)
    }
    public func delete(_ url: URL, headers: [String: String], timeout: TimeInterval) throws -> (Data, Int) {
        try send("DELETE", url, headers: headers, body: nil, timeout: timeout)
    }

    private func send(_ method: String, _ url: URL, headers: [String: String], body: Data?,
                      timeout override: TimeInterval? = nil) throws -> (Data, Int) {
        let sink = try transfer(method, url, headers: headers, body: body, handle: nil, limit: Int64(smallLimit),
                                timeoutOverride: override)
        return (sink.buffer, sink.status)
    }

    public func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        try download(url, headers: headers, to: file, limit: limit, phase: "downloading")
    }

    public func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64, phase: String) throws -> Int {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil) else { throw khuFail("cannot write \(file.path)") }
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { throw khuFail("cannot write \(file.path)") }
        defer { try? handle.close() }
        // The bytes already on disk are the transfer's own progress: a failed or stopped download
        // keeps its partial file, and the next attempt asks the server only for what is missing.
        // A partial the signed size cannot hold is not progress; that one starts over.
        var start = Int64((try? handle.seekToEnd()) ?? 0)
        var requestHeaders = headers
        if start > 0, start < limit {
            requestHeaders["Range"] = "bytes=\(start)-"
        } else if start > 0 {
            _ = try? handle.truncate(atOffset: 0); _ = try? handle.seek(toOffset: 0); start = 0
        }
        DownloadControl.updateProgress(phase, received: start, total: start > 0 ? limit : nil)
        let status = try transfer("GET", url, headers: requestHeaders, body: nil, handle: handle, limit: limit,
                                  phase: phase, resumeFrom: start).status
        DownloadControl.updateProgress("checking")
        return status
    }

    private func transfer(_ method: String, _ url: URL, headers: [String: String], body: Data?,
                          handle: FileHandle?, limit: Int64, phase: String = "downloading",
                          resumeFrom: Int64 = 0, timeoutOverride: TimeInterval? = nil) throws -> StreamSink {
        // Downloads get a deadline sized from the bytes still to move; everything else (hold POSTs,
        // feed/status GETs) keeps the old shorten-only behaviour. Keeping them apart means nobody
        // can merge the two paths by accident and silently cap a download at totalTimeout again.
        let deadline: TimeInterval
        if handle != nil {
            let remaining = max(0, limit - resumeFrom)
            deadline = Self.transferDeadline(bytes: remaining, rate: assumedBytesPerSecond)
        } else {
            deadline = Self.requestTimeout(total: totalTimeout, override: timeoutOverride)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(timeout, timeoutOverride ?? timeout))
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let officialHosts, !Self.officialURL(url, hosts: officialHosts) {
            throw khuFail("download refused: URL is outside the vendor's official HTTPS hosts")
        }
        let sink = StreamSink(handle: handle, limit: limit, officialHosts: officialHosts, phase: phase, resumeFrom: resumeFrom)
        let session = URLSession(configuration: .ephemeral, delegate: sink, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        // The deadline is ours to keep, not the peer's to reset. A download the person paused from
        // the Launcher is held where it is and its paused time does not count; Cancel stops it.
        // The cancel state belongs to the operation, not to this transfer: it is reset once before
        // an install starts, so a Cancel is never erased by the next source a fallback tries.
        var finished = false, spent: TimeInterval = 0, suspended = false, cancelled = false
        while spent < deadline {
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
            // A cancelled transfer's session must go now, not wait for tasks that will never finish:
            // `finishTasksAndInvalidate` leaves it — and its delegate, its sockets and its Mach ports —
            // alive, and one of these per timed-out check is what grew an idle agent to 16k ports.
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }
        TransferMeter.record()
        if cancelled { throw khuFail("cancelled on this Mac; nothing was changed") }
        guard finished else { throw khuFail("\(url.path) did not finish within \(Int(deadline)) s; it was stopped") }
        if let error = sink.error { throw error }
        return sink
    }
}

/// HTTP transfers this process has made. Each completed one costs the system's HTTP stack about one
/// Mach port and 30-50 KB that are never given back — measured 2026-11-17 with a bare URLSession,
/// independent of session lifetime and of how the session is invalidated — so the agent bounds its
/// own lifetime by this count and starts again in place before the total can matter.
public enum TransferMeter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    public static var completed: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func record() { lock.lock(); count += 1; lock.unlock() }
}

/// When this process should start again in place. Both bounds live here so the arithmetic is in one
/// place: an idle run is the feed, the status report and the orders check — three transfers every
/// five minutes, 864 a day — so 500 lasts about fourteen hours and caps the process at roughly 500
/// ports and 20 MB, instead of the ~864 ports and ~35 MB a day it would otherwise add.
public enum AgentRecycle {
    public static let afterTransfers = 500
    public static let afterSeconds: TimeInterval = 24 * 3600
    public static func due(transfers: Int, age: TimeInterval,
                           afterTransfers: Int = afterTransfers,
                           afterSeconds: TimeInterval = afterSeconds) -> String? {
        if transfers >= afterTransfers {
            return "it has made \(transfers) transfers, and the system's HTTP stack keeps a port for each"
        }
        if age >= afterSeconds {
            return "it has been running \(Int(age / 3600)) h, and the system's HTTP stack keeps a port for each transfer"
        }
        return nil
    }
}

/// The Launcher's Pause and Cancel for the download in progress. One download runs at a time.
public enum DownloadControl {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = (paused: false, cancelled: false)
    nonisolated(unsafe) private static var transferProgress = (phase: "preparing", received: Int64?.none, total: Int64?.none)
    public static var progress: (phase: String, received: Int64?, total: Int64?) {
        lock.lock(); defer { lock.unlock() }; return transferProgress
    }
    static func updateProgress(_ phase: String, received: Int64? = nil, total: Int64? = nil) {
        lock.lock(); transferProgress = (phase, received, total); lock.unlock()
    }
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
    var expected: Int64?
    var status = 0
    var error: Error?
    /// Bytes already on disk when this transfer started; a Range reply appends after them.
    var initial: Int64

    let officialHosts: [String]?
    /// What the Launcher is told is happening while these bytes arrive.
    let phase: String
    init(handle: FileHandle?, limit: Int64, officialHosts: [String]?, phase: String = "downloading", resumeFrom: Int64 = 0) {
        self.handle = handle; self.limit = limit; self.officialHosts = officialHosts; self.phase = phase
        self.initial = resumeFrom
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
        let length = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if status == 206 {
            // The rest of the file, after the bytes already on disk; the total is still the signed size.
            expected = length.map { initial + $0 }
            if let length, initial + length > limit {
                error = DeliveryMismatch(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
                completionHandler(.cancel)
                return
            }
        } else if status == 200 {
            // A peer that does not honour Range sends the whole file: start the file over rather
            // than appending a second copy to the bytes already there.
            if initial > 0, let handle {
                _ = try? handle.truncate(atOffset: 0)
                _ = try? handle.seek(toOffset: 0)
                initial = 0
            }
            expected = length
            if response.expectedContentLength > limit {
                error = DeliveryMismatch(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
                completionHandler(.cancel)
                return
            }
        } else if status == 416 {
            // The server cannot continue from what is here; the caller starts this one over. The
            // reply's own body is not artifact bytes and is dropped by the status guard below.
            completionHandler(.allow)
            return
        } else {
            // Any other status carries an error message: it is never written onto a partial file.
            expected = length
        }
        if handle != nil { DownloadControl.updateProgress(phase, received: initial, total: expected) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // An error reply's body is not artifact bytes: it must never land on a partial file that
        // a later attempt will resume from. Small replies (get/post) keep their body: that is the
        // publisher's own refusal sentence, which the person is shown.
        guard status == 200 || status == 206 || handle == nil else { return }
        received += Int64(data.count)
        guard initial + received <= limit else {
            error = DeliveryMismatch(description: "\(dataTask.originalRequest?.url?.path ?? "response") is larger than expected")
            dataTask.cancel()
            return
        }
        guard let handle else { buffer.append(data); return }
        // Paused from the Launcher: hold this delivery, so the connection backs up and the sender
        // waits. Suspending the task alone lets data already in flight keep arriving.
        while DownloadControl.paused && !DownloadControl.cancelled { usleep(100_000) }
        do {
            try handle.write(contentsOf: data)
            DownloadControl.updateProgress(phase, received: initial + received, total: expected)
        } catch { self.error = error; dataTask.cancel() }
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
    /// Displaced versions from local offline rollbacks, reconciled when a signed feed returns.
    public var offlineRollbacks: [String: String]?
    public struct Mismatch: Codable, Sendable, Equatable { public var sha256: String; public var count: Int }
    /// app → consecutive downloads of the same signed artifact whose bytes did not match it.
    public var deliveryMismatches: [String: Mismatch]?
    public var observedStubRollbacks: Int?
    public var updaterArtifacts: [String: String]?
    public var feedPublishedAt: String?
    public var feedSHA256: String?
    public var feedNetwork: FeedNetwork?
    /// app → "version|status|reason" of the last refused or failed attempt already written to the
    /// local log, so a refusal repeated every cycle is said once, not every 5 minutes.
    public var refusalsSaid: [String: String]?
    /// app → since when an update has waited for the app to close (its build predates the hold),
    /// and why. Reported on each status, so the page says the Mac is waiting, not failing.
    public struct Waiting: Codable, Sendable, Equatable { public var since: String; public var reason: String }
    public var waiting: [String: Waiting]?
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
    /// The one recipe that never installs: an app observed on this Mac that keeps its own updater.
    /// It is only set by `Catalog.discover` for an app the live sources mark that way.
    static let statusOnly: Set<String> = ["status"]
    /// Recipes that put a bundle in place with the journaled app-dmg route. `story` and `hub` are the
    /// names older configs still carry for Story and Hub; they now install like every other app.
    static let appDmgRecipes: Set<String> = ["app-dmg", "gateway", "story", "hub"]
    static let knownRecipes: Set<String> = statusOnly.union(appDmgRecipes).union(["updater", "fake-for-tests"])
    /// An app that updates itself: its own updater owns its life, so KH Updater never installs or
    /// updates it by itself — Automatic and remote orders leave it alone. The person at the Mac may
    /// still choose to install or update it by hand, from the Launcher. Only the live catalog marks
    /// one (the signed feed's kind, or an SSD for an app the feed does not list); no app id is
    /// special-cased here.
    static func updatesItself(app: String, recipe: String? = nil, entry: CatalogEntry? = nil) -> Bool {
        if statusOnly.contains(app) { return true }
        if let recipe, statusOnly.contains(recipe) { return true }
        return entry?.updatesItself ?? false
    }
    /// A Production app that updates itself is not replaced while it runs: this route proves no
    /// quiet point, so the person is asked to finish the work first — the same rule the explicit
    /// SSD action keeps. Nothing is touched and nothing is downloaded. The live catalog decides,
    /// not this Mac's recipe alone: an older config that still says `app-dmg` is a self-updating app
    /// when its SSD entry says so.
    static func refusesWhileRunning(app: String, cfg: AppConfig, control: (String, AppConfig) -> AppControl,
                                    entry: CatalogEntry? = nil) -> String? {
        guard updatesItself(app: app, recipe: cfg.recipe, entry: entry) else { return nil }
        guard control(app, cfg).isRunning() ?? true else { return nil }
        return "Quit this app when its work is finished, then try again. No quiet point was proved."
    }
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
            if real.path.hasPrefix(versions) {
                // Runs from versions/<v>/khu or the named helper bundle inside that folder.
                let version = StubLayout.version(of: real)
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
                               connectionFile: URL? = nil, configFile: URL? = nil) throws -> AgentRunResult {
        // A config that names only the helper is a Mac that was just enrolled: it seeds itself from
        // the signed feed and what is installed here (see `adoptInstalledApps`). Read before this
        // run's own discovery adds anything, so "just enrolled" stays a fact about the saved file.
        let sparseConfig = config.apps.keys.allSatisfy { $0 == "updater" }
        // The paths as the live config states them, so a repair can be written back to that file.
        let loadedPaths = config.apps.mapValues(\.bundlePath)
        // Apps installed by hand since this Mac was set up are found by bundle ID and managed too.
        let stateURL = URL(fileURLWithPath: config.stateDir)
        var config = config
        // Saved registrations join the config before discovery, so an app adopted last run is not
        // found (and announced) again on every cycle.
        let savedRegistrations = try mergeRegistrations(config: config, stateDir: stateURL)
        config = savedRegistrations.config
        let startingNotes = savedRegistrations.notes
        var repairNotes: [String] = [], adoptedIDs: [String] = []
        config.apps = Catalog.adopting(config.apps,
                                       discovered: Catalog.discover(config: config, known: Catalog.known(in: stateURL, ssd: ssd), folders: appFolders),
                                       repairs: &repairNotes, adopted: &adoptedIDs)
        // An app found on this Mac is kept: its registration is saved, so the next run starts with
        // it and the one-line note is said once, not on every cycle.
        if !adoptedIDs.isEmpty {
            persistAdoptions(adoptedIDs, config: config, stateDir: stateURL)
            repairNotes += adoptedIDs.sorted().map { "\($0): adopted this Mac's installed app" }
        }
        try validate(config)
        let stateDir = URL(fileURLWithPath: config.stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // One agent at a time per Mac. A second long-running agent refuses instead of racing; a
        // one-shot local request (`--install`, `--once`, or a request handed to the loop) is bounded
        // explicit work, so it waits for the run in progress instead of failing on its lock.
        return try FileLock.withExclusive(stateDir.appendingPathComponent("agent.lock"),
                                          wait: config.once || !requested.isEmpty) {
            try runLocked(config: config, stateDir: stateDir, http: http, shell: shell,
                          control: control ?? { liveControl($1, shell: shell) }, executable: executable, now: now,
                          requested: requested, installing: installing ?? { _ in }, ssd: ssd, connectionFile: connectionFile,
                          appFolders: appFolders, sparseConfig: sparseConfig, startingNotes: startingNotes + repairNotes,
                          configFile: configFile, loadedPaths: loadedPaths)
        }
    }

    /// The saved Launcher registrations, merged under the config's own entries. Both the pre-run
    /// discovery and the locked run use it, so an app adopted last run is not found again.
    static func mergeRegistrations(config: AgentConfig, stateDir: URL) throws -> (config: AgentConfig, notes: [String]) {
        let registrations = try AtomicFile.readJSON([String: AppConfig].self, from: stateDir.appendingPathComponent("launcher-apps.json")) ?? [:]
        var merged = config
        var notes: [String] = []
        for (app, registration) in registrations.sorted(by: { $0.key < $1.key }) where merged.apps[app] == nil {
            var candidate = merged
            candidate.apps[app] = registration
            do { try validate(candidate); merged = candidate }
            catch { notes.append("\(app): saved Launcher registration was skipped: \(error)") }
        }
        return (merged, notes)
    }

    /// A refused or failed attempt names its reason in this Mac's own log, not only in the
    /// publisher's record: once per app, version and reason. A success clears it, so the next
    /// refusal is said again.
    /// The hold step's answer for a running build that predates its hold: not a refusal, a wait.
    public static let waitingForClose = "waiting_for_close"

    static func refusalNote(app: String, version: String?, result: RecipeResult, memory: inout AgentMemory) -> String? {
        let refusals: Set<String> = [waitingForClose, "refused", "failed", "install_failed", "download_failed", "download_mismatch",
                                     "did_not_start", "rolled_back", "rollback_failed", "rollback_unhealthy", "rollback_blocked"]
        guard refusals.contains(result.status) else { memory.refusalsSaid?[app] = nil; return nil }
        let shown = version ?? "the feed's version"
        let said = "\(shown)|\(result.status)|\(result.reason ?? "")"
        guard memory.refusalsSaid?[app] != said else { return nil }
        memory.refusalsSaid = (memory.refusalsSaid ?? [:]).merging([app: said]) { _, new in new }
        return "\(app) \(shown): \(result.status) — \(result.reason ?? "no reason was given")"
    }

    static func liveControl(_ cfg: AppConfig, shell: Shell) -> AppControl {
        cfg.recipe == "gateway" ? LiveControl.gateway(cfg.bundlePath, shell: shell) : LiveControl.appDmg(cfg.bundlePath, shell: shell)
    }

    static func runLocked(config: AgentConfig, stateDir: URL, http: HTTPClient, shell: Shell,
                          control: @escaping (String, AppConfig) -> AppControl, executable: String?, now: Date,
                          requested asked: Set<String> = [], installing: (String?) -> Void = { _ in }, ssd: [SSDSource] = [],
                          connectionFile: URL? = nil, appFolders: [URL] = Catalog.applicationFolders,
                          sparseConfig: Bool = false, startingNotes: [String] = [],
                          configFile: URL? = nil, loadedPaths: [String: String] = [:]) throws -> AgentRunResult {
        DownloadControl.reset()
        var config = config
        let mergedRegistrations = try mergeRegistrations(config: config, stateDir: stateDir)
        config = mergedRegistrations.config
        try validate(config)
        // A path repair found during discovery is written back before anything else uses it.
        persistRepairedPaths(loaded: loadedPaths, config: config, file: configFile)
        let registrationNotes = mergedRegistrations.notes
        let vendors = try AtomicFile.readJSON([String: AppConfig].self, from: stateDir.appendingPathComponent("vendor-apps.json")) ?? [:]
        config.apps.merge(vendors) { configured, _ in configured }
        // From the Launcher: "<app>" installs or updates, "reinstall:<app>" installs the same
        // version again, "rollback:<app>" puts back the version this Mac kept.
        let reinstall = Set(asked.filter { $0.hasPrefix("reinstall:") }.map { String($0.dropFirst("reinstall:".count)) })
        let rollbacks = Set(asked.filter { $0.hasPrefix("rollback:") }.map { String($0.dropFirst("rollback:".count)) })
        let initialSSD = Set(asked.filter { $0.hasPrefix("ssd:") }.map { String($0.dropFirst("ssd:".count)) })
        let requested = Set(asked.filter { !$0.contains(":") }).union(reinstall).union(initialSSD)
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
        result.notes = startingNotes + registrationNotes

        // 0. Finish or undo any install a killed run left half done, before anything else.
        var interruptedOrders: [String: (app: String, journal: InstallJournal)] = [:]
        /// Apps whose journal this run cleared: their old failure result is no longer true.
        var recoveredApps: [String: String] = [:]
        // A hand install of an observed-only app is journaled like any other, so recovery reads
        // every recipe that can put a bundle in place.
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key })
        where appDmgRecipes.contains(cfg.recipe) || statusOnly.contains(cfg.recipe) {
            let before = try? AtomicFile.readJSON(InstallJournal.self, from: Recipe.journalURL(stateDir: stateDir.path, app: app))
            let wasUnresolved = Recipe.isUnresolved(stateDir: stateDir.path, app: app)
            let note = try Recipe.recover(installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app,
                                          control: control(app, cfg), controlForPath: { path in
                var original = cfg; original.bundlePath = path
                return control(app, original)
            })
            if !note.isEmpty { result.notes.append("\(app): \(note)") }
            if wasUnresolved, !note.isEmpty, !Recipe.isUnresolved(stateDir: stateDir.path, app: app) {
                recoveredApps[app] = note
            }
            // A swap the owner ordered is the recovery's own business too: the order it belonged to
            // is answered from what is on disk, not run a second time.
            if let journal = before, journal.intent == "owner_rollback", let order = journal.order {
                interruptedOrders[order] = (app, journal)
            }
        }
        // A recovery that cleared a journal settles the app: the row must stop repeating the old
        // failure and the retry that has already happened.
        if !recoveredApps.isEmpty {
            for (app, note) in recoveredApps.sorted(by: { $0.key < $1.key }) {
                // Delivered like any other automatic result: the fleet page must not keep the old
                // failure after this Mac has recovered it.
                memory.done["auto-recovered-\(app)-\(UUID().uuidString)"] = .init(
                    app: app, status: "updated", reason: "an interrupted install was finished on this run: \(note)",
                    at: ISO.string(now), sent: false)
            }
            try remember()
        }

        // 1. What is installed and running here — none of this needs the feed. Beside each version,
        // the identity a marketing version alone cannot give: the bundle's `CFBundleVersion` and the
        // SHA-256 of its executable as read from disk now. Both stay absent when they cannot be
        // read — an absent build is unknown, never "matching", and this bytes hash is about the
        // installed executable only, never the artifact a release was signed from.
        var installed: [String: String] = [:]
        var installedBuild: [String: String] = [:]
        var installedExecutableSha256: [String: String] = [:]
        var health: [String: String] = [:]
        for (app, cfg) in config.apps {
            if cfg.recipe == "updater" { continue }
            if let info = try? BundleInfo.read(cfg.bundlePath) {
                installed[app] = info.version
                if let build = info.build { installedBuild[app] = build }
                if let sha = info.executableSha256(in: cfg.bundlePath) { installedExecutableSha256[app] = sha }
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
        // Absent unless read: an app whose bundle carries no build simply reports no build, so the
        // page can tell "not checked" from an exact match. Neither key changes `installed`, which
        // every older publisher and page already reads.
        if !installedBuild.isEmpty { report["installed_build"] = installedBuild }
        if !installedExecutableSha256.isEmpty { report["installed_executable_sha256"] = installedExecutableSha256 }
        if let name = MacName.current(expectedMachine: config.machine) { report["display_name"] = name }
        if let until = helper.pausedUntil, helper.paused(at: now) { report["paused_until"] = until }
        if let waiting = memory.waiting, !waiting.isEmpty { report["waiting"] = waiting.mapValues { $0.reason } }
        // A read-only snapshot of this Mac's own hardware, addresses and installed apps, bounded
        // like every other report. Fields that could not be read stay absent; the machine's name
        // is never used as hardware, and the installed managed-app maps above are untouched.
        if let inventory = MacInventory.collect(now: now, shell: shell).asJSONObject() {
            report["inventory"] = inventory
        }
        let statusBody = try JSONSerialization.data(withJSONObject: report)
        let statusCode: Int?
        do { statusCode = try http.post(serverBase.appendingPathComponent("status"), headers: headers, body: statusBody).1 }
        catch {
            // A refused address is a sentence for the person, never Foundation's own text: this one
            // reaches the Launcher window unchanged, and "Code=-1022 … /status" told nobody anything.
            if blockedByTransportSecurity(error) {
                throw khuFail(plainUnreachable(serverBase.appendingPathComponent("status"), error: error))
            }
            guard transportUnavailable(error) else { throw error }
            statusCode = nil; publisherAvailable = false
            result.notes.append("publisher unavailable; local requests may use a verified source, remote orders and Automatic wait")
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
        let selected: SelectedFeed
        do { selected = try selectFeed(http: http, serverBase: serverBase, config: config, memory: &memory, now: now) }
        catch is FeedUnavailable {
            return try offlineSSD(config: config, requested: requested, installed: installed, memory: &memory,
                                  stateDir: stateDir, ssd: ssd, http: http, shell: shell, control: control,
                                  executable: executable, serverBase: serverBase, now: now, installing: installing, appFolders: appFolders, reinstall: reinstall, rollbacks: rollbacks, initialSSD: initialSSD, previousResult: result)
        }
        let feed = selected.feed
        for (app, version) in memory.offlineRollbacks ?? [:] {
            if let entry = feed.apps[app], entry.version == version { memory.rejected[app] = entry.sha256 }
            memory.offlineRollbacks?[app] = nil
        }
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
        result.notes += adoptInstalledApps(config: &config, feed: feed, folders: appFolders, sparseConfig: sparseConfig,
                                           stateDir: stateDir)
        result.notes += repairConfiguredPaths(config: &config, feed: feed, folders: appFolders, stateDir: stateDir,
                                              installed: &installed, build: &installedBuild, health: &health)
        persistRepairedPaths(loaded: loadedPaths, config: config, file: configFile)
        let catalog = Catalog.build(feed: feed, ssd: ssd, seen: Catalog.seen(in: stateDir), icons: stateDir.appendingPathComponent("icons"))
        upgradeObservedOnlyRecipes(config: &config, catalog: catalog, feed: feed, stateDir: stateDir)
        let registrationErrors = try registerLauncherApps(requested, catalog: catalog, config: &config, stateDir: stateDir, folders: appFolders)
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
                    .appendingQuery("machine", config.machine)
                    .appendingQuery("capabilities", [AgentCapability.ownerRollback, AgentCapability.vendorInstall,
                                                     AgentCapability.launch].joined(separator: ",")), headers: headers)
            } catch {
                if blockedByTransportSecurity(error) {
                    throw khuFail(plainUnreachable(serverBase.appendingPathComponent("commands"), error: error))
                }
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

        var todo: [(app: String, id: String, action: String, explicit: Bool, manual: Bool)] = []
        for command in orders.commands where command.machine == config.machine {
            if let done = memory.done[command.id] {
                // Already carried out; only the report was lost.
                if delivered(post(command.id, done)) { memory.done[command.id]?.sent = true }
                continue
            }
            if !todo.contains(where: { $0.app == command.app || $0.id == command.id }) {
                // A remote order is the publisher's, not this Mac's: it never installs an app that
                // updates itself, whoever asked for it there.
                todo.append((command.app, command.id, command.action, true, false))
            }
        }
        // "Update now" from the menu-bar icon is this Mac's own order: it runs even while paused.
        for app in requested.sorted() where (config.apps[app] != nil || registrationErrors[app] != nil) && !todo.contains(where: { $0.app == app }) {
            todo.append((app, "auto-\(app)-menu-\(UUID().uuidString)", ServerCommand.update, true, true))
        }
        for app in rollbacks.sorted() where config.apps[app] != nil && !todo.contains(where: { $0.app == app }) {
            todo.append((app, "auto-\(app)-menu-\(UUID().uuidString)", ServerCommand.rollback, true, true))
        }
        // A pause from the menu holds Automatic only; the owner's orders and "Update now" still run.
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key })
        where publisherAvailable && !helper.paused(at: now) && helper.installsAutomatically
            && helper.automatic(app, page: orders.automatic[app], pageAt: orders.automaticAt?[app], config: cfg.automatic) {
            guard !todo.contains(where: { $0.app == app }), let entry = feed.apps[app] else { continue }
            guard !updatesItself(app: app, recipe: cfg.recipe, entry: catalog.first { $0.id == app }) else { continue }
            guard memory.rejected[app] != entry.sha256 else { continue }  // failed here before: wait for a new artifact
            let current = installed[app]
            if current == nil || VersionCompare.isNewer(entry.version, than: current!) {
                todo.append((app, "auto-\(app)-\(UUID().uuidString)", ServerCommand.update, false, false))
            }
        }
        // A skip is a decision, not silence: every feed app left behind says why, once, with the
        // origin of the rule that stopped it — never only `updates=0` in a log nobody can explain.
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key }) {
            guard let entry = feed.apps[app], !todo.contains(where: { $0.app == app }) else { continue }
            let current = installed[app]
            guard current == nil || VersionCompare.isNewer(entry.version, than: current!) else { continue }
            if updatesItself(app: app, recipe: cfg.recipe, entry: catalog.first { $0.id == app }) {
                result.notes.append("\(app): skipped — the live sources mark it as updating itself")
            } else if !publisherAvailable {
                result.notes.append("\(app): skipped — the publisher is unavailable, so remote switches are unknown")
            } else if helper.paused(at: now) {
                result.notes.append("\(app): skipped — automatic updates are paused on this Mac")
            } else if !helper.installsAutomatically {
                result.notes.append("\(app): skipped — automatic installs are set to manual on this Mac")
            } else if let sha = memory.rejected[app], sha == entry.sha256 {
                result.notes.append("\(app): skipped — this exact version failed here; a new artifact clears it")
            } else {
                let decision = helper.automaticDecision(app, page: orders.automatic[app],
                                                        pageAt: orders.automaticAt?[app], config: cfg.automatic)
                if !decision.on { result.notes.append("\(app): skipped — automatic is off (\(decision.origin.words))") }
            }
        }
        try remember()

        // 6. One install at a time; a failure is reported and the next app still runs.
        // An app no longer asked for is no longer waiting.
        memory.waiting = memory.waiting?.filter { w in todo.contains { $0.app == w.key } }
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
            DownloadControl.reset()
            DownloadControl.updateProgress("preparing")
            installing(item.app)
            defer { installing(nil) }
            do {
                switch item.action {
                case ServerCommand.update:
                    if let failure = registrationErrors[item.app] {
                        res = RecipeResult(status: "refused", reason: failure)
                        break
                    }
                    // An older SSD is an explicit first-install choice; ordinary installs select the newest offer.
                    let entry = catalog.first { $0.id == item.app }
                    let current = installed[item.app] ?? config.apps[item.app].flatMap { try? BundleInfo.read($0.bundlePath).version }
                    if initialSSD.contains(item.app), current != nil {
                        res = RecipeResult(status: "refused", reason: "The older SSD choice is for a first install only. The installed app was kept.")
                        break
                    }
                    let local = initialSSD.contains(item.app) ? entry?.initialSSD : (requested.contains(item.app) ? entry?.ssd : nil)
                    if initialSSD.contains(item.app), local == nil {
                        res = RecipeResult(status: "refused", reason: "That SSD installer is no longer available. Nothing was installed.")
                        break
                    }
                    res = try install(app: item.app, feed: feed, installed: current, config: config,
                                      serverBase: artifactBase, stateDir: stateDir, http: http, shell: shell, control: control, local: local,
                                      force: reinstall.contains(item.app), artifactFallbacks: artifactFallbacks, manual: item.manual,
                                      catalogEntry: entry, quitOldBuild: item.explicit && config.quitOldBuilds != false)
                case ServerCommand.launch:
                    res = launchOrdered(app: item.app, config: config, shell: shell, wait: Agent.launchWait(config))
                case ServerCommand.vendorInstall:
                    guard let command = orders.commands.first(where: { $0.id == item.id && $0.machine == config.machine }) else {
                        throw khuFail("vendor install requires an explicit signed order for this Mac")
                    }
                    res = try installVendor(command, config: config, stateDir: stateDir, http: http, shell: shell, control: control)
                case ServerCommand.rollback:
                    res = try orderedRollback(app: item.app, order: item.id, installed: installed[item.app], config: config,
                                              stateDir: stateDir, shell: shell, control: control,
                                              holdURL: feed.apps[item.app]?.holdURL, holdSince: feed.apps[item.app]?.holdSince, http: http)
                default:
                    res = RecipeResult(status: "refused", reason: "this Mac does not know the order action \"\(item.action)\"; refused")
                }
            } catch let error as ArtifactFailure {
                res = RecipeResult(status: "failed", reason: "\(error)")
            } catch {
                // A row says the one sentence the recipe produced, never Foundation's own text:
                // "NSCocoaErrorDomain 516 … an item with the same name already exists" reached the
                // owner's Launcher on 2026-11-17 and named nothing they could act on.
                res = RecipeResult(status: "install_failed", reason: PlainFailure.sentence(error, app: item.app))
            }
            // A build that predates its hold installs the first time the app is closed: the order
            // stays pending and is tried again each run, up to its own ceiling (then it is refused,
            // terminal). The person at this Mac can close the app now, so their request is answered.
            if res.status == Agent.waitingForClose {
                let days = config.waitForCloseDays ?? 14
                let since = memory.waiting?[item.app]?.since ?? ISO.string(now)
                if item.manual {
                    res.status = "refused"
                } else if item.explicit, let start = ISO.date(since), now.timeIntervalSince(start) > Double(days) * 86_400 {
                    res = RecipeResult(status: "refused", reason: "\(res.reason ?? "") It waited \(days) days for \(item.app) to close; send the order again to keep waiting.")
                } else {
                    memory.waiting = (memory.waiting ?? [:]).merging([item.app: .init(since: since, reason: res.reason ?? "")]) { _, new in new }
                    if let note = refusalNote(app: item.app, version: feed.apps[item.app]?.version, result: res, memory: &memory) {
                        result.notes.append(note)
                    }
                    try remember()
                    continue
                }
            }
            memory.waiting?[item.app] = nil
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
            let refusal = refusalNote(app: item.app, version: feed.apps[item.app]?.version, result: res, memory: &memory)
            if res.quitWithoutHold {
                let how = res.status == "refused" ? "did not quit within its time limit; nothing was changed"
                    : res.status == "updated" ? "quit cleanly and was updated" : "quit cleanly, then \(res.status)"
                result.notes.append("\(item.app) \(installed[item.app] ?? "unknown version"): predates its update hold, asked to quit without one — \(how)")
                for line in res.quitTrace { result.notes.append("\(item.app) \(line)") }
            } else if let refusal {
                result.notes.append(refusal)
            }
            let done = AgentMemory.Done(app: item.app, status: res.status, reason: res.reason ?? "", at: ISO.string(Date()), sent: false)
            memory.done[item.id] = done
            try remember()  // recorded before it is reported: a crash here re-reports, never re-installs
            if delivered(post(item.id, done)) { memory.done[item.id]?.sent = true; try remember() }
            result.commandsRun += 1
            if ["updated", "switched"].contains(res.status) { result.updates += 1 }
            // Said where a person at this Mac can see it: the fleet page is not in front of them.
            // A refusal note already said it (and only once, so it is not repeated every run).
            if res.quitWithoutHold == false, refusal == nil {
                result.notes.append("\(item.app): \(res.status)" + (res.reason.map { " — \($0)" } ?? ""))
            }
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
        // Prune the updater's own trash after every run settles. Never throws or fails a run.
        do {
            let kept = max(config.trashKept ?? Space.defaultBucketsKept, 0)
            let swept = Space.pruneTrash(in: stateDir, keeping: kept, shell: shell)
            if !swept.isEmpty { result.notes.append(swept.words) }
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
            let info = cfg?.recipe == "updater" ? nil : cfg.flatMap { try? BundleInfo.read($0.bundlePath) }
            let installed = cfg?.recipe == "updater" ? selfVersion(config: config, executable: executable) : info?.version
            let last = memory.done.values.filter { $0.app == app }.max { $0.at < $1.at }.map { ($0.status, $0.reason) }
            // An app its SSD marks as updating itself is shown that way, whatever this Mac's recipe.
            let only = updatesItself(app: app, recipe: cfg?.recipe, entry: entry)
            let available = cfg?.recipe == "updater" ? feed.apps[app]?.version : (entry?.available ?? feed.apps[app]?.version)
            // An app that updates itself is never installed by KH Updater on its own, but the person
            // at this Mac may install or update it by choosing it: that needs an installer and the
            // app's own identity, so the Launcher can offer the right action.
            let hasOffer = entry?.ssd != nil || entry?.initialSSD != nil || feed.apps[app] != nil
            let manual = only && hasOffer && entry?.bundleID != nil && entry?.bundleName != nil
            let (status, reason) = HelperApp.status(installed: installed, available: available, statusOnly: only, manual: manual, last: last)
            // The row's value and the origin shown beside it are one answer, not two rules: an app
            // that updates itself, or one this Mac does not manage, has no switch to explain.
            let auto: HelperSettings.AutomaticDecision? = only || cfg == nil ? nil
                : helper.automaticDecision(app, page: orders.automatic[app], pageAt: orders.automaticAt?[app], config: cfg!.automatic)
            var row = HelperApp(app: app, installed: installed, available: available, statusOnly: only,
                                automatic: auto?.on ?? false,
                                status: status, reason: reason)
            row.automaticOrigin = auto?.origin.words
            row.manuallyInstallable = manual
            // The Launcher only draws Install or Update for an app the agent can really adopt: an
            // app this Mac already manages, or one whose signed offer names the bundle to install.
            row.installable = cfg != nil || (hasOffer && entry?.bundleID != nil && entry?.bundleName != nil
                                             && entry?.mainMacOnly != true)
            // The build and byte identity of what is installed now: nil when the bundle carries no
            // build or its executable cannot be read — a row reports "not checked", never a match.
            row.installedBuild = info?.build
            if let cfg, let info { row.installedExecutableSha256 = info.executableSha256(in: cfg.bundlePath) }
            row.name = cfg?.recipe == "updater" ? "Studio Launcher KH Helper" : (entry?.name ?? feed.apps[app]?.name ?? AppNames.display(app))
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
            // The drive's own reason, when a copy on it could not be used. It never claims what the
            // copy would have saved, only why this one is not the offer.
            row.ssdNote = entry?.ssdNote
            row.serverVersion = feed.apps[app]?.version
            row.ssdVersion = entry?.ssd?.version ?? entry?.initialSSD?.version
            if installed == nil, let local = entry?.initialSSD, let server = feed.apps[app],
               VersionCompare.isNewer(server.version, than: local.version), !only || manual {
                row.initialSSD = "\(local.volume) · \(local.version)"
            }
            if let cfg, installed != nil, cfg.recipe != "updater" {
                row.installedAt = ((try? FileManager.default.attributesOfItem(atPath: cfg.bundlePath))?[.modificationDate] as? Date).map(ISO.string)
                // An app that updates itself is never rolled back by KH Updater, so it offers no
                // rollback: a button that could only be refused is no help.
                row.canRollBack = !only && FileManager.default.fileExists(atPath: Recipe.Paths(installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app).rollback.path)
            }
            if let cfg, installed != nil, cfg.recipe != "updater" { row.bundlePath = cfg.bundlePath }
            // The icon read from the app's own bundle (cached from an SSD or the feed), else the installed copy's.
            row.icon = entry?.icon ?? feedIcon(feed.apps[app], http: http, serverBase: serverBase, stateDir: stateDir) ?? row.bundlePath
            // A retired app is not presented as current: the row says what it is, offers no update and
            // no Automatic switch, and is drawn only on a Mac that still has the bundle. Nothing is
            // removed for anyone — Uninstall stays a person's own click.
            if let note = RetiredApps.note(app) {
                row.retired = note
                row.reason = note
                row.automatic = false
                row.automaticOrigin = nil
                row.installable = false
                row.manuallyInstallable = false
                row.canRollBack = false
                row.initialSSD = nil
            }
            return row
        }.filter { row in
            // Offered only where it can be installed; the control window only where it already is;
            // a retired app only where its bundle still exists (a Mac that never had it stays as it is).
            guard row.retired == nil || row.installed != nil else { return false }
            return (row.managed || row.available != nil) && !(row.installed == nil && catalog.first { $0.id == row.app }?.mainMacOnly == true)
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

    /// How long a remote launch waits for the app's own process to appear; `launchWaitSeconds`
    /// replaces it. The wait is its own ceiling: a launch is not an install and must not borrow a
    /// health window, and an app that never appears is `failed`, not left saying "launching".
    public static let launchWaitSeconds: TimeInterval = 30

    /// The ceiling a launch actually uses: a positive `launchWaitSeconds`, else the 30 s default.
    /// A typo (`-30`) is read as unset, not as a 1 s window that would call a slow start a failure.
    public static func launchWait(_ config: AgentConfig) -> TimeInterval {
        guard let seconds = config.launchWaitSeconds, seconds > 0 else { return launchWaitSeconds }
        return TimeInterval(seconds)
    }

    /// The owner's launch order: open the installed app hidden and detached, then prove it is
    /// running. The exit status of `open` proves nothing — the pid does. Nothing is quit, stopped,
    /// installed or downloaded; an app that is already running is reported with its pid.
    static func launchOrdered(app: String, config: AgentConfig, shell: Shell,
                              processes: (String) -> [pid_t]? = LiveControl.processes,
                              clock: () -> TimeInterval = Mono.now,
                              wait: TimeInterval = Agent.launchWaitSeconds) -> RecipeResult {
        guard let installedPath = config.apps[app]?.bundlePath else {
            return RecipeResult(status: "failed", reason: "\(app) has no installed app path in this Mac's settings; nothing was opened")
        }
        guard FileManager.default.fileExists(atPath: installedPath) else {
            return RecipeResult(status: "failed", reason: "\(app) is not installed at \(installedPath); nothing was opened")
        }
        guard Recipe.signatureVerifies(installedPath, shell: shell) else {
            return RecipeResult(status: "failed",
                                reason: "the installed \(app) at \(installedPath) does not pass its signature check; it was not opened")
        }
        if let pid = processes(installedPath)?.first {
            return RecipeResult(status: "launched", reason: "already running (pid \(pid))")
        }
        // `-g` never brings it forward, `-j` starts it hidden: a remote launch never takes the
        // owner's desktop.
        let opened = try? shell.run("/usr/bin/open", arguments: ["-g", "-j", installedPath], timeout: 30)
        let deadline = clock() + wait
        repeat {
            if let pid = processes(installedPath)?.first {
                return RecipeResult(status: "launched", reason: "pid \(pid)")
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while clock() < deadline
        let why = opened.map { "open exited \($0.exitCode)" + ($0.stderr.isEmpty ? "" : " (\($0.stderr.prefix(200)))") }
            ?? "open could not be run"
        return RecipeResult(status: "failed",
                            reason: "\(app) did not start within \(Int(wait)) s (\(why)); nothing else was changed")
    }

    /// The owner's rollback order: the version this Mac kept goes back through the same journaled,
    /// health-settled path an install uses. Nothing is downloaded and the feed is not consulted —
    /// what runs is the bundle already on this Mac, verified before anything is stopped.
    static func orderedRollback(app: String, order: String, installed: String?, config: AgentConfig, stateDir: URL,
                                shell: Shell, control: (String, AppConfig) -> AppControl,
                                holdURL: String? = nil, holdSince: String? = nil, http: HTTPClient? = nil) throws -> RecipeResult {
        guard let cfg = config.apps[app] else {
            return RecipeResult(status: "refused", reason: "\(app) is not configured on this Mac")
        }
        if updatesItself(app: app, recipe: cfg.recipe) {
            return RecipeResult(status: "refused", reason: "\(app) is updated by its own updater; KH Updater will not roll it back")
        }
        switch cfg.recipe {
        case let recipe where appDmgRecipes.contains(recipe):
            guard installed != nil || FileManager.default.fileExists(atPath: cfg.bundlePath) else {
                return RecipeResult(status: "refused", reason: "\(app) is not installed at \(cfg.bundlePath), so there is nothing to roll back from")
            }
            // A rollback is a swap like any other: a running app is held or refused first, never quit
            // under its work. The same endpoint is renewed at the boundary and resumed afterwards.
            let ctl = control(app, cfg)
            var endpoint: URL?
            let exempt = ["updater", "launcher"].contains(app) || cfg.recipe == "updater"
            if let http {
                let hold = beginUpdateHold(app: app, holdURL: holdURL, http: http, control: ctl, exempt: exempt,
                                           installed: installed, holdSince: holdSince)
                if let refusal = hold.refusal { return refusal }
                endpoint = hold.endpoint
            } else if ctl.isRunning() != false, !exempt {
                return RecipeResult(status: "refused", reason: "\(app) is running and does not offer an update hold; nothing was changed. Update it by hand.")
            }
            defer { if let endpoint, let http { UpdateHold.resume(endpoint, http: http) } }
            let beforeStop: (() throws -> Void)? = endpoint.flatMap { url in
                guard let http else { return nil }
                return {
                    guard ctl.isRunning() != false else { return }
                    let renewed = try UpdateHold.begin(url, http: http, timeoutS: 0)
                    guard renewed.safe else {
                        let names = (renewed.unsettled ?? []).joined(separator: ", ")
                        throw khuFail("\(app)'s update hold is no longer safe (still in flight: \(names)); nothing was changed")
                    }
                }
            }
            return try Recipe.ownerRollback(shell: shell, installedPath: cfg.bundlePath, stateDir: stateDir.path, app: app,
                                            expectedBundleID: cfg.bundleID, order: order, control: ctl,
                                            beforeStop: beforeStop)
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

    /// Takes the app's update hold inside one settle window. Shared by the install and owner-rollback
    /// paths so both hold before a swap and both refuse an app that cannot offer a gap. Returns the
    /// endpoint even when the reply is unsafe, so the caller can resume it.
    static func beginUpdateHold(app: String, holdURL: String?, http: HTTPClient, control: AppControl,
                                exempt: Bool, installed: String? = nil, holdSince: String? = nil) -> (endpoint: URL?, note: String?, refusal: RecipeResult?) {
        guard control.isRunning() != false, !exempt else { return (nil, nil, nil) }
        guard let raw = holdURL, let endpoint = UpdateHold.trusted(raw) else {
            return (nil, nil, RecipeResult(status: "refused", reason: "\(app) is running and the feed does not name an update-hold endpoint; nothing was changed. Update it by hand."))
        }
        let window = Date().addingTimeInterval(UpdateHold.ceiling)
        do {
            var reply = try UpdateHold.begin(endpoint, http: http, deadline: window)
            if !reply.safe, window.timeIntervalSinceNow > 3 {
                Thread.sleep(forTimeInterval: 2)   // one retry, only with time left in the window
                reply = try UpdateHold.begin(endpoint, http: http, deadline: window)
            }
            guard reply.safe else {
                let names = (reply.unsettled ?? []).joined(separator: ", ")
                return (endpoint, nil, RecipeResult(status: "refused", reason: "\(app) could not settle its work (still in flight: \(names)); nothing was changed and it keeps running."))
            }
            return (endpoint, reply.summary, nil)
        } catch {
            // The feed names an endpoint the installed build does not serve: a first hold-capable
            // release needs one normal install while the app is closed. Say that, not a bare -1004.
            if let refused = error as? UpdateHold.Refused {
                // A build older than the feed's holdSince has no hold route yet, so its auth layer's
                // 401/403 (or a 404) is "needs one install while closed", not a credential refusal.
                if [401, 403, 404].contains(refused.status), let installed, let since = holdSince,
                   VersionCompare.isNewer(since, than: installed) {
                    var out = RecipeResult(status: waitingForClose,
                        reason: "Waiting for \(app) to close: \(app) \(installed) predates its update hold (first in \(since)), so it answered \(refused.status); it needs one normal install while \(app) is closed, which happens on the first run that finds it closed. Nothing was changed.")
                    out.predatesHold = true
                    return (endpoint, nil, out)
                }
                let reason: String
                switch refused.status {
                case 401, 403:
                    reason = "\(app) refused the update hold (credential); nothing was changed. The app must publish a hold credential this Mac can present."
                case 404:
                    reason = "\(app) does not serve an update hold at the feed's address; nothing was changed. The feed's holdURL does not match this build."
                default:
                    reason = "\(app)'s update hold answered \(refused.status); nothing was changed."
                }
                return (endpoint, nil, RecipeResult(status: "refused", reason: reason))
            }
            if UpdateHold.endpointAbsent(error) {
                var out = RecipeResult(status: waitingForClose,
                    reason: "Waiting for \(app) to close: its installed build has no update-hold endpoint, so it needs one normal install while \(app) is closed, which happens on the first run that finds it closed. Nothing was changed.")
                out.predatesHold = true
                return (endpoint, nil, out)
            }
            return (endpoint, nil, RecipeResult(status: "refused", reason: "\(error)"))
        }
    }

    /// Idle checks that ship with the helper, so a Mac is armed without anyone editing its config.
    /// Hub's is Hub's owner's own command, reviewed against fixture data from 0.6.235: it counts
    /// queued *and* running items by their state, not the batch's flag, and fails closed — a missing,
    /// unreadable or corrupt database, or an unknown table, exits non-zero. So a wrong guess about
    /// its data folder makes that Mac wait, and never quits a working Hub.
    /// It reads Hub's default data folder; on a Mac that moved it, the probe says "not idle".
    public static let builtInIdleProbes: [String: String] = ["hub": #"test -r "$HOME/Library/Application Support/StudioHub Standalone/hub/hub.db" && [ "$(/usr/bin/sqlite3 -readonly "$HOME/Library/Application Support/StudioHub Standalone/hub/hub.db" "select count(*) from batches, json_each(json_extract(batches.payload,'$.items')) i where (batches.finished=0 or batches.created_at > strftime('%s','now')-86400) and json_extract(i.value,'$.state') in ('queued','running','cancel_requested','cancelling','paused','uncertain','recovery_pending','draining','restart_requested')" 2>/dev/null)" = 0 ]"#]

    /// Hub's data folder under the user's real home. A launch agent's environment is not an
    /// interactive shell's, so this is joined here and exported into the check, never inherited.
    public static let hubDatabase = "Library/Application Support/StudioHub Standalone/hub/hub.db"

    /// A shell word that survives any space or quote in a real home path.
    static func shellWord(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The check as it is actually run: an explicit HOME and PATH, then the app's own command.
    static func idleScript(_ command: String, home: URL) -> String {
        "HOME=\(shellWord(home.path))\nexport HOME\nPATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\n\(command)"
    }

    static func firstLine(_ answer: ShellResult) -> String? {
        (answer.stdout + "\n" + answer.stderr)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Why Hub's check could not answer, in the operator's words. The check itself discards sqlite's
    /// message, so a missing database, a missing sqlite3, a foreign or locked file all read as a bare
    /// "exited 1 (no output)". This asks once more, keeping the words, and only after a refusal.
    static func hubDiagnosis(home: URL, shell: Shell) -> String? {
        let db = home.appendingPathComponent(hubDatabase).path
        let script = """
        db=\(shellWord(db))
        [ -r "$db" ] || { printf 'no database at %s\n' "$db"; exit 0; }
        /usr/bin/sqlite3 -readonly "$db" 'select count(*) from batches' 2>&1 || true
        """
        guard let answer = try? shell.run("/bin/sh", arguments: ["-lc", script], timeout: 5) else {
            return "the database could not be read"
        }
        return firstLine(answer)
    }

    /// Which idle check an app on this Mac gets, in the order the owner's rule asks for: the Mac's
    /// own `idleProbe` wins, an explicit empty string turns the unattended quit off for that Mac, and
    /// a missing one falls back to the built-in check for that app. Never a rule: rearrange it or
    /// switch it off per Mac.
    public static func idleProbe(app: String, cfg: AppConfig) -> String? {
        cfg.idleProbe ?? builtInIdleProbes[app]
    }

    /// The owner's rule before an old build is quit unattended: the app's own probe must answer that
    /// it has nothing running or queued. No probe, a non-zero answer, output that names a job or a
    /// probe that outlasts its own short ceiling all skip the quit. Returns why, or nil when it is safe.
    /// Returns what the check answered (`said`, always worth a log line) and why the quit must be
    /// skipped (`skip`, nil when it is safe to go ahead and quit).
    static func idleRefusal(app: String, probe: String?, shell: Shell, timeout: TimeInterval = 15,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (said: String, skip: String?) {
        let command = probe?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return ("idle check: none configured", "\(app) has no idle check configured, so it was not asked to quit and nothing was interrupted.")
        }
        do {
            let answer = try shell.run("/bin/sh", arguments: ["-lc", idleScript(command, home: home)], timeout: timeout)
            guard answer.exitCode != 0 else { return ("idle check exited 0, so it is idle", nil) }
            // What the check said, and when it said nothing, why it could not: Hub's own check
            // discards sqlite's message, and "exited 1 (no output)" tells an operator nothing.
            var said = firstLine(answer) ?? ""
            if said.isEmpty, builtInIdleProbes[app] != nil, let why = hubDiagnosis(home: home, shell: shell) {
                said = why
            }
            if said.isEmpty { said = "no output" }
            return ("idle check exited \(answer.exitCode) (\(said))",
                    "\(app)'s idle check exited \(answer.exitCode) (\(said)), so it was not asked to quit and nothing was interrupted.")
        } catch {
            return ("idle check did not answer within \(Int(timeout)) s",
                    "\(app)'s idle check did not answer within \(Int(timeout)) s, so it was not asked to quit and nothing was interrupted.")
        }
    }

    static func install(app: String, feed: Feed, installed: String?, config: AgentConfig, serverBase: URL, stateDir: URL,
                        http: HTTPClient, shell: Shell, control: (String, AppConfig) -> AppControl,
                        local: CatalogEntry.Local? = nil, force: Bool = false, artifactFallbacks: [URL] = [],
                        manual: Bool = false, catalogEntry: CatalogEntry? = nil, quitOldBuild: Bool = false) throws -> RecipeResult {
        guard let cfg = config.apps[app] else { throw khuFail("\(app) is not configured on this Mac") }
        // An app that updates itself is never installed by KH Updater on its own: Automatic and a
        // remote order leave it alone. Only a choice made here, at this Mac, may install it.
        // The live catalog carries the policy as well as this Mac's recipe, so an existing `app-dmg`
        // config for an app its SSD marks as self-updating cannot be driven by a remote order.
        // One value for the whole run: the boundary closure outlives the call and must not capture
        // the non-escaping `control` parameter itself.
        let appControl = control(app, cfg)
        let itself = updatesItself(app: app, recipe: cfg.recipe, entry: catalogEntry)
        if itself, !manual {
            return RecipeResult(status: "status_only", reason: "updated by its own updater")
        }
        // A running Production app is kept: this route proves no quiet point.
        if let refusal = refusesWhileRunning(app: app, cfg: cfg, control: control, entry: catalogEntry) {
            return RecipeResult(status: "refused", reason: refusal)
        }
        // An install this Mac could not finish or undo is not a settled app: an order for it must
        // not be answered "current" while a rollback is still owed. The next run picks it up.
        if Recipe.isUnresolved(stateDir: stateDir.path, app: app) {
            return RecipeResult(status: "unresolved", reason: "an earlier install of \(app) could not be finished or undone; "
                               + "\(Recipe.journalURL(stateDir: stateDir.path, app: app).path) is kept and the next run tries it again")
        }
        // The update gap (CONTRACT.md): a running app's queue is held before a byte moves. An app
        // with no trusted hold endpoint is refused rather than interrupted silently.
        var holdEndpoint: URL?
        var holdNote: String?
        var legacyQuit = false
        // The three facts this Mac's log must carry for every unattended quit, whichever way it
        // ends: what the idle check answered, whether the app exited and how long it took, and
        // whether it came back with its services. Written where those things really happen, so a
        // Mac that stalls, refuses or half-restarts still says which of the three failed.
        var probeSaid: String?
        var quitSaid: String?
        var servicesSaid: String?
        func traced(_ base: AppControl) -> AppControl {
            guard legacyQuit else { return base }
            var wrapped = base
            wrapped.quit = {
                let started = Date()
                let gone = base.quit()
                let took = String(format: "%.1f", Date().timeIntervalSince(started))
                quitSaid = gone ? "quit: the app exited after \(took) s"
                                : "quit: the app had not exited after \(took) s, so its own ceiling was reached"
                return gone
            }
            wrapped.resumeServices = {
                let resume = base.resumeServices()
                servicesSaid = resume.ok ? "services: started"
                                         : "services: did NOT start (\(resume.reason ?? "launchd refused"))"
                return resume
            }
            return wrapped
        }
        /// The three lines plus what came back, attached to a result the moment it is known.
        func withTrace(_ result: RecipeResult) -> RecipeResult {
            guard legacyQuit else { return result }
            var out = result
            out.quitWithoutHold = true
            let back = appControl.isRunning() == false ? "the app did NOT come back"
                                                       : "the app came back as \((try? BundleInfo.read(cfg.bundlePath))?.version ?? "an unreadable version")"
            out.quitTrace = [probeSaid, quitSaid, servicesSaid, back].compactMap { $0 }
            return out
        }
        func acquireHold() -> RecipeResult? {
            guard holdEndpoint == nil, !legacyQuit else { return nil }
            // The updater's own engine and menu-bar UI hold no work queue: the engine switches itself
            // through installUpdater, and the Launcher updates itself from its own Update click.
            let exempt = ["updater", "launcher"].contains(app) || cfg.recipe == "updater"
            DownloadControl.updateProgress("held")
            let hold = beginUpdateHold(app: app, holdURL: feed.apps[app]?.holdURL, http: http,
                                       control: appControl, exempt: exempt, installed: installed,
                                       holdSince: feed.apps[app]?.holdSince)
            // A build that predates its hold is updated the way it was before holds existed: asked to
            // quit (bounded by the quit's own ceiling, never killed), swapped, relaunched hidden —
            // but only when the app's own probe says it has nothing running or queued.
            if quitOldBuild, let refusal = hold.refusal, refusal.status == waitingForClose {
                let answer = idleRefusal(app: app, probe: idleProbe(app: app, cfg: cfg), shell: shell)
                probeSaid = answer.said
                // The owner, 2026-11-16: "can we use the old force update first to add this guard.
                // then next release we remove? like the old updater used to work?" A build that
                // predates its hold is quit the way updates worked before holds existed: the idle
                // check is logged, not obeyed. Hub's owner established a quit loses no work —
                // queued items are written through to its database and reloaded, a running item is
                // requeued. TEMPORARY: remove this force path once the fleet is past the hold.
                if refusal.predatesHold {
                    legacyQuit = true
                    let feedVersion = feed.apps[app]?.version ?? "the feed's version"
                    holdNote = "\(app) \(installed ?? "") predates its update hold (\(feed.apps[app]?.holdSince ?? "first hold version unknown")); "
                        + "asked to quit without waiting for an idle check, the way updates worked before holds existed, to install \(feedVersion) (temporary force path)."
                    return nil
                }
                if let skipped = answer.skip {
                    holdEndpoint = hold.endpoint
                    var out = refusal
                    out.reason = (out.reason.map { $0 + " " } ?? "") + skipped
                    out.quitTrace = ["\(app)'s \(answer.said)"]
                    return out
                }
                legacyQuit = true
                holdNote = "\(app) \(installed ?? "") predates its update hold; its idle check passed, so it was asked to quit without one (quitOldBuilds is on)."
                return nil
            }
            // Resume is attempted even when the POST itself failed: it may have paused before failing.
            holdEndpoint = hold.endpoint
            holdNote = hold.note
            return hold.refusal
        }
        // Resume on success, abort and rollback; the pause expires by itself if this never runs.
        defer {
            if let holdEndpoint {
                DownloadControl.updateProgress("resumed")
                UpdateHold.resume(holdEndpoint, http: http)
            }
        }
        // At the mutation boundary the app is sampled again: one opened while the installer was
        // prepared is held now (or refused if it has no endpoint), one that exited needs nothing.
        // A hold taken before the download is renewed here with no wait, so an expired pause never
        // permits the swap.
        let beforeStop: () throws -> Void = {
            guard appControl.isRunning() != false else { return }
            if holdEndpoint == nil {
                if let refusal = acquireHold() { throw khuFail(refusal.reason ?? "the update was refused") }
                guard holdEndpoint != nil else { return }   // the updater's own apps hold no queue
            }
            guard let endpoint = holdEndpoint else { return }
            let renewed = try UpdateHold.begin(endpoint, http: http, timeoutS: 0)
            guard renewed.safe else {
                let names = (renewed.unsettled ?? []).joined(separator: ", ")
                throw khuFail("\(app)'s update hold is no longer safe (still in flight: \(names)); nothing was changed")
            }
        }
        func withHoldNote(_ result: RecipeResult) -> RecipeResult {
            guard let holdNote else { return result }
            var out = result
            out.reason = (out.reason.map { $0 + " " } ?? "") + holdNote
            return withTrace(out)
        }
        // An old build that would not quit within its ceiling (busy, or a question on its screen)
        // is a refusal: nothing was swapped, so it is said plainly and nothing is retried.
        func refusedQuit(_ run: () throws -> RecipeResult) throws -> RecipeResult {
            do { return try run() } catch {
                let said = "\(error)"
                guard legacyQuit && said.contains(Recipe.didNotQuit) && !said.contains("did not restart") else { throw error }
                return withTrace(RecipeResult(status: "refused", reason: "\(holdNote ?? "") It did not quit within its time limit, so nothing was changed and it keeps running."))
            }
        }
        if let local {
            if let refusal = acquireHold() { return refusal }
            DownloadControl.updateProgress("copying")
            return try refusedQuit { withHoldNote(try installLocal(local, app: app, installed: installed, cfg: cfg, stateDir: stateDir, shell: shell, control: { a, c in traced(control(a, c)) },
                                                 force: force, manual: manual || legacyQuit, catalogEntry: catalogEntry, beforeStop: beforeStop)) }
        }
        guard let entry = feed.apps[app] else { throw khuFail("the feed has no \(app)") }
        // The report can lag the disk: a stale one re-downloaded and reinstalled media-studio 0.1.109
        // over itself at 01:21. Judge the installed bundle now, before any download; fall back to
        // the report only when the bundle cannot be read.
        let liveVersion = cfg.bundlePath.isEmpty ? nil : (try? BundleInfo.read(cfg.bundlePath))?.version
        if let current = liveVersion ?? installed {
            guard let order = VersionCompare.compare(entry.version, current) else {
                return RecipeResult(status: "refused", reason: "\(current) here and \(entry.version) in the feed cannot be compared")
            }
            if order == 0 && !force { return RecipeResult(status: "current", reason: "\(entry.version) is already installed") }
            if order < 0 { return RecipeResult(status: "refused", reason: "the feed has \(entry.version), older than \(current) here; no downgrade") }
        }

        if let refusal = acquireHold() { return refusal }
        let artifact: URL
        do {
            artifact = try download(entry, app: app, serverBase: serverBase, stateDir: stateDir, http: http, fallbacks: artifactFallbacks,
                                    reserveBytes: UInt64(max(config.reserveGB ?? Space.defaultReserveGB, 0)) * 1_000_000_000)
        } catch let error as Space.NoSpace {
            return RecipeResult(status: "refused", reason: "\(error)")
        } catch let error as ArtifactFailure {
            return RecipeResult(status: "failed", reason: "\(error)")
        } catch let error as DeliveryMismatch {
            return RecipeResult(status: "download_mismatch", reason: "\(error)")
        } catch {
            // Transport, not artifact: nothing here says the bytes are bad, so it is not a version
            // this Mac has rejected — the next run downloads it again.
            return RecipeResult(status: "download_failed", reason: "\(error)")
        }
        DownloadControl.updateProgress("installing")
        // One journaled app-dmg path for every recipe that installs a bundle: the plain ones and a
        // legacy `story`/`hub` config, and an observed-only app the person chose to install here.
        // A self-updating app is checked again before anything is stopped.
        switch cfg.recipe {
        case "updater":
            return try withHoldNote(installUpdater(entry, artifact: artifact, config: config))
        case "fake-for-tests":
            return withHoldNote(RecipeResult(status: "updated"))
        default:
            guard appDmgRecipes.contains(cfg.recipe) || statusOnly.contains(cfg.recipe) else {
                throw khuFail("unknown recipe \(cfg.recipe)")
            }
            // Put back what the install stopped, unattended included: the owner's rule is that the
            // app resumes by itself — nobody is there to open it after an automatic update or an
            // order. The relaunch is hidden (`open -g -j`), never a window on the owner's desktop.
            return try refusedQuit { withHoldNote(try Recipe.appDmg(shell: shell, installedPath: cfg.bundlePath, artifactPath: artifact.path, feedVersion: entry.version,
                                                  expectedBundleID: cfg.bundleID, stateDir: stateDir.path, app: app, control: traced(control(app, cfg)),
                                                  refuseIfRunning: itself, relaunchAfterInstall: true,
                                                  appearCeiling: TimeInterval(cfg.appearCeilingSeconds ?? Int(Recipe.appearCeiling)),
                                                  beforeStop: beforeStop)) }
        }
    }

    /// An install from an SSD: the copy must match the SHA-256 its `apps.json` names before
    /// anything is touched, then it takes the same journaled app-dmg path, with rollback, as a
    /// download does.
    static func installLocal(_ local: CatalogEntry.Local, app: String, installed: String?, cfg: AppConfig, stateDir: URL,
                             shell: Shell, control: (String, AppConfig) -> AppControl, force: Bool = false,
                             manual: Bool = false, catalogEntry: CatalogEntry? = nil,
                             beforeStop: (() throws -> Void)? = nil) throws -> RecipeResult {
        // One value for the whole run: the boundary closure outlives the call and must not capture
        // the non-escaping `control` parameter itself.
        let appControl = control(app, cfg)
        let itself = updatesItself(app: app, recipe: cfg.recipe, entry: catalogEntry)
        if Recipe.isUnresolved(stateDir: stateDir.path, app: app) {
            return RecipeResult(status: "unresolved", reason: "An earlier installation still needs recovery. Both copies were kept.")
        }
        // The same live check as a downloaded install: a stale report must not reinstall an equal
        // version from the SSD either.
        let liveVersion = cfg.bundlePath.isEmpty ? nil : (try? BundleInfo.read(cfg.bundlePath))?.version
        if let current = liveVersion ?? installed {
            guard let order = VersionCompare.compare(local.version, current) else {
                return RecipeResult(status: "refused", reason: "The installed and SSD versions cannot be compared. Nothing was changed.")
            }
            if order < 0 || (order == 0 && !force) {
                return RecipeResult(status: "current", reason: "\(current) is already installed; \(local.volume) has \(local.version). No downgrade.")
            }
        }
        let source = URL(fileURLWithPath: local.file)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return RecipeResult(status: "refused", reason: "The SSD installer is not a regular file. Nothing was changed.")
        }
        let staging = stateDir.appendingPathComponent("ssd-staging/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { _ = try? Trash.move(staging, into: Trash.root(in: stateDir)) }
        let artifact = staging.appendingPathComponent("installer.dmg")
        DownloadControl.updateProgress("copying")
        try FileManager.default.copyItem(at: source, to: artifact)
        let digest = try Signing.sha256Hex(fileAt: artifact)
        guard digest.hex == local.sha256, local.bytes.map({ $0 == digest.bytes }) ?? true else {
            return RecipeResult(status: "refused", reason: "the copy on \(local.volume) does not match its checksum; nothing was changed")
        }
        guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
        DownloadControl.updateProgress("installing")
        var result: RecipeResult
        switch cfg.recipe {
        case "fake-for-tests":
            result = RecipeResult(status: "updated", reason: "from \(local.volume)")
        default:
            // The same journaled app-dmg path for the plain recipes and the legacy names.
            guard appDmgRecipes.contains(cfg.recipe) || statusOnly.contains(cfg.recipe) else {
                return RecipeResult(status: "refused", reason: "the \(cfg.recipe) recipe does not install from an SSD")
            }
            result = try Recipe.appDmg(shell: shell, installedPath: cfg.bundlePath, artifactPath: artifact.path, feedVersion: local.version,
                                     expectedBundleID: cfg.bundleID, stateDir: stateDir.path, app: app, control: control(app, cfg),
                                     refuseIfRunning: itself, relaunchAfterInstall: true,
                                     appearCeiling: TimeInterval(cfg.appearCeilingSeconds ?? Int(Recipe.appearCeiling)),
                                     verifyStaged: { path in
                guard Recipe.signatureVerifies(path, shell: shell) else { throw khuFail("The staged app signature could not be verified. Nothing was replaced.") }
            }, beforeStop: beforeStop)
        }
        // Keep the verified SSD installer in the normal cache so the next server patch can use it.
        if result.status == "updated" {
            do {
                let cache = stateDir.appendingPathComponent("downloads").appendingPathComponent(try SafeName.component(app, what: "app id"))
                // A trash with no reader is the bug: remove the old cache outright.
                _ = Space.remove(cache, shell: shell, fileManager: FileManager.default)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: artifact, to: cache.appendingPathComponent(local.sha256 + ".dmg"))
            } catch {
                result.reason = (result.reason ?? "Installed.") + " The installer cache could not be kept; the next update may need a full download."
            }
        }
        return result
    }

    /// Stream the artifact to `downloads/<app>/`, checked against the signed size and SHA-256
    /// before any recipe sees it. A finished artifact is reused (a failed install never downloads
    /// it again); a failed transfer keeps its `.part` for the next attempt to resume; a superseded
    /// version's bytes go to `_trash`.
    ///
    /// A signed patch is tried first, but only against the exact full artifact this Mac already
    /// has cached — never against the installed app, whose bytes are not the signed artifact. The
    /// base is verified again immediately before it is used, and the rebuilt artifact against the
    /// signed size and hash afterwards. Anything that does not add up falls back to the whole
    /// signed artifact; a cancelled download stops instead of fetching anything else.
    ///
    /// The exact base is taken out of the cache once and kept for every source this one operation
    /// tries. It is retired only when the new artifact replaces it: an operation that ends in
    /// failure or cancellation leaves the base where it is, so the next source, and the next run,
    /// still have the exact bytes a patch was built for.
    static func download(_ entry: FeedApp, app: String, serverBase: URL, stateDir: URL, http: HTTPClient, fallbacks: [URL] = [],
                         freeSpace: (URL) -> UInt64? = Space.freeBytes, reserveBytes: UInt64 = Space.defaultReserveBytes) throws -> URL {
        let dir = stateDir.appendingPathComponent("downloads").appendingPathComponent(app)
        // The only base a patch may use: the exact full artifact this Mac already downloaded.
        let base = takeCachedBase(for: entry.delta, in: dir, app: app)
        let artifact = try download(entry, app: app, serverBase: serverBase, stateDir: stateDir, http: http,
                                    fallbacks: fallbacks, base: base, freeSpace: freeSpace, reserveBytes: reserveBytes)
        // The new artifact is this Mac's base from now on: the slot is retired, whatever it held.
        _ = try? Trash.move(heldBase(in: dir, app: app), into: Trash.root(in: stateDir))
        return artifact
    }

    /// One download operation: every source it is given is offered the same exact base to patch
    /// from, so a source that does not have the patch cannot cost the next one its chance.
    private static func download(_ entry: FeedApp, app: String, serverBase: URL, stateDir: URL, http: HTTPClient,
                                 fallbacks: [URL], base: URL?, freeSpace: (URL) -> UInt64? = Space.freeBytes,
                                 reserveBytes: UInt64 = Space.defaultReserveBytes) throws -> URL {
        let name = try SafeName.component(entry.file, what: "artifact name")
        let dir = stateDir.appendingPathComponent("downloads").appendingPathComponent(app)
        let fm = FileManager.default
        let trash = Trash.root(in: stateDir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent(name + ".part")
        let artifact = dir.appendingPathComponent(name)
        // An artifact this Mac already finished stays: a failed install (an app that did not quit)
        // is retried from it, never by downloading the same signed bytes again.
        if let measured = try? Signing.sha256Hex(fileAt: artifact), measured.bytes == entry.bytes, measured.hex == entry.sha256 {
            DownloadControl.updateProgress("checking")
            return artifact
        }
        // Only this artifact's own partial may be resumed. Anything else in the folder is a
        // superseded version's bytes: removed, not trashed — a trash with no reader is the bug.
        _ = Space.sweep(dir, keeping: [name, name + ".part"], shell: SystemShell(), fileManager: fm)
        // A partial that already reached the signed size (a run stopped between its last byte and
        // the move) only needs verifying — the whole artifact is not fetched a second time.
        if let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber, size.int64Value == entry.bytes {
            DownloadControl.updateProgress("checking")
            if let measured = try? Signing.sha256Hex(fileAt: part), measured.hex == entry.sha256 {
                try fm.moveItem(at: part, to: artifact)
                return artifact
            }
            _ = try? Trash.move(part, into: trash)
        }
        // Nothing usable is on disk, so these bytes really must be fetched: refuse before the first
        // request when the disk cannot hold them and still leave the reserve. A Mac that already
        // has the artifact or a complete partial never reaches this and is never refused.
        if let free = freeSpace(dir), free < UInt64(clamping: entry.bytes) + reserveBytes {
            throw Space.NoSpace(app: app, version: entry.version, artifact: UInt64(clamping: entry.bytes),
                                reserve: reserveBytes, free: free)
        }
        let triedPatch = entry.delta != nil && base != nil
        if let delta = entry.delta, let base {
            do {
                return try deliverPatch(delta, entry: entry, base: base, dir: dir, part: part,
                                        serverBase: serverBase, http: http, trash: trash)
            } catch {
                // The base is kept: the next source, and the next run, still have the exact bytes
                // this patch was built for.
                _ = try? Trash.move(part, into: trash)
                if DownloadControl.cancelled { throw error }
                // The patch did not add up, so the whole signed artifact is fetched instead. That
                // fetch is the whole file: nothing is saved and nothing is promised.
                DownloadControl.updateProgress("full-fallback")
            }
        }
        let phase = triedPatch ? "full-fallback" : "downloading"
        func fetch() throws -> Int {
            try http.download(serverBase.appendingPathComponent("artifacts").appendingPathComponent(name),
                              headers: [:], to: part, limit: entry.bytes, phase: phase)
        }
        do {
            var code = try fetch()
            if code == 416 {
                // This Mac's partial is not a range the source can continue from: this artifact
                // starts over, and only this attempt's own bytes are given up.
                _ = try? Trash.move(part, into: trash)
                code = try fetch()
            }
            guard code == 200 || code == 206 else { throw khuFail("artifact download answered \(code); nothing was changed") }
            DownloadControl.updateProgress("checking")
            let (sha, bytes) = try Signing.sha256Hex(fileAt: part)
            guard bytes == entry.bytes, sha == entry.sha256 else {
                // Bytes that do not match the signed artifact are not progress any retry may
                // resume onto; the next attempt starts this artifact from the beginning.
                _ = try? Trash.move(part, into: trash)
                throw DeliveryMismatch(description: "artifact size or sha256 mismatch; nothing was changed")
            }
            guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
            try fm.moveItem(at: part, to: artifact)
            return artifact
        } catch {
            // Cancel is the one failure that gives up the partial; a transport or server failure
            // keeps it, and the next source or the next run resumes from where this one stopped.
            if DownloadControl.cancelled { _ = try? Trash.move(part, into: trash); throw error }
            if let next = fallbacks.first {
                return try download(entry, app: app, serverBase: next, stateDir: stateDir, http: http,
                                    fallbacks: Array(fallbacks.dropFirst()), base: base,
                                    freeSpace: freeSpace, reserveBytes: reserveBytes)
            }
            throw error
        }
    }

    /// The exact full artifact this Mac already downloaded, when it is the one a patch was built
    /// for. It is held outside the download folder, because that folder goes to `_trash` when the
    /// new download starts, and it rests there until a new artifact replaces it: a source that
    /// fails does not take the base away from the next source, or from the next run.
    private static func takeCachedBase(for delta: ArtifactDelta?, in dir: URL, app: String) -> URL? {
        let fm = FileManager.default
        let held = heldBase(in: dir, app: app)
        if fm.fileExists(atPath: held.path) {
            // A base is kept for one patch only: one that names another base is of no use here.
            if let delta, let measured = try? Signing.sha256Hex(fileAt: held),
               measured.hex == delta.baseSHA256, measured.bytes == delta.baseBytes { return held }
            if delta != nil {
                _ = try? Trash.move(held, into: Trash.root(in: dir.deletingLastPathComponent()))
            }
        }
        guard let delta else { return nil }
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for item in items {
            let candidate = dir.appendingPathComponent(item)
            guard let measured = try? Signing.sha256Hex(fileAt: candidate),
                  measured.hex == delta.baseSHA256, measured.bytes == delta.baseBytes else { continue }
            do { try fm.moveItem(at: candidate, to: held) } catch { return nil }
            return held
        }
        return nil
    }

    /// Where a patch base rests while it is not the file the download folder holds: one slot per
    /// app, so a base is never stranded under a name nothing looks for again.
    private static func heldBase(in dir: URL, app: String) -> URL {
        dir.deletingLastPathComponent().appendingPathComponent(".khu-patch-base-\(app)")
    }

    /// The patch, applied to the exact base it was built for. The rebuilt artifact is checked
    /// against the signed size and hash before it is moved into place, so a recipe never sees
    /// anything but a verified file.
    private static func deliverPatch(_ delta: ArtifactDelta, entry: FeedApp, base: URL, dir: URL, part: URL,
                                     serverBase: URL, http: HTTPClient, trash: URL) throws -> URL {
        let name = try SafeName.component(delta.file, what: "delta name")
        let patch = dir.appendingPathComponent(name + ".part")
        // The patch's bytes never stay in the cache: a refused or half-written patch is retired.
        defer { _ = try? Trash.move(patch, into: trash) }
        let code = try http.download(serverBase.appendingPathComponent("artifacts").appendingPathComponent(name),
                                     headers: [:], to: patch, limit: delta.bytes, phase: "delta-downloading")
        guard code == 200 || code == 206 else { throw khuFail("delta download answered \(code); nothing was changed") }
        let (sha, bytes) = try Signing.sha256Hex(fileAt: patch)
        guard bytes == delta.bytes, sha == delta.sha256 else {
            throw khuFail("the delta patch does not match its signed size or hash; nothing was changed")
        }
        // The base is verified again immediately before it is used: a patch is only ever applied to
        // the exact full artifact it was built for.
        DownloadControl.updateProgress("checking-base")
        let measured = try Signing.sha256Hex(fileAt: base)
        guard measured.hex == delta.baseSHA256, measured.bytes == delta.baseBytes else {
            throw khuFail("the cached artifact is not the base this patch was built for; nothing was changed")
        }
        DownloadControl.updateProgress("reconstructing")
        try ArtifactDeltaPatch.apply(base: base, patch: patch, to: part,
                                     baseBytes: delta.baseBytes, targetBytes: entry.bytes)
        DownloadControl.updateProgress("checking")
        let (out, outBytes) = try Signing.sha256Hex(fileAt: part)
        guard outBytes == entry.bytes, out == entry.sha256 else {
            throw khuFail("the rebuilt artifact does not match the signed size or hash; nothing was changed")
        }
        guard !DownloadControl.cancelled else { throw khuFail("cancelled on this Mac; nothing was changed") }
        let artifact = dir.appendingPathComponent(try SafeName.component(entry.file, what: "artifact name"))
        try FileManager.default.moveItem(at: part, to: artifact)
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
