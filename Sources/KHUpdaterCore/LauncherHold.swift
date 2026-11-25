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
}
