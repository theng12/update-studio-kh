import Foundation
import CryptoKit

private final class MirrorClient: HTTPClient, @unchecked Sendable {
    var files: [String: Data] = [:]
    var downloads: [String] = []
    var credentialSent = false
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { throw khuFail("unexpected mirror GET") }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw khuFail("unexpected mirror POST") }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        downloads.append(url.lastPathComponent)
        credentialSent = credentialSent || headers["Authorization"] != nil
        guard let data = files[url.lastPathComponent] else { throw URLError(.cannotConnectToHost) }
        guard data.count <= limit else { throw khuFail("fixture transfer exceeds signed limit") }
        try data.write(to: file)
        return 200
    }
}

func feedMirrorTests() {
    let root = tmpDir("feed-mirror")
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let origin = URL(string: "http://127.0.0.1:8790")!
    let now = Date()
    let http = MirrorClient()
    func make(_ number: Int) throws -> (Feed, Data) {
        let bytes = Data("installer \(number)".utf8)
        let name = "fixture-\(number).dmg"
        http.files[name] = bytes
        var app = FeedApp(version: "1.0.\(number)", file: name, sha256: Signing.sha256Hex(bytes), bytes: Int64(bytes.count), kind: "app-dmg")
        let icon = Data("icon \(number)".utf8)
        app.icon = "icon-\(number).png"; app.iconSha256 = Signing.sha256Hex(icon)
        http.files[app.icon!] = icon
        let feed = Feed(published_at: ISO.string(now.addingTimeInterval(Double(number))), apps: ["fixture": app])
        let body = JSON.encode(feed)
        return (feed, JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: key))))
    }
    func sync(_ data: Data, at destination: URL = root) throws -> Feed {
        try FeedMirror.sync(releaseData: data, sourceBase: origin, root: destination, publicKey: publicKey, http: http, now: now)
    }
    do {
        let (first, release1) = try make(1)
        _ = try sync(release1)
        let saved = try Data(contentsOf: root.appendingPathComponent("release.json"))
        expect(saved == release1 && http.downloads.count == 2, "FM signed release published only with its verified artifact and icon")
        expect(!http.credentialSent, "FM mirror refresh never sends an enrolment token")
        _ = try sync(release1)
        expect(http.downloads.count == 2, "FM unchanged artifacts are reused after hashing")
        let (second, release2) = try make(2)
        http.files[second.apps["fixture"]!.file] = Data("corrupt".utf8)
        expectThrows("FM corrupt artifact refuses publication", contains: "mismatch") { _ = try sync(release2) }
        let afterFailure = try Data(contentsOf: root.appendingPathComponent("release.json"))
        expect(afterFailure == release1, "FM failed sync keeps the last signed release")
        _ = try make(2)
        _ = try sync(release2)
        expect(fm.fileExists(atPath: root.appendingPathComponent("artifacts/" + first.apps["fixture"]!.file).path), "FM previous artifact retained")
        expectThrows("FM rollback refused", contains: "rollback") { _ = try sync(release1) }
        var conflicting = second; conflicting.apps["fixture"]?.notes = "changed"
        let changedBody = JSON.encode(conflicting)
        let changedRelease = JSON.encode(Release(feed: changedBody, signature: try Signing.sign(changedBody, with: key)))
        expectThrows("FM same-date changed feed refused", contains: "same published_at") { _ = try sync(changedRelease) }
        let (_, release3) = try make(3)
        _ = try sync(release3)
        expect(!fm.fileExists(atPath: root.appendingPathComponent("artifacts/" + first.apps["fixture"]!.file).path)
               && fm.fileExists(atPath: root.appendingPathComponent("artifacts/" + second.apps["fixture"]!.file).path), "FM only current and previous artifacts remain live")
        let retired = try fm.subpathsOfDirectory(atPath: root.appendingPathComponent("_trash").path)
        expect(retired.contains(where: { $0.hasSuffix(first.apps["fixture"]!.file) }), "FM older bytes stay restorable in _trash")
        let other = Curve25519.Signing.PrivateKey()
        let body = JSON.encode(second)
        let untrusted = JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: other)))
        expectThrows("FM wrong signature refused", contains: "signature") { _ = try sync(untrusted) }
        let (_, release4) = try make(4)
        http.files.removeValue(forKey: "icon-4.png")
        expectThrows("FM missing icon blocks partial publication") { _ = try sync(release4) }
        let afterMissing = try Data(contentsOf: root.appendingPathComponent("release.json"))
        expect(afterMissing == release3, "FM partial transfer failure keeps the working release")
        _ = try make(4)
        let cleanupLink = root.appendingPathComponent("artifacts/unsafe-link")
        try fm.createSymbolicLink(at: cleanupLink, withDestinationURL: root.appendingPathComponent("release.json"))
        expectThrows("FM cleanup refusal happens before release publication", contains: "symbolic link") { _ = try sync(release4) }
        let afterCleanupFailure = try Data(contentsOf: root.appendingPathComponent("release.json"))
        expect(afterCleanupFailure == release3, "FM cleanup failure leaves the prior signed release live")
        let recovery = tmpDir("mirror-missing-current")
        _ = try sync(release1, at: recovery)
        _ = try sync(release2, at: recovery)
        try Trash.move(recovery.appendingPathComponent("release.json"), into: Trash.root(in: recovery))
        _ = try sync(release3, at: recovery)
        let recoveredPrevious = try Data(contentsOf: recovery.appendingPathComponent("previous-release.json"))
        expect(recoveredPrevious == release1 && fm.fileExists(atPath: recovery.appendingPathComponent("artifacts/fixture-1.dmg").path),
               "FM missing current release preserves the signed previous release and its artifact")
        try Trash.move(recovery.appendingPathComponent("release.json"), into: Trash.root(in: recovery))
        var ancient = first; ancient.published_at = ISO.string(now.addingTimeInterval(-60))
        let ancientBody = JSON.encode(ancient)
        let ancientRelease = JSON.encode(Release(feed: ancientBody, signature: try Signing.sign(ancientBody, with: key)))
        expectThrows("FM previous release also protects recovery against rollback", contains: "rollback") { _ = try sync(ancientRelease, at: recovery) }
        let linked = tmpDir("mirror-symlink")
        let outside = tmpDir("mirror-outside")
        try fm.createSymbolicLink(at: linked.appendingPathComponent("artifacts"), withDestinationURL: outside)
        expectThrows("FM destination symlink refused", contains: "symbolic link") { _ = try sync(release1, at: linked) }
    } catch { expect(false, "FM mirror checks: \(error)") }
}
