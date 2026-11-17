import Foundation
import CryptoKit

private final class NetworkClient: HTTPClient, @unchecked Sendable {
    var releases: [String: Data] = [:]
    var artifacts: [String: Data] = [:]
    var gets: [URL] = []
    var downloads: [URL] = []
    var credentialOnMirror = false
    var statusOffline = false
    var statusCode = 200
    var downloadOffline: Set<String> = []
    var commands = Data()
    var statusReports: [[String: Any]] = []
    var validateHealth = false
    var acceptedStatus = false
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        gets.append(url)
        if url.host == "100.64.0.2" && headers["Authorization"] != nil { credentialOnMirror = true }
        if url.path == "/commands" { return (commands, 200) }
        guard let data = releases[url.host ?? ""] else { throw URLError(.cannotConnectToHost) }
        return (data, 200)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if statusOffline { throw URLError(.cannotConnectToHost) }
        if url.path == "/status", let report = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            statusReports.append(report)
            if validateHealth, FeedServer.reportRefusal(installed: report["installed"] as? [String: String],
                health: report["health"] as? [String: String], defaults: report["automatic_default"] as? [String: Bool]) != nil {
                return (Data(), 400)
            }
            acceptedStatus = statusCode == 200
        }
        return (Data(), statusCode)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        downloads.append(url)
        if downloadOffline.contains(url.host ?? "") { throw URLError(.cannotConnectToHost) }
        if url.host == "100.64.0.2" && headers["Authorization"] != nil { credentialOnMirror = true }
        let data = artifacts[url.host ?? ""] ?? Data()
        try data.write(to: file)
        return 200
    }
}
private struct NetworkShell: Shell {
    var hostStatus = ""
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: executable == "/bin/launchctl" ? hostStatus : "", stderr: "")
    }
}

