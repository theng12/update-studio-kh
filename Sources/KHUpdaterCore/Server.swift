import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

public struct HTTPRequest {
    public var method: String
    /// The path without its query, percent-decoded once.
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        let (decoded, query) = HTTP.split(path)
        self.method = method; self.path = decoded; self.query = query; self.headers = headers; self.body = body
    }
}

public enum HTTPBody {
    case data(Data)
    case file(URL, Int64)
}

public struct HTTPResponse {
    public var status: Int
    public var contentType: String
    public var body: HTTPBody
    public var headers: [String: String] = [:]

    public init(_ status: Int, _ contentType: String = "text/plain; charset=utf-8", _ text: String) {
        self.status = status; self.contentType = contentType; self.body = .data(Data(text.utf8))
    }
    public init(_ status: Int, _ contentType: String, data: Data) {
        self.status = status; self.contentType = contentType; self.body = .data(data)
    }
    public var data: Data { if case .data(let d) = body { return d }; return Data() }
}

public enum HTTP {
    public static func split(_ target: String) -> (String, [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "").removingPercentEncoding ?? String(parts.first ?? "")
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
        }
        return (path, query)
    }

    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                headers[String(line[..<idx]).lowercased().trimmingCharacters(in: .whitespaces)] =
                    String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                           body: Data(data[end.upperBound...]))
    }

    /// Read one request — headers (at most 64 KiB), then exactly Content-Length body bytes (at
    /// most `limit`) — within `deadline` seconds IN TOTAL. A client trickling one byte at a time
    /// is cut off at the deadline instead of holding the connection for ever.
    public static func readRequest(from fd: Int32, limit: Int = 1 << 20, deadline: TimeInterval = 15) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let separator = Data("\r\n\r\n".utf8)
        let until = Mono.now() + deadline
        while true {
            if let end = data.range(of: separator) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard length >= 0, length <= limit else { return nil }
                if data.count - end.upperBound >= length { return data.prefix(end.upperBound + length) }
            } else if data.count > 65536 {
                return nil
            }
            let remaining = until - Mono.now()
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 15) * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            data.append(contentsOf: chunk[0..<n])
        }
    }

    /// Write every byte; false when the peer stops reading (SO_SNDTIMEO) or goes away.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    static let reasons = [200: "OK", 303: "See Other", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Content Too Large",
                          429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"]

    public static func head(_ response: HTTPResponse, length: Int64) -> Data {
        var out = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\n"
        out += "Content-Type: \(response.contentType)\r\n"
        out += "Content-Length: \(length)\r\n"
        out += "X-Content-Type-Options: nosniff\r\n"
        out += "Cache-Control: no-store\r\n"
        for (k, v) in response.headers.sorted(by: { $0.key < $1.key }) { out += "\(k): \(v)\r\n" }
        out += "Connection: close\r\n\r\n"
        return Data(out.utf8)
    }

    /// Send a response; a file body is streamed in 1 MiB pieces rather than loaded whole.
    public static func send(_ fd: Int32, _ response: HTTPResponse) {
        switch response.body {
        case .data(let data):
            var out = head(response, length: Int64(data.count))
            out.append(data)
            writeAll(fd, out)
        case .file(let url, let size):
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                send(fd, HTTPResponse(404, "text/plain; charset=utf-8", "not found")); return
            }
            defer { try? handle.close() }
            guard writeAll(fd, head(response, length: size)) else { return }
            var sent: Int64 = 0
            while sent < size, let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                guard writeAll(fd, chunk) else { return }
                sent += Int64(chunk.count)
            }
        }
    }
}

public enum OwnerAccess {
    public static func isSameOrigin(_ origin: String, port: Int) -> Bool {
        origins(port).contains(origin)
    }

    static func origins(_ port: Int) -> [String] {
        ["http://127.0.0.1:\(port)", "http://localhost:\(port)", "http://[::1]:\(port)"]
    }

    /// The Host a browser sends for this page. Anything else is a rebinding attempt (a name that
    /// resolves to 127.0.0.1 but is not ours).
    public static func isAllowedHost(_ host: String?, port: Int) -> Bool {
        guard let host else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host.lowercased())
    }

    /// A state-changing owner request must say where it came from, and it must be this page:
    /// Origin when present, else Referer. Neither is refused.
    public static func isSameSite(_ headers: [String: String], port: Int) -> Bool {
        if let origin = headers["origin"] { return isSameOrigin(origin, port: port) }
        if let referer = headers["referer"] { return origins(port).contains { referer == $0 || referer.hasPrefix($0 + "/") } }
        return false
    }

    /// The body's fields, from JSON (`on` may be a bool) or a urlencoded form.
    public static func fields(_ req: HTTPRequest) -> [String: String] {
        if let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
            return obj.reduce(into: [:]) { out, kv in
                if let s = kv.value as? String { out[kv.key] = s } else if let b = kv.value as? Bool { out[kv.key] = b ? "true" : "false" }
            }
        }
        let text = String(decoding: req.body, as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    public static func isLoopback(_ remote: String) -> Bool {
        remote == "127.0.0.1" || remote == "::1"
    }
}

