import Foundation
import Darwin

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

    /// The Launcher's own hold credential, 0600, created on first use. Apps read their own copy;
    /// the Launcher never reads an app's credential files.
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

    /// Why a hold could not be presented. Typed so a caller can say what is wrong in plain words
    /// instead of trying a credential the app never asked for (issue `20261124-90`).
    public enum HoldCredential: Error {
        /// The app declares its own credential file, but that file cannot be read as a token.
        case unreadable(URL)
        /// The app declares `KHHoldTokenFile` with a value that is not a usable path.
        case invalid(String)
        /// No app file is declared and the Launcher's own shared file cannot be read either.
        case sharedUnavailable
    }

    /// The credential an app's own hold expects. Six apps keep their own copy of the token, printed
    /// in their bundle's `KHHoldTokenFile`, and never read the Launcher's shared file — so the shared
    /// one is rotated by every agent start while theirs stays put (issue `20261124-90`: after one
    /// rotation each of those apps refused every hold). The rule, once: a plist that names no file
    /// keeps the shared credential exactly as before; a plist that names one uses that file only, and
    /// a named file that is missing or unusable refuses the hold with the path — never the shared
    /// token, which the app would reject anyway and which would hide the fault.
    public static func credentialFile(bundlePath: String?) -> Result<URL?, HoldCredential> {
        guard let bundlePath, let plist = Bundle(path: bundlePath)?.infoDictionary else { return .success(nil) }
        guard let raw = plist["KHHoldTokenFile"] else { return .success(nil) }
        guard let named = raw as? String, !named.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .failure(.invalid("KHHoldTokenFile is not a usable path")) }
        return .success(URL(fileURLWithPath: (named as NSString).expandingTildeInPath))
    }

    /// A read-only, bounded read of an app's own credential: a regular file only (a symlink is never
    /// followed), never more than 512 bytes, and never a value that is not one token. This path is
    /// never created, chmodded or replaced — the app owns its own file.
    static func token(at url: URL) -> String? {
        var info = stat()
        // `S_IFMT`/`S_IFREG` as octal: `stat.st_mode` is `mode_t` here, so the C macros' own type
        // would not match without a cast that hides what is being asked.
        guard Darwin.lstat(url.path, &info) == 0, info.st_mode & 0o170000 == 0o100000 else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0, opened.st_mode & 0o170000 == 0o100000 else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while data.count <= 512 {
            let n = buffer.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress, raw.count) }
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; return nil }
            data.append(contentsOf: buffer[0..<n])
        }
        guard data.count <= 512, let raw = String(data: data, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A hold credential is exactly one 64-hex token (issue `20261123-39`): an empty, short,
        // non-hex, whitespace-bearing or oversized value is not a credential to present.
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard text.count == 64, text.unicodeScalars.allSatisfy(hex.contains) else { return nil }
        return text
    }

    /// The credential headers for one app's hold. Declared file → that file only; no declaration →
    /// the shared file; declared but missing or unusable → throw, so no request is made at all.
    static func credentialHeaders(bundlePath: String? = nil) throws -> [String: String] {
        let credential: String
        switch credentialFile(bundlePath: bundlePath) {
        case .failure(let error):
            throw error
        case .success(.some(let url)):
            guard let own = token(at: url) else { throw HoldCredential.unreadable(url) }
            credential = own
        case .success(.none):
            guard let shared = localToken() else { throw HoldCredential.sharedUnavailable }
            credential = shared
        }
        return ["X-Hub-Token": credential, "Authorization": "Bearer \(credential)"]
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
                             deadline: Date? = nil, bundlePath: String? = nil) throws -> Reply {
        let timeout = max(0, min(Int(settleWindow), timeoutS))
        let url = endpoint.appendingQuery("timeout_s", "\(timeout)").appendingQuery("pause_s", "\(max(1, pauseS))")
        let wait = max(1, min(answerAllowance, deadline?.timeIntervalSinceNow ?? answerAllowance))
        let (data, code) = try http.post(url, headers: try credentialHeaders(bundlePath: bundlePath), body: Data(), timeout: wait)
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
    /// an app that has stopped taking work. The credential is still the app's own when it declares
    /// one, and an unreadable one makes no request rather than sending a credential the app rejects.
    public static func resume(_ endpoint: URL, http: HTTPClient, bundlePath: String? = nil) throws {
        _ = try http.delete(endpoint, headers: try credentialHeaders(bundlePath: bundlePath), timeout: answerAllowance)
    }
}