func feedNetworkTests() {
    let key = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    let now = Date()
    let root = tmpDir("feed-network")
    let origin = URL(string: "http://100.64.0.1")!
    let mirror = "http://100.64.0.2/release.json"
    let upstream = "http://100.64.0.1/release.json"
    var config = AgentConfig(feedURL: upstream, publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
        stateDir: root.path, machine: "client", token: "fixture-token", apps: [:])
    config.network = FeedNetwork(feedURLs: [mirror, upstream])
    let bytes = Data("verified artifact".utf8)
    let entry = FeedApp(version: "1.0.0", file: "fixture.dmg", sha256: Signing.sha256Hex(bytes), bytes: Int64(bytes.count), kind: "app-dmg")
    let feed = Feed(published_at: ISO.string(now), apps: ["fixture": entry])
    func signed(_ feed: Feed, by signer: Curve25519.Signing.PrivateKey) throws -> Data {
        let body = JSON.encode(feed)
        return JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: signer)))
    }
    do {
        let http = NetworkClient()
        http.releases["100.64.0.1"] = try signed(feed, by: key)
        var memory = AgentMemory()
        let selected = try Agent.selectFeed(http: http, serverBase: origin, config: config, memory: &memory, now: now)
        expect(selected.base.appendingPathComponent("release.json") == URL(string: upstream)! && http.gets.first?.host == "100.64.0.2", "FN unreachable mirror falls back to original publisher")
        http.gets = []
        http.releases["100.64.0.2"] = try signed(feed, by: other)
        _ = try Agent.selectFeed(http: http, serverBase: origin, config: config, memory: &memory, now: now)
        expect(http.gets.count == 2, "FN untrusted mirror never replaces the pinned signer; valid fallback works")
        var older = feed; older.published_at = ISO.string(now.addingTimeInterval(-60))
        http.releases["100.64.0.2"] = try signed(older, by: key)
        let fresh = try Agent.selectFeed(http: http, serverBase: origin, config: config, memory: &memory, now: now)
        expect(fresh.feed.published_at == feed.published_at, "FN stale mirror does not lower the feed high-water mark")
        http.artifacts["100.64.0.2"] = Data("bad bytes".utf8)
        http.artifacts["100.64.0.1"] = bytes
        let downloaded = try Agent.download(entry, app: "fixture", serverBase: URL(string: "http://100.64.0.2")!, stateDir: root, http: http, fallbacks: [origin])
        let received = try Data(contentsOf: downloaded)
        expect(received == bytes && http.downloads.count == 2, "FN corrupt mirrored bytes fall back and still match signed hash")
        http.downloadOffline = ["100.64.0.2"]
        // The finished artifact above is reused by design; this case needs a Mac that has not
        // downloaded it, so the unavailable source and the fallback are really reached.
        _ = try? Trash.move(downloaded, into: Trash.root(in: root))
        let recovered = try Agent.download(entry, app: "fixture", serverBase: URL(string: "http://100.64.0.2")!, stateDir: root, http: http, fallbacks: [origin])
        let recoveredBytes = try Data(contentsOf: recovered)
        expect(recoveredBytes == bytes, "FN unavailable artifact source falls back even without a partial file")
        expect(!http.credentialOnMirror, "FN mirror feed and artifact requests carry no enrolment token")
        var hostMemory = memory
        hostMemory.feedNetwork = FeedNetwork(feedURLs: [mirror, upstream], hosts: ["client": FeedHostRole(enabled: true, bind: "100.64.0.2")])
        let sources = try Agent.feedSources(config: config, memory: hostMemory, serverBase: origin)
        expect(sources == [URL(string: upstream)!, URL(string: mirror)!],
               "FN a feed host reads the original publisher first, never its own mirror")
        // A host whose role is off (a publisher Mac that does not mirror) reads the same source:
        // an install there must never depend on the hosting role.
        var offMemory = memory
        offMemory.feedNetwork = FeedNetwork(feedURLs: [mirror, upstream], hosts: ["client": FeedHostRole(enabled: false, bind: "100.64.0.2")])
        let offSources = try Agent.feedSources(config: config, memory: offMemory, serverBase: origin)
        expect(offSources == sources, "FN a host with its hosting role off selects the configured feed exactly the same way")
    } catch { expect(false, "FN source verification: \(error)") }
    do {
        let http = NetworkClient(); http.statusOffline = true
        http.releases["100.64.0.2"] = try signed(feed, by: key)
        http.artifacts["100.64.0.2"] = bytes
        var local = config
        local.stateDir = tmpDir("offline-feed-client").path
        local.apps = ["fixture": AppConfig(bundlePath: root.appendingPathComponent("missing.app").path, recipe: "fake-for-tests", automatic: true)]
        let result = try Agent.runOnce(config: local, http: http, shell: NetworkShell(), now: now, requested: ["fixture"], appFolders: [])
        expect(!result.statusPosted && result.updates == 1, "FN explicit local install works from mirror while publisher is offline")
        expect(!http.gets.contains(where: { $0.path == "/commands" }), "FN offline client does not invent a signed remote order")
        let automatic = try Agent.runOnce(config: local, http: http, shell: NetworkShell(), now: now, appFolders: [])
        expect(automatic.updates == 0, "FN Automatic waits for the publisher rather than guessing remote switches")
        http.statusOffline = false; http.statusCode = 401
        expectThrows("FN authentication refusal is never treated as publisher downtime", contains: "status was refused") {
            _ = try Agent.runOnce(config: local, http: http, shell: NetworkShell(), now: now, requested: ["fixture"], appFolders: [])
        }
    } catch { expect(false, "FN offline local install: \(error)") }
    do {
        let publisher = tmpDir("network-publisher")
        let keyFile = publisher.appendingPathComponent("fixture.key")
        try Signing.savePrivateKey(key, to: keyFile)
        try FeedPublisher.saveFeed(feed, to: publisher, key: key)
        let legacy = try FeedPublisher.loadVerifiedFeed(from: publisher, publicKey: key.publicKey)
        expect(legacy?.network == nil, "FN legacy signed feeds have no host role by default")
        let network = FeedNetwork(feedURLs: [mirror, upstream], hosts: ["host": FeedHostRole(enabled: true, bind: "100.64.0.2")])
        try FeedPublisher.configureNetwork(feedDir: publisher, keyFile: keyFile, network: network, now: now.addingTimeInterval(-60))
        let configured = try FeedPublisher.loadVerifiedFeed(from: publisher, publicKey: key.publicKey)
        expect(configured?.apps == feed.apps && configured?.network == network, "FN network publication preserves app entries under the pinned signature")
        expect((configured?.publishedAt ?? .distantPast) > (feed.publishedAt ?? .distantPast), "FN network publication advances date even with an older clock")
        let artifact = publisher.appendingPathComponent("helper.bin")
        try bytes.write(to: artifact)
        try FeedPublisher.publish(feedDir: publisher, keyFile: keyFile, app: "updater", version: "1.0.0", artifact: artifact,
                                  kind: "updater", allowSame: false, meta: nil, now: now)
        let next = try FeedPublisher.loadVerifiedFeed(from: publisher, publicKey: key.publicKey)
        expect(next?.network == network, "FN later app publication keeps signed host and fallback settings")
        let before = try Data(contentsOf: FeedPublisher.releaseFile(in: publisher))
        expectThrows("FN invalid host publication leaves signed release intact", contains: "feed hosting") {
            try FeedPublisher.configureNetwork(feedDir: publisher, keyFile: keyFile,
                network: FeedNetwork(hosts: ["host": FeedHostRole(enabled: true, bind: "0.0.0.0")]))
        }
        let after = try Data(contentsOf: FeedPublisher.releaseFile(in: publisher))
        expect(before == after, "FN invalid network settings cannot replace a signed release")
    } catch { expect(false, "FN signed network publication: \(error)") }
    // A publisher must bind where this Mac is now, not where it was when a plist was written.
    do {
        expect((try? BindAddress.resolve("127.0.0.1")) == "127.0.0.1", "FN loopback bind is passed through")
        expect(BindAddress.isHostName("test-mac.tail4e72cf.ts.net"), "FN a MagicDNS name is a host name")
        expect(!BindAddress.isHostName("0.0.0.0"), "FN an IPv4 literal is not a host name")
        expect(!BindAddress.isHostName("bad_host"), "FN an underscore is not a host name")
        expectThrows("FN a name off the tailnet is refused with the reason", contains: "not a tailnet address") {
            _ = try BindAddress.resolve("localhost")
        }
        _ = try FeedHostRole(enabled: true, bind: "auto").validated()
        expect(true, "FN auto is accepted and resolved when the server starts")
    } catch { expect(false, "FN bind resolution: \(error)") }
    do {
        let state = tmpDir("host-report-recovery")
        let statusFile = state.appendingPathComponent("feed-host-status.json")
        let legacy = "feed host installed and started (launchd job com.khupdater.feed-host)"
        expect(legacy.utf8.count == 69 && FeedServer.reportRefusal(installed: nil,
            health: ["feed-host": legacy], defaults: nil) != nil, "FN controller rejects the released 69-byte host status")
        try AtomicFile.writeJSON(["status": legacy], to: statusFile)
        var local = config; local.stateDir = state.path
        let http = NetworkClient(); http.validateHealth = true
        // No release is supplied: stop after status and source selection, before any host reconciliation.
        do {
            _ = try Agent.runOnce(config: local, http: http,
                shell: NetworkShell(hostStatus: "state = spawn scheduled\nlast exit code = 78\n"), now: now, appFolders: [])
        } catch { /* The missing release is expected; assertions below prove the status path completed. */ }
        let health = http.statusReports.first?["health"] as? [String: String]
        expect(http.acceptedStatus && !http.gets.isEmpty, "FN stale host status no longer blocks reports or feed refresh")
        expect(health?["feed-host"] == "not running (last exit 78)", "FN status reports observed failure instead of stale success")
        let saved = try AtomicFile.readJSON([String: String].self, from: statusFile)
        expect(saved?["status"] == health?["feed-host"] && saved?["checked_at"] == ISO.string(now),
               "FN status file is refreshed before the status post")
        try AtomicFile.writeJSON(["status": "setup failed", "error": "failed: bootstrap refused"], to: statusFile)
        let retry = NetworkClient(); retry.validateHealth = true
        do {
            _ = try Agent.runOnce(config: local, http: retry,
                shell: NetworkShell(hostStatus: "state = running\npid = 123\n"), now: now, appFolders: [])
        } catch { /* Missing release again stops before host reconciliation. */ }
        let retriedHealth = retry.statusReports.first?["health"] as? [String: String]
        let retriedFile = try AtomicFile.readJSON([String: String].self, from: statusFile)
        expect(retry.acceptedStatus && retriedHealth?["feed-host"] == "running (pid 123); setup failed",
               "FN prior setup failure remains visible in bounded publisher health")
        expect(retriedFile?["error"] == "failed: bootstrap refused" && retriedFile?["status"] == retriedHealth?["feed-host"],
               "FN observation preserves failure detail until reconciliation succeeds")
    } catch { expect(false, "FN host status recovery: \(error)") }
    let server = FeedServer(feedDir: root, stateDir: root.appendingPathComponent("server"), bind: "127.0.0.1", port: 0, feedOnly: true)
    expect(server.handleRequest(HTTPRequest(method: "POST", path: "/enrol"), remote: "127.0.0.1").status == 404,
           "FN feed-only host exposes no enrolment route")
    expect(server.handleRequest(HTTPRequest(method: "GET", path: "/commands"), remote: "127.0.0.1").status == 404,
           "FN feed-only host exposes no control route")
    for invalid in ["http://evil.example/release.json", "http://100.64.0.2/other", "http://token@100.64.0.2/release.json"] {
        expectThrows("FN unsafe feed endpoint refused", contains: "feed address") { _ = try FeedNetwork.feedURL(invalid) }
    }
    // FN40 a mirror named by a bare IP can never answer: macOS refuses plain HTTP to an address
    // (ATS -1022) every time, so the agent drops it instead of retrying it forever. The parser still
    // reads one, because a signed handoff record may name a publisher that way.
    expect((try? FeedNetwork.feedURL("http://100.82.91.102:8790/release.json")) != nil,
           "FN40 the parser still reads an address a signed record may name")
    expect(FeedNetwork.isAddressLiteral("100.82.91.102") && !FeedNetwork.isAddressLiteral("terranash-1301.tail093f2c.ts.net"),
           "FN40 an address literal is told apart from a host name")
    expect((try? FeedNetwork.feedURL("http://terranash-1301.tail093f2c.ts.net:8790/release.json")) != nil,
           "FN40 the host name the feed uses is still accepted")
    expect((try? FeedNetwork.feedURL("http://127.0.0.1:8790/release.json")) != nil,
           "FN40 loopback stays usable for this Mac's own publisher")
}
