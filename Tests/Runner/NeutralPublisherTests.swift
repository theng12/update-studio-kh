import Foundation

private struct OfflineHTTP: HTTPClient {
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { throw URLError(.cannotConnectToHost) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw URLError(.cannotConnectToHost) }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        throw URLError(.cannotConnectToHost)
    }
}

/// A copy built for public download carries the pinned key and no publisher address: it is not an
/// error, just "not connected yet", and nothing is sent until an address is typed.
func neutralPublisherTests() {
    let root = tmpDir("neutral-publisher")
    let kit = root.appendingPathComponent("kit")
    let home = root.appendingPathComponent("home")
    try! fm.createDirectory(at: kit, withIntermediateDirectories: true)
    try! fm.createDirectory(at: home, withIntermediateDirectories: true)
    let pair = Signing.generateKeyPair()
    let pinch = ["publicKey": pair.publicKeyBase64]
    let files: [String: Data] = ["publisher.json": try! JSON.encode(pinch),
                                 "install-agent.sh": Data("#!/bin/bash\n".utf8)]
    var pins: [String: Any] = [:]
    for (name, data) in files {
        try! data.write(to: kit.appendingPathComponent(name))
        pins[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
    }
    try! JSONSerialization.data(withJSONObject: ["format": "fixture", "files": pins])
        .write(to: kit.appendingPathComponent("MANIFEST.json"))

    guard let pub = try? Connect.publisher(kit: kit) else {
        expect(false, "NP1 an address-less publisher record still verifies as a kit")
        return
    }
    expect(pub.feedURL == nil && pub.enrolURL == nil, "NP1 an address-less publisher record still verifies as a kit")
    expect(pub.publicKey == pair.publicKeyBase64, "NP2 the pinned key is kept")
    expectThrows("NP3 nothing is sent until an address is typed",
                 contains: "not connected to an Update Studio yet") {
        _ = try Connect.run(kit: kit, home: home, machine: "mac-a", code: "123456", http: OfflineHTTP())
    }
    expect(!Connect.isSetUp(home: home), "NP4 the refused attempt installed nothing")
}
