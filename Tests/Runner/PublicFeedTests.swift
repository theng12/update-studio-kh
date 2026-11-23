import Foundation
import CryptoKit

private final class RecordingHTTP: HTTPClient, @unchecked Sendable {
    struct Call { let method: String; let url: URL; let headers: [String: String]; let body: Data? }
    private let lock = NSLock()
    private var seen: [Call] = []
    private let feed: Data?
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return seen }
    init(feed: Data?) { self.feed = feed }
    private func record(_ method: String, _ url: URL, _ headers: [String: String], _ body: Data? = nil) {
        lock.lock(); seen.append(Call(method: method, url: url, headers: headers, body: body)); lock.unlock()
    }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        record("GET", url, headers)
        if url.path.hasSuffix("/release.json"), let feed { return (feed, 200) }
        return (Data("no".utf8), 404)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        record("POST", url, headers, body); return (Data(), 404)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        record("DOWNLOAD", url, headers); return 404
    }
}

private struct NoShell: Shell {
    struct Called: Error {}
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        throw Called()
    }
}

/// A public feed is read and installed from anonymously; a publisher's address still gets the token.
func publicFeedTests() {
    let root = tmpDir("public-feed")
    expect((try? FeedNetwork.feedURL("https://theng12.github.io/kh-releases/release.json")) != nil,
           "PF1 a public https feed address is accepted")
    expect((try? FeedNetwork.feedURL("http://100.64.0.7:8790/release.json")) != nil,
           "PF2 the tailnet http address still works")
    expect((try? FeedNetwork.feedURL("http://example.com/release.json")) == nil,
           "PF3 plain http to a public host is refused")
    expect((try? FeedNetwork.feedURL("https://user:pw@example.com/release.json")) == nil,
           "PF4 an address with credentials is refused")
    expect((try? FeedNetwork.feedURL("https://example.com/feed.json")) == nil,
           "PF5 a path other than /release.json is refused")
    expect((try? FeedNetwork.feedURL("https://example.com/release.json?x=1")) == nil,
           "PF6 a query is refused")
    expect((try? FeedNetwork.feedURL("ftp://example.com/release.json")) == nil,
           "PF7 another scheme is refused")
    expect(!FeedNetwork.authenticated(URL(string: "https://theng12.github.io/kh-releases/release.json")!),
           "PF8 a public address never receives this Mac's token")
    expect(FeedNetwork.authenticated(URL(string: "http://100.64.0.7:8790/release.json")!)
           && FeedNetwork.authenticated(URL(string: "http://mac.tail.ts.net:8790/release.json")!)
           && FeedNetwork.authenticated(URL(string: "http://127.0.0.1:8790/release.json")!),
           "PF9 the publisher's own addresses are authenticated")

    let fleet = Signing.generateKeyPair()
    let other = Signing.generateKeyPair()
    PinnedKey.test = fleet.publicKeyBase64
    defer { PinnedKey.test = nil }
    var feed = Feed(published_at: ISO.string(Date()))
    feed.apps["updater"] = FeedApp(version: "0.1.67", file: "khu", sha256: Signing.sha256Hex(Data("u".utf8)),
                                   bytes: 1, kind: "updater")
    func signed(_ feed: Feed, signer: Curve25519.Signing.PrivateKey) -> Data {
        let body = try! JSON.encode(feed)
        return try! JSON.encode(Release(feed: body, signature: try! Signing.sign(body, with: signer)))
    }
    func config(_ address: String) -> AgentConfig {
        AgentConfig(feedURL: address, publicKey: fleet.publicKeyBase64, stateDir: root.appendingPathComponent("state").path,
                    machine: "public-mac", token: "fixture-token-0123456789abcdef")
    }

    // A public feed: the run reads it anonymously and contacts no publisher at all.
    let publicHTTP = RecordingHTTP(feed: signed(feed, signer: fleet.privateKey))
    _ = try? Agent.runOnce(config: config("https://theng12.github.io/kh-releases/release.json"), http: publicHTTP,
                           shell: NoShell(), executable: nil, appFolders: [])
    expect(publicHTTP.calls.contains { $0.url.path.hasSuffix("/release.json") },
           "PF10 the public feed itself was read")
    expect(publicHTTP.calls.allSatisfy { $0.headers["Authorization"] == nil },
           "PF11 no request to a public address carried this Mac's token")
    expect(publicHTTP.calls.allSatisfy { !$0.url.path.hasSuffix("/status") && !$0.url.path.hasSuffix("/commands") },
           "PF12 a public feed is never reported to and never asked for orders")

    // The publisher's own address: still authenticated, still reporting.
    let publisherHTTP = RecordingHTTP(feed: signed(feed, signer: fleet.privateKey))
    _ = try? Agent.runOnce(config: config("http://100.64.0.7:8790/release.json"), http: publisherHTTP,
                           shell: NoShell(), executable: nil, appFolders: [])
    expect(publisherHTTP.calls.contains { $0.url.path.hasSuffix("/status")
           && $0.headers["Authorization"] == "Bearer fixture-token-0123456789abcdef" },
           "PF13 the publisher's address still receives the authenticated status")

    // Setup from a public link: verified before anything is installed, and no token is written.
    func kit(_ name: String, key: String) -> URL {
        let dir = root.appendingPathComponent(name)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pub: [String: String] = ["feedURL": "http://100.64.0.7:8790/release.json",
                                     "enrolURL": "http://100.64.0.7:8790/enrol", "publicKey": key]
        let script = "#!/bin/bash\nset -e\nmkdir -p \"$2/Library/KHUpdater/base\"\ncp \"$1\" \"$2/Library/KHUpdater/base/config.json\"\necho installed\n"
        let files: [String: Data] = ["publisher.json": try! JSON.encode(pub), "install-agent.sh": Data(script.utf8)]
        var pins: [String: Any] = [:]
        for (n, d) in files {
            try! d.write(to: dir.appendingPathComponent(n)); pins[n] = ["bytes": d.count, "sha256": Signing.sha256Hex(d)]
        }
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("install-agent.sh").path)
        try! JSONSerialization.data(withJSONObject: ["format": "fixture", "files": pins])
            .write(to: dir.appendingPathComponent("MANIFEST.json"))
        return dir
    }
    let fleetKit = kit("kit-fleet", key: fleet.publicKeyBase64)
    let home = root.appendingPathComponent("home")
    try! fm.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
    let good = RecordingHTTP(feed: signed(feed, signer: fleet.privateKey))
    var message: String?, setupFailure: String?
    do {
        message = try Connect.usePublicFeed(kit: fleetKit, home: home, machine: "public-mac",
                                            address: "https://theng12.github.io/kh-releases/release.json", http: good)
    } catch { setupFailure = "\(error)" }
    expect(message != nil, "PF14 a public link signed by the pinned key sets this Mac up (\(setupFailure ?? "no message"))")
    expect(good.calls.allSatisfy { $0.headers["Authorization"] == nil },
           "PF15 setup from a public link sent no token")
    let saved = (try? JSON.decode(AgentConfig.self, from: Data(contentsOf: home.appendingPathComponent("Library/KHUpdater/base/config.json"))))
    expect(saved?.feedURL == "https://theng12.github.io/kh-releases/release.json" && saved?.token == "",
           "PF16 the saved settings name the public feed and carry no token")

    let home2 = root.appendingPathComponent("home2")
    try! fm.createDirectory(at: home2.appendingPathComponent("Library"), withIntermediateDirectories: true)
    expectThrows("PF17 a link whose feed is not signed by the pinned key is refused",
                 contains: "signed by this fleet's key") {
        _ = try Connect.usePublicFeed(kit: fleetKit, home: home2, machine: "public-mac",
                                      address: "https://example.test/release.json",
                                      http: RecordingHTTP(feed: signed(feed, signer: other.privateKey)))
    }
    expectThrows("PF18 a publisher's own address is not a public link", contains: "publisher's address") {
        _ = try Connect.usePublicFeed(kit: fleetKit, home: home2, machine: "public-mac",
                                      address: "http://publisher.tail.ts.net:8790/release.json", http: good)
    }
    expect(!Connect.isSetUp(home: home2), "PF19 a refused public setup installed nothing")
}

