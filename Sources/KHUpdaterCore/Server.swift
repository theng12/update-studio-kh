import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
}

public enum HTTP {
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let rl = requestLine.split(separator: " ")
        guard rl.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                headers[String(line[..<idx]).lowercased().trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return HTTPRequest(method: String(rl[0]), path: String(rl[1]), headers: headers, body: Data(body.utf8))
    }

    /// Read one request: the headers, then exactly Content-Length body bytes (at most 1 MiB, bounded by
    /// the socket's receive timeout). nil for a request that never completes or is too large.
    public static func readRequest(from fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let separator = Data("\r\n\r\n".utf8)
        while data.count <= limit + 65536 {
            if let end = data.range(of: separator) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
                let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard length >= 0, length <= limit else { return nil }
                if data.count - end.upperBound >= length { return data.prefix(end.upperBound + length) }
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            data.append(contentsOf: chunk[0..<n])
        }
        return nil
    }

    /// Write every byte (a large artifact does not go out in one write).
    public static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 { if errno == EINTR { continue }; return }
                sent += n
            }
        }
    }

    public static func response(status: Int, contentType: String = "text/plain", body: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 303: statusText = "See Other"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        default: statusText = "Error"
        }
        var out = "HTTP/1.1 \(status) \(statusText)\r\n"
        if status == 303 { out += "Location: \(String(decoding: body, as: UTF8.self))\r\n" }
        out += "Content-Type: \(contentType)\r\n"
        out += "Content-Length: \(body.count)\r\n"
        out += "Connection: close\r\n\r\n"
        var d = Data(out.utf8)
        d.append(body)
        return d
    }
}

public enum ServerDecision {
    public static func isLoopbackRemote(_ remote: String) -> Bool { OwnerAccess.isLoopback(remote) }
    public static func ownerRouteAllowed(remote: String) -> Bool { isLoopbackRemote(remote) }
}

public final class FeedServer {
    public let feedDir: URL
    public let stateDir: URL
    public let bind: String
    public let port: Int
    private var listener: Int32 = -1

    public init(feedDir: URL, stateDir: URL, bind: String, port: Int) {
        self.feedDir = feedDir
        self.stateDir = stateDir
        self.bind = bind
        self.port = port
    }

