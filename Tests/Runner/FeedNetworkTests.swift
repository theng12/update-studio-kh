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
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        gets.append(url)
        if url.host == "100.64.0.2" && headers["Authorization"] != nil { credentialOnMirror = true }
        if url.path == "/commands" { return (commands, 200) }
        guard let data = releases[url.host ?? ""] else { throw URLError(.cannotConnectToHost) }
        return (data, 200)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if statusOffline { throw URLError(.cannotConnectToHost) }
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
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
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
        let recovered = try Agent.download(entry, app: "fixture", serverBase: URL(string: "http://100.64.0.2")!, stateDir: root, http: http, fallbacks: [origin])
        let recoveredBytes = try Data(contentsOf: recovered)
        expect(recoveredBytes == bytes, "FN unavailable artifact source falls back even without a partial file")
        expect(!http.credentialOnMirror, "FN mirror feed and artifact requests carry no enrolment token")
        var hostMemory = memory
        hostMemory.feedNetwork = FeedNetwork(feedURLs: [mirror, upstream], hosts: ["client": FeedHostRole(enabled: true, bind: "100.64.0.2")])
        let sources = try Agent.feedSources(config: config, memory: hostMemory, serverBase: origin)
        expect(sources == [URL(string: upstream)!], "FN a feed host refreshes from the original publisher rather than itself")
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
    let server = FeedServer(feedDir: root, stateDir: root.appendingPathComponent("server"), bind: "127.0.0.1", port: 0, feedOnly: true)
    expect(server.handleRequest(HTTPRequest(method: "POST", path: "/enrol"), remote: "127.0.0.1").status == 404,
           "FN feed-only host exposes no enrolment route")
    expect(server.handleRequest(HTTPRequest(method: "GET", path: "/commands"), remote: "127.0.0.1").status == 404,
           "FN feed-only host exposes no control route")
    for invalid in ["http://evil.example/release.json", "http://100.64.0.2/other", "http://token@100.64.0.2/release.json"] {
        expectThrows("FN unsafe feed endpoint refused", contains: "feed address") { _ = try FeedNetwork.feedURL(invalid) }
    }
}
