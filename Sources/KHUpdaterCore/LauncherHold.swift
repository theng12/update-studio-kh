import Foundation
import Network

/// The Launcher's own update hold (`_orchestra/youtube-stack/update-hold/CONTRACT.md`).
///
/// Sparkle's shim posts here before any check, so a self-update never replaces the Launcher while
/// it is installing another app — the one place a self-replacing updater corrupts an install. Fixed
/// loopback port (8792, the next free one in the contract's table), its own 0600 token — never the
/// agent's, which rotates per agent start — and a `safe:false` whose `unsettled` names the app being
/// installed, so the refusal is readable rather than a boolean to guess.
public final class LauncherHold: @unchecked Sendable {
    public static let port: UInt16 = 8792
    public static let path = "/api/maintenance/hold"
    public static let tokenName = "launcher-hold-token"
    public static let pauseSeconds = 120
    /// The URL the shim and the contract name. `KHHoldURL` in Info.plist carries it.
    public static var url: String { "http://127.0.0.1:\(port)\(path)" }

    private let lock = NSLock()
    private let resumed = NSCondition()
    private let queue = DispatchQueue(label: "kh.launcher.hold")
    private var listener: NWListener?
    private var pausedUntil: Date?
    private let token: String
    private let busy: @Sendable () -> [String]
    private let log: @Sendable (String) -> Void
    public private(set) var boundPort: UInt16?

    public init(token: String, busy: @escaping @Sendable () -> [String],
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.token = token
        self.busy = busy
        self.log = log
    }

    /// The token: the 0600 file when it exists, else a fresh 32-byte hex value written 0600.
    /// Created once and never rotated by a client; a new one would strand whatever holds the old.
    public static func token(in stateDir: URL) throws -> String {
        let file = stateDir.appendingPathComponent(tokenName)
        if let held = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           held.count >= 32 { return held }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw khuFail("cannot read a random token for the Launcher's update hold")
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        guard (try? AtomicFile.write(Data(value.utf8), to: file, permissions: 0o600)) != nil else {
            throw khuFail("cannot write \(file.path); the Launcher's own update hold needs it")
        }
        return value
    }

    /// Binds 127.0.0.1 only. A taken port is reported, never fatal: an app that cannot open its
    /// hold port still runs and still does its work; it just cannot be held.
    public func start(port wanted: UInt16? = LauncherHold.port) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: (wanted.map(NWEndpoint.Port.init) ?? .any))
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.lock.lock(); self.boundPort = listener.port.map { UInt16($0.rawValue) }; self.lock.unlock()
            case .failed(let error):
                self.lock.lock(); self.boundPort = nil; self.lock.unlock()
                FileHandle.standardError.write(Data("launcher hold: port \(wanted.map(String.init) ?? "any") unavailable (\(error)); the Launcher runs unheld\n".utf8))
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() { listener?.cancel(); listener = nil }

    /// The shim posts before any update action; wait for the listener to be bound before calling it,
    /// so a slow bind is not read as a refused hold (20261125-31).
    public func waitUntilBound(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let bound = boundPort != nil; lock.unlock()
            if bound { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// True from a POST until a DELETE or the in-memory pause expires. The agent reads this before
    /// it starts work, so a Sparkle hold cannot race a feed install.
    public func paused(at now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (pausedUntil ?? .distantPast) > now
    }

    /// Waits for that pause to end, bounded by the caller's own ceiling; DELETE wakes it at once.
    public func waitForResume(limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, limit))
        resumed.lock(); defer { resumed.unlock() }
        while true {
            let held = paused()
            if !held || Date() >= deadline { return held }
            resumed.wait(until: deadline)
        }
    }

    /// A refused shim start never leaves this process holding itself paused.
    public func release() {
        lock.lock(); pausedUntil = nil; lock.unlock()
        resumed.broadcast()
        log("resumed")
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil { connection.cancel(); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.reply(to: head, on: connection)
                return
            }
            if done || buffer.count > 16_384 { connection.cancel(); return }
            self.receive(connection, buffer: buffer)
        }
    }

    /// One request in, one answer out. Anything but the two contract requests is named.
    private func reply(to head: String, on connection: NWConnection) {
        func send(_ status: String, _ body: [String: Any], extra: [String: String] = [:]) {
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
            var headers = ["HTTP/1.1 \(status)", "Content-Type: application/json", "Content-Length: \(data.count)",
                           "Connection: close"]
            for (key, value) in extra { headers.append("\(key): \(value)") }
            let response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + data
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count >= 2 else { return send("400 Bad Request", ["error": "not an HTTP request"]) }
        let method = String(request[0])
        let path = String(request[1].split(separator: "?").first ?? request[1])
        guard path == Self.path || path == Self.path + "/" else {
            return send("404 Not Found", ["error": "no such route"])
        }
        guard method == "POST" || method == "DELETE" else {
            return send("405 Method Not Allowed", ["error": "\(method) is not a hold request; POST pauses, DELETE resumes"],
                        extra: ["Allow": "POST, DELETE"])
        }
        let authorization = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("authorization:") }?
            .split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard authorization == "Bearer \(token)" else {
            return send("401 Unauthorized", ["error": "the Launcher's hold needs its own token"])
        }
        lock.lock()
        let installing = busy()
        let held: String
        if method == "POST" {
            pausedUntil = Date().addingTimeInterval(Double(Self.pauseSeconds))
            held = installing.isEmpty ? "held; new work paused \(Self.pauseSeconds) s"
                                      : "held with \(installing.joined(separator: ", ")) in flight; new work paused \(Self.pauseSeconds) s"
        } else {
            pausedUntil = nil
            held = "resumed"
        }
        lock.unlock()
        resumed.broadcast()
        log(held)
        // The Launcher's work is one install at a time; anything in it is what a restart would
        // strand, and it is named so the shim's refusal can say which app.
        send("200 OK", ["safe": installing.isEmpty, "unsettled": installing, "dispatch_paused_s": Self.pauseSeconds,
                        "in_flight": installing.count, "waiting": 0])
    }
}