    public func handleRequest(_ req: HTTPRequest, remote: String) -> (Int, String, Data) {
        // auth for agent routes
        let isOwner = ServerDecision.ownerRouteAllowed(remote: remote)
        // feed
        if req.method == "GET" {
            if req.path == "/feed.json" {
                if let d = try? Data(contentsOf: feedDir.appendingPathComponent("feed.json")) { return (200, "application/json", d) }
                return (404, "text/plain", Data("not found".utf8))
            }
            if req.path == "/feed.json.sig" {
                if let d = try? Data(contentsOf: feedDir.appendingPathComponent("feed.json.sig")) { return (200, "application/octet-stream", d) }
                return (404, "text/plain", Data("not found".utf8))
            }
            if req.path.hasPrefix("/artifacts/") {
                let name = String(req.path.dropFirst("/artifacts/".count))
                if let safe = try? SafeName.component(name, what: "artifact") {
                    // ensure listed
                    if let feed = FeedPublisher.loadFeed(from: feedDir), feed.apps.values.contains(where: { $0.file == safe }) {
                        let url = feedDir.appendingPathComponent("artifacts").appendingPathComponent(safe)
                        if let d = try? Data(contentsOf: url) { return (200, "application/octet-stream", d) }
                    }
                }
                return (404, "text/plain", Data("not found".utf8))
            }
            if req.path == "/" {
                if !isOwner { return (403, "text/plain", Data("forbidden".utf8)) }
                return (200, "text/html", Data(statusHTML().utf8))
            }
        }
        // agent auth
        func authToken() -> String? {
            if let h = req.headers["authorization"], h.lowercased().hasPrefix("bearer ") {
                return String(h.dropFirst(7))
            }
            return nil
        }
        func authMachine() -> (String?, String?) {
            // returns (machine, error)
            guard let tok = authToken() else { return (nil, "missing token") }
            // machine from query or body
            return (nil, nil)
        }
        if req.method == "POST" && req.path == "/status" {
            guard let tok = authToken() else { return (401, "text/plain", Data("missing token".utf8)) }
            // simple: expect machine in body
            let machine = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["machine"] as? String
            guard let m = machine else { return (400, "text/plain", Data("missing machine".utf8)) }
            let state = try? StateStore.load(from: stateDir)
            var st = state ?? ServerState()
            var ms = st.machines[m] ?? MachineState(machine: m)
            guard ms.tokenHash == Enrolment.sha256Hex(tok) else { return (401, "text/plain", Data("wrong token".utf8)) }
            // update fields
            if let inst = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["installed"] as? [String: String] { ms.installed = inst }
            if let health = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["health"] as? [String: String] { ms.health = health }
            ms.lastSeen = ISO.string(Date())
            st.machines[m] = ms
            try? StateStore.save(st, to: stateDir)
            return (200, "application/json", Data("{}".utf8))
        }
        if req.method == "GET" && req.path.hasPrefix("/commands") {
            let machine = queryParam(req.path, "machine")
            guard let m = machine else { return (400, "text/plain", Data("missing machine".utf8)) }
            guard let tok = authToken() else { return (401, "text/plain", Data("missing token".utf8)) }
            var state = (try? StateStore.load(from: stateDir)) ?? ServerState()
            var ms = state.machines[m] ?? MachineState(machine: m)
            guard ms.tokenHash == Enrolment.sha256Hex(tok) else { return (401, "text/plain", Data("wrong token".utf8)) }
            let cmds = ms.pending
            ms.pending = []
            state.machines[m] = ms
            try? StateStore.save(state, to: stateDir)
            let data = (try? JSON.encode(CommandsReply(commands: cmds, automatic: ms.automatic))) ?? Data("{}".utf8)
            return (200, "application/json", data)
        }
        if req.method == "POST" && req.path.hasPrefix("/commands/") && req.path.hasSuffix("/result") {
            let id = String(req.path.dropFirst("/commands/".count).dropLast("/result".count))
            guard let tok = authToken() else { return (401, "text/plain", Data("missing token".utf8)) }
            let machine = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["machine"] as? String
            guard let m = machine else { return (400, "text/plain", Data("missing machine".utf8)) }
            var state = (try? StateStore.load(from: stateDir)) ?? ServerState()
            var ms = state.machines[m] ?? MachineState(machine: m)
            guard ms.tokenHash == Enrolment.sha256Hex(tok) else { return (401, "text/plain", Data("wrong token".utf8)) }
            // store last result
            if let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
                let status = obj["status"] as? String ?? ""
                let reason = obj["reason"] as? String
                ms.lastResult = CommandResult(commandId: id, status: status, reason: reason)
                if let app = obj["app"] as? String, !app.isEmpty {
                    var all = ms.lastResults ?? [:]
                    all[app] = CommandResult(commandId: id, status: status, reason: reason)
                    ms.lastResults = all
                }
            }
            state.machines[m] = ms
            try? StateStore.save(state, to: stateDir)
            return (200, "application/json", Data("{}".utf8))
        }
        // owner api
        if req.method == "POST" && (req.path == "/api/request-update" || req.path == "/api/automatic") {
            if !isOwner { return (403, "text/plain", Data("forbidden".utf8)) }
            // A browser sends Origin on a cross-site form post: only this page may drive these buttons.
            if let origin = req.headers["origin"], !OwnerAccess.isSameOrigin(origin, port: port) {
                return (403, "text/plain", Data("cross-site request refused".utf8))
            }
            let f = OwnerAccess.fields(req)
            guard let machine = f["machine"], let app = f["app"], !machine.isEmpty, !app.isEmpty else {
                return (400, "text/plain", Data("send machine and app".utf8))
            }
            var state = (try? StateStore.load(from: stateDir)) ?? ServerState()
            guard var ms = state.machines[machine], ms.tokenHash != nil else {
                return (404, "text/plain", Data("no enrolled Mac named \(machine)".utf8))
            }
            if req.path == "/api/request-update" {
                if !ms.pending.contains(where: { $0.app == app }) { ms.pending.append(ServerCommand(machine: machine, app: app)) }
            } else {
                ms.automatic[app] = f["on"] == "true"
            }
            state.machines[machine] = ms
            do { try StateStore.save(state, to: stateDir) } catch { return (500, "text/plain", Data("could not save".utf8)) }
            // The page's own buttons post a form: send the owner back to the page.
            if (req.headers["content-type"] ?? "").hasPrefix("application/x-www-form-urlencoded") {
                return (303, "text/plain", Data("/".utf8))
            }
            return (200, "application/json", Data("{}".utf8))
        }
        return (404, "text/plain", Data("not found".utf8))
    }

    public func statusHTML() -> String {
        let state = (try? StateStore.load(from: stateDir)) ?? ServerState()
        let feed = FeedPublisher.loadFeed(from: feedDir)
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
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
                let pending = ms.pending.contains { $0.app == app } ? "waiting for the Mac" : ""
                let last = ms.lastResults?[app].map { "\($0.status)\($0.reason.map { $0.isEmpty ? "" : ": " + $0 } ?? "") (\($0.at))" } ?? ""
                let ownUpdater = app == "story" || app == "hub"
                let auto = ms.automatic[app] ?? false
                let update = ownUpdater || feed?.apps[app] == nil ? "" : form("/api/request-update", machine, app, "", "Update")
                let automatic = ownUpdater || feed?.apps[app] == nil ? "" :
                    form("/api/automatic", machine, app, "<input type=hidden name=on value=\(auto ? "false" : "true")>", auto ? "Automatic: on" : "Automatic: off")
                let note = ownUpdater ? "updated by its own updater" : ""
                rows += "<tr><td>\(h(machine))</td><td>\(h(app))</td><td>\(h(installed))</td><td>\(h(latest))</td><td>\(h(ms.health[app] ?? ""))</td><td>\(h(ms.lastSeen ?? "never"))</td><td>\(h(pending))</td><td>\(h(last))</td><td>\(update)\(h(note))</td><td>\(automatic)</td></tr>"
            }
        }
        return """
        <!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=30><title>KH Updater</title>
        <style>body{font:14px -apple-system,sans-serif;margin:24px}table{border-collapse:collapse}td,th{border-bottom:1px solid #ddd;padding:6px 10px;text-align:left}form{display:inline}</style></head>
        <body><h1>KH Updater</h1><p>Every Mac and app, refreshed every 30 s. Update installs the feed's version on that Mac; Automatic does it whenever the feed is newer.</p>
        <table><tr><th>Mac</th><th>App</th><th>Installed</th><th>Feed</th><th>Health</th><th>Last seen</th><th>Pending</th><th>Last result</th><th></th><th></th></tr>\(rows)</table></body></html>
        """
    }


    // minimal serve
    public static let stateLock = NSLock()

    public func serve() throws {
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
        } else {
            inet_pton(AF_INET, bind, &addr.sin_addr)
        }
        if bind != "0.0.0.0" && inet_pton(AF_INET, bind, &addr.sin_addr) != 1 { close(fd); throw khuFail("\(bind) is not an IPv4 address") }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.bind(fd, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw khuFail("cannot listen on \(bind):\(port) (errno \(errno))") }
        guard listen(fd, 16) == 0 else { close(fd); throw khuFail("listen failed on \(bind):\(port)") }
        self.listener = fd
        while true {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                    accept(fd, sptr, &len)
                }
            }
            if cfd < 0 { continue }
            // read request
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let data = HTTP.readRequest(from: cfd)
            let req = data.flatMap(HTTP.parse)
            let remote = String(cString: inet_ntoa(clientAddr.sin_addr))
            let (status, ct, body): (Int, String, Data)
            if let r = req {
                // One server process may listen on several addresses; its state file has one writer at a time.
                FeedServer.stateLock.lock()
                let res = handleRequest(r, remote: remote)
                FeedServer.stateLock.unlock()
                status = res.0; ct = res.1; body = res.2
            } else {
                status = 400; ct = "text/plain"; body = Data("bad request".utf8)
            }
            let resp = HTTP.response(status: status, contentType: ct, body: body)
            HTTP.writeAll(cfd, resp)
            close(cfd)
        }
    }
}

// helper to decode arbitrary JSON
private struct AnyCodable: Codable {}
func queryParam(_ path: String, _ name: String) -> String? {
    guard let q = path.split(separator: "?").dropFirst().first else { return nil }
    for pair in q.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        if kv.count == 2 && String(kv[0]) == name {
            return String(kv[1]).removingPercentEncoding
        }
    }
    return nil
}
