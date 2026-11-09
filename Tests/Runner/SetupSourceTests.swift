import Foundation

private struct SetupHTTP: HTTPClient {
    var release: Data
    var payload: Data
    var status = 200
    var offline = false
    var downloadOffline = false
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        if offline { throw URLError(.notConnectedToInternet) }
        return (release, status)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        throw URLError(.unsupportedURL)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        if downloadOffline { throw URLError(.networkConnectionLost) }
        try payload.write(to: file)
        return status
    }
}

func setupSourceTests() {
    let root = tmpDir("setup-source")
    let kit = root.appendingPathComponent("kit")
    let library = root.appendingPathComponent("Library")
    try! fm.createDirectory(at: kit.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: library, withIntermediateDirectories: true)
    let pair = Signing.generateKeyPair()
    let pub = Connect.Publisher(feedURL: "http://100.64.0.7:8790/release.json", enrolURL: "http://100.64.0.7:8790/enrol", publicKey: pair.publicKeyBase64)
    let old = Data("old helper".utf8), newest = Data("new helper".utf8)
    let files: [String: Data] = ["publisher.json": try! JSON.encode(pub), "VERSION": Data("0.1.1\n".utf8),
                                "bin/khu": old, "install-agent.sh": Data("#!/bin/bash\n".utf8)]
    var pins: [String: Any] = [:]
    for (name, data) in files {
        try! data.write(to: kit.appendingPathComponent(name))
        pins[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
    }
    try! JSONSerialization.data(withJSONObject: ["format": "fixture", "files": pins])
        .write(to: kit.appendingPathComponent("MANIFEST.json"))
    var feed = Feed(published_at: ISO.string(Date()))
    feed.apps["updater"] = FeedApp(version: "0.1.2", file: "new-khu", sha256: Signing.sha256Hex(newest), bytes: Int64(newest.count), kind: "updater")
    func signed(_ feed: Feed, otherSigner: Bool = false) -> Data {
        let body = try! JSON.encode(feed)
        let signature = try! Signing.sign(body, with: otherSigner ? Signing.generateKeyPair().privateKey : pair.privateKey)
        return try! JSON.encode(Release(feed: body, signature: signature))
    }
    let network = SetupHTTP(release: signed(feed), payload: newest)
    let selected = try? Connect.setupKit(kit, publisher: pub, library: library, http: network)
    expect(selected != nil && selected != kit, "NS1 setup selects the signed network helper before its local kit")
    if let selected {
        expect((try? Data(contentsOf: selected.appendingPathComponent("bin/khu"))) == newest,
               "NS1 selected bytes match the signed network helper")
        expect((try? String(contentsOf: selected.appendingPathComponent("VERSION"), encoding: .utf8)) == "0.1.2\n"
               && (try? Connect.publisher(kit: selected)) != nil, "NS1 selected kit version and manifest agree")
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: selected.appendingPathComponent("MANIFEST.json")))) as? [String: Any]
        expect(object?["format"] as? String == "fixture" && object?["agent_version"] as? String == "0.1.2",
               "NS1 manifest format survives and helper metadata follows the selected version")
    }
    expect((try? Data(contentsOf: kit.appendingPathComponent("bin/khu"))) == old,
           "NS1 original SSD kit remains unchanged")
    var offline = network; offline.offline = true
    expect((try? Connect.setupKit(kit, publisher: pub, library: library, http: offline)) == kit,
           "NS2 feed transport outage uses verified local kit")
    var interrupted = network; interrupted.downloadOffline = true
    expect((try? Connect.setupKit(kit, publisher: pub, library: library, http: interrupted)) == kit,
           "NS2 interrupted helper transfer uses verified local kit")
    var unavailable = network; unavailable.status = 503
    expect((try? Connect.setupKit(kit, publisher: pub, library: library, http: unavailable)) == kit,
           "NS2 unavailable download service uses verified local kit")
    var wrongSigner = network; wrongSigner.release = signed(feed, otherSigner: true)
    expectThrows("NS3 wrong publisher signature cannot fall back", contains: "not signed") {
        _ = try Connect.setupKit(kit, publisher: pub, library: library, http: wrongSigner)
    }
    var corrupt = network; corrupt.payload = Data("wrong bytes".utf8)
    expectThrows("NS3 corrupted download cannot fall back", contains: "checksum") {
        _ = try Connect.setupKit(kit, publisher: pub, library: library, http: corrupt)
    }
    var refused = network; refused.status = 403
    expectThrows("NS3 refused setup cannot fall back", contains: "refused") {
        _ = try Connect.setupKit(kit, publisher: pub, library: library, http: refused)
    }
    var older = feed; older.apps["updater"]!.version = "0.1.0"
    expect((try? Connect.setupKit(kit, publisher: pub, library: library, http: SetupHTTP(release: signed(older), payload: newest))) == kit,
           "NS4 network setup never downgrades a newer local kit")
    try! Data("tampered".utf8).write(to: kit.appendingPathComponent("bin/khu"))
    expectThrows("NS5 corrupt local kit cannot be an offline fallback", contains: "changed") {
        _ = try Connect.setupKit(kit, publisher: pub, library: library, http: offline)
    }
    try! old.write(to: kit.appendingPathComponent("bin/khu"))
    var different = pub; different.publicKey = Signing.generateKeyPair().publicKeyBase64
    expectThrows("NS5 fallback cannot change the packaged publisher pin", contains: "pin") {
        _ = try Connect.setupKit(kit, publisher: different, library: library, http: offline)
    }
    let active = ((try? fm.contentsOfDirectory(atPath: library.path)) ?? []).filter { $0.hasPrefix(".khu-connect-kit-") }
    expect(active.count == 1, "NS4 failed network staging is retired; only the successful fixture remains")
}