/// The cross-app Sparkle contention marker (`khsparkle.m:65-85`): while the Launcher is installing
/// any app, this file exists with a fresh mtime so Sparkle in this app and every other KH app
/// defers its own check/download until the install finishes. A marker older than 15 minutes is
/// ignored by the shim as a crashed installer.
public enum SparkleInstallMarker {
    public static let relativePath = "Library/Application Support/kh-sparkle/install-in-progress"
    public static let environmentVariable = "KH_SPARKLE_INSTALL_MARKER"

    public static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(relativePath)
    }

    /// Write or refresh the marker while `app` is installing; remove it on `nil`.
    public static func set(_ app: String?,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment) {
        let url = fileURL(home: home, environment: environment)
        let fm = FileManager.default
        if let app, !app.isEmpty {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try? AtomicFile.write(Data("\(app)\n".utf8), to: url, permissions: 0o600)
        } else {
            try? fm.removeItem(at: url)
        }
    }

    /// True when the marker exists and its modification time is younger than 15 minutes
    /// (matching `another_install_in_progress()` in `khsparkle.m`).
    public static func isActive(now: Date = Date(),
                                maxAge: TimeInterval = 15 * 60,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let url = fileURL(home: home, environment: environment)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(mtime) < maxAge
    }
}

/// Short-lived marker written by `Studio Launcher KH sparkle-check` right before Sparkle terminates
/// and relaunches the app (state 2). When the new `Studio Launcher KH.app` launches immediately
/// after the swap, `FrontDoor.run()` consumes the marker, sends `DELETE /api/maintenance/hold` so
/// the Helper resumes right away, logs the silent relaunch, and exits with zero visible windows.
public enum SparkleRelaunchMarker {
    public static let fileName = "sparkle-relaunch"
    public static let ttlSeconds: TimeInterval = 60
    public static let stateDirEnv = "KHU_SPARKLE_STATE_DIR"

    public struct Record: Codable, Equatable, Sendable {
        public let fromVersion: String
        public let holdURL: String
        public let tokenFile: String
        public let writtenAt: String

        public init(fromVersion: String, holdURL: String, tokenFile: String, writtenAt: String) {
            self.fromVersion = fromVersion
            self.holdURL = holdURL
            self.tokenFile = tokenFile
            self.writtenAt = writtenAt
        }
    }