public enum ServerDecision {
    public static func isLoopbackRemote(_ remote: String) -> Bool { OwnerAccess.isLoopback(remote) }
    public static func ownerRouteAllowed(remote: String) -> Bool { isLoopbackRemote(remote) }
}

/// A bound on how often ONE key may ask for something that costs a lock, a state read and a
/// signature. `/enrol` is keyed by client address (a body is two short strings and costs almost
/// nothing to send, while the window's own cap bounds the enrolments that succeed); the report
/// routes are keyed by machine id (a Mac posts status once per run, but nothing stops a loop).
///
/// Held in memory, per listening server: the limit is a guard against a scripted flood, not a
/// durable record, and restarting `serve` clearing it is fine.
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: [TimeInterval]] = [:]
    private let attempts: Int
    private let span: TimeInterval = 60

    init(attempts: Int) { self.attempts = attempts }

    /// Counts the attempt only when it is allowed: a refused key stays refused for the rest of
    /// the minute instead of pushing its own deadline forward.
    func allow(_ key: String, now: Date = Date()) -> Bool {
        let t = now.timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if seen.count > 256 { seen = seen.filter { t - ($0.value.last ?? 0) < span } }
        var hits = (seen[key] ?? []).filter { t - $0 < span }
        let allowed = hits.count < attempts
        if allowed { hits.append(t) }
        seen[key] = hits
        return allowed
    }
}

public final class FeedServer: @unchecked Sendable {
    public let feedDir: URL
    public let stateDir: URL
    public let bind: String
    public let port: Int
    public let maxConnections: Int
    /// The key that signs every order reply. Without it the server has no way to answer a Mac with
    /// something the Mac can tell apart from a forgery, so it refuses to answer at all.
    public let commandKey: Curve25519.Signing.PrivateKey?
    /// New Macs one open enrolment window may enrol, and `/enrol` attempts one address may make per
    /// minute. Both are injectable so a test can prove the bounds without a 200-Mac fixture.
    public let maxEnrolmentsPerWindow: Int
    public let enrolAttemptsPerMinute: Int
    /// `/status` and result posts one Mac may make per minute.
    public let reportPostsPerMinute: Int
    private let enrolLimiter: RateLimiter
    private let reportLimiter: RateLimiter

    public init(feedDir: URL, stateDir: URL, bind: String, port: Int,
                commandKey: Curve25519.Signing.PrivateKey? = nil, maxConnections: Int = 32,
                maxEnrolmentsPerWindow: Int = EnrolPolicy.maxPerWindow,
                enrolAttemptsPerMinute: Int = EnrolPolicy.attemptsPerMinute,
                reportPostsPerMinute: Int = ReportPolicy.perMachinePerMinute) {
        self.feedDir = feedDir
        self.stateDir = stateDir
        self.bind = bind
        self.port = port
        self.commandKey = commandKey
        self.maxConnections = maxConnections
        self.maxEnrolmentsPerWindow = maxEnrolmentsPerWindow
        self.enrolAttemptsPerMinute = enrolAttemptsPerMinute
        self.reportPostsPerMinute = reportPostsPerMinute
        self.enrolLimiter = RateLimiter(attempts: enrolAttemptsPerMinute)
        self.reportLimiter = RateLimiter(attempts: reportPostsPerMinute)
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse { HTTPResponse(status, "text/plain; charset=utf-8", message) }
    static let ok = HTTPResponse(200, "application/json", "{}")

    /// A state transaction, answered honestly: an unreadable state file is a 503 that says so (the
    /// file is left as it is), and a change that could not be saved is a 500 — never a 200.
    ///
    /// The detail names the absolute state path and the decoder's own words, which is what the owner
    /// needs on their own Mac. `/enrol` is the one route anything on the tailnet may call, so it
    /// asks for `genericFailure`: the sender gets a plain sentence and the detail never leaves this
    /// Mac.
    func transact(genericFailure: Bool = false,
                  _ change: (inout ServerState) throws -> HTTPResponse) -> HTTPResponse {
        do {
            return try FileLock.withExclusive(StateStore.lockFile(in: stateDir)) {
                let state: ServerState
                do { state = try StateStore.load(from: stateDir) } catch {
                    FileHandle.standardError.write(Data("publisher: state unreadable: \(error)\n".utf8))
                    return genericFailure
                        ? Self.text(503, "the publisher cannot read its own state right now; ask its owner to check it")
                        : Self.text(503, "the publisher's state file cannot be read (\(error)); it was left untouched")
                }
                var next = state
                let response = try change(&next)
                if next != state {
                    do { try StateStore.save(next, to: stateDir) } catch {
                        FileHandle.standardError.write(Data("publisher: state not saved: \(error)\n".utf8))
                        return genericFailure
                            ? Self.text(500, "the publisher could not record that just now; try again shortly")
                            : Self.text(500, "could not save the publisher's state: \(error)")
                    }
                }
                return response
            }
        } catch {
            return genericFailure ? Self.text(500, "the publisher could not answer that just now") : Self.text(500, "\(error)")
        }
    }

    func machineToken(_ req: HTTPRequest) -> String? {
        guard let h = req.headers["authorization"], h.lowercased().hasPrefix("bearer ") else { return nil }
        return String(h.dropFirst(7))
    }

    func authorised(_ state: ServerState, _ machine: String, _ token: String) -> Bool {
        guard let hash = state.machines[machine]?.tokenHash else { return false }
        return hash == Enrolment.sha256Hex(token)
    }

    /// The feed URL a Mac learning this publisher gets. It is the address THIS listener was bound
    /// to, which is the address the Mac just reached it at, written the one way `publisher.json`
    /// writes it — so the Mac's own check that the reply agrees with its kit cannot fail for a
    /// mistake in a second place. Nothing is guessed: an address the Mac's Hub would refuse is one
    /// the reply must not name, so enrolment is refused instead.
    var enrolFeedURL: String? {
        guard (1...65535).contains(port), Self.isTailnet(bind) else { return nil }
        return "http://\(bind):\(port)/release.json"
    }

    /// An address the Hub's own `publisher_config` will accept: 100.64.0.0/10, the Tailscale CGNAT
    /// range and the only range a Mac in this fleet is told to use. The two sides must agree or the
    /// publisher hands out a feed URL the Hub refuses to adopt — a Mac that enrolled successfully
    /// and still cannot report. The macOS listener refuses loopback, wildcard, link-local, multicast
    /// and ordinary LAN addresses alike, rather than guessing which of them some Mac could reach.
    static func isTailnet(_ address: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return false }
        let host = UInt32(bigEndian: addr.s_addr)
        return host >> 24 == 100 && (64...(127)).contains((host >> 16) & 0xFF)   // 100.64.0.0/10
    }

