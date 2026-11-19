import Foundation
import CryptoKit

private final class CountingHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    private func note(_ url: URL) {
        lock.lock(); seen.append(url.absoluteString); lock.unlock()
    }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        note(url); throw URLError(.cannotConnectToHost)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        note(url); throw URLError(.cannotConnectToHost)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        note(url); throw URLError(.cannotConnectToHost)
    }
}

/// The publisher key is pinned in the build: a rewritten trust file cannot make another publisher's
/// signatures verify, and a config or kit naming a different key is refused in one sentence.
func pinnedKeyTests() {
    let root = tmpDir("pinned-key")
    let fleet = Signing.generateKeyPair()
    let other = Signing.generateKeyPair()
    PinnedKey.test = fleet.publicKeyBase64
    defer { PinnedKey.test = nil }

    func release(_ feed: Feed, signer: Curve25519.Signing.PrivateKey) -> Data {
        let body = try! JSON.encode(feed)
        return try! JSON.encode(Release(feed: body, signature: try! Signing.sign(body, with: signer)))
    }
    var feed = Feed(published_at: ISO.string(Date()))
    feed.apps["updater"] = FeedApp(version: "0.1.66", file: "khu", sha256: Signing.sha256Hex(Data("x".utf8)),
                                   bytes: 1, kind: "updater")
    let state = root.appendingPathComponent("state")
    let config = AgentConfig(feedURL: "http://127.0.0.1:9/release.json", publicKey: fleet.publicKeyBase64,
                             stateDir: state.path, machine: "pin-mac", token: String(repeating: "t", count: 32))
    let pinnedPrint = PinnedKey.fingerprint(fleet.publicKeyBase64)
    let otherPrint = PinnedKey.fingerprint(other.publicKeyBase64)

    var memory = AgentMemory()
    expect((try? Agent.checkedFeed(release(feed, signer: fleet.privateKey), config: config,
                                   memory: &memory, now: Date())) != nil,
           "PK1 a feed signed with the pinned key verifies")
    expectThrows("PK2 a feed signed with any other key is refused", contains: "invalid feed signature") {
        var otherMemory = AgentMemory()
        _ = try Agent.checkedFeed(release(feed, signer: other.privateKey), config: config,
                                  memory: &otherMemory, now: Date())
    }

    var wrong = config
    wrong.publicKey = other.publicKeyBase64
    expectThrows("PK3 a config naming another key is refused, naming the saved key", contains: otherPrint) {
        try Agent.validate(wrong)
    }
    expectThrows("PK4 the refusal names the pinned key too", contains: pinnedPrint) {
        try Agent.validate(wrong)
    }
    expectThrows("PK5 the refusal says what to do", contains: "Connect with the current kit") {
        try Agent.validate(wrong)
    }
    let counter = CountingHTTP()
    expectThrows("PK6 a mismatched config makes no request", contains: "Nothing was changed") {
        try Connect.check(config: wrong, http: counter)
    }
    expect(counter.calls.isEmpty, "PK7 the refused check sent nothing")

    func makeKit(_ name: String, key: String) -> URL {
        let kit = root.appendingPathComponent(name)
        try! fm.createDirectory(at: kit, withIntermediateDirectories: true)
        let pub: [String: String] = ["feedURL": "http://100.64.0.7:8790/release.json",
                                     "enrolURL": "http://100.64.0.7:8790/enrol", "publicKey": key]
        let files: [String: Data] = ["publisher.json": try! JSON.encode(pub),
                                     "install-agent.sh": Data("#!/bin/bash\n".utf8)]
        var pins: [String: Any] = [:]
        for (name, data) in files {
            try! data.write(to: kit.appendingPathComponent(name))
            pins[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
        }
        try! JSONSerialization.data(withJSONObject: ["format": "fixture", "files": pins])
            .write(to: kit.appendingPathComponent("MANIFEST.json"))
        return kit
    }
    let home = root.appendingPathComponent("home")
    try! fm.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
    let otherKit = makeKit("kit-other", key: other.publicKeyBase64)
    expectThrows("PK8 a setup kit naming another key is refused", contains: "not the key inside this copy") {
        _ = try Connect.run(kit: otherKit, home: home, machine: "pin-mac", code: "123456", http: counter)
    }
    expect(counter.calls.isEmpty, "PK9 the refused kit sent nothing")
    let fleetKit = makeKit("kit-fleet", key: fleet.publicKeyBase64)
    expect((try? Connect.run(kit: fleetKit, home: home, machine: "pin-mac", code: "123456", http: counter)) == nil
           && counter.calls.count == 1,
           "PK10 the pinned kit is tried against its publisher")

    let base = home.appendingPathComponent("Library/KHUpdater/base")
    let helperState = home.appendingPathComponent("Library/KHUpdater/state")
    try! fm.createDirectory(at: base, withIntermediateDirectories: true)
    try! fm.createDirectory(at: helperState, withIntermediateDirectories: true)
    var saved = config
    saved.stateDir = helperState.path
    saved.stubBase = base.path
    try! JSON.encode(saved).write(to: base.appendingPathComponent("config.json"))
    expectThrows("PK11 repair refuses a kit naming another key", contains: "not the key inside this copy") {
        _ = try Connect.repairSetup(kit: otherKit, home: home)
    }
    expectThrows("PK12 repair refuses a config naming another key", contains: otherPrint) {
        var foreign = saved
        foreign.publicKey = other.publicKeyBase64
        try! JSON.encode(foreign).write(to: base.appendingPathComponent("config.json"))
        defer { try! JSON.encode(saved).write(to: base.appendingPathComponent("config.json")) }
        _ = try Connect.repairSetup(kit: fleetKit, home: home)
    }
}
