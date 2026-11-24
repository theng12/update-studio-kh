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
        try FeedMirror.sync(releaseData: data, sourceBase: origin, root: destination, publicKey: publicKey, http: http, now: now,
                            retireArtifact: { _ = try Trash.move($0, into: destination.appendingPathComponent("fixture-system-trash")) })
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
        // Same artifacts, different packaging (notes only) at one published_at is the same release
        // (0.1.64); a genuinely different artifact at that instant is still refused.
        var repackaged = second; repackaged.apps["fixture"]?.notes = "changed"
        let repackagedBody = JSON.encode(repackaged)
        let repackagedRelease = JSON.encode(Release(feed: repackagedBody, signature: try Signing.sign(repackagedBody, with: key)))
        expect((try? sync(repackagedRelease)) != nil, "FM same-date feed with only different packaging is accepted")
        var conflicting = second; conflicting.apps["fixture"]?.sha256 = String(repeating: "e", count: 64)
        let changedBody = JSON.encode(conflicting)
        let changedRelease = JSON.encode(Release(feed: changedBody, signature: try Signing.sign(changedBody, with: key)))
        expectThrows("FM same-date changed feed refused", contains: "same published_at") { _ = try sync(changedRelease) }
        let (_, release3) = try make(3)
        _ = try sync(release3)
        expect(!fm.fileExists(atPath: root.appendingPathComponent("artifacts/" + first.apps["fixture"]!.file).path)
               && fm.fileExists(atPath: root.appendingPathComponent("artifacts/" + second.apps["fixture"]!.file).path), "FM only current and previous artifacts remain live")
        let retired = try fm.subpathsOfDirectory(atPath: root.appendingPathComponent("fixture-system-trash").path)
        expect(retired.contains(where: { $0.hasSuffix(first.apps["fixture"]!.file) }), "FM older artifacts use the system Trash destination")
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
        let (older, _) = try make(5)
        let (current, _) = try make(6)
        func signed(_ feed: Feed) throws -> Data {
            let body = JSON.encode(feed)
            return JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: key)))
        }
        var seeded = current
        seeded.previous = older.apps
        let fresh = tmpDir("mirror-seeded-previous")
        _ = try sync(signed(seeded), at: fresh)
        expect(fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-5.dmg").path)
               && fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-6.dmg").path),
               "FM fresh mirror downloads both signed installer versions")
        seeded.published_at = ISO.string(now.addingTimeInterval(7))
        seeded.apps["fixture"]?.notes = "metadata publication"
        _ = try sync(signed(seeded), at: fresh)
        expect(fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-5.dmg").path),
               "FM metadata publication preserves each app's older version")
        let (next, _) = try make(8)
        var promoted = next; promoted.previous = current.apps
        _ = try sync(signed(promoted), at: fresh)
        expect(!fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-5.dmg").path)
               && fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-6.dmg").path),
               "FM signed pins retain exactly current plus one older installer")
        let trashed = try fm.subpathsOfDirectory(atPath: fresh.appendingPathComponent("fixture-system-trash").path)
        expect(trashed.contains(where: { $0.hasSuffix("fixture-5.dmg") }), "FM third installer goes through the system Trash callback")
        let (later, _) = try make(9)
        var refused = later; refused.previous = next.apps
        let nextRelease = try signed(refused)
        var retirements = 0
        expectThrows("FM system Trash failure stays visible", contains: "fixture Trash unavailable") {
            _ = try FeedMirror.sync(releaseData: nextRelease, sourceBase: origin, root: fresh, publicKey: publicKey,
                                    http: http, now: now, retireArtifact: { file in
                retirements += 1
                if retirements == 2 { throw khuFail("fixture Trash unavailable") }
                _ = try Trash.move(file, into: fresh.appendingPathComponent("fixture-system-trash"))
            })
        }
        expect(try Data(contentsOf: fresh.appendingPathComponent("release.json")) == nextRelease,
               "FM partial Trash failure keeps the complete newly signed pins live")
        expect(try Data(contentsOf: fresh.appendingPathComponent("previous-release.json")) == nextRelease,
               "FM recovery snapshot names only the two installers kept live")
        expect(fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-8.dmg").path)
               && fm.fileExists(atPath: fresh.appendingPathComponent("artifacts/fixture-9.dmg").path),
               "FM failed retirement never removes a live or fallback installer")
        try Trash.move(fresh.appendingPathComponent("release.json"), into: Trash.root(in: fresh))
        _ = try sync(nextRelease, at: fresh)
        expect(try Data(contentsOf: fresh.appendingPathComponent("release.json")) == nextRelease,
               "FM pinned recovery retries unfinished Trash without downloading retired versions")
        var invalid = current; invalid.previous = current.apps
        expectThrows("FM signed fallback must be an older version", contains: "previous installer must be older") { _ = try invalid.validated() }
        invalid.previous = ["unknown": older.apps["fixture"]!]
        expectThrows("FM signed fallback cannot introduce another app", contains: "previous installer must be older") { _ = try invalid.validated() }

        let publisher = tmpDir("publisher-retained-previous")
        let sourceArtifacts = publisher.appendingPathComponent("artifacts")
        try fm.createDirectory(at: sourceArtifacts, withIntermediateDirectories: true)
        for (name, bytes) in http.files { try bytes.write(to: sourceArtifacts.appendingPathComponent(name)) }
        let ledger = ["apps": ["fixture": ["current": current.apps["fixture"]!, "previous": older.apps["fixture"]!]]]
        try AtomicFile.writeJSON(ledger, to: publisher.appendingPathComponent("artifact-retention.json"))
        let noLedger = tmpDir("publisher-no-retention")
        expect(try FeedPublisher.withPreviousInstallers(current, in: noLedger).previous == nil,
               "FM absent ledger preserves legacy mirror retention semantics")
        try AtomicFile.writeJSON(["apps": [String: [String: FeedApp]]()], to: noLedger.appendingPathComponent("artifact-retention.json"))
        expect(try FeedPublisher.withPreviousInstallers(current, in: noLedger).previous == nil,
               "FM empty ledger does not sign empty fallback metadata")
        let adopted = try FeedPublisher.withPreviousInstallers(current, in: publisher)
        expect(adopted.previous == older.apps, "FM publisher reuses the existing per-app retention ledger")
        let previousArtifact = sourceArtifacts.appendingPathComponent("fixture-5.dmg")
        try Data("corrupt previous".utf8).write(to: previousArtifact)
        expectThrows("FM publisher refuses an invalid previous seed", contains: "hash or size mismatch") {
            _ = try FeedPublisher.withPreviousInstallers(current, in: publisher)
        }
        try http.files["fixture-5.dmg"]!.write(to: previousArtifact)
        let fixtureKey = publisher.appendingPathComponent("fixture.key")
        try Signing.savePrivateKey(key, to: fixtureKey)
        try FeedPublisher.saveFeed(current, to: publisher, key: key)
        try FeedPublisher.configureNetwork(feedDir: publisher, keyFile: fixtureKey, network: FeedNetwork(), now: now.addingTimeInterval(7))
        let configured = try FeedPublisher.loadVerifiedFeed(from: publisher, publicKey: key.publicKey)!
        expect(configured.apps == current.apps && configured.previous == older.apps,
               "FM host setup signs existing previous pins without changing app versions")
        let nextArtifact = publisher.appendingPathComponent("next.dmg")
        try http.files["fixture-8.dmg"]!.write(to: nextArtifact)
        try FeedPublisher.publish(feedDir: publisher, keyFile: fixtureKey, app: "fixture", version: "1.0.8", artifact: nextArtifact,
                                  kind: "app-dmg", allowSame: false, meta: nil, now: now.addingTimeInterval(8), url: "https://example.test/artifacts/")
        let published = try FeedPublisher.loadVerifiedFeed(from: publisher, publicKey: key.publicKey)!
        expect(published.previous?["fixture"] == current.apps["fixture"], "FM every publish automatically replaces just that app's fallback")
        try FeedPublisher.publish(feedDir: publisher, keyFile: fixtureKey, app: "other", version: "1.0.1", artifact: nextArtifact,
                                  kind: "app-dmg", allowSame: false, meta: nil, now: now.addingTimeInterval(9), url: "https://example.test/artifacts/")
        let unrelated = try FeedPublisher.loadVerifiedFeed(from: publisher, publicKey: key.publicKey)!
        expect(unrelated.previous?["fixture"] == current.apps["fixture"], "FM another app's publish preserves the older installer pin")
        try fm.createDirectory(at: noLedger.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        try http.files["fixture-6.dmg"]!.write(to: noLedger.appendingPathComponent("artifacts/fixture-6.dmg"))
        try FeedPublisher.saveFeed(current, to: noLedger, key: key)
        try FeedPublisher.publish(feedDir: noLedger, keyFile: fixtureKey, app: "fixture", version: "1.0.8", artifact: nextArtifact,
                                  kind: "app-dmg", allowSame: false, meta: nil, now: now.addingTimeInterval(8), url: "https://example.test/artifacts/")
        let withoutLedger = try FeedPublisher.loadVerifiedFeed(from: noLedger, publicKey: key.publicKey)!
        expect(withoutLedger.previous?["fixture"] == current.apps["fixture"],
               "FM publishing without a ledger still pins the displaced current version")
        let staleLedger = ["apps": ["fixture": ["current": older.apps["fixture"]!]]]
        try AtomicFile.writeJSON(staleLedger, to: publisher.appendingPathComponent("artifact-retention.json"))
        let recoveredPins = try FeedPublisher.withPreviousInstallers(current, in: publisher)
        expect(recoveredPins.previous == older.apps, "FM stale ledger current becomes the verified older fallback")
        let invalidLedger = ["apps": ["fixture": ["current": current.apps["fixture"]!, "previous": current.apps["fixture"]!]]]
        try AtomicFile.writeJSON(invalidLedger, to: publisher.appendingPathComponent("artifact-retention.json"))
        expectThrows("FM invalid same-version fallback fails loudly instead of dropping protection", contains: "previous installer must be older") {
            _ = try FeedPublisher.withPreviousInstallers(current, in: publisher)
        }
    } catch { expect(false, "FM mirror checks: \(error)") }
}