    /// A nonce is 64 hexadecimal characters and is echoed back verbatim. Accepting anything else
    /// would let a reply name a question the Mac never asked.
    static func isNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == EnrolPolicy.nonceCharacters
            && nonce.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }

    /// A `/status` report is bounded before it is stored, so one Mac — possibly one that claimed a
    /// token through a window and has never been inspected — cannot make `state.json` grow without
    /// limit. Returns the refusal sentence, or nil when the report fits.
    static func reportRefusal(installed: [String: String]?, health: [String: String]?,
                              defaults: [String: Bool]?) -> String? {
        func fits(_ names: [String], _ values: [String], _ valueLimit: Int) -> Bool {
            names.count <= ReportPolicy.maxApps && values.count <= ReportPolicy.maxApps
                && names.allSatisfy { !$0.isEmpty && $0.utf8.count <= ReportPolicy.maxNameCharacters }
                && values.allSatisfy { $0.utf8.count <= valueLimit }
        }
        if let installed, !fits(Array(installed.keys), Array(installed.values), ReportPolicy.maxVersionCharacters) {
            return "that Mac reported more apps, or longer names or versions, than this publisher accepts (at most \(ReportPolicy.maxApps) apps, \(ReportPolicy.maxNameCharacters) characters for a name, \(ReportPolicy.maxVersionCharacters) for a version)"
        }
        if let health, !fits(Array(health.keys), Array(health.values), ReportPolicy.maxHealthCharacters) {
            return "that Mac reported more health entries, or longer ones, than this publisher accepts (at most \(ReportPolicy.maxApps), \(ReportPolicy.maxHealthCharacters) characters each)"
        }
        if let defaults, defaults.count > ReportPolicy.maxApps
            || !defaults.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= ReportPolicy.maxNameCharacters }) {
            return "that Mac reported more Automatic defaults, or longer app names, than this publisher accepts (at most \(ReportPolicy.maxApps) apps, \(ReportPolicy.maxNameCharacters) characters for a name)"
        }
        return nil
    }

    /// `POST /enrol` — a Mac claiming a token for itself while the owner has a window open. Every
    /// refusal is a plain sentence and leaves the state exactly as it was.
    func enrol(_ req: HTTPRequest, remote: String, now: Date = Date()) -> HTTPResponse {
        guard enrolLimiter.allow(remote, now: now) else {
            return Self.text(429, "too many enrolment requests from this address; wait a minute and try again")
        }
        // This is the one route with no token, so it is the one a web page could reach: a
        // `text/plain` POST is a "simple request" that a browser sends cross-site without a
        // preflight, and spending the owner's enrolment window would be the whole effect. Browsers
        // send Origin (and usually Referer); a Mac's own agent sends neither, so a request that
        // carries one is refused before its body is touched.
        guard req.headers["origin"] == nil, req.headers["referer"] == nil else {
            return Self.text(403, "a web page cannot enrol a Mac: this route is for a Mac's own agent, which sends no Origin or Referer")
        }
        guard req.body.count <= EnrolPolicy.maxBodyBytes else {
            return Self.text(413, "that enrolment request is too large")
        }
        guard let object = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let machine = object["machine"] as? String, let nonce = object["nonce"] as? String else {
            return Self.text(400, "send machine and nonce as JSON")
        }
        // The id becomes a key in state.json and a name on the owner's page; it is decided here, and
        // the message never repeats what was sent back to the sender.
        guard (try? SafeName.component(machine, what: "machine id")) != nil else {
            return Self.text(400, "that machine id is not one this publisher accepts")
        }
        guard Self.isNonce(nonce) else {
            return Self.text(400, "a nonce is \(EnrolPolicy.nonceCharacters) hexadecimal characters")
        }
        guard let commandKey else {
            return Self.text(403, "this publisher has no signing key, so it cannot enrol a Mac: start `khu serve` with --key")
        }
        // A sentence for the sender, never the bind or the port this listener was given: `/enrol`
        // is open to anything on the tailnet, and where the publisher listens is not its business.
        guard let feedURL = enrolFeedURL else {
            return Self.text(403, "this publisher is not listening on an address a Mac can reach, so it cannot enrol one: its owner must bind the Tailscale address (the LaunchAgent does)")
        }
        let publicKey = commandKey.publicKey.rawRepresentation.base64EncodedString()
        let issuedAt = Int(now.timeIntervalSince1970)
        return transact(genericFailure: true) { state in
            guard let window = state.enrolWindow, window.isOpen(at: now) else {
                return Self.text(403, "this publisher is not taking new Macs right now; ask the owner to open an enrolment window")
            }
            // A Mac this publisher already has a record of is refused over the network, whatever
            // else happens: another device on the tailnet must never be able to rotate a real Mac's
            // token out from under it. Re-enrolment runs on the publisher itself (`khu enrol`), and
            // a removed Mac enrols again through a window because it has no record left.
            //
            // The one exception is the SAME claim arriving twice: a Mac that enrolled through a
            // window and never reported, resending its own machine and nonce because the signed
            // reply was lost on the way back. It cannot use the token it never received, so a plain
            // 409 would strand it until the owner removed it by hand. The nonce is what makes it
            // the same claim — a different nonce, or a record that has reported, is still 409 —
            // and the resend mints a fresh token, so a reply that WAS seen and kept is replaced by
            // one this Mac asked for with the same question.
            let retry = state.machines[machine].map { record in
                record.enrolmentSource == MachineState.windowSource && record.lastSeen == nil
                    && record.enrolNonceHash == Enrolment.sha256Hex(nonce)
            } ?? false
            guard state.machines[machine] == nil || retry else {
                return Self.text(409, "that Mac is already enrolled with this publisher, so another device on the tailnet cannot take its place; if it was reset, the owner removes it on the publisher first (Remove Mac on the status page, or `khu remove`) and then it enrols again through a window")
            }
            // A resend is the same enrolment, not a second one: it must not spend another slot.
            guard retry || window.enrolled < maxEnrolmentsPerWindow else {
                return Self.text(429, "this enrolment window has already enrolled as many Macs as it allows (\(maxEnrolmentsPerWindow)); ask the owner to open a new one")
            }
            let token = Enrolment.token()
            // Signed BEFORE the state changes: a reply that could not be signed must not leave a
            // token stored that the Mac never received.
            let body = JSON.encode(EnrolReply(machine: machine, nonce: nonce, feedURL: feedURL,
                                              publicKey: publicKey, issuedAt: issuedAt, token: token))
            guard let signature = try? Signing.sign(body, with: commandKey) else {
                FileHandle.standardError.write(Data("publisher: could not sign an enrolment reply\n".utf8))
                return Self.text(500, "the publisher could not answer that just now; try again")
            }
            Enrolment.store(token, for: machine, at: now, source: MachineState.windowSource,
                            nonce: nonce, in: &state)
            if !retry { state.enrolWindow?.enrolled = window.enrolled + 1 }
            return HTTPResponse(200, "application/json", data: JSON.encode(SignedReply(reply: body, signature: signature), pretty: false))
        }
    }

    /// `now` exists so a test can drive the enrolment window's end time and the rate limit without
    /// waiting; every real caller leaves it alone.
    public func handleRequest(_ req: HTTPRequest, remote: String, now: Date = Date()) -> HTTPResponse {
        if req.method == "GET" {
            if req.path == "/release.json" {
                let url = FeedPublisher.releaseFile(in: feedDir)
                guard let data = try? Data(contentsOf: url) else { return Self.text(404, "nothing published yet") }
                return HTTPResponse(200, "application/json", data: data)
            }
            if req.path.hasPrefix("/artifacts/") {
                let name = String(req.path.dropFirst("/artifacts/".count))
                // Everything the publisher ever stored is served, not only what the newest feed
                // names: a Mac already downloading the release it verified must not be cut off by
                // the next publish. The name can never leave `artifacts/` (SafeName), and the agent
                // checks the signed size and SHA-256 before it uses one byte of it.
                guard let safe = try? SafeName.component(name, what: "artifact") else { return Self.text(404, "not found") }
                let url = feedDir.appendingPathComponent("artifacts").appendingPathComponent(safe)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
                    return Self.text(404, "not found")
                }
                return HTTPResponse(status: 200, contentType: "application/octet-stream", body: .file(url, size.int64Value))
            }
        }

        // A Mac enrolling itself: the one route with no token, open only while the owner's window
        // is, and refused by the checks inside `enrol`.
        if req.method == "POST" && req.path == "/enrol" { return enrol(req, remote: remote, now: now) }

        if req.method == "POST" && req.path == "/status" {
            guard let token = machineToken(req) else { return Self.text(401, "missing token") }
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let machine = body["machine"] as? String else { return Self.text(400, "missing machine") }
            let installed = body["installed"] as? [String: String]
            let health = body["health"] as? [String: String]
            let defaults = body["automatic_default"] as? [String: Bool]
            if let refusal = Self.reportRefusal(installed: installed, health: health, defaults: defaults) {
                return Self.text(400, refusal)
            }
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                // Counted only for the Mac the token proves: a limit keyed on a machine id the
                // body names, before the token is checked, would let anything on the tailnet
                // silence a Mac's reports by sending them with its id.
                guard reportLimiter.allow(machine) else { return Self.text(429, "this Mac is reporting too often; try again in a minute") }
                var ms = state.machines[machine]!
                if let installed { ms.installed = installed }
                if let health { ms.health = health }
                if let defaults { ms.automaticDefault = defaults }
                ms.lastSeen = ISO.string(Date())
                state.machines[machine] = ms
                return Self.ok
            }
        }
        if req.method == "GET" && req.path == "/commands" {
            guard let machine = req.query["machine"] else { return Self.text(400, "missing machine") }
            guard let token = machineToken(req) else { return Self.text(401, "missing token") }
            guard let commandKey else {
                return Self.text(503, "this publisher has no signing key, so it will not send orders: start `khu serve` with --key")
            }
            // Read-only: an order stays pending until its result is reported.
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                var ms = state.machines[machine]!
                // Record the capabilities this agent advertised, so the status page can warn when
                // a pending rollback order cannot be delivered to an older agent.
                let capabilities = Set((req.query["capabilities"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                ms.capabilities = Array(capabilities)
                state.machines[machine] = ms
                // A rollback order is withheld from an agent that does not say it understands one:
                // an older agent would carry the same order out as an update.
                let deliverable = ms.pending.filter {
                    $0.action == ServerCommand.update || capabilities.contains(AgentCapability.ownerRollback)
                }
                // Signed with the key every agent is pinned to, and naming this Mac and the moment
                // it was made: a forged or replayed reply is refused at the Mac.
                let body = JSON.encode(CommandsReply(machine: machine, commands: deliverable, automatic: ms.automatic), pretty: false)
                guard let signature = try? Signing.sign(body, with: commandKey) else {
                    return Self.text(500, "could not sign the orders")
                }
                return HTTPResponse(200, "application/json", data: JSON.encode(SignedReply(reply: body, signature: signature), pretty: false))
            }
        }
        if req.method == "POST" && (req.path.hasPrefix("/commands/") || req.path.hasPrefix("/automatic/")) && req.path.hasSuffix("/result") {
            let automatic = req.path.hasPrefix("/automatic/")
            let prefix = automatic ? "/automatic/" : "/commands/"
            let id = String(req.path.dropFirst(prefix.count).dropLast("/result".count))
            guard !id.isEmpty, !id.contains("/") else { return Self.text(404, "not found") }
            // An id is stored with its result and comes out of the path. 404, not 400: the agent
            // reads that as an order the publisher no longer has, which is the truthful answer for
            // an id this publisher would never have issued.
            guard id.utf8.count <= ReportPolicy.maxCommandIdCharacters else { return Self.text(404, "not found") }
            guard let token = machineToken(req) else { return Self.text(401, "missing token") }
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let machine = body["machine"] as? String else { return Self.text(400, "missing machine") }
            let status = body["status"] as? String ?? ""
            let reason = body["reason"] as? String
            // `status` and `reason` are rendered on the owner's page, and both are the reporting
            // Mac's own words: a bounded sentence, not a place to grow state.json.
            guard status.utf8.count <= ReportPolicy.maxStatusCharacters,
                  (reason?.utf8.count ?? 0) <= ReportPolicy.maxReasonCharacters else {
                return Self.text(400, "that result's status or reason is too long")
            }
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                // As on /status: counted for the Mac the token proves, never for a name the body
                // chose.
                guard reportLimiter.allow(machine) else { return Self.text(429, "this Mac is reporting too often; try again in a minute") }
                var ms = state.machines[machine]!
                let result = CommandResult(commandId: id, status: status, reason: reason)
                let named = (body["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var all = ms.lastResults ?? [:]
                // An order is looked up by id for this Mac, and it is the order — never the body —
                // that decides which app the result belongs to and whether anything is cleared. A
                // body naming another app cannot acknowledge an order that was never carried out.
                if !automatic {
                    guard let order = ms.pending.first(where: { $0.id == id && $0.machine == machine }) else {
                        return Self.text(404, "no order \(id) is pending for \(machine)")
                    }
                    guard named == order.app else {
                        return Self.text(400, "order \(id) is for \(order.app), not \(named ?? "a named app")")
                    }
                    all[order.app] = result
                    ms.pending.removeAll { $0.id == id }  // the acknowledgement
                } else {
                    // Automatic reports have their own route and never acknowledge pending orders.
                    // The Mac mints its own `auto-` ids, so there is no stored order to match one
                    // by; what bounds this map instead is the number of apps it may hold, below.
                    guard id.hasPrefix("auto-"), let named else { return Self.text(400, "an automatic result needs an auto id and app") }
                    guard (try? SafeName.component(named, what: "app")) != nil else {
                        return Self.text(404, "that app name is not one this publisher accepts")
                    }
                    all[named] = result
                }
                // One result per app — the map is keyed by app — and at most `maxApps` apps. A Mac
                // that keeps naming new ones evicts the oldest rather than growing the file for
                // ever; with `installed`, `health` and the value bounds capped at the same figure,
                // everything a Mac can write has a size that does not depend on how long it runs.
                if all.count > ReportPolicy.maxApps {
                    let oldest = all.min { ($0.value.at, $0.key) < ($1.value.at, $1.key) }?.key
                    if let oldest { all.removeValue(forKey: oldest) }
                }
                ms.lastResult = result
                ms.lastResults = all
                state.machines[machine] = ms
                return Self.ok
            }
        }

        // The owner's page and buttons: this Mac only, under its own name, from its own page.
        if req.path == "/" || req.path.hasPrefix("/api/") {
            guard ServerDecision.ownerRouteAllowed(remote: remote), OwnerAccess.isAllowedHost(req.headers["host"], port: port) else {
                return Self.text(403, "forbidden")
            }
            if req.method == "GET" && req.path == "/" {
                // The page's countdown is the one script it runs, allowed by this nonce alone: the
                // CSP stays `default-src 'none'` with no 'unsafe-inline' for scripts.
                let nonce = Enrolment.randomBase64(bytes: 16)
                var page = HTTPResponse(200, "text/html; charset=utf-8", statusHTML(nonce: nonce))
                page.headers = ["Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; form-action 'self'; frame-ancestors 'none'",
                                "X-Frame-Options": "DENY", "Referrer-Policy": "same-origin"]
                return page
            }
            if req.method == "POST" && (req.path == "/api/request-update" || req.path == "/api/request-rollback"
                                        || req.path == "/api/automatic" || req.path == "/api/enrol-window"
                                        || req.path == "/api/remove-machine") {
                guard OwnerAccess.isSameSite(req.headers, port: port) else { return Self.text(403, "cross-site request refused") }
                let f = OwnerAccess.fields(req)
                let response = transact { state -> HTTPResponse in
                    // Opening and closing the window, and removing a Mac, are decisions about this
                    // publisher rather than about one app on one Mac.
                    if req.path == "/api/enrol-window" {
                        guard let text = f["minutes"], let minutes = Int(text) else {
                            return Self.text(400, "send minutes: 0 closes the window, 1 to \(EnrolPolicy.maxMinutes) opens one")
                        }
                        if minutes == 0 {
                            // The same close the CLI performs: a window-enrolled record that never
                            // reported goes with it, so the cap is not left full of claims nobody
                            // made good on.
                            state.pruneUnreportedWindowEnrolments()
                            state.enrolWindow = nil
                            return Self.ok
                        }
                        guard (1...EnrolPolicy.maxMinutes).contains(minutes) else {
                            return Self.text(400, "minutes must be 0 (close) or 1 to \(EnrolPolicy.maxMinutes)")
                        }
                        state.pruneUnreportedWindowEnrolments()
                        state.enrolWindow = EnrolWindow.starting(minutes: minutes)
                        return Self.ok
                    }
                    guard let machine = f["machine"], !machine.isEmpty else { return Self.text(400, "send machine") }
                    if req.path == "/api/remove-machine" {
                        guard (try? SafeName.component(machine, what: "machine id")) != nil else {
                            return Self.text(400, "that machine id is not one this publisher accepts")
                        }
                        guard let record = state.machines[machine] else {
                            return Self.text(404, "no enrolled Mac named \(machine)")
                        }
                        // The token hash and the pending orders go with the record; what the Mac
                        // reported stays in the removed list with the moment of the removal.
                        state.removed.append(RemovedMachine(from: record, at: Date()))
                        state.machines.removeValue(forKey: machine)
                        return Self.ok
                    }
                    guard let app = f["app"], !app.isEmpty else { return Self.text(400, "send machine and app") }
                    guard var ms = state.machines[machine], ms.tokenHash != nil else {
                        return Self.text(404, "no enrolled Mac named \(machine)")
                    }
                    if req.path == "/api/automatic" {
                        ms.automatic[app] = f["on"] == "true"
                    } else {
                        let action = req.path == "/api/request-rollback" ? ServerCommand.rollback : ServerCommand.update
                        if !ms.pending.contains(where: { $0.app == app && $0.action == action }) {
                            ms.pending.append(ServerCommand(machine: machine, app: app, action: action))
                        }
                    }
                    state.machines[machine] = ms
                    return Self.ok
                }
                // The page's own buttons post a form: send the owner back to the page.
                if response.status == 200, (req.headers["content-type"] ?? "").hasPrefix("application/x-www-form-urlencoded") {
                    var back = HTTPResponse(303, "text/plain; charset=utf-8", "")
                    back.headers = ["Location": "/"]
                    return back
                }
                return response
            }
        }
        return Self.text(404, "not found")
    }

    /// The owner's page. `nonce` allows the one script that ticks the enrolment countdown; without
    /// one (a caller that only wants the markup) the server-rendered minutes stand on their own.
    public func statusHTML(nonce: String = "") -> String {
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let state: ServerState
        do { state = try StateStore.read(in: stateDir) } catch {
            return "<!doctype html><meta charset=utf-8><title>KH Updater</title><h1>KH Updater</h1>"
                + "<p><b>The state file cannot be read</b>: \(h("\(error)")). It was left untouched.</p>"
        }
        let feed = FeedPublisher.loadFeed(from: feedDir)
        func form(_ action: String, _ machine: String, _ app: String, _ extra: String, _ label: String) -> String {
            "<form method=post action=\(action)><input type=hidden name=machine value=\"\(h(machine))\"><input type=hidden name=app value=\"\(h(app))\">\(extra)<button>\(label)</button></form>"
        }
        let clock = DateFormatter()
        clock.dateFormat = "yyyy-MM-dd HH:mm"
        func stamp(_ iso: String?) -> String { iso.flatMap(ISO.date).map { clock.string(from: $0) } ?? (iso ?? "") }
        func form(_ action: String, _ fields: [String: String], _ label: String) -> String {
            let inputs = fields.sorted { $0.key < $1.key }
                .map { "<input type=hidden name=\"\(h($0.key))\" value=\"\(h($0.value))\">" }.joined()
            return "<form method=post action=\(action)>\(inputs)<button>\(label)</button></form>"
        }

        // The enrolment window, its countdown, and how many of the window's allowance are used.
        let window = state.enrolWindow
        let isOpen = window?.isOpen() ?? false
        let openForm = "<form method=post action=/api/enrol-window><input type=number name=minutes value=\(EnrolPolicy.defaultMinutes) min=1 max=\(EnrolPolicy.maxMinutes) size=4><button>Open an enrolment window for that many minutes</button></form>"
        var enrol = "<h2>Network enrolment</h2>"
        var countdown = ""
        if let window, isOpen {
            let seconds = Int(window.remaining())
            let endUnix = window.untilDate.map { Int($0.timeIntervalSince1970) } ?? 0
            enrol += "<p><b>Open</b> until \(h(stamp(window.until))), <span id=left data-until=\"\(endUnix)\">\(seconds / 60) min \(seconds % 60) s</span> left"
                + " — \(window.enrolled) of \(maxEnrolmentsPerWindow) new Macs enrolled in this window. A Mac that is not enrolled yet may claim a token for itself.</p>"
                + form("/api/enrol-window", ["minutes": "0"], "Close the window now")
            countdown = "<script nonce=\"\(h(nonce))\">var e=document.getElementById('left'),u=Number(e.getAttribute('data-until'));"
                + "function t(){var s=Math.round(u-Date.now()/1000);e.textContent=s<=0?'closing now':Math.floor(s/60)+' min '+(s%60)+' s'}"
                + "t();setInterval(t,1000)</script>"
        } else if let window {
            enrol += "<p><b>Closed</b>: the window that ended \(h(stamp(window.until))) is over, so the publisher is not taking new Macs. It enrolled \(window.enrolled) of \(maxEnrolmentsPerWindow).</p>\(openForm)"
        } else {
            enrol += "<p><b>Closed</b>: no Mac can enrol itself. Open a window to let a Mac that is not enrolled yet claim a token for itself.</p>\(openForm)"
        }
        // Only rendered when a nonce allows it; the minutes above are the no-script answer.
        let script = isOpen && !nonce.isEmpty ? countdown : ""

        var rows = ""
        for machine in state.machines.keys.sorted() {
            guard let ms = state.machines[machine], ms.tokenHash != nil else { continue }
            let apps = Set(ms.installed.keys).union(feed?.apps.keys.map { $0 } ?? []).sorted()
            for app in apps {
                let installed = ms.installed[app] ?? "not installed"
                let latest = feed?.apps[app]?.version ?? "—"
                let hasPendingRollback = ms.pending.contains { $0.app == app && $0.action == ServerCommand.rollback }
                let agentTooOld = hasPendingRollback && ms.capabilities != nil && !(ms.capabilities?.contains(AgentCapability.ownerRollback) ?? false)
                let pending = ms.pending.contains { $0.app == app } ? (agentTooOld ? "waiting for the Mac (agent too old for rollback)" : "waiting for the Mac") : ""
                let last = ms.lastResults?[app].map { "\($0.status)\($0.reason.map { $0.isEmpty ? "" : ": " + $0 } ?? "") (\($0.at))" } ?? ""
                let ownUpdater = app == "story" || app == "hub"
                let auto = ms.effectiveAutomatic(app)
                let update = ownUpdater || feed?.apps[app] == nil ? "" : form("/api/request-update", machine, app, "", "Update")
                // Rollback needs no feed entry: it puts back the version this Mac kept.
                let rollback = ownUpdater ? "" : form("/api/request-rollback", machine, app, "", "Roll back")
                let automatic = ownUpdater || feed?.apps[app] == nil ? "" :
                    form("/api/automatic", machine, app, "<input type=hidden name=on value=\(auto ? "false" : "true")>", auto ? "Automatic: on" : "Automatic: off")
                let note = ownUpdater ? "updated by its own updater" : ""
                rows += "<tr><td>\(h(machine))</td><td>\(h(app))</td><td>\(h(installed))</td><td>\(h(latest))</td><td>\(h(ms.health[app] ?? ""))</td><td>\(h(ms.lastSeen ?? "never"))</td><td>\(h(pending))</td><td>\(h(last))</td><td>\(update)\(rollback)\(h(note))</td><td>\(automatic)</td></tr>"
            }
        }

        // Which Macs enrolled themselves, when — the owner's review list — and how to remove one.
        var macRows = ""
        var windowRows = 0
        for machine in state.machines.keys.sorted() {
            guard let ms = state.machines[machine], ms.tokenHash != nil else { continue }
            let via = ms.enrolmentSource == MachineState.windowSource ? "a window" : "the publisher"
            if ms.enrolmentSource == MachineState.windowSource { windowRows += 1 }
            macRows += "<tr><td>\(h(machine))</td><td>\(h(via))</td><td>\(h(stamp(ms.enrolledAt)))</td><td>\(h(ms.lastSeen.map(stamp) ?? "never"))</td><td>\(ms.pending.count)</td>"
                + "<td>\(form("/api/remove-machine", ["machine": machine], "Remove Mac"))</td></tr>"
        }
        let macs = macRows.isEmpty ? "<p>No Mac is enrolled.</p>"
            : "<table><tr><th>Mac</th><th>Enrolled via</th><th>Enrolled</th><th>Last seen</th><th>Orders waiting</th><th></th></tr>\(macRows)</table>"
        var removedRows = ""
        for removal in state.removed.sorted(by: { $0.removedAt > $1.removedAt }) {
            let live = state.machines[removal.machine] != nil ? "enrolled again since" : "not enrolled"
            removedRows += "<tr><td>\(h(removal.machine))</td><td>\(h(stamp(removal.removedAt)))</td><td>\(h(stamp(removal.lastSeen)))</td><td>\(h(live))</td></tr>"
        }
        let removed = state.removed.isEmpty ? "<p>No Mac has been removed.</p>"
            : "<table><tr><th>Mac</th><th>Removed</th><th>Last seen then</th><th>Now</th></tr>\(removedRows)</table>"
        return """
        <!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=30><title>KH Updater</title>
        <style>body{font:14px -apple-system,sans-serif;margin:24px}table{border-collapse:collapse}td,th{border-bottom:1px solid #ddd;padding:6px 10px;text-align:left}form{display:inline}input[type=number]{width:5em}</style></head>
        <body><h1>KH Updater</h1><p>Every Mac and app, refreshed every 30 s. Update installs the feed's version on that Mac; Roll back puts the version that Mac kept back in place; Automatic does it whenever the feed is newer; Remove Mac drops a Mac's token and its waiting orders, and that Mac enrols again through an open window.</p>
        \(enrol)\(script)
        <h2>Macs enrolled\(windowRows > 0 ? " (\(windowRows) through a window)" : "")</h2>\(macs)
        <h2>Macs removed</h2>\(removed)
        <h2>Apps</h2>
        <table><tr><th>Mac</th><th>App</th><th>Installed</th><th>Feed</th><th>Health</th><th>Last seen</th><th>Pending</th><th>Last result</th><th></th><th></th></tr>\(rows)</table></body></html>
        """
    }

    /// Bind and listen; returns the listening socket (port 0 picks a free port: see `boundPort`).
    public func listen() throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)  // a client that disconnects mid-download must not kill the server
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw khuFail("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        if bind == "0.0.0.0" {
            addr.sin_addr.s_addr = INADDR_ANY
        } else if inet_pton(AF_INET, bind, &addr.sin_addr) != 1 {
            close(fd); throw khuFail("\(bind) is not an IPv4 address")
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw khuFail("cannot listen on \(bind):\(port) (errno \(errno))") }
        guard Darwin.listen(fd, 64) == 0 else { close(fd); throw khuFail("listen failed on \(bind):\(port)") }
        return fd
    }

    public static func boundPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    public func serve() throws { try serve(on: listen()) }

    /// Each connection on its own thread (at most `maxConnections` at once), with a total read
    /// deadline and a send timeout: one slow or stalled client never holds up the other Macs.
    public func serve(on fd: Int32) throws {
        let slots = DispatchSemaphore(value: maxConnections)
        while true {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if cfd < 0 { if errno == EBADF { return }; continue }
            var yes: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            let remote = String(cString: inet_ntoa(clientAddr.sin_addr))
            guard slots.wait(timeout: .now()) == .success else {
                HTTP.send(cfd, Self.text(503, "busy"))
                close(cfd)
                continue
            }
            Thread.detachNewThread { [self] in
                defer { close(cfd); slots.signal() }
                guard let data = HTTP.readRequest(from: cfd), let req = HTTP.parse(data) else {
                    HTTP.send(cfd, Self.text(400, "bad request"))
                    return
                }
                HTTP.send(cfd, handleRequest(req, remote: remote))
            }
        }
    }
}

extension HTTPResponse {
    public init(status: Int, contentType: String, body: HTTPBody) {
        self.status = status; self.contentType = contentType; self.body = body
    }
}
