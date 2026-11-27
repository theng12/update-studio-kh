#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// A one-shot HTTP server on a real loopback socket, so the live checks prove the real client's
/// POST (with the contract's query) and DELETE reach a socket, not an in-process stand-in.
final class LoopbackHTTPServer: @unchecked Sendable {
    /// method, target → the JSON body to answer with 200.
    var handler: ((String, String) -> Data)?
    let listenFD: Int32
    let port: UInt16
    let lock = NSLock()
    var requests: [String] = []
    var stopped = false
    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return nil }
        var actual = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd; port = UInt16(bigEndian: actual.sin_port)
    }
    func serve() {
        while true {
            lock.lock(); let done = stopped; lock.unlock(); if done { break }
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) > 0 else { continue }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            var wait = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            var head = Data()
            var buf = [UInt8](repeating: 0, count: 2048)
            while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(client, &buf, buf.count, 0)
                if n <= 0 { break }
                head.append(contentsOf: buf[0..<n])
            }
            let text = String(decoding: head, as: UTF8.self)
            guard let line = text.split(separator: "\r\n").first else { continue }
            lock.lock(); requests.append(String(line)); lock.unlock()
            let method = line.split(separator: " ").first.map(String.init) ?? ""
            let target = line.split(separator: " ").count > 1 ? String(line.split(separator: " ")[1]) : ""
            let body = handler?(method, target) ?? Data("{}".utf8)
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = (reply.data(using: .utf8) ?? Data()).withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            _ = body.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return requests }
}

/// HOLD_LIVE_ONLY=1: the real URLSession client, a real loopback socket, no window and no app.
func updateHoldLiveTests() {
    setenv("KHU_HOLD_TOKEN_FILE", tmpDir("hold-token-live").appendingPathComponent("hold-token").path, 1)
    guard let server = LoopbackHTTPServer() else { expect(false, "HL1 the loopback fixture could not listen"); return }
    server.handler = { method, _ in
        method == "POST"
            ? Data(#"{"safe":true,"unsettled":[],"dispatch_paused_s":120,"in_flight":2}"#.utf8)
            : Data("{}".utf8)
    }
    let thread = Thread { server.serve() }
    thread.start()
    let endpoint = UpdateHold.trusted("http://127.0.0.1:\(server.port)/api/maintenance/hold")
    expect(endpoint != nil, "HL1 a real loopback endpoint is trusted")
    guard let endpoint else { return }
    do {
        let reply = try beginLive(endpoint)
        expect(reply.safe && reply.inFlight == 2 && reply.pausedSeconds == 120,
               "HL2 the real client reads the contract's reply (\(reply))")
        try? UpdateHold.resume(endpoint, http: URLSessionHTTPClient())
    } catch { expect(false, "HL2 the live hold failed: \(error)") }
    let deadline = Date().addingTimeInterval(5)
    while server.seen.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    server.stop()
    let seen = server.seen
    expect(seen.contains { $0.hasPrefix("POST /api/maintenance/hold?") && $0.contains("timeout_s=20") && $0.contains("pause_s=120") },
           "HL3 the POST carries the contract's timeout and pause (\(seen))")
    expect(seen.contains { $0.hasPrefix("DELETE /api/maintenance/hold") }, "HL4 the DELETE resumes the same endpoint (\(seen))")
}

private func beginLive(_ endpoint: URL) throws -> UpdateHold.Reply {
    try UpdateHold.begin(endpoint, http: URLSessionHTTPClient())
}