/// A mirror keeps only the apps this Mac is asked for and still serves the whole signed feed.
func mirrorOnlyTests() {
    let root = tmpDir("feed-mirror-only")
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let origin = URL(string: "http://127.0.0.1:8790")!
    let now = Date()
    let http = MirrorClient()
    do {
        // Only the apps this Mac has are mirrored; the feed it serves is still the whole release.
        let limitedRoot = tmpDir("mirror-only")
        let bytes = Data("installer 11".utf8)
        http.files["fixture-11.dmg"] = bytes
        let fixture = FeedApp(version: "1.0.11", file: "fixture-11.dmg", sha256: Signing.sha256Hex(bytes),
                              bytes: Int64(bytes.count), kind: "app-dmg")
        let other = FeedApp(version: "1.0.0", file: "other.dmg", sha256: Signing.sha256Hex(Data("other installer".utf8)),
                            bytes: 15, kind: "app-dmg")
        http.files["other.dmg"] = Data("other installer".utf8)
        let feed = Feed(published_at: ISO.string(now.addingTimeInterval(11)), apps: ["fixture": fixture, "other": other])
        let body = JSON.encode(feed)
        let release = JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: key)))
        let kept = try FeedMirror.sync(releaseData: release, sourceBase: origin, root: limitedRoot, publicKey: publicKey,
                                       http: http, now: now, only: ["fixture"],
                                       retireArtifact: { _ = try Trash.move($0, into: limitedRoot.appendingPathComponent("fixture-system-trash")) })
        let served = try Data(contentsOf: limitedRoot.appendingPathComponent("release.json"))
        let stored = (try? fm.contentsOfDirectory(atPath: limitedRoot.appendingPathComponent("artifacts").path)) ?? []
        expect(kept.apps["other"] != nil && served == release
               && stored.contains("fixture-11.dmg") && !stored.contains("other.dmg"),
               "FM a mirror keeps only the apps it is asked for and still serves the whole signed feed")
    } catch { expect(false, "FM mirror-only: \(error)") }
}
