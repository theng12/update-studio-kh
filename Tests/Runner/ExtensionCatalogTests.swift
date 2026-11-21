import Foundation
import CryptoKit

/// An extension catalogue served by a recorded HTTP client and signed by a fixture key: no live
/// feed, no download and no registration. Each check uses the signed `Release` envelope the real
/// publisher writes, with a deliberately injected signer instead of the fleet key.
private final class CatalogHTTP: HTTPClient, @unchecked Sendable {
    struct Call { let url: URL; let headers: [String: String] }
    private let lock = NSLock()
    private var seen: [Call] = []
    private let reply: (Data, Int)?
    private let failure: Error?
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return seen }
    init(reply: (Data, Int)? = nil, failure: Error? = nil) {
        self.reply = reply; self.failure = failure
    }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        lock.lock(); seen.append(Call(url: url, headers: headers)); lock.unlock()
        if let failure { throw failure }
        return reply ?? (Data(), 404)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        throw khuFail("the catalogue must never POST")
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        throw khuFail("the catalogue must never download")
    }
}

func extensionCatalogTests() {
    let fleet = Signing.generateKeyPair()
    let stranger = Signing.generateKeyPair()

    func body(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["extensions": entries])
    }
    func entry(id: String = "notes", name: String = "Notes", version: String = "1.2.3",
               url: String = "https://cdn.example.com/extensions/notes.dmg",
               sha: String = String(repeating: "a", count: 64)) -> [String: Any] {
        ["id": id, "name": name, "version": version, "summary": "A small notes extension.",
         "downloadURL": url, "sha256": sha]
    }
    func signed(_ body: Data, by signer: Curve25519.Signing.PrivateKey = fleet.privateKey) -> Data {
        let release = Release(feed: body, signature: try! Signing.sign(body, with: signer))
        return try! JSON.encode(release)
    }
    func catalog(_ entries: [[String: Any]], by signer: Curve25519.Signing.PrivateKey = fleet.privateKey) -> Data {
        signed(body(entries), by: signer)
    }
    func load(_ data: Data, _ code: Int = 200, key: String? = nil) throws -> [ExtensionCatalog.Entry]? {
        try ExtensionCatalog.load(http: CatalogHTTP(reply: (data, code)), key: key ?? fleet.publicKeyBase64)
    }

    let one = entry()
    let two = entry(id: "calendar", name: "Calendar", version: "0.9",
                    url: "https://cdn.example.com/extensions/calendar.dmg?source=catalog")
    let http = CatalogHTTP(reply: (catalog([one, two]), 200))
    let list = try? ExtensionCatalog.load(http: http, key: fleet.publicKeyBase64)
    expect(list?.count == 2 && list?.first?.id == "notes" && list?.last?.id == "calendar"
           && list?.first?.name == "Notes" && list?.first?.version == "1.2.3"
           && list?.first?.summary == "A small notes extension."
           && list?.first?.kind == "extension"
           && list?.first?.downloadURL?.absoluteString == "https://cdn.example.com/extensions/notes.dmg"
           && list?.last?.downloadURL?.absoluteString == "https://cdn.example.com/extensions/calendar.dmg?source=catalog"
           && list?.first?.sha256 == String(repeating: "a", count: 64),
           "EC1 a signed catalogue decodes every field into browser-only entries")
    expect(http.calls.count == 1 && http.calls.first?.url == ExtensionCatalog.endpoint
           && http.calls.first?.url.lastPathComponent == "extensions.json"
           && http.calls.first?.headers.isEmpty == true,
           "EC2 one anonymous GET to extensions.json beside the public feed")
    expect(ExtensionCatalog.endpoint.absoluteString.hasPrefix("https://")
           && ExtensionCatalog.endpoint.deletingLastPathComponent() ==
              URL(string: Connect.publicFeedURL)!.deletingLastPathComponent(),
           "EC3 the endpoint sits next to Connect.publicFeedURL")
    expect((try? load(catalog([])))?.isEmpty == true, "EC4 a signed empty catalogue is empty, not a failure")

    // Not published is a normal answer; a bad status, a network error and bad bytes are not.
    expect((try? load(Data("not a release".utf8), 404)) == nil
           && (try? load(Data("not a release".utf8), 410)) == nil
           && (try? load(Data(), 204)) == nil,
           "EC5 404, 410 and no-content mean no catalogue is published")
    expectThrows("EC6 any other status is a failure", contains: "answered 500") {
        _ = try load(Data(), 500)
    }
    let offline = CatalogHTTP(failure: khuFail("offline"))
    expectThrows("EC7 a network error is not 'not published'", contains: "offline") {
        _ = try ExtensionCatalog.load(http: offline, key: fleet.publicKeyBase64)
    }

    // The envelope is verified before any of its contents are trusted.
    let badSignature = try! JSON.encode(Release(feed: body([one]),
                                                 signature: try! Signing.sign(Data("something else".utf8),
                                                                              with: fleet.privateKey)))
    expectThrows("EC8 a tampered signature is refused", contains: "signature is invalid") {
        _ = try load(badSignature)
    }
    expectThrows("EC9 another signer's catalogue is refused", contains: "signature is invalid") {
        _ = try load(catalog([one], by: stranger.privateKey))
    }
    expectThrows("EC10 a catalog signed by the fleet key but read with another key is refused",
                 contains: "signature is invalid") {
        _ = try load(catalog([one]), key: stranger.publicKeyBase64)
    }
    #if KHU_TESTS
    let previousKey = PinnedKey.test
    PinnedKey.test = fleet.publicKeyBase64
    defer { PinnedKey.test = previousKey }
    expect((try? ExtensionCatalog.load(http: CatalogHTTP(reply: (catalog([one]), 200))))?.count == 1,
           "EC11 production load uses the key pinned in this build")
    #endif

    expectThrows("EC12 a malformed envelope is refused", contains: "malformed JSON") {
        _ = try load(Data("{not json".utf8))
    }
    expectThrows("EC13 a malformed signed body is refused", contains: "malformed JSON") {
        _ = try load(signed(Data("not json".utf8)))
    }
    expectThrows("EC14 a body without extensions is refused", contains: "malformed JSON") {
        _ = try load(signed(try! JSONSerialization.data(withJSONObject: ["items": []])))
    }
    var missing = one; missing.removeValue(forKey: "sha256")
    expectThrows("EC15 an extension without a download or hash is refused", contains: "needs a public download address and sha256") {
        _ = try load(catalog([missing]))
    }
    // An extension and a plugin are different categories; a plugin may be listed before it ships.
    var plugin: [String: Any] = ["id": "efficient-orchestration", "name": "Efficient Orchestration",
                                 "version": "0.3.204", "summary": "Coordinates work across Studio apps.", "kind": "plugin"]
    let mixed = try? load(catalog([one, plugin]))
    expect(mixed?.count == 2 && mixed?.last?.kind == "plugin" && mixed?.last?.downloadURL == nil,
           "EC17 a plugin row lists without a download")
    plugin["downloadURL"] = "https://cdn.example.com/plugins/eo.zip"; plugin["sha256"] = String(repeating: "b", count: 64)
    expect((try? load(catalog([plugin])))?.first?.downloadURL != nil, "EC18 a plugin may carry a public download")
    var private_plugin = plugin; private_plugin["downloadURL"] = "https://mac.ts.net/eo.zip"
    expectThrows("EC19 a plugin download is held to the same public address", contains: "public HTTPS URL") {
        _ = try load(catalog([private_plugin]))
    }
    var odd: [String: Any] = plugin; odd["kind"] = "app"
    expectThrows("EC20 only extension and plugin categories are accepted", contains: "only extension or plugin") {
        _ = try load(catalog([odd]))
    }
    var unhashed = one; unhashed.removeValue(forKey: "sha256")
    expectThrows("EC21 an extension without its hash is refused", contains: "needs a public download address and sha256") {
        _ = try load(catalog([unhashed]))
    }
    expectThrows("EC16 an oversized response is refused before decoding", contains: "larger than") {
        _ = try load(Data(repeating: 0x61, count: 300_000))
    }

    // The download address is only a browser address: no credentials, no private destination.
    let unsafeURLs = [
        "http://cdn.example.com/notes.dmg",
        "https://user:pw@cdn.example.com/notes.dmg",
        "https://cdn.example.com@evil.example/notes.dmg",
        "https://127.0.0.1/notes.dmg", "https://10.0.0.4/notes.dmg",
        "https://192.168.1.2/notes.dmg", "https://169.254.169.254/latest/meta-data",
        "https://[::1]/notes.dmg", "https://127.1/notes.dmg",
        "https://cdn.local/notes.dmg", "https://cdn.internal/notes.dmg",
        "https://cdn.test/notes.dmg", "https://cdn.home.arpa/notes.dmg",
        "https://mac.ts.net/notes.dmg", "https://cdn.example.com:8443/notes.dmg",
        "not a url",
    ]
    for (index, url) in unsafeURLs.enumerated() {
        expectThrows("EC17.\(index) unsafe download address \(url) is refused",
                     contains: "not a public HTTPS URL") {
            _ = try load(catalog([entry(url: url)]))
        }
    }

    // Signed content still has to be structurally safe and bounded.
    let badVersions = ["", "v1", "1.0-beta", "1..2", "1.1234567890"]
    for (index, version) in badVersions.enumerated() {
        expectThrows("EC18.\(index) an unsafe version \(version) is refused", contains: "invalid extension version") {
            _ = try load(catalog([entry(version: version)]))
        }
    }
    for badID in ["../notes", "Notes", "notes/x", String(repeating: "a", count: 65)] {
        expectThrows("EC19 an unsafe id \(badID) is refused", contains: "unsafe extension id") {
            _ = try load(catalog([entry(id: badID)]))
        }
    }
    expectThrows("EC20 duplicate ids are refused", contains: "duplicate extension id") {
        _ = try load(catalog([one, one]))
    }
    expectThrows("EC21 a missing sha256 value is refused", contains: "no usable sha256") {
        _ = try load(catalog([entry(sha: "xyz")]))
    }
    expectThrows("EC22 an overlong summary is refused", contains: "refused extension summary") {
        _ = try load(catalog([entry(url: "https://cdn.example.com/a.dmg")].map {
            var copy = $0; copy["summary"] = String(repeating: "x", count: 400); return copy
        }))
    }
    expectThrows("EC23 an overlong catalogue is refused", contains: "more than 64 entries") {
        _ = try load(catalog((0..<65).map { entry(id: "extension-\($0)") }))
    }
}