    /// Expands a leading `~` or `~/` against `home`, matching the bundle plist's `~/Library/...` form.
    public static func expandTilde(_ path: String,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    /// Resolves the shared state directory for both `sparkle-check` and a LaunchServices relaunch
    /// (which does not inherit custom env vars): `KHU_SPARKLE_STATE_DIR` wins if set, else the
    /// parent directory of `KHHoldTokenFile` from Info.plist, else `<home>/Library/KHUpdater/state`.
    public static func stateDir(info: [String: Any]?,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[stateDirEnv], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let tokenFile = info?["KHHoldTokenFile"] as? String, !tokenFile.isEmpty {
            return URL(fileURLWithPath: expandTilde(tokenFile, home: home)).deletingLastPathComponent()
        }
        return home.appendingPathComponent("Library/KHUpdater/state")
    }

    public static func fileURL(in stateDir: URL) -> URL {
        stateDir.appendingPathComponent(fileName)
    }

    public static func write(fromVersion: String, holdURL: String, tokenFile: String,
                             in stateDir: URL, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let record = Record(fromVersion: fromVersion, holdURL: holdURL, tokenFile: tokenFile,
                            writtenAt: ISO.string(now))
        guard let data = try? JSONEncoder().encode(record) else { return }
        _ = try? AtomicFile.write(data, to: fileURL(in: stateDir), permissions: 0o600)
    }

    public static func clear(in stateDir: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: stateDir))
    }

    /// Removes the marker unconditionally so it can never fire twice, returning the decoded record
    /// only when its modification time is within `ttl` seconds of `now`.
    public static func consumeIfFresh(in stateDir: URL,
                                      now: Date = Date(),
                                      ttl: TimeInterval = ttlSeconds) -> Record? {
        let url = fileURL(in: stateDir)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let data = try? Data(contentsOf: url)
        try? fm.removeItem(at: url)
        let age = now.timeIntervalSince(mtime)
        guard age <= ttl && age >= -60 else { return nil }
        if let data, let decoded = try? JSONDecoder().decode(Record.self, from: data) {
            return decoded
        }
        return Record(fromVersion: "unknown", holdURL: "", tokenFile: "", writtenAt: ISO.string(mtime))
    }

    /// Best-effort synchronous `DELETE` to the Launcher's hold endpoint so the Helper resumes
    /// immediately after a silent relaunch or an aborted check.
    public static func releaseHold(urlString: String,
                                   tokenFile: String?,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   timeout: TimeInterval = 5) -> Bool {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return false }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "DELETE"
        if let tokenFile, !tokenFile.isEmpty {
            let resolved = expandTilde(tokenFile, home: home)
            if let raw = try? String(contentsOfFile: resolved, encoding: .utf8) {
                let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            }
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var status = -1 }
        let box = Box()
        session.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse { box.status = http.statusCode }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return box.status == 200
    }
}

/// Schedules headless `Studio Launcher KH.app` `sparkle-check` runs from the Helper process.
///
/// The Helper (`Studio Launcher KH Helper.app`) deliberately does not embed Sparkle.framework:
/// Sparkle must target the user-facing `Studio Launcher KH.app` bundle directly. This scheduler
/// runs at most one child at a time, only between `Agent.runOnce` runs when nothing is installing
/// and the hold is idle, on a bounded cadence, so Sparkle and the estate feed never race.
public final class SparkleCheckScheduler: @unchecked Sendable {
    public static let defaultSettleSeconds: TimeInterval = 0
    public static let defaultIntervalSeconds: TimeInterval = 4 * 3600
    public static let launcherAppEnv = "KHU_SPARKLE_LAUNCHER_APP"
    public static let settleSecondsEnv = "KHU_SPARKLE_SETTLE_SECONDS"
    public static let intervalSecondsEnv = "KHU_SPARKLE_INTERVAL_SECONDS"

    private let lock = NSLock()
    private let idle = NSCondition()
    private var active = false
    private var lastAttemptAt: Date?
    private let startedAt: Date
    private let settleSeconds: TimeInterval
    private let intervalSeconds: TimeInterval
    private let log: @Sendable (String) -> Void
    private let findLauncher: @Sendable () -> URL?
    private let runCheck: @Sendable (URL) -> Int32

