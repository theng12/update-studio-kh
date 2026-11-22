import Foundation

func publisherStatusTests() {
    let root = tmpDir("publisher-status")
    let feed = root.appendingPathComponent("feed")
    let state = root.appendingPathComponent("state")
    let bin = root.appendingPathComponent("bin/khu")
    let base = root.appendingPathComponent("base")
    let current = base.appendingPathComponent("current")
    let target = base.appendingPathComponent("versions/0.1.80/khu")
    let release = FeedPublisher.releaseFile(in: feed)
    let server = FeedServer(feedDir: feed, stateDir: state, bind: "127.0.0.1", port: 0)
    let request = HTTPRequest(method: "GET", path: "/status")
    let keys: Set<String> = ["disk", "feed", "bin_khu", "base_current"]
    func object(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
    }

    do {
        let empty = server.handleRequest(request, remote: "127.0.0.1")
        let fields = object(empty)
        expect(empty.status == 200 && Set(fields.keys) == keys, "PS1 empty publisher returns the four status fields")
        expect(["feed", "bin_khu", "base_current"].allSatisfy { fields[$0] is NSNull },
               "PS1 missing files are explicitly null")
        let missing = root.appendingPathComponent("missing")
        let badDisk = FeedServer(feedDir: missing.appendingPathComponent("feed"), stateDir: state, bind: "127.0.0.1", port: 0)
        let unavailable = badDisk.handleRequest(request, remote: "127.0.0.1")
        expect(unavailable.status == 200 && object(unavailable)["disk"] is NSNull, "PS1 unreadable volume is null, not a failed request")

        for directory in [feed, bin.deletingLastPathComponent(), target.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let timestamp = "2026-11-22T05:00:00.123Z"
        let envelope = Release(feed: JSON.encode(Feed(published_at: timestamp)), signature: Data([2, 3]))
        try JSON.encode(envelope).write(to: release)
        let binBytes = Data("a stale binary".utf8), targetBytes = Data("a current binary".utf8)
        try binBytes.write(to: bin)
        try targetBytes.write(to: target)
        try fm.createSymbolicLink(atPath: current.path, withDestinationPath: "versions/0.1.80/khu")

        let start = ProcessInfo.processInfo.systemUptime
        let reply = server.handleRequest(request, remote: "100.64.0.9")
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let status = object(reply)
        expect(reply.status == 200 && reply.contentType == "application/json" && Set(status.keys) == keys,
               "PS2 tailnet publisher returns the exact status shape (fixture: \(elapsed) ms)")
        let disk = status["disk"] as? [String: Double]
        expect((disk?["total_gb"] ?? 0) > 0 && (disk?["free_gb"] ?? -1) >= 0, "PS2 disk reports the fixture's real volume")
        let served = server.handleRequest(HTTPRequest(method: "GET", path: "/release.json"), remote: "127.0.0.1")
        let published = status["feed"] as? [String: String]
        expect(served.status == 200 && published?["sha256"] == Signing.sha256Hex(served.data), "PS2 hashes the exact served envelope bytes")
        expect(published?["published_at"] == timestamp, "PS2 timestamp comes from the decoded envelope")
        expect(status["bin_khu"] as? String == Signing.sha256Hex(binBytes), "PS2 bin/khu copy hash")
        expect(status["base_current"] as? String == Signing.sha256Hex(targetBytes), "PS2 base/current hashes its resolved binary")

        try fm.removeItem(at: target)
        let broken = server.handleRequest(request, remote: "127.0.0.1")
        expect(broken.status == 200 && object(broken)["base_current"] is NSNull && object(broken)["feed"] is [String: String],
               "PS3 a dangling current link does not hide the other fields")
        let mirror = FeedServer(feedDir: feed, stateDir: state, bind: "127.0.0.1", port: 0, feedOnly: true)
        expect(object(mirror.handleRequest(request, remote: "127.0.0.1"))["ok"] as? Bool == true,
               "PS4 a feed-only mirror keeps the old liveness body")
        expect(object(server.handleRequest(request, remote: "192.0.2.1"))["ok"] as? Bool == true,
               "PS4 a non-tailnet peer gets no host diagnostics")
        expect(server.handleRequest(HTTPRequest(method: "POST", path: "/status"), remote: "100.64.0.9").status == 401,
               "PS4 POST /status still requires a token")
    } catch { expect(false, "publisher status fixture: \(error)") }
}
