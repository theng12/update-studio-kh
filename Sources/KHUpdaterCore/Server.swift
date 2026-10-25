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
                          404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error", 503: "Service Unavailable"]

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

public final class FeedServer: @unchecked Sendable {
    public let feedDir: URL
    public let stateDir: URL
    public let bind: String
    public let port: Int
    public let maxConnections: Int
    /// The key that signs every order reply. Without it the server has no way to answer a Mac with
    /// something the Mac can tell apart from a forgery, so it refuses to answer at all.
    public let commandKey: Curve25519.Signing.PrivateKey?

    public init(feedDir: URL, stateDir: URL, bind: String, port: Int,
                commandKey: Curve25519.Signing.PrivateKey? = nil, maxConnections: Int = 32) {
        self.feedDir = feedDir
        self.stateDir = stateDir
        self.bind = bind
        self.port = port
        self.commandKey = commandKey
        self.maxConnections = maxConnections
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse { HTTPResponse(status, "text/plain; charset=utf-8", message) }
    static let ok = HTTPResponse(200, "application/json", "{}")

    /// A state transaction, answered honestly: an unreadable state file is a 503 that says so (the
    /// file is left as it is), and a change that could not be saved is a 500 — never a 200.
    func transact(_ change: (inout ServerState) throws -> HTTPResponse) -> HTTPResponse {
        do {
            return try FileLock.withExclusive(StateStore.lockFile(in: stateDir)) {
                let state: ServerState
                do { state = try StateStore.load(from: stateDir) } catch {
                    return Self.text(503, "the publisher's state file cannot be read (\(error)); it was left untouched")
                }
                var next = state
                let response = try change(&next)
                if next != state {
                    do { try StateStore.save(next, to: stateDir) } catch {
                        return Self.text(500, "could not save the publisher's state: \(error)")
                    }
                }
                return response
            }
        } catch {
            return Self.text(500, "\(error)")
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

    public func handleRequest(_ req: HTTPRequest, remote: String) -> HTTPResponse {
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

        if req.method == "POST" && req.path == "/status" {
            guard let token = machineToken(req) else { return Self.text(401, "missing token") }
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let machine = body["machine"] as? String else { return Self.text(400, "missing machine") }
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                var ms = state.machines[machine]!
                if let installed = body["installed"] as? [String: String] { ms.installed = installed }
                if let health = body["health"] as? [String: String] { ms.health = health }
                if let defaults = body["automatic_default"] as? [String: Bool] { ms.automaticDefault = defaults }
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
            guard let token = machineToken(req) else { return Self.text(401, "missing token") }
            guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let machine = body["machine"] as? String else { return Self.text(400, "missing machine") }
            return transact { state in
                guard authorised(state, machine, token) else { return Self.text(401, "wrong token") }
                var ms = state.machines[machine]!
                let result = CommandResult(commandId: id, status: body["status"] as? String ?? "", reason: body["reason"] as? String)
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
                    guard id.hasPrefix("auto-"), let named else { return Self.text(400, "an automatic result needs an auto id and app") }
                    all[named] = result
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
                var page = HTTPResponse(200, "text/html; charset=utf-8", statusHTML())
                page.headers = ["Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
                                "X-Frame-Options": "DENY", "Referrer-Policy": "same-origin"]
                return page
            }
            if req.method == "POST" && (req.path == "/api/request-update" || req.path == "/api/request-rollback"
                                        || req.path == "/api/automatic") {
                guard OwnerAccess.isSameSite(req.headers, port: port) else { return Self.text(403, "cross-site request refused") }
                let f = OwnerAccess.fields(req)
                guard let machine = f["machine"], let app = f["app"], !machine.isEmpty, !app.isEmpty else {
                    return Self.text(400, "send machine and app")
                }
                let response = transact { state in
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

    public func statusHTML() -> String {
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
        return """
        <!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=30><title>KH Updater</title>
        <style>body{font:14px -apple-system,sans-serif;margin:24px}table{border-collapse:collapse}td,th{border-bottom:1px solid #ddd;padding:6px 10px;text-align:left}form{display:inline}</style></head>
        <body><h1>KH Updater</h1><p>Every Mac and app, refreshed every 30 s. Update installs the feed's version on that Mac; Roll back puts the version that Mac kept back in place; Automatic does it whenever the feed is newer.</p>
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
