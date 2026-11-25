import Foundation

/// PP1–PP3 (row 20261125-37). The post-publish probe checks one asset, and a single transient 5xx
/// used to fail a feed that had already been committed and read back from Pages — twice on
/// 2026-11-25. It now retries with bounded backoff and then reports what it could not check,
/// while a real byte mismatch is still named as a mismatch.
func feedProbeRetryTests() {
    final class ProbeHTTP: HTTPClient, @unchecked Sendable {
        let answers: [Int]
        let body: Data
        var asked = 0
        init(_ answers: [Int], body: Data) { self.answers = answers; self.body = body }
        func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
            let code = answers[min(asked, answers.count - 1)]
            asked += 1
            return (code == 200 ? body : Data(), code)
        }
        func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { (Data(), 404) }
        func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { 404 }
    }

    let bytes = Data("published-bytes".utf8)
    let sha = Signing.sha256Hex(bytes)
    var app = FeedApp(version: "0.1.84", file: "a.dmg", sha256: sha, bytes: Int64(bytes.count), kind: "app-dmg")
    app.url = "https://example.invalid/a.dmg"
    let feed = Feed(published_at: "2026-11-25T00:00:00Z", apps: ["displays-studio": app])
    let envelope = try! JSONSerialization.data(withJSONObject: ["feed": JSON.encode(feed).base64EncodedString()])

    // PP1. Two transient failures then the matching bytes: the probe verifies, it does not fail.
    var pauses: [TimeInterval] = []
    let flaky = ProbeHTTP([503, 500, 200], body: bytes)
    let verified = FeedPages.verifyOneAsset(envelope: envelope, http: flaky, attempts: 3) { pauses.append($0) }
    expect(verified == nil, "PP1 two transient failures then a match: the probe verifies without failing the publish")
    expect(flaky.asked == 3, "PP1 the probe asked three times, not once")
    expect(pauses == [2, 4], "PP1 the backoff is bounded and grows: 2 s then 4 s")

    // PP2. A persistent failure names the app and gives up after the declared attempts.
    let dead = ProbeHTTP([503], body: bytes)
    let reason = FeedPages.verifyOneAsset(envelope: envelope, http: dead, attempts: 3) { _ in }
    expect(reason == "displays-studio (did not answer)", "PP2 a persistent failure reports the app and the reason, never a pass")
    expect(dead.asked == 3, "PP2 it stops after the declared attempts")

    // PP3. Wrong bytes are a mismatch, not a silent pass.
    let wrong = ProbeHTTP([200], body: Data("something-else".utf8))
    let mismatch = FeedPages.verifyOneAsset(envelope: envelope, http: wrong, attempts: 2) { _ in }
    expect(mismatch?.hasPrefix("displays-studio (does not match") == true,
           "PP3 bytes that fail the row's sha256 are reported as a mismatch")
}
