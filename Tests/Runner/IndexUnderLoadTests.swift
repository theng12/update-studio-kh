import Foundation

/// The feed index must answer while every transfer slot is busy (row 20261120-215).
///
/// Measured 2026-11-20: 46–65 Macs pulling at once made `GET /release.json` answer `503 busy` for
/// ~18 s. The index took one of the same fixed slots as a 1.48 GB stream, so a fleet checking during
/// a rollout was told the publisher was busy and retried together. 65 is the fleet size, not 46.
func indexUnderLoadTests() {
    let rig = Rig("index-under-load")
    try? rig.publish("big", "1.0.0", rig.artifact("big.bin", String(repeating: "x", count: 8 << 20)))
    guard let file = FeedPublisher.loadFeed(from: rig.feed)?.apps["big"]?.file else {
        expect(false, "IDX1 fixture feed"); return
    }
    // The fleet's real size, and the same count of transfer slots.
    let fleet = 65
    let server = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0,
                            maxConnections: fleet)
    guard let fd = try? server.listen() else { expect(false, "IDX1 listen"); return }
    let port = FeedServer.boundPort(fd)
    Thread.detachNewThread { try? server.serve(on: fd) }
    defer { close(fd) }

    func connect() -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return s
    }
    func send(_ s: Int32, _ line: String) { _ = line.withCString { write(s, $0, strlen($0)) } }
    func get(_ path: String, timeout: TimeInterval = 10) -> (Int, String)? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var out: (Int, String)?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                out = (http.statusCode, String(decoding: data ?? Data(), as: UTF8.self))
            }
            sem.signal()
        }.resume()
        return sem.wait(timeout: .now() + timeout + 2) == .success ? out : nil
    }

    // Every slot is held by an artifact transfer whose reader has stopped reading: the server is
    // blocked in send, exactly as it is during a rollout of a 1.48 GB app.
    var stalled: [Int32] = []
    for _ in 0..<fleet {
        let s = connect()
        send(s, "GET /artifacts/\(file) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        stalled.append(s)
    }
    defer { for s in stalled { close(s) } }
    Thread.sleep(forTimeInterval: 1.0)

    // Still full: another transfer is refused exactly as before.
    expect(get("/artifacts/\(file)")?.0 == 503,
           "IDX1 with all \(fleet) slots held by transfers, another transfer is still answered 503 busy")

    // The index answers anyway. Before 0.1.73 both of these were 503 for ~18 s.
    let index = get("/release.json")
    expect(index?.0 == 200 && index?.1.contains("kh.feed") == true,
           "IDX1 the feed index answers 200 while all \(fleet) transfer slots are held (\(index?.0 ?? -1))")
    let page = get("/")
    expect(page?.0 == 200, "IDX1 the page answers 200 while all \(fleet) transfer slots are held (\(page?.0 ?? -1))")
}
