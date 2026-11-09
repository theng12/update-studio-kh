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
    public let publisherBind: String?
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
    public let feedOnly: Bool
    private let enrolLimiter: RateLimiter
    private let reportLimiter: RateLimiter

    public init(feedDir: URL, stateDir: URL, bind: String, port: Int,
                commandKey: Curve25519.Signing.PrivateKey? = nil, maxConnections: Int = 32,
                maxEnrolmentsPerWindow: Int = EnrolPolicy.maxPerWindow,
                enrolAttemptsPerMinute: Int = EnrolPolicy.attemptsPerMinute,
                reportPostsPerMinute: Int = ReportPolicy.perMachinePerMinute, publisherBind: String? = nil, feedOnly: Bool = false) {
        self.feedDir = feedDir
        self.stateDir = stateDir
        self.bind = bind
        self.port = port
        self.publisherBind = (publisherBind ?? (Self.isTailnet(bind) ? bind : nil)).flatMap { Self.isTailnet($0) ? $0 : nil }
        self.commandKey = commandKey
        self.maxConnections = maxConnections
        self.maxEnrolmentsPerWindow = maxEnrolmentsPerWindow
        self.enrolAttemptsPerMinute = enrolAttemptsPerMinute
        self.reportPostsPerMinute = reportPostsPerMinute
        self.feedOnly = feedOnly
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

    /// What a `GET /commands` request says it can carry out. `absent` and `named([])` are different:
    /// a request that never names the parameter (the Hub's token probe) must not edit the record,
    /// while an agent that names an empty list is telling the publisher it can do nothing special.
    enum Capabilities: Equatable {
        case absent
        case refused(String)
        case named([String])
    }

    /// Bounded like everything else a Mac may write: the list is stored on its record, so a query
    /// string is not a place to put a paragraph or ten thousand names.
    static func parsedCapabilities(_ raw: String?) -> Capabilities {
        guard let raw else { return .absent }
        guard raw.utf8.count <= ReportPolicy.maxCapabilitiesQueryBytes else {
            return .refused("that capabilities list is longer than this publisher accepts (\(ReportPolicy.maxCapabilitiesQueryBytes) bytes)")
        }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count <= ReportPolicy.maxCapabilities else {
            return .refused("that Mac named more capabilities than this publisher accepts (at most \(ReportPolicy.maxCapabilities))")
        }
        guard names.allSatisfy({ $0.utf8.count <= ReportPolicy.maxCapabilityCharacters }) else {
            return .refused("a capability name is longer than this publisher accepts (\(ReportPolicy.maxCapabilityCharacters) characters)")
        }
        return .named(Array(Set(names)).sorted())
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

    /// `POST /enrol` — a Mac claiming a token for itself, with the pairing code or (sending none)
    /// while the owner has a window open, which is how Hub's bootstrap does it. Every refusal is a
    /// plain sentence and leaves the state exactly as it was, except that a wrong code is counted.
    func enrol(_ req: HTTPRequest, remote: String, now: Date = Date()) -> HTTPResponse {
        // This is the one route with no token, so it is the one a web page could reach: a
        // `text/plain` POST is a "simple request" that a browser sends cross-site without a
        // preflight, and spending the owner's enrolment window would be the whole effect. Browsers
        // send Origin (and usually Referer); a Mac's own agent sends neither, so a request that
        // carries one is refused before its body is touched — and before it counts against the
        // address's allowance, so a page the owner visits cannot use up a Mac's attempts.
        guard req.headers["origin"] == nil, req.headers["referer"] == nil else {
            return Self.text(403, "a web page cannot enrol a Mac: this route is for a Mac's own agent, which sends no Origin or Referer")
        }
        guard enrolLimiter.allow(remote, now: now) else {
            return Self.text(429, "too many enrolment requests from this address; wait a minute and try again")
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
            var window: EnrolWindow?
            if let sent = object["code"] {
                guard var pairing = state.pairing else {
                    return Self.text(403, "this publisher has no pairing code yet; ask its owner to click New code in Update Studio KH")
                }
                guard !pairing.locked(at: now) else {
                    return Self.text(429, "too many wrong pairing codes; wait \(EnrolPolicy.pairingLockMinutes) minutes and try again")
                }
                guard let typed = sent as? String, pairing.matches(typed) else {
                    pairing.wrongTries += 1
                    let left = EnrolPolicy.pairingWrongTries - pairing.wrongTries
                    if left <= 0 {
                        pairing.wrongTries = 0
                        pairing.lockedUntil = ISO.string(now.addingTimeInterval(Double(EnrolPolicy.pairingLockMinutes) * 60))
                    }
                    state.pairing = pairing
                    return left <= 0
                        ? Self.text(429, "that pairing code is wrong, and that was the last try: wait \(EnrolPolicy.pairingLockMinutes) minutes and try again")
                        : Self.text(403, "that pairing code is wrong; check the code shown in Update Studio KH (\(left) \(left == 1 ? "try" : "tries") left before a \(EnrolPolicy.pairingLockMinutes)-minute lock)")
                }
                pairing.wrongTries = 0
                pairing.lockedUntil = nil
                state.pairing = pairing
            } else {
                guard let open = state.enrolWindow, open.isOpen(at: now) else {
                    return Self.text(403, "this publisher needs a pairing code to take a new Mac, or an open enrolment window; ask its owner")
                }
                window = open
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
                (record.enrolmentSource == MachineState.windowSource || record.enrolmentSource == MachineState.pairingSource)
                    && record.lastSeen == nil && record.enrolNonceHash == Enrolment.sha256Hex(nonce)
            } ?? false
            guard state.machines[machine] == nil || retry else {
                return Self.text(409, "This Mac's name is already in use. If this Mac was reset, remove it in Update Studio (Remove Mac), then connect again.")
            }
            // A resend is the same enrolment, not a second one: it must not spend another slot.
            guard retry || window.map({ $0.enrolled < maxEnrolmentsPerWindow }) ?? true else {
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
            Enrolment.store(token, for: machine, at: now, source: window == nil ? MachineState.pairingSource : MachineState.windowSource,
                            nonce: nonce, in: &state)
            if !retry, let window { state.enrolWindow?.enrolled = window.enrolled + 1 }
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

        if feedOnly { return Self.text(404, "this host serves signed updates only") }

        // A Mac enrolling itself: the one route with no token, refused by the checks inside `enrol`.
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
            let builds = body["installed_build"] as? [String: String]
            let executableHashes = body["installed_executable_sha256"] as? [String: String]
            for field in ["installed_build", "installed_executable_sha256"] {
                if body[field] != nil && body[field] as? [String: String] == nil {
                    return Self.text(400, "\(field) must be a map of app names to strings")
                }
            }
            for values in [builds, executableHashes] {
                if let refusal = Self.reportRefusal(installed: values, health: nil, defaults: nil) {
                    return Self.text(400, refusal)
                }
            }
            guard builds?.values.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil }) ?? true else {
                return Self.text(400, "an installed build must be one nonempty bounded line")
            }
            guard executableHashes?.values.allSatisfy({ value in
                value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }) ?? true else {
                return Self.text(400, "an installed executable SHA-256 must be 64 lowercase hexadecimal characters")
            }
            // The Mac's menu switches, each with its time; bounded like everything else it reports.
            let local = (body["automatic_local"] as? [String: [String: Any]] ?? [:]).compactMapValues { v -> (Bool, Date)? in
                guard let on = v["on"] as? Bool, let at = (v["at"] as? String).flatMap(ISO.date) else { return nil }
                return (on, at)
            }
            guard local.count <= ReportPolicy.maxApps, local.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= ReportPolicy.maxNameCharacters }) else {
                return Self.text(400, "that Mac reported more Automatic switches, or longer app names, than this publisher accepts (at most \(ReportPolicy.maxApps) apps, \(ReportPolicy.maxNameCharacters) characters for a name)")
            }
            let inventory = MacInventory.read(body["inventory"])
            if case .refused(let reason) = inventory { return Self.text(400, reason) }
            let reportedName = body["display_name"] as? String
            if let reportedName, !MacName.valid(reportedName) {
                return Self.text(400, "send a valid Mac name (at most \(MacName.maxCharacters) characters)")
            }
            let pausedUntil = (body["paused_until"] as? String).flatMap(ISO.date).map(ISO.string)
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                // Counted only for the Mac the token proves: a limit keyed on a machine id the
                // body names, before the token is checked, would let anything on the tailnet
                // silence a Mac's reports by sending them with its id.
                guard reportLimiter.allow(machine) else { return Self.text(429, "this Mac is reporting too often; try again in a minute") }
                var ms = state.machines[machine]!
                if let reportedName { ms.report(name: reportedName) }
                if case .accepted(let reportedInventory) = inventory { ms.inventory = reportedInventory }
                if let installed { ms.installed = installed }
                // Missing identity on a newer report is unknown, never a stale previous match.
                ms.installedBuild = builds
                ms.installedExecutableSha256 = executableHashes
                if let health { ms.health = health }
                if let defaults { ms.automaticDefault = defaults }
                // Whichever change is later wins: a switch on the Mac, or the page's.
                for (app, (on, at)) in local where ms.automaticSet?[app].flatMap({ ISO.date($0.at) }).map({ at > $0 }) ?? true {
                    ms.automatic[app] = on
                    ms.automaticSet = (ms.automaticSet ?? [:]).merging([app: AutomaticChange(at: ISO.string(at), byMac: true)]) { _, new in new }
                }
                ms.pausedUntil = pausedUntil
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
            let advertised = Self.parsedCapabilities(req.query["capabilities"])
            if case .refused(let message) = advertised { return Self.text(400, message) }
            // Read-only: an order stays pending until its result is reported.
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                // Counted for the Mac the token proves, like every other report route: this request
                // rewrites the Mac's record (its capabilities) and so holds the one state lock.
                guard reportLimiter.allow(machine) else { return Self.text(429, "this Mac is asking too often; try again in a minute") }
                var ms = state.machines[machine]!
                // Record the capabilities this agent advertised, so the status page can warn when
                // a pending rollback order cannot be delivered to an older agent. A request that
                // does not name them changes NOTHING: the Hub asks this route with a stored token
                // to learn whether the publisher still honours it, and a probe must never edit the
                // record it is asking about.
                let names: Set<String>
                if case .named(let list) = advertised {
                    names = Set(list)
                    ms.capabilities = list
                    state.machines[machine] = ms
                } else {
                    names = []
                }
                // A rollback order is withheld from an agent that does not say it understands one:
                // an older agent would carry the same order out as an update.
                let deliverable = ms.pending.filter {
                    switch $0.action {
                    case ServerCommand.update: return true
                    case ServerCommand.rollback: return names.contains(AgentCapability.ownerRollback)
                    case ServerCommand.vendorInstall:
                        guard names.contains(AgentCapability.vendorInstall), let payload = $0.vendor,
                              ms.vendorAssignments?[payload.entry.id] == true,
                              let catalog = try? VendorCatalog.load(from: VendorCatalog.url(in: stateDir.path)),
                              let preferences = try? VendorPreferences.load(stateDir),
                              !preferences.retired.contains(payload.entry.id),
                              payload.byteCap == preferences.byteCap,
                              var current = catalog.entries.first(where: { $0.id == payload.entry.id }) else { return false }
                        current.enabled = true
                        return current == payload.entry
                    default: return names.contains(AgentCapability.ownerRollback)
                    }
                }
                // Signed with the key every agent is pinned to, and naming this Mac and the moment
                // it was made: a forged or replayed reply is refused at the Mac.
                let body = JSON.encode(CommandsReply(machine: machine, commands: deliverable, automatic: ms.automatic,
                                                       automaticAt: ms.automaticSet?.mapValues(\.at)), pretty: false)
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
                // The page's history: the version the Mac was on when it answered (its status report
                // comes after its results) and what the feed offered then; a rollback offers nothing.
                func remember(_ app: String, rollback: Bool) {
                    let entry = HistoryEntry(app: app, from: ms.installed[app],
                                             to: rollback ? nil : FeedPublisher.loadFeed(from: feedDir)?.apps[app]?.version,
                                             status: status, reason: reason, at: result.at)
                    ms.history = Array(([entry] + (ms.history ?? [])).prefix(HistoryEntry.kept))
                }
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
                    remember(order.app, rollback: order.action == ServerCommand.rollback)
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
                    remember(named, rollback: false)
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
                page.headers = ["Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'",
                                "X-Frame-Options": "DENY", "Referrer-Policy": "same-origin"]
                return page
            }
            if req.method == "POST", ["/api/vendor-edit", "/api/vendor-retire", "/api/vendor-restore", "/api/vendor-assign"].contains(req.path) {
                return vendorRequest(req)
            }
            if req.method == "POST" && (req.path == "/api/request-update" || req.path == "/api/request-rollback"
                                        || req.path == "/api/automatic" || req.path == "/api/enrol-window"
                                        || req.path == "/api/remove-machine" || req.path == "/api/update-all"
                                        || req.path == "/api/pairing-code" || req.path == "/api/rename-machine"
                                        || req.path == "/api/mac-metadata") {
                guard OwnerAccess.isSameSite(req.headers, port: port) else { return Self.text(403, "cross-site request refused") }
                let f = OwnerAccess.fields(req)
                var createdOrders = 0
                let response = transact { state -> HTTPResponse in
                    // Opening and closing the window, and removing a Mac, are decisions about this
                    // publisher rather than about one app on one Mac.
                    if req.path == "/api/enrol-window" {
                        guard let text = f["minutes"], let minutes = Int(text) else {
                            return Self.text(400, "send minutes: 0 closes the window, 1 to \(EnrolPolicy.maxMinutes) opens one")
                        }
                        if minutes == 0 {
                            // Closing drops the window and nothing else: a Mac that enrolled
                            // through it may not have run its agent yet, and its token has to keep
                            // working. Only a new window (after the abandonment age) prunes.
                            state.enrolWindow = nil
                            return Self.ok
                        }
                        guard (1...EnrolPolicy.maxMinutes).contains(minutes) else {
                            return Self.text(400, "minutes must be 0 (close) or 1 to \(EnrolPolicy.maxMinutes)")
                        }
                        state.pruneAbandonedWindowEnrolments()
                        state.enrolWindow = EnrolWindow.starting(minutes: minutes)
                        return Self.ok
                    }
                    if req.path == "/api/pairing-code" {
                        state.pairing = PairingCode.fresh(replacing: state.pairing?.code)
                        return Self.ok
                    }
                    if req.path == "/api/update-all" {
                        // Update every connected Mac whose copy of this app is behind the feed: the
                        // same Macs the page counts as "Update available" for it.
                        guard let app = f["app"], !app.isEmpty else { return Self.text(400, "send app") }
                        let feed = FeedPublisher.loadFeed(from: feedDir)
                        for (machine, var ms) in state.machines where Self.updateAvailable(ms, app: app, feed: feed, now: Date()) {
                            ms.pending.append(ServerCommand(machine: machine, app: app, action: ServerCommand.update))
                            createdOrders += 1
                            state.machines[machine] = ms
                        }
                        return Self.ok
                    }
                    guard let machine = f["machine"], !machine.isEmpty else { return Self.text(400, "send machine") }
                    if req.path == "/api/mac-metadata" {
                        let site = (f["site"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let tags = (f["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        guard site.count <= 128, tags.count <= 20, tags.allSatisfy({ $0.count <= 64 }),
                              ([site] + tags).allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                            return Self.text(400, "Use a site up to 128 characters and at most 20 tags, each up to 64 characters; no control characters.")
                        }
                        guard var ms = state.machines[machine], ms.tokenHash != nil else { return Self.text(404, "no enrolled Mac") }
                        ms.site = site
                        ms.tags = Array(Set(tags)).sorted()
                        state.machines[machine] = ms
                        return Self.ok
                    }
                    if req.path == "/api/rename-machine" {
                        guard let name = f["name"], MacName.valid(name) else {
                            return Self.text(400, "send a valid Mac name (at most \(MacName.maxCharacters) characters)")
                        }
                        guard var ms = state.machines[machine], ms.tokenHash != nil else { return Self.text(404, "no enrolled Mac") }
                        ms.rename(to: name)
                        state.machines[machine] = ms
                        return Self.ok
                    }
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
                        ms.automaticSet = (ms.automaticSet ?? [:]).merging([app: AutomaticChange(at: ISO.string(Date()), byMac: false)]) { _, new in new }
                    } else {
                        let action = req.path == "/api/request-rollback" ? ServerCommand.rollback : ServerCommand.update
                        if !ms.pending.contains(where: { $0.app == app && $0.action == action }) {
                            ms.pending.append(ServerCommand(machine: machine, app: app, action: action))
                            createdOrders += 1
                        }
                    }
                    state.machines[machine] = ms
                    return Self.ok
                }
                if response.status == 200, createdOrders > 0 {
                    let audit: [String: Any] = ["at": ISO.string(Date()), "path": req.path,
                                               "app": f["app"] ?? "", "created": createdOrders, "source": "owner-page"]
                    if let data = try? JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys]) {
                        FileHandle.standardError.write(Data("order-provenance ".utf8) + data + Data("\n".utf8))
                    }
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
            return "<!doctype html><meta charset=utf-8><title>Update Studio KH</title><h1>Update Studio KH</h1>"
                + "<p><b>The state file cannot be read</b>: \(h("\(error)")). It was left untouched.</p>"
        }
        let feed = FeedPublisher.loadFeed(from: feedDir)
        func form(_ action: String, _ machine: String, _ app: String, _ extra: String, _ label: String, _ style: String, confirm: String = "") -> String {
            "<form method=post action=\(action)\(confirm.isEmpty ? "" : " data-confirm=\"\(h(confirm))\"")><input type=hidden name=machine value=\"\(h(machine))\"><input type=hidden name=app value=\"\(h(app))\">\(extra)<button class=\"\(style)\">\(label)</button></form>"
        }
        let clock = DateFormatter()
        clock.dateFormat = "yyyy-MM-dd HH:mm"
        func stamp(_ iso: String?) -> String { iso.flatMap(ISO.date).map { clock.string(from: $0) } ?? (iso ?? "") }
        func form(_ action: String, _ fields: [String: String], _ label: String) -> String {
            let inputs = fields.sorted { $0.key < $1.key }
                .map { "<input type=hidden name=\"\(h($0.key))\" value=\"\(h($0.value))\">" }.joined()
            return "<form method=post action=\(action)>\(inputs)<button>\(label)</button></form>"
        }

        let now = Date()
        let joinedFormat = DateFormatter()
        joinedFormat.dateFormat = "d MMM, HH:mm"
        func ago(_ iso: String?) -> String {
            guard let date = iso.flatMap(ISO.date) else { return "never" }
            let s = Int(now.timeIntervalSince(date))
            if s < 60 { return "just now" }
            if s < 3600 { return "\(s / 60) min ago" }
            if s < 86_400 { return "\(s / 3600) h ago" }
            return stamp(iso)
        }
        func name(_ app: String) -> String { AppNames.display(app) }
        func words(_ status: String) -> String { let s = status.replacingOccurrences(of: "_", with: " "); return s.prefix(1).uppercased() + s.dropFirst() }

        // The enrolment window: its state, its countdown, and how much of its allowance is used.
        let window = state.enrolWindow
        let isOpen = window?.isOpen() ?? false
        var enrol = ""
        var leftText = ""
        if let window, isOpen {
            let seconds = Int(window.remaining())
            let endUnix = window.untilDate.map { Int($0.timeIntervalSince1970) } ?? 0
            leftText = "<span id=left data-until=\"\(endUnix)\">\(seconds / 60) min \(seconds % 60) s</span>"
            // Only a window opened with `khu enrol-window` gets here; the page shows it and can stop it.
            enrol = "<p><span class=\"dot ok\"></span><b>Open</b>: new Macs can connect without a code until \(h(stamp(window.until))), \(leftText) left"
                + " — \(window.enrolled) of \(maxEnrolmentsPerWindow) new Macs enrolled in this window. A Mac that is not enrolled yet may claim a token for itself.</p>"
                + form("/api/enrol-window", ["minutes": "0"], "Stop allowing new Macs")
        }

        // Every Mac, one compact row each, problems first. Each app has exactly one state, and
        // nothing the publisher cannot vouch for reads as fine.
        struct MacRow { var rank: Int; var name: String; var html: String; var state: String }
        var macRows: [MacRow] = []
        var total = 0, connected = 0, upToDate = 0, needUpdate = 0, updates = 0, requested = 0, failedMacs = 0, offline = 0
        var joined: [String] = []
        for machine in state.machines.keys.sorted() {
            guard let ms = state.machines[machine], ms.tokenHash != nil else { continue }
            total += 1
            let label = ms.name
            let duplicate = state.machines.values.filter { $0.tokenHash != nil && $0.name == label }.count > 1
            if isOpen, let window, ms.enrolmentSource == MachineState.windowSource, let at = ms.enrolledAt, at >= window.openedAt {
                joined.append("<li><b>\(h(machine))</b> <span class=sub>\(h(ago(at)))\(ms.lastSeen == nil ? ", has not reported yet" : "")</span></li>")
            }
            let online = Self.isOnline(ms, now: now)
            if online { connected += 1 }
            // What this Mac runs, plus feed apps its own config lists but has not installed yet, plus
            // anything with an order waiting. A Mac that has never reported has only its orders.
            let feedApps = Set(feed?.apps.keys.map { $0 } ?? [])
            let reported = ms.lastSeen == nil ? Set<String>()
                : Set(ms.installed.keys).union(ms.automaticDefault.map { Set($0.keys).intersection(feedApps) } ?? feedApps)
            // Vendor apps report in the Other apps section below; a duplicate row here would read
            // "Not checked · not in feed" and offer feed-style rollback for a vendor journal.
            let apps = reported.union(ms.pending.map(\.app)).filter { !$0.hasPrefix("vendor-") }.sorted { name($0) < name($1) }
            var anyFailed = false, anyUpdating = false, anyUpdate = false
            var chips = "", rows = "", failures = "", failSummary = "", rowUpdate = ""
            for app in apps {
                let installed = ms.installed[app]
                let feedApp = feed?.apps[app]
                let ownUpdater = app == "story" || app == "hub"
                let order = ms.pending.first { $0.app == app }
                // Warn unless there is POSITIVE evidence this agent understands a rollback: a Mac
                // that has advertised nothing at all — every build before the action existed, and
                // anything that has only ever been probed — cannot be assumed capable. So this is
                // "we have no evidence", never "the Mac said it cannot".
                let agentTooOld = order?.action == ServerCommand.rollback && !(ms.capabilities?.contains(AgentCapability.ownerRollback) ?? false)
                let result = ms.lastResults?[app]
                let failed = result.map { Self.failureStatuses.contains($0.status) } ?? false
                let behind = installed.flatMap { i in feedApp.map { VersionCompare.isNewer($0.version, than: i) } } ?? false
                let same = installed.flatMap { i in feedApp.map { VersionCompare.compare(i, $0.version) == 0 } } ?? false
                let st: (String, String)
                if let order {
                    st = order.action == ServerCommand.rollback ? (agentTooOld ? "Rollback requested (agent too old for rollback)" : "Rollback requested", "info") : ("Update requested", "info")
                    anyUpdating = true
                } else if failed { st = ("Failed", "bad"); anyFailed = true }
                else if !online { st = ("Not checked · no report for 10 min", "unknown") }
                else if ownUpdater { st = ("Updates itself", "muted") }
                else if feedApp == nil { st = ("Not checked · not in feed", "unknown") }
                else if installed == nil || behind { st = (installed == nil ? "Not installed" : "Update available", "warn"); anyUpdate = true; updates += 1 }
                else if same { st = ("Up to date", "ok") }
                else { st = ("Newer than feed", "muted") }
                let auto = ms.effectiveAutomatic(app)
                chips += "<span class=\"app t-\(st.1)\">\(h(name(app))) <span class=num>\(h(installed ?? "—"))</span></span>"
                var actions = ""
                if !ownUpdater && feedApp != nil && !same && order == nil {
                    actions += form("/api/request-update", machine, app, "", installed == nil ? "Install" : "Update", "primary small")
                    if online && !failed && rowUpdate.isEmpty { rowUpdate = form("/api/request-update", machine, app, "", "Update \(h(name(app)))", "primary small") }
                }
                // Rollback needs no feed entry: it puts back the version this Mac kept.
                if !ownUpdater {
                    // The version it goes back to is the one the last update replaced, when this page saw it.
                    let kept = ms.history?.first { $0.app == app && ($0.status == "updated" || $0.status == "switched") }?.from
                    actions += form("/api/request-rollback", machine, app, "", "Roll back", "small",
                                    confirm: "Roll back \(name(app)) on \(machine) to \(kept ?? "the version it kept")?")
                }
                if !ownUpdater && feedApp != nil {
                    actions += form("/api/automatic", machine, app, "<input type=hidden name=on value=\(auto ? "false" : "true")>", auto ? "Turn Automatic off" : "Turn Automatic on", "small")
                }
                let health = ms.health[app].flatMap { $0 == "running" ? nil : " <span class=warntext>\(h($0))</span>" } ?? ""
                rows += "<tr><td class=name>\(h(name(app)))</td><td class=num>\(h(installed ?? "—"))\(health)</td><td class=num>\(h(feedApp?.version ?? "—"))</td>"
                    + "<td><span class=\"chip \(st.1)\">\(h(st.0))</span>\(auto && !ownUpdater && feedApp != nil ? " <span class=\"tag on\">Automatic: on</span>" : "")\(ms.automaticSet?[app]?.byMac == true && !ownUpdater ? " <span class=sub>changed on this Mac</span>" : "")</td><td class=actions>\(actions)</td></tr>"
                if failed, let result {
                    if failSummary.isEmpty { failSummary = "\(name(app)): \(words(result.status).lowercased())" }
                    let entry = ms.history?.first { $0.app == app && $0.at == result.at }
                    let back = entry?.from.map { result.status.hasPrefix("rolled_back") || result.status.hasPrefix("rollback") ? "Back on \($0)" : "Was on \($0)" }
                    let tried = entry?.to.map { "tried \($0)" }
                    let report = ["Update Studio KH error report", "Mac: \(machine)", "App: \(name(app)) (\(app))", "Result: \(result.status)",
                                  "Reason: \(result.reason ?? "none given")", "Time: \(stamp(result.at))",
                                  "Versions: \(entry?.from ?? "?") -> \(entry?.to ?? "?")", "Installed now: \(installed ?? "not installed")"].joined(separator: "\n")
                    failures += "<div class=failure><div class=failhead><b>\(h(name(app))) failed: \(h(words(result.status)))</b><span class=sub>\(h(stamp(result.at)))</span></div>"
                        + "<p>\(h(result.reason.flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The Mac gave no reason."))</p>"
                        + "<p class=sub>\(h([back, tried].compactMap { $0 }.joined(separator: ", ")))</p>"
                        + "<button type=button class=copy data-copy=\"\(h(report))\">Copy error report</button></div>"
                }
            }
            if online {
                if anyUpdating { requested += 1 }
                if anyFailed { failedMacs += 1 }
                else if anyUpdate || anyUpdating { needUpdate += 1 }
                else if ms.lastSeen != nil { upToDate += 1 }
            }
            if !online { offline += 1 }
            let overall: (String, String, String, Int)
            if ms.lastSeen == nil { overall = ("Not seen yet", "muted", "offline", 1) }
            else if !online { overall = ("Offline", "muted", "offline", 1) }
            else if anyFailed { overall = ("Failed · \(failSummary)", "bad", "failed", 0) }
            else if anyUpdating { overall = ("Awaiting update result", "info", "updating", 2) }
            else if anyUpdate { overall = ("Update available", "warn", "update", 3) }
            else { overall = ("Up to date", "ok", "ok", 5) }
            let history = (ms.history ?? []).map { e in
                "<tr><td>\(h(name(e.app)))</td><td class=num>\(h(e.from ?? "—")) → \(h(e.to ?? "previous"))</td><td class=num>\(h(stamp(e.at)))</td>"
                    + "<td class=\"\(Self.failureStatuses.contains(e.status) ? "badtext" : "")\">\(h(e.status == "renamed" ? (e.reason ?? "Renamed") : words(e.status)))</td></tr>"
            }.joined()
            let model = ms.inventory?.model_name.map { "<small>\(h($0))</small>" } ?? ""
            let deviceIcon = PublisherFleet.icon(ms.inventory?.model_name ?? ms.inventory?.model_id)
            let seen = ms.lastSeen == nil ? "<span class=\"dot warn\"></span>Never seen"
                : online ? "<span class=\"dot ok\"></span>Online · \(h(ago(ms.lastSeen)))"
                : "<span class=\"dot bad\"></span><span class=badtext>Offline · \(h(ago(ms.lastSeen)))</span>"
            let tags = ms.tags ?? []
            let site = ms.site ?? ""
            let tagsJSON = String(decoding: JSON.encode(tags, pretty: false), as: UTF8.self)
            let metadata = ([site].filter { !$0.isEmpty } + tags).joined(separator: " · ")
            let ownIDs = Set((feed?.apps ?? [:]).filter { AppNames.names[$0.key] != nil }.values.compactMap(\.bundleID))
            let appInventory = PublisherInventory.apps(ms.inventory, ownBundleIDs: ownIDs, h: h)
            let hardware = PublisherInventory.facts(ms.inventory, lastSeen: ms.lastSeen.map { stamp($0) }, h: h)
            let html = "<details class=\"mac s-\(overall.2)\" data-machine=\"\(h(machine))\" data-label=\"\(h(label))\" data-mac=\"\(h((label + " " + machine + " " + metadata).lowercased()))\" data-site=\"\(h(site))\" data-tags=\"\(h(tagsJSON))\" data-rank=\(overall.3) data-state=\(overall.2)><summary>"
                + "<span class=who>\(deviceIcon)<span class=whotext><b>\(h(label))</b>\(duplicate ? "<small>same name</small>" : "")\(model)\(metadata.isEmpty ? "" : "<small>\(h(metadata))</small>")</span></span><span class=apps>\(chips)</span>"
                + "<span class=state>\(overall.0.isEmpty ? "" : "<span class=\"chip \(overall.1)\">\(h(overall.0))</span>")\(rowUpdate)</span><span class=\"seen num\">\(seen)</span><span class=chev aria-hidden=true></span></summary><div class=detail>"
                + "<div class=macsummary>\(deviceIcon)<div><span class=\"chip \(overall.1)\">\(h(overall.0))</span><p class=sub>\(seen)</p></div></div>"
                + failures
                + "<h3>Apps managed by Update Studio</h3>"
                + (rows.isEmpty ? "<p class=sub>No versions yet: they appear after this Mac's first report.</p>"
                   : "<table class=apptable><thead><tr><th>App</th><th>Installed</th><th>Feed</th><th>State</th><th><span class=sr>Actions</span></th></tr></thead>\(rows)</table>")
                + appInventory
                + "<h3>Connection and hardware</h3><dl class=identity><dt>Connection ID</dt><dd><code>\(h(machine))</code><button type=button class=small data-copy=\"\(h(machine))\">Copy ID</button><span class=sub>Stays fixed when this Mac is renamed</span></dd>"
                + "<dt>Name last reported by this Mac</dt><dd>\(h(ms.reportedName ?? "Not reported separately by this helper"))</dd>"
                + "</dl>" + hardware
                + "<p class=sub>The reported name may come from Hub or macOS; this helper does not report its source separately. Changing this page’s label does not change the Mac, its location or its connection ID.</p>"
                + "<form method=post action=/api/rename-machine data-confirm=\"Rename this Mac’s label? Its connection stays the same.\"><input type=hidden name=machine value=\"\(h(machine))\"><label>Mac name <input name=name required maxlength=\(MacName.maxCharacters) value=\"\(h(label))\"></label> <button>Rename</button> <span class=sub>Up to \(MacName.maxCharacters) characters</span></form>"
                + "<form class=metadata method=post action=/api/mac-metadata><input type=hidden name=machine value=\"\(h(machine))\"><label>Location / site<input name=site maxlength=128 value=\"\(h(site))\"></label><label>Tags, separated by commas<input name=tags value=\"\(h(tags.joined(separator: ", ")))\"></label><button>Save site and tags</button><p class=sub>Site: up to 128 characters. Up to 20 tags, each up to 64 characters.</p></form>"
                + "<h3>Recent results</h3>" + (history.isEmpty ? "<p class=sub>No install results yet.</p>"
                   : "<table class=hist><thead><tr><th>App</th><th>From → to</th><th>Time</th><th>Result</th></tr></thead>\(history)</table>")
                + "<div class=macfoot><span class=sub>Connected on \(h(ms.enrolledAt.flatMap(ISO.date).map { joinedFormat.string(from: $0) } ?? "an unknown date"))\(ms.pausedUntil.flatMap(ISO.date).map { $0 > now ? " · Automatic paused on this Mac until \(h(stamp(ms.pausedUntil)))" : "" } ?? "")\(ms.pending.isEmpty ? "" : " · \(ms.pending.count) order\(ms.pending.count == 1 ? "" : "s") waiting")</span>"
                + "<form method=post action=/api/remove-machine data-confirm=\"Remove \(h(machine))? It stops being served until it connects again with the pairing code.\"><input type=hidden name=\"machine\" value=\"\(h(machine))\"><button class=danger>Remove Mac</button></form></div>"
                + "</div></details>"
            macRows.append(MacRow(rank: overall.3, name: label, html: html, state: overall.2))
        }
        macRows.sort { ($0.rank, $0.name) < ($1.rank, $1.name) }
        func count(_ states: Set<String>) -> Int { macRows.filter { states.contains($0.state) }.count }
        let filters = [("all", "All", macRows.count), ("update", "Needs update", count(["update", "updating"])),
                       ("failed", "Failed", count(["failed"])), ("offline", "Offline", count(["offline"]))]
            .map { "<button type=button class=filter data-f=\($0.0) aria-pressed=\($0.0 == "all" ? "true" : "false")>\($0.1) <span class=num>\($0.2)</span></button>" }.joined()
        let macs = macRows.isEmpty ? "<p class=empty>No Mac is connected yet. Connect one with the steps below.</p>"
            : "<div class=fleetoptions hidden><label>Site <select id=site-filter><option value=''>All sites</option></select></label><label>Tag <select id=tag-filter><option value=''>All tags</option></select></label><label>Group by <select id=group-by><option value=''>No grouping</option><option value=site>Site</option><option value=tags>Tag set</option></select></label></div><div class=maclist>\(macRows.map(\.html).joined())</div><p id=nomatch class=empty hidden>No Macs match this filter.</p><div class=pager hidden><label>Macs per page <select id=page-size><option>10</option><option selected>25</option><option>50</option><option>100</option><option value=all>All</option></select></label><span id=page-label class=sub role=status aria-live=polite></span><button type=button id=page-prev>Previous</button><button type=button id=page-next>Next</button></div>"
        let summary = "<div class=stats>"
            + "<div class=stat><span class=n>\(connected)<small> of \(total)</small></span><span>Connected<small>reported in the last 10 min</small></span></div>"
            + "<div class=stat><span class=\"n\(connected > 0 && upToDate == connected ? " ok" : "")\">\(upToDate)</span><span>Up to date<small>every app on the feed version</small></span></div>"
            + "<div class=stat><span class=\"n\(needUpdate > 0 ? " warn" : "")\">\(needUpdate)</span><span>Needs update<small>\(updates) available · \(requested) Mac\(requested == 1 ? "" : "s") awaiting results</small></span></div>"
            + "<div class=stat><span class=\"n\(failedMacs > 0 ? " bad" : offline > 0 ? " warn" : "")\">\(failedMacs + offline)</span><span>Failed or offline<small>\(failedMacs) failed · \(offline) offline</small></span></div>"
            + "</div>"
        let banner = isOpen ? "<p class=banner><span class=\"dot ok\"></span>New Macs can connect for \(leftText.replacingOccurrences(of: "id=left ", with: "")) left — \(joined.count) new Mac\(joined.count == 1 ? "" : "s") joined. <a href=#connect>See who joined</a></p>" : ""

        // Connect a new Mac: the pairing code and the existing kit, in three steps.
        let codeLocked = state.pairing?.locked(at: Date()) ?? false
        let pairing = "<div class=pair><span class=paircode id=pairing-code>\(state.pairing.map { h($0.shown) } ?? "No code yet")</span></div>"
            + "<div class=pairactions>\(state.pairing.map { "<button type=button class=primary data-copy=\"\(h($0.shown))\">Copy code</button>" } ?? "")"
            + "<form method=post action=/api/pairing-code\(state.pairing == nil ? "" : " data-confirm=\"New code? The old code stops working. Macs already connected stay connected.\"")><button>New code</button></form></div>"
        let lockStatus = codeLocked
            ? "<p class=lockstatus><span class=\"chip bad\">Pairing locked</span> After \(EnrolPolicy.pairingWrongTries) wrong tries. Try again after \(h(stamp(state.pairing?.lockedUntil ?? ""))). No code is accepted until then.</p>"
            : "<p class=lockstatus><span class=\"chip ok\">Ready to connect</span> \(EnrolPolicy.pairingWrongTries) wrong tries lock pairing for \(EnrolPolicy.pairingLockMinutes) minutes.</p>"
        let joinedList = isOpen ? "<div class=joined><h3>Joined in this window</h3>" + (joined.isEmpty ? "<p class=sub>None yet. This list updates every 10 s.</p>" : "<ul>\(joined.joined())</ul>") + "</div>" : ""
        let destination = publisherBind.map {
            "<div class=address><span class=sub>Update Studio address</span><div class=addressvalue><code>http://\(h($0)):\(port)</code><button type=button data-copy=\"http://\(h($0)):\(port)\">Copy address</button></div></div>"
        } ?? "<p class=warntext>This publisher has no configured Tailscale listener. Set its Tailscale address before connecting another Mac.</p>"
        let connect = "<section id=connect data-view=connect><div class=pagehead><div><h2>Connect a Mac</h2><p class=sub>One Launcher, one code. Your apps stay yours to choose.</p></div><a class=textlink href=#macs>View connected Macs</a></div>"
            + "<div class=connectlayout><div class=setup><h3>On the new Mac</h3><ol class=steps>"
            + "<li><div><b>Open Studio Launcher KH</b><p>Install from your SSD, or transfer a copy from this Mac. Drag it into Applications and open it.</p><button type=button id=save-launcher hidden>Save Launcher copy…</button></div></li>"
            + "<li><div><b>Connect through Tailscale</b><p>Use a Tailscale network that can reach this publisher. Launcher already carries its address and trusted key.</p></div></li>"
            + "<li><div><b>Enter the pairing code</b><p>Choose <strong>Studio Launcher KH → Connect to Update Studio</strong>, confirm the Mac name, enter this code and click <strong>Connect</strong>.</p></div></li>"
            + "<li><div><b>Look for the first report</b><p>Launcher shows the result. The new Mac appears in Macs after its first report.</p></div></li></ol></div>"
            + "<aside class=pairpanel aria-labelledby=code-title><h3 id=code-title>Pairing code</h3>\(pairing)\(lockStatus)\(destination)<p class=sub>The code stays valid until you choose New code. Changing it does not disconnect existing Macs.</p></aside></div>"
            + "<div class=connectfoot><p>Launcher’s own automatic updates start on by default. No other app is silently installed by connecting.</p><a href=#settings>Connection settings</a></div>\(enrol)\(joinedList)</section>"
        let settings = "<section data-view=settings><div class=pagehead><div><h2>Settings</h2><p class=sub>Connection details and update choices.</p></div></div><div class=settingslist>"
            + "<div class=setting><div><h3>Publisher address</h3><p class=sub>Other Macs reach this Update Studio through Tailscale. Launcher carries this address and the trusted key.</p></div><div>\(destination)<p class=sub>Listener addresses are set in this Mac’s publisher configuration. Changing this display would not change the listener.</p></div></div>"
            + "<div class=setting><div><h3>Pairing protection</h3><p class=sub>The code is protected against repeated wrong attempts.</p></div><div>\(lockStatus)<a href=#connect>View code and connect a Mac</a><p class=sub>Already connected Macs keep their connection and Automatic choices.</p></div></div>"
            + "<div class=setting><div><h3>Automatic updates</h3><p class=sub>Every Mac keeps its own choices.</p></div><div><p>New Launcher connections start with Launcher automatic updates on. Other apps follow that Mac’s saved settings.</p><p class=sub>Use the Automatic control beside an app in a Mac’s details to change its effective setting. Existing choices are never reset by connecting.</p><a href=#macs>Manage choices in Macs</a></div></div></div></section>"

        // The feed: what each app is published at, its notes, and one button for every Mac behind it.
        let sizes = ByteCountFormatter()
        let feedRows = (feed?.apps ?? [:]).sorted { name($0.key) < name($1.key) }.map { app, entry -> String in
            let behind = state.machines.filter { Self.updateAvailable($0.value, app: app, feed: feed, now: now) }.count
            // KH Updater's own apps (agent and app) read their own changelog entry when the feed has no notes.
            let own = app == "updater" || app == "kh-updater-app"
                ? (app == "updater" ? Changelog.launcher : Changelog.text).components(separatedBy: "\n## ").dropFirst().first { $0.hasPrefix(entry.version + " ") }
                    .map { $0.split(separator: "\n").dropFirst().joined(separator: "\n") } : nil
            let lines = (entry.notes.flatMap { $0.isEmpty ? nil : $0 } ?? own ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let notes = lines.isEmpty ? "<span class=sub>No notes yet</span>"
                : "<details class=notes><summary>What's new</summary><ul>\(lines.map { "<li>\(h($0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0))</li>" }.joined())</ul></details>"
            let action = behind == 0 ? "<span class=sub>No Mac needs it</span>"
                : "<form method=post action=/api/update-all data-confirm=\"Update \(h(name(app))) to \(h(entry.version)) on \(behind) Mac\(behind == 1 ? "" : "s")?\"><input type=hidden name=app value=\"\(h(app))\"><button class=primary>Update \(behind) Mac\(behind == 1 ? "" : "s")</button></form>"
            return "<tr><td class=name>\(h(name(app)))</td><td class=num>\(h(entry.version))</td><td class=num>\(h(sizes.string(fromByteCount: entry.bytes)))</td>"
                + "<td>\(notes)</td><td class=actions>\(action)</td></tr>"
        }.joined()
            // The apps that update themselves are not in the feed: the newest version any Mac reports.
            + ["story", "hub", "gateway"].filter { feed?.apps[$0] == nil }.map { app -> String in
                let seen = state.machines.values.compactMap { $0.installed[app] }
                let newest = seen.max(by: { (VersionCompare.compare($0, $1) ?? 0) < 0 })
                return "<tr><td class=name>\(h(name(app)))</td><td class=num>\(h(newest ?? "—"))</td><td class=num>—</td>"
                    + "<td><span class=sub>\(newest == nil ? "No connected Mac reports it" : "Newest on a Mac; its notes are in the app")</span></td><td class=actions><span class=sub>Updates itself</span></td></tr>"
            }.joined()
        let feedSection = feed == nil || feedRows.isEmpty ? "<p class=empty>Nothing is published yet. Publish a release with <code>khu publish</code>.</p>"
            : "<div class=tablewrap><table class=feed><thead><tr><th>App</th><th>Version</th><th>Size</th><th>What's new</th><th><span class=sr>Actions</span></th></tr></thead>\(feedRows)</table></div>"

        var removedRows = ""
        for removal in state.removed.sorted(by: { $0.removedAt > $1.removedAt }) {
            let live = state.machines[removal.machine] != nil ? "enrolled again since" : "not enrolled"
            removedRows += "<tr><td class=name>\(h(removal.machine))</td><td class=num>\(h(stamp(removal.removedAt)))</td><td class=num>\(h(stamp(removal.lastSeen)))</td><td>\(h(live))</td></tr>"
        }
        let removed = state.removed.isEmpty ? "<p class=sub>No Mac has been removed.</p>"
            : "<div class=tablewrap><table><thead><tr><th>Mac</th><th>Removed</th><th>Last seen then</th><th>Now</th></tr></thead>\(removedRows)</table></div>"
        let latest = WhatsNew.publisher.first
        let news = (latest?.items ?? []).map { "<li>\(h($0))</li>" }.joined()
        let currentVersion = latest?.version ?? "unknown"
        let version = "<details class=news><summary><span class=link>v\(h(currentVersion)) · built \(h(Changelog.buildDate)) · What's new</span></summary><div class=newsbody><h2>What's new in v\(h(currentVersion))</h2><ul>\(news)</ul></div></details>"
        // Filters and search (kept across the refresh), open rows kept open, confirm, copy, countdown.
        let script = nonce.isEmpty ? "" : "<script nonce=\"\(h(nonce))\">" + PublisherFleet.script + #"""
        setInterval(function(){document.querySelectorAll('[data-until]').forEach(function(e){var s=Math.round(Number(e.getAttribute('data-until'))-Date.now()/1000);e.textContent=s<=0?'closing now':Math.floor(s/60)+' min '+(s%60)+' s'})},1000);
        var S=sessionStorage,mode=S.getItem('khu-mode')||'all',refreshing=false;
        function show(){var v=location.hash.slice(1)||S.getItem('khu-view')||'macs';if(['macs','apps','connect','settings'].indexOf(v)<0)v='macs';var was=S.getItem('khu-view');S.setItem('khu-view',v);
        document.querySelectorAll('[data-view]').forEach(function(e){e.hidden=e.getAttribute('data-view')!=v});document.querySelectorAll('[data-tab]').forEach(function(a){a.setAttribute('aria-current',a.getAttribute('data-tab')==v?'page':'false')});if(was&&was!=v)window.scrollTo(0,0)}
        function bind(){document.querySelector('.tabs').hidden=false;show();
        bindFleet();
        document.querySelectorAll('form[data-confirm]').forEach(function(x){x.addEventListener('submit',function(e){if(!confirm(x.getAttribute('data-confirm')))e.preventDefault()})});
        document.querySelectorAll('button[data-copy]').forEach(function(b){var label=b.textContent;b.addEventListener('click',function(){var t=b.getAttribute('data-copy'),done=function(){b.textContent='Copied';(document.querySelector('dialog[open] .copystatus')||document.getElementById('copy-status')).textContent=label+' copied.';setTimeout(function(){b.textContent=label},2000)};
        if(navigator.clipboard){navigator.clipboard.writeText(t).then(done,fallback)}else fallback();function fallback(){var a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();var copied=false;try{copied=document.execCommand('copy')}catch(e){}a.remove();b.focus();if(copied)done();else (document.querySelector('dialog[open] .copystatus')||document.getElementById('copy-status')).textContent='Copy was unavailable. Select the text and copy it manually.'}})});
        document.getElementById('refresh').addEventListener('click',refresh);
        var save=document.getElementById('save-launcher');if(save){save.hidden=!(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.saveLauncher);save.addEventListener('click',function(){window.webkit.messageHandlers.saveLauncher.postMessage('save')})}}
        window.addEventListener('hashchange',show);bind();
        function closeNews(){document.querySelector('details.news').open=false}
        document.addEventListener('keydown',function(e){if(e.key=='Escape'&&!document.querySelector('dialog[open]'))closeNews();if(e.metaKey&&e.key==','){e.preventDefault();location.hash='settings';show()}if(e.metaKey&&e.key=='k'){e.preventDefault();location.hash='macs';show();document.getElementById('filter').focus()}});document.addEventListener('click',function(e){var news=document.querySelector('details.news');if(news.open&&!news.contains(e.target))closeNews()});
        async function refresh(){if(refreshing||document.querySelector('dialog[open]'))return;refreshing=true;var button=document.getElementById('refresh'),controller=new AbortController(),timeout=setTimeout(function(){controller.abort()},15000);
        button.disabled=true;button.textContent='Refreshing…';document.getElementById('refresh-status').textContent='Fetching the latest fleet and app reports…';
        var focused=document.activeElement,id=focused&&focused.id,start=focused&&focused.selectionStart,end=focused&&focused.selectionEnd,y=window.scrollY;
        try{var response=await fetch(location.pathname,{cache:'no-store',signal:controller.signal});if(!response.ok)throw Error('Publisher returned '+response.status);
        var doc=new DOMParser().parseFromString(await response.text(),'text/html'),main=doc.querySelector('main');if(!main||!main.querySelector('#refresh'))throw Error('Publisher state could not be read');
        if(document.querySelector('dialog[open]')){document.getElementById('refresh-status').textContent='Refresh resumes after closing Mac details.';return}
        document.querySelector('main').replaceWith(main);bind();window.scrollTo(0,y);var active=id&&document.getElementById(id);if(active){active.focus({preventScroll:true});if(start!=null&&active.setSelectionRange)active.setSelectionRange(start,end)}
        document.getElementById('refresh-status').textContent='Latest reports fetched at '+new Date().toLocaleTimeString()+'. Last seen shows when each Mac reported.';
        }catch(error){document.getElementById('refresh-status').textContent='Refresh failed: '+(error.name=='AbortError'?'publisher did not respond within 15 seconds':error.message)+'. Showing the previous reports. Try Refresh again.';
        }finally{clearTimeout(timeout);refreshing=false;button=document.getElementById('refresh');button.disabled=false;button.textContent='Refresh'}}
        function tick(){var a=document.activeElement;if(!document.querySelector('dialog[open]')&&!document.querySelector('details.news').open&&!document.querySelector('details.notes[open]')&&!(a&&(a.tagName=='INPUT'||a.tagName=='TEXTAREA')))refresh();setTimeout(tick,REFRESH*1000)}
        setTimeout(tick,REFRESH*1000);
        """#.replacingOccurrences(of: "REFRESH", with: isOpen ? "10" : "30") + "</script>"
        return """
        <!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta name=color-scheme content="light dark"><noscript><meta http-equiv=refresh content=\(isOpen ? 10 : 30)></noscript><title>Update Studio KH</title>
        <style>\(Self.pageStyle)\(PublisherFleet.style)</style></head>
        <body><header class=top><div class=brand>\(Self.mark)<div><h1>Update Studio KH</h1><p class=sub>Apps across your Macs</p></div></div>
        <nav class=tabs aria-label="Views" hidden><a href=#macs data-tab=macs>Macs</a><a href=#apps data-tab=apps>Apps &amp; updates</a><a href=#settings data-tab=settings>Settings</a></nav>
        <div class=headright>\(version)<a class=connectbtn href=#connect data-tab=connect>+ Connect a Mac</a></div></header>
        <main>
        <div data-view=macs><div class=pagehead><div><h2>Your Macs</h2><p class=sub>See what needs attention. Open a Mac for its apps and update choices.</p></div></div><section>\(summary)\(banner)</section>
        <section><h2>Macs</h2><div class=tools hidden><div class=filters role=group aria-label="Show Macs">\(filters)</div><input id=filter type=search placeholder="Find a Mac" aria-label="Find a Mac"><button type=button id=refresh>Refresh</button><span id=count class=sub></span></div><p id=refresh-status class=sub role=status aria-live=polite>Latest saved reports. Last seen shows when each Mac reported.</p>\(macs)
        </section>
        \(state.removed.isEmpty ? "" : "<section><details class=removed><summary><h2>Macs removed (\(state.removed.count))</h2></summary>\(removed)</details></section>")</div>
        \(connect)
        \(settings)
        <section data-view=apps><div class=pagehead><div><h2>Apps &amp; updates</h2><p class=sub>Published versions, release notes and updates for your connected Macs.</p></div></div><p class=sub>Update N Macs updates every connected Mac that is behind. Each Mac reports its result here.</p>\(feedSection)\(vendorHTML(state))</section>
        <dialog id=mac-dialog aria-labelledby=mac-dialog-title><div class=modalbar><h2 id=mac-dialog-title>Mac details</h2><button type=button id=mac-dialog-close aria-label="Close Mac details">Close</button></div><div id=mac-dialog-body></div><p class=\"sr copystatus\" role=status aria-live=polite></p></dialog><p id=copy-status class=sr role=status aria-live=polite></p></main>\(script)</body></html>
        """
    }

    static let failureStatuses: Set<String> = ["failed", "install_failed", "download_failed", "download_mismatch", "rolled_back",
                                               "rollback_failed", "rollback_unhealthy", "rollback_blocked", "unresolved",
                                               "blocked", "refused", "needs_admin", "needs_person"]
    /// A Mac not seen for longer than this shows as offline, never with its last known state.
    static let offlineAfter: TimeInterval = 10 * 60
    static func isOnline(_ ms: MachineState, now: Date) -> Bool {
        ms.lastSeen.flatMap(ISO.date).map { now.timeIntervalSince($0) < offlineAfter } ?? false
    }
    /// The page's "Update available": an online Mac with this app installed behind the feed, no order
    /// already waiting and no failure to look at first. "Update N Macs" sends to exactly these.
    static func updateAvailable(_ ms: MachineState, app: String, feed: Feed?, now: Date) -> Bool {
        guard ms.tokenHash != nil, app != "story", app != "hub", isOnline(ms, now: now),
              let installed = ms.installed[app], let offered = feed?.apps[app]?.version,
              !ms.pending.contains(where: { $0.app == app }),
              !(ms.lastResults?[app].map { failureStatuses.contains($0.status) } ?? false) else { return false }
        return VersionCompare.isNewer(offered, than: installed)
    }
    /// "M2 Pro · 16 GB · 512 GB" from a fleet name like terranash-1607-m2-pro-32-512-hub; nil otherwise.
    static func model(of machine: String) -> String? {
        let parts = machine.split(separator: "-").map(String.init)
        guard parts.count >= 5, parts[0] == "terranash", parts[1].count == 4, Int(parts[1]) != nil,
              parts[2].count == 2, parts[2].hasPrefix("m"), Int(parts[2].dropFirst()) != nil else { return nil }
        var i = 3, chip = parts[2].uppercased()
        if ["pro", "max", "ultra"].contains(parts[i]) { chip += " " + parts[i].capitalized; i += 1 }
        guard parts.count > i + 1, let ram = Int(parts[i]), let disk = Int(parts[i + 1]),
              parts.count == i + 2 || (parts.count == i + 3 && parts[i + 2] == "hub") else { return nil }
        return "\(chip) · \(ram) GB · " + (disk >= 1000 ? "\(disk / 1000) TB" : "\(disk) GB")
    }

    /// The page's mark: a down arrow into a tray, drawn the same way as the app icon.
    static let mark = "<svg class=mark viewBox=\"0 0 32 32\" aria-hidden=true><rect width=32 height=32 rx=8 fill=\"var(--accent)\"/><path d=\"M16 7v12m-5-5 5 5 5-5M9 21v3h14v-3\" fill=none stroke=\"#fff\" stroke-width=2.4 stroke-linecap=round stroke-linejoin=round/></svg>"

    static let pageStyle = """
    :root{--bg:#f5f6f5;--panel:#fff;--line:#e2e5e3;--line2:#eef0ef;--text:#16201c;--sub:#5b6762;--accent:#1d6b51;--accent-ink:#fff;--ok:#1a7448;--ok-bg:#e2f3e9;--warn:#875800;--warn-bg:#fcefd2;--bad:#b42318;--bad-bg:#fde8e6;--info:#1d5fa8;--info-bg:#e5eefb;--muted-bg:#eef0ef;--focus:#2e8b6a;--field:#9aa6a0;--shadow:0 10px 30px rgba(15,30,25,.14)}
    @media (prefers-color-scheme:dark){:root{--bg:#101513;--panel:#171e1b;--line:#29332f;--line2:#202926;--text:#e6ece9;--sub:#a9b5af;--accent:#3fa37f;--accent-ink:#06120d;--ok:#62d19a;--ok-bg:#15301f;--warn:#f0b450;--warn-bg:#33270f;--bad:#ff8a7e;--bad-bg:#3a1714;--info:#8ab8f2;--info-bg:#15263c;--muted-bg:#212a26;--focus:#62d19a;--field:#5f6e67;--shadow:0 12px 32px rgba(0,0,0,.5)}}
    *{box-sizing:border-box}html{background:var(--bg);color:var(--text);font:13.5px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
    body{margin:0}::selection{background:var(--accent);color:var(--accent-ink)}a{color:var(--accent)}
    h1{font-size:16px;letter-spacing:-.02em;margin:0}h2{font-size:15px;margin:0 0 10px;letter-spacing:-.01em}h3{font-size:12px;font-weight:600;color:var(--sub);letter-spacing:0;margin:16px 0 6px}p{margin:0 0 8px}
    .sub{color:var(--sub);font-size:12.5px}.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}.num{font-variant-numeric:tabular-nums}
    .top{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;padding:16px 24px;border-bottom:1px solid var(--line);background:var(--panel);position:sticky;top:0;z-index:4}
    .top{align-items:center}.brand{display:flex;gap:10px;align-items:center}.headright{display:flex;align-items:center;gap:14px}.connectbtn{background:var(--accent);color:var(--accent-ink);text-decoration:none;font-weight:600;padding:6px 12px;border-radius:8px;white-space:nowrap}.connectbtn:hover{filter:brightness(1.08)}.connectbtn[aria-current=page]{background:var(--panel);color:var(--accent);box-shadow:inset 0 0 0 1.5px var(--accent)}#count{min-width:5.5em;text-align:right}.tabs{display:flex;gap:2px;padding:2px;background:var(--muted-bg);border-radius:9px}.tabs[hidden]{display:none}.tabs a{padding:5px 14px;border-radius:7px;color:var(--sub);text-decoration:none;font-weight:550}.tabs a[aria-current=page]{background:var(--panel);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.12)}[data-view][hidden]{display:none}.mark{width:34px;height:34px;flex:none}.brand .sub{margin:0}
    main{width:100%;padding:28px 24px 48px;max-width:1480px;margin:0 auto}section{margin-bottom:28px}
    .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line);border:1px solid var(--line);border-radius:12px;overflow:hidden}
    .stat{display:flex;align-items:center;gap:12px;padding:14px 16px;background:var(--panel)}
    .stat .n{font-size:26px;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums;white-space:nowrap}.stat .n small{font-size:13px;color:var(--sub);font-weight:500}
    .stat small{display:block;color:var(--sub);font-size:11.5px}.n.ok{color:var(--ok)}.n.warn{color:var(--warn)}.n.bad{color:var(--bad)}
    .banner{margin:10px 0 0;padding:10px 14px;border-radius:10px;background:var(--ok-bg);color:var(--text)}
    .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--sub);margin:0 6px 0 2px;vertical-align:1px}.dot.ok{background:var(--ok)}.dot.bad{background:var(--bad)}.dot.warn{background:var(--warn)}
    .row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.unit{color:var(--sub)}form{display:inline;margin:0}
    button,input{font:inherit;color:inherit}
    button{border:1px solid var(--line);background:var(--panel);border-radius:7px;padding:4px 11px;cursor:pointer;white-space:nowrap;transition:background .15s}
    button:hover{background:var(--muted-bg)}button.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);font-weight:550}button.primary:hover{filter:brightness(1.08)}
    button.small{padding:2px 9px;font-size:12.5px}button.quiet{border-color:transparent;color:var(--sub)}button.danger{color:var(--bad)}button.danger:hover{background:var(--bad-bg)}
    input[type=number]{width:4.5em;padding:4px 6px;border:1px solid var(--field);border-radius:7px;background:var(--panel)}::placeholder{color:var(--sub);opacity:1}
    input[type=search]{flex:1 1 280px;min-width:180px;max-width:100%;padding:7px 10px;border:1px solid var(--field);border-radius:8px;background:var(--panel)}
    button:disabled{cursor:wait;opacity:.65}.tools{margin-bottom:6px}#refresh-status{margin-bottom:12px;overflow-wrap:anywhere}
    :focus-visible{outline:2px solid var(--focus);outline-offset:2px}
    .sechead{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px}.sechead h2{margin:0}
    .tools{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.tools[hidden]{display:none}
    .filters{display:flex;gap:2px;padding:2px;background:var(--muted-bg);border-radius:9px}
    .filter{border:0;background:transparent;padding:4px 10px;border-radius:7px;color:var(--sub)}.filter .num{margin-left:2px}
    .filter[aria-pressed=true]{background:var(--panel);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.12)}
    .maclist{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
    details.mac+details.mac{border-top:1px solid var(--line2)}details.mac[hidden]{display:none}
    details.mac>summary{list-style:none;cursor:pointer;display:grid;grid-template-columns:minmax(150px,1.1fr) minmax(0,1.6fr) auto 140px 14px;gap:14px;align-items:center;padding:9px 16px}
    details.mac>summary::-webkit-details-marker{display:none}details.mac>summary:hover{background:var(--line2)}details.mac[open]>summary{background:var(--muted-bg)}
    .who{display:flex;flex-direction:column;min-width:0}.who b{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.who small{color:var(--sub);font-size:11.5px}
    .apps{display:flex;flex-wrap:wrap;gap:4px}
    .app{font-size:12px;padding:1px 7px;border-radius:6px;background:var(--line2);color:var(--sub);white-space:nowrap}.app .num{color:var(--text)}
    .app.t-warn{background:var(--warn-bg);color:var(--warn)}.app.t-bad{background:var(--bad-bg);color:var(--bad)}.app.t-info{background:var(--info-bg);color:var(--info)}
    .seen{color:var(--sub);font-size:12.5px;text-align:right;white-space:nowrap}.state{display:flex;align-items:center;gap:8px;justify-content:flex-end}.chev{width:8px;height:8px;border-right:1.6px solid var(--sub);border-bottom:1.6px solid var(--sub);transform:rotate(-45deg);transition:transform .15s;justify-self:end}details.mac[open]>summary .chev{transform:rotate(45deg)}details.mac.s-failed>summary{box-shadow:inset 3px 0 0 var(--bad)}
    .chip{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:550;white-space:nowrap}
    .chip.ok{background:var(--ok-bg);color:var(--ok)}.chip.warn{background:var(--warn-bg);color:var(--warn)}.chip.bad{background:var(--bad-bg);color:var(--bad)}.chip.info{background:var(--info-bg);color:var(--info)}.chip.muted{background:var(--muted-bg);color:var(--sub)}.chip.unknown{background:transparent;color:var(--warn);box-shadow:inset 0 0 0 1px var(--warn)}
    .detail{padding:6px 16px 16px;border-top:1px solid var(--line2)}
    .identity{display:grid;grid-template-columns:minmax(120px,auto) minmax(0,1fr);gap:6px 16px;margin:10px 0}.identity dt{color:var(--sub)}.identity dd{margin:0;overflow-wrap:anywhere}.identity code{word-break:break-word}
    @media(max-width:560px){.identity{grid-template-columns:1fr;gap:3px}.identity dd{margin-bottom:7px}}
    table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:7px 10px;vertical-align:top}
    thead th{font-size:11.5px;font-weight:600;color:var(--sub);letter-spacing:0;border-bottom:1px solid var(--line)}
    tbody tr+tr td{border-top:1px solid var(--line2)}.name{font-weight:550}.name .sub{font-weight:400}
    .actions{text-align:right;white-space:nowrap}.actions>*{margin-left:6px}
    .tag.on{font-size:12px;color:var(--accent);font-weight:600}.warntext{color:var(--warn)}.badtext{color:var(--bad);font-weight:550}
    .failure{margin:10px 0;padding:12px 14px;border-radius:10px;background:var(--bad-bg);color:var(--text)}
    .failhead{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:4px}.failhead b{color:var(--bad)}.failure p{margin:0 0 6px}
    .macfoot{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-top:14px;padding-top:12px;border-top:1px solid var(--line2)}
    .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px}
    .pair{display:flex;align-items:center;gap:14px;margin:4px 0 6px}.paircode{font:600 28px/1.2 ui-monospace,Menlo,monospace;letter-spacing:.04em;user-select:all;font-variant-numeric:tabular-nums}
    .steps{margin:12px 0 0;padding-left:20px}.steps li{margin-bottom:10px}.steps li>b{display:block;margin-bottom:4px}.steps p{margin:0 0 6px}
    .joined{margin-top:6px;padding-top:10px;border-top:1px solid var(--line2)}.joined ul{margin:0;padding-left:18px}
    .tablewrap{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:2px 6px}
    details.notes summary{cursor:pointer;color:var(--accent)}details.notes ul{margin:6px 0 0;padding-left:16px}details.notes li{margin-bottom:2px}
    details.news{text-align:right;font-size:12.5px}details.news summary{list-style:none;cursor:pointer}details.news summary::-webkit-details-marker{display:none}details.news summary p{margin:0}
    .link{color:var(--accent);font-size:12.5px}.newsbody{position:absolute;right:24px;margin-top:8px;width:min(440px,calc(100vw - 48px));text-align:left;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;box-shadow:var(--shadow)}
    .newsbody h2{font-size:13px}.newsbody ul{margin:0;padding-left:18px}
    details.removed summary{cursor:pointer;color:var(--sub)}details.removed summary h2{display:inline;font-size:13px}details.removed[open] summary{margin-bottom:10px}
    .empty{background:var(--panel);border:1px dashed var(--line);border-radius:12px;padding:18px;color:var(--sub)}.foot{margin-top:10px;max-width:90ch}
    code{font:12px ui-monospace,Menlo,monospace;background:var(--muted-bg);padding:1px 5px;border-radius:5px;word-break:break-all}
    @media (max-width:820px){.top{padding:10px 14px;flex-wrap:wrap;gap:8px}.tabs{order:3;width:100%}.tabs a{flex:1;text-align:center}.headright{gap:8px}.connectbtn{padding:5px 10px}.state{justify-content:flex-start;flex-wrap:wrap}.top{padding:12px 16px}main{padding:14px}.brand .sub{display:none}.mark{width:28px;height:28px}h1{font-size:18px}details.news summary p{font-size:12px}
    .stats{grid-template-columns:1fr 1fr}.stat{padding:12px}.stat .n{font-size:21px}
    details.mac>summary{grid-template-columns:1fr;gap:6px;padding:10px 14px}.state{order:1}.apps{order:2}.seen{order:3;text-align:left}
    .apptable thead,.hist thead,.feed thead{display:none}.apptable tr,.feed tr{display:grid;grid-template-columns:1fr auto;gap:2px 10px;padding:8px 0}.apptable td,.feed td{padding:0;border:0!important}.apptable tbody tr+tr,.feed tbody tr+tr{border-top:1px solid var(--line2)}
    .apptable td:nth-child(3)::before{content:"Feed ";color:var(--sub)}.apptable td.actions,.feed td.actions,.feed td:nth-child(4){grid-column:1/-1;text-align:left}.actions>*{margin:4px 6px 0 0}
    .hist tr{display:grid;grid-template-columns:1fr auto;gap:0 10px;padding:6px 0}.hist td{padding:0;font-size:12.5px;border:0!important}.hist tbody tr+tr{border-top:1px solid var(--line2)}details.mac>summary{position:relative;padding-right:34px}.chev{position:absolute;right:16px;top:18px}input[type=search]{width:100%}.tools{width:100%}#filter{flex:1 1 100%;min-width:0;order:2}#refresh{order:3}#count{order:4;min-width:0;text-align:left}.filters{max-width:100%;flex-wrap:wrap}.filter{padding:5px 8px}}

    [hidden]{display:none!important}a{text-underline-offset:3px}input{caret-color:var(--accent)}
    ::-webkit-scrollbar{width:11px;height:11px}::-webkit-scrollbar-thumb{background:var(--line);border-radius:8px;border:3px solid var(--bg)}
    .brand p{font-size:12px;margin:1px 0 0}.top{padding:14px 22px}.mark{width:30px;height:30px}
    .pagehead{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:24px}.pagehead h2{font-size:26px;letter-spacing:-.025em;font-weight:650;margin:0 0 4px}.pagehead p{margin:0;font-size:13.5px}.textlink{white-space:nowrap}
    button{min-height:30px;font-weight:550}button.primary{color:var(--accent-ink)}
    .connectlayout{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(340px,.85fr);gap:40px;align-items:start}
    .setup{padding:12px 0}.setup h3,.pairpanel h3{font-size:14px;color:var(--text);text-transform:none;letter-spacing:0;margin:0 0 20px}
    .steps{list-style:none;padding:0;margin:0;counter-reset:setup;display:flex;flex-direction:column;gap:24px}
    .steps li{counter-increment:setup;display:grid;grid-template-columns:30px minmax(0,1fr);gap:12px;margin:0}
    .steps li::before{content:counter(setup);display:grid;place-items:center;align-self:start;height:30px;background:var(--muted-bg);color:var(--accent);font-weight:650;border-radius:8px}
    .steps b{font-size:14px;font-weight:600;display:block;margin:3px 0 5px}.steps p{color:var(--sub);max-width:65ch;margin:0 0 8px;line-height:1.55}
    .pairpanel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:28px;min-width:0}.pair{margin:24px 0 20px}.paircode{font-size:clamp(36px,4.5vw,64px);letter-spacing:.04em;line-height:1.1;overflow-wrap:anywhere}.pairactions{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:20px}.pairactions button{min-height:34px}
    .lockstatus{color:var(--sub);font-size:12.5px;line-height:1.6}.lockstatus .chip{margin-right:6px}.address{padding:20px 0;margin:20px 0;border-top:1px solid var(--line2);border-bottom:1px solid var(--line2)}.addressvalue{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:8px}.address code{font-size:12px;padding:4px 6px;user-select:all;overflow-wrap:anywhere}
    .connectfoot{display:flex;justify-content:space-between;gap:20px;margin-top:32px;padding-top:20px;border-top:1px solid var(--line);color:var(--sub);font-size:12.5px}.connectfoot p{max-width:70ch}.connectfoot a{white-space:nowrap}
    .settingslist{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:0 24px}.setting{display:grid;grid-template-columns:minmax(180px,.7fr) minmax(0,1.3fr);gap:40px;padding:24px 0}.setting+.setting{border-top:1px solid var(--line2)}.setting h3{font-size:14px;color:var(--text);text-transform:none;margin:0 0 6px;letter-spacing:0}.setting p{max-width:70ch}.setting .address{margin:0 0 10px;padding:0;border:0}
    .macpick{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:8px 0}.macpick+.macpick{border-top:1px solid var(--line2)}
    .vendors{margin-top:28px}input[type=checkbox]{accent-color:var(--accent)}
    .tablewrap{padding:0 8px;overflow-x:auto}.feed td{padding:18px 12px}.feed th{padding:12px}.feed .name{font-weight:600;min-width:160px}.feed .num{font-size:12.5px}.stat{padding:16px}.detail{overflow-x:auto}
    @media(min-width:821px) and (max-width:1100px){.brand p{display:none}.top{gap:10px}.tabs a{padding:5px 9px}.headright{gap:10px}.stats{grid-template-columns:1fr 1fr}.connectlayout{gap:24px}.pairpanel{padding:24px}details.mac>summary{grid-template-columns:minmax(130px,1fr) minmax(0,1fr) auto 14px}.seen{grid-column:1/4;text-align:left}.chev{grid-column:4;grid-row:1}}
    @media(max-width:820px){.pagehead{align-items:flex-start;flex-direction:column;gap:8px;margin-bottom:20px}.pagehead h2{font-size:23px}.connectlayout{grid-template-columns:minmax(0,1fr);gap:24px}.pairpanel{order:-1;padding:24px}.paircode{font-size:48px}.pair{margin:20px 0}.connectfoot{flex-direction:column;gap:8px}.setting{grid-template-columns:1fr;gap:12px}.settingslist{padding:0 18px}.headright{margin-left:auto}.brand{min-width:0}.top h1{font-size:15px}.tabs{overflow-x:auto}.tabs a{padding:5px 10px;white-space:nowrap}.feed td{min-width:0}.feed .name{min-width:0}.feed .actions{white-space:normal}.feed .num{overflow-wrap:anywhere}}
    @media(prefers-reduced-motion:reduce){*{transition:none!important;scroll-behavior:auto!important}}
    """ + Changelog.layoutCSS

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