/// Owner, 2026-11-24: the gate carries a cold first run from a data dir that does not exist, because
/// the drives carry 0.1.75 and a Mac set up tomorrow may pull this build first. This walks the
/// window's own one-press state into the setup call and reads the result back off disk.
func firstRunWalkTests() {
    _ = NSApplication.shared
    let root = tmpDir("first-run-walk")
    let fleet = Signing.generateKeyPair()
    PinnedKey.test = fleet.publicKeyBase64
    defer { PinnedKey.test = nil }
    var feed = Feed(published_at: ISO.string(Date()))
    feed.apps["updater"] = FeedApp(version: "0.1.81", file: "khu", sha256: Signing.sha256Hex(Data("u".utf8)),
                                    bytes: 1, kind: "updater")

    // A copy downloaded for anyone: it carries the pinned key and no address.
    let kit = root.appendingPathComponent("kit")
    try! fm.createDirectory(at: kit, withIntermediateDirectories: true)
    let script = "#!/bin/bash\nset -e\nmkdir -p \"$2/Library/KHUpdater/base\"\ncp \"$1\" \"$2/Library/KHUpdater/base/config.json\"\necho installed\n"
    let files: [String: Data] = ["publisher.json": try! JSON.encode(["publicKey": fleet.publicKeyBase64]),
                                 "install-agent.sh": Data(script.utf8)]
    var pins: [String: Any] = [:]
    for (n, d) in files {
        try! d.write(to: kit.appendingPathComponent(n)); pins[n] = ["bytes": d.count, "sha256": Signing.sha256Hex(d)]
    }
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kit.appendingPathComponent("install-agent.sh").path)
    try! JSONSerialization.data(withJSONObject: ["format": "fixture", "files": pins])
        .write(to: kit.appendingPathComponent("MANIFEST.json"))

    // The window a fresh Mac opens: its feed is already named, nothing is asked for, one press.
    let home = root.appendingPathComponent("home")   // deliberately never created
    let window = ConnectionWindow.testFirstRun(kit: kit, home: home)
    let state = window.testState
    expect(state.address == ConnectionWindow.publicFeedURL && !state.editable,
           "FW1 a fresh Mac's first run already names its feed and cannot be retyped (\(state.address))")
    expect(!state.codeVisible && state.primary == "Connect",
           "FW1 and it asks for nothing before the one press (code \(state.codeVisible), \(state.primary))")
    window.testFail("the feed did not answer")
    expect(window.testState.primary == "Retry" && window.testState.status.contains("the feed did not answer"),
           "FW2 an unreachable feed is a named failure with Retry (\(window.testState.status))")

    // The press, from nothing on disk.
    let body = try! JSON.encode(feed)
    let release = try! JSON.encode(Release(feed: body, signature: try! Signing.sign(body, with: fleet.privateKey)))
    let http = RecordingHTTP(feed: release)
    do {
        _ = try Connect.usePublicFeed(kit: kit, home: home, machine: "fresh-mac", address: state.address, http: http)
        expect(true, "FW3 the one press set this Mac up")
    } catch { expect(false, "FW3 the one press set this Mac up (\(error))") }
    let cfgFile = home.appendingPathComponent("Library/KHUpdater/base/config.json")
    let cfg = (try? Data(contentsOf: cfgFile)).flatMap { try? JSON.decode(AgentConfig.self, from: $0) }
    expect(cfg?.feedURL == ConnectionWindow.publicFeedURL && cfg?.token == "",
           "FW4 the saved settings name the public feed and carry no token (\(cfg?.feedURL ?? "nothing saved"))")
    expect(cfg?.apps["updater"]?.automatic == true,
           "FW5 the helper this Mac just installed updates itself automatically")
    expect(HelperSettings.load(from: home.appendingPathComponent("Library/KHUpdater/state")).installsAutomatically,
           "FW6 and with nothing saved this Mac installs updates automatically")
    do {
        _ = try Connect.usePublicFeed(kit: kit, home: home, machine: "fresh-mac", address: state.address, http: http)
        expect(false, "FW7 a second first run is refused")
    } catch {
        expect("\(error)".contains("already set up"), "FW7 a second first run is refused (\(error))")
    }
}