    public init(startedAt: Date = Date(),
                settleSeconds: TimeInterval? = nil,
                intervalSeconds: TimeInterval? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                log: @escaping @Sendable (String) -> Void = { _ in },
                findLauncher: (@Sendable () -> URL?)? = nil,
                runCheck: (@Sendable (URL) -> Int32)? = nil) {
        self.startedAt = startedAt
        self.settleSeconds = settleSeconds
            ?? environment[Self.settleSecondsEnv].flatMap(TimeInterval.init)
            ?? Self.defaultSettleSeconds
        self.intervalSeconds = intervalSeconds
            ?? environment[Self.intervalSecondsEnv].flatMap(TimeInterval.init)
            ?? Self.defaultIntervalSeconds
        self.log = log
        self.findLauncher = findLauncher ?? { Self.resolveLauncherBundle(environment: environment) }
        self.runCheck = runCheck ?? { bundle in Self.spawnCheck(bundle: bundle, log: log) }
    }

    public var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Waits for an active `sparkle-check` child to exit, bounded by `limit`.
    /// Returns `true` if still running when `limit` elapsed, `false` once idle.
    public func waitUntilIdle(limit: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, limit))
        idle.lock(); defer { idle.unlock() }
        while true {
            let busy = running
            if !busy || Date() >= deadline { return busy }
            idle.wait(until: deadline)
        }
    }

    public func isDue(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return false }
        if let last = lastAttemptAt {
            return now.timeIntervalSince(last) >= intervalSeconds
        }
        return now.timeIntervalSince(startedAt) >= settleSeconds
    }

    /// Starts one `sparkle-check` run on a background thread when idle, safe, and due.
    /// Returns `true` when a check was launched, `false` when deferred or not due.
    @discardableResult
    public func triggerIfDue(now: Date = Date(),
                             paused: Bool,
                             installInProgress: Bool,
                             hasPendingInstalls: Bool) -> Bool {
        guard !paused && !installInProgress && !hasPendingInstalls else { return false }
        lock.lock()
        guard !active else { lock.unlock(); return false }
        let due: Bool
        if let last = lastAttemptAt {
            due = now.timeIntervalSince(last) >= intervalSeconds
        } else {
            due = now.timeIntervalSince(startedAt) >= settleSeconds
        }
        guard due else { lock.unlock(); return false }
        active = true
        lastAttemptAt = now
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock(); self.active = false; self.lock.unlock()
                self.idle.broadcast()
            }
            guard let bundle = self.findLauncher() else {
                self.log("sparkle: no verified Studio Launcher KH.app found; self-update deferred, this app still updates through the feed")
                return
            }
            let status = self.runCheck(bundle)
            if status != 0 {
                self.log("sparkle: sparkle-check exited \(status)")
            }
        }
        return true
    }

    /// Resolves the verified packaged `Studio Launcher KH.app` carrying Sparkle.framework.
    /// `KHU_SPARKLE_LAUNCHER_APP` is a test-only override for isolated proof harnesses.
    public static func resolveLauncherBundle(environment: [String: String] = ProcessInfo.processInfo.environment,
                                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                             verify: (URL) -> Bool = { Connect.packagedLauncherVerifies($0) }) -> URL? {
        let fm = FileManager.default
        let candidates: [URL]
        if let override = environment[launcherAppEnv], !override.isEmpty {
            candidates = [URL(fileURLWithPath: override)]
        } else {
            candidates = [
                URL(fileURLWithPath: "/Applications/Studio Launcher KH.app"),
                home.appendingPathComponent("Applications/Studio Launcher KH.app"),
            ]
        }
        for bundle in candidates {
            let exec = bundle.appendingPathComponent("Contents/MacOS/Studio Launcher KH")
            let fw = bundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
            var isDir: ObjCBool = false
            guard fm.isExecutableFile(atPath: exec.path),
                  fm.fileExists(atPath: fw.path, isDirectory: &isDir), isDir.boolValue,
                  verify(bundle) else { continue }
            return bundle
        }
        return nil
    }

    /// Spawns `<bundle>/Contents/MacOS/Studio Launcher KH sparkle-check` directly as a child process
    /// (never `open -a`) and waits for it to settle and exit.
    private static func spawnCheck(bundle: URL, log: @escaping @Sendable (String) -> Void) -> Int32 {
        let exec = bundle.appendingPathComponent("Contents/MacOS/Studio Launcher KH")
        let proc = Process()
        proc.executableURL = exec
        proc.arguments = ["sparkle-check"]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            log("sparkle: could not launch sparkle-check (\(error))")
            return -1
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if let text = String(data: errData, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                log(String(line))
            }
        }
        return proc.terminationStatus
    }
}
