import Foundation

/// The app-side update hold every KH app implements (`_orchestra/youtube-stack/update-hold/CONTRACT.md`):
/// POST pauses dispatch and settles in-flight work within a bounded window, DELETE resumes. The
/// endpoint is a loopback address the signed feed names for that app — anything else is not a
/// trusted update target.
public enum UpdateHold {
    public struct Reply: Decodable, Sendable, Equatable {
        public var safe: Bool
        public var unsettled: [String]?
        public var inFlight: Int?
        public var pausedSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case safe, unsettled
            case inFlight = "in_flight"
            case pausedSeconds = "dispatch_paused_s"
        }
        public var summary: String {
            let jobs = inFlight ?? 0
            let paused = pausedSeconds.map { "; new work paused \($0) s" } ?? ""
            return jobs > 0 ? "held (\(jobs) job\(jobs == 1 ? "" : "s") in flight\(paused))" : "held\(paused)"
        }
    }

    /// The trusted endpoint for a feed entry: plain HTTP on this Mac's loopback, an explicit port,
    /// and exactly the contract's two paths. A remote or malformed URL is no endpoint at all.
    public static func trusted(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
              url.port != nil, url.user == nil, url.password == nil,
              // Exact paths only, never a prefix: Gateway's real route is included, any other
              // /admin/... path, a query or a fragment is not.
              url.query == nil, url.fragment == nil,
              ["/api/maintenance/hold", "/api/maintenance/drain",
               "/admin/api/maintenance/drain"].contains(url.path) else { return nil }
        return url
    }

    /// The Launcher's own hold credential, 0600, created on first use. Apps that gate their hold
    /// route read this same file; the Launcher never reads an app's own credential files.
    public static var tokenFile: URL {
        if let override = ProcessInfo.processInfo.environment["KHU_HOLD_TOKEN_FILE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/KHUpdater/state/hold-token")
    }

    public static func localToken() -> String? {
        let url = tokenFile
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            // A file an older rotation left 0644 is refused by an app that gates its hold on the
            // mode, so the mode is corrected where the credential is read as well as where it is written.
            let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            if mode?.intValue != 0o600 { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            return text
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard (try? Data(token.utf8).write(to: url, options: .atomic)) != nil else { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    /// Issues a fresh token and replaces the file atomically, so a reader sees either the old or the
    /// new credential and never a partial one. Called when the agent starts; apps read it per request.
    @discardableResult
    public static func rotateToken() -> String? {
        let url = tokenFile
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".hold-token.\(UUID().uuidString)")
        guard (try? Data(token.utf8).write(to: temp, options: .atomic)) != nil else { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if fm.fileExists(atPath: url.path) {
            guard (try? fm.replaceItemAt(url, withItemAt: temp)) != nil else {
                try? fm.removeItem(at: temp)
                return nil
            }
        } else {
            guard (try? fm.moveItem(at: temp, to: url)) != nil else {
                try? fm.removeItem(at: temp)
                return nil
            }
        }
        // `replaceItemAt` keeps the *replaced* file's mode, so the temp's 0600 is discarded and an
        // old 0644 token stayed 0644 — which an app that gates its hold on the mode refuses with 401.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    static func credentialHeaders() -> [String: String] {
        guard let token = localToken() else { return [:] }
        return ["X-Hub-Token": token, "Authorization": "Bearer \(token)"]
    }

    /// The endpoint answered but refused the request: kept typed so the caller can say whether the
    /// credential or the address is wrong, instead of a generic answer.
    public struct Refused: Error, Equatable { public let status: Int }

    /// What we ask the app to settle for: the app's own wait, and the contract's window.
    public static let settleWindow: TimeInterval = 20

    /// How long past that window the app may take to put its answer on the wire. A request capped
    /// at the window itself gives the app no time to answer, which is how a real 20.2 s refusal
    /// reached the log as a bare -1001.
    public static let answerMargin: TimeInterval = 15

    /// The HTTP client's allowance for one hold request: the settle window plus the app's answer
    /// margin. Bounded again only by the caller's own `deadline`, never clamped back to the window.
    public static let answerAllowance: TimeInterval = settleWindow + answerMargin

    /// Pauses dispatch and waits for the app's bounded settle. `timeoutS` is what the app is asked
    /// to settle for, never more than `settleWindow`; 0 renews an existing hold without waiting.
    /// `deadline` is the caller's own deadline (an install's window), not the contract's: with no
    /// deadline the request gets `answerAllowance`.
    public static func begin(_ endpoint: URL, http: HTTPClient, timeoutS: Int = 20, pauseS: Int = 120,
                             deadline: Date? = nil) throws -> Reply {
        let timeout = max(0, min(Int(settleWindow), timeoutS))
        let url = endpoint.appendingQuery("timeout_s", "\(timeout)").appendingQuery("pause_s", "\(max(1, pauseS))")
        let wait = max(1, min(answerAllowance, deadline?.timeIntervalSinceNow ?? answerAllowance))
        let (data, code) = try http.post(url, headers: credentialHeaders(), body: Data(), timeout: wait)
        guard code == 200 else { throw Refused(status: code) }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw khuFail("the app's update hold did not answer with the contract's reply; nothing was changed")
        }
        return reply
    }

    /// A refused connection to the feed's endpoint is not a generic failure: it means the installed
    /// build predates the hold and needs one normal install while it is closed. Kept distinct from a
    /// timeout (endpoint present but slow) so the recorded reason names the real next step.
    public static func endpointAbsent(_ error: Error) -> Bool {
        let codes: [Int] = [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost]
        if let urlError = error as? URLError { return codes.contains(urlError.code.rawValue) }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && codes.contains(ns.code)
    }

    /// A timeout means the endpoint is present, but the app did not settle or answer inside the
    /// hold window — distinct from an absent endpoint so the failure names the hold timeout.
    public static func timedOut(_ error: Error) -> Bool {
        // Our own client's read deadline is enforced before URLSession's, so it reports its own type.
        if error is TransferTimeout { return true }
        if let urlError = error as? URLError { return urlError.code == .timedOut }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut
    }

    /// Best effort: the pause is in-memory and expires by itself, so a failed DELETE never leaves
    /// an app that has stopped taking work.
    public static func resume(_ endpoint: URL, http: HTTPClient) {
        _ = try? http.delete(endpoint, headers: credentialHeaders(), timeout: answerAllowance)
    }
}
