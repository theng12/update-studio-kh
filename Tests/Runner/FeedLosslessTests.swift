import Foundation
import CryptoKit

/// The old shape, with no `extras`: the control that shows the field loss this fix removes.
private struct LegacyFeedApp: Codable {
    var version, file, sha256, kind: String
    var bytes: Int64
    var type: String?
}
private struct LegacyFeed: Codable {
    var schema: Int
    var published_at: String
    var apps: [String: LegacyFeedApp]
}

/// A feed written by a newer build keeps every field this build does not model: the publisher
/// rewrites the whole feed on every release, so a dropped field would vanish fleet-wide.
func feedLosslessTests() {
    let sha = String(repeating: "a", count: 64)
    let json = """
    {"schema":1,"published_at":"2026-11-22T10:00:00Z","revision_note":"kept at the top",
     "apps":{"media-studio":{"version":"0.1.122","file":"a.dmg","sha256":"\(sha)","bytes":123,
       "kind":"app","type":"media","extensions":["x"],"previousExtensions":["y"]}}}
    """
    let data = Data(json.utf8)

    do {
        // FL0 control: the previous model drops the unknown fields — this is the measured fault.
        let legacy = try JSONDecoder().decode(LegacyFeed.self, from: data)
        let legacyText = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        expect(!legacyText.contains("revision_note") && !legacyText.contains("extensions"),
               "FL0 the old model drops unknown feed fields first")

        let feed = try JSON.decode(Feed.self, from: data)
        expect(feed.extras["revision_note"] != nil, "FL1 an unknown top-level field survives decoding")
        expect(feed.apps["media-studio"]?.extras["extensions"] != nil
               && feed.apps["media-studio"]?.extras["previousExtensions"] != nil,
               "FL1 unknown per-app fields survive decoding")
        let text = String(decoding: JSON.encode(feed), as: UTF8.self)
        expect(text.contains("revision_note") && text.contains("extensions") && text.contains("previousExtensions"),
               "FL2 re-encoded JSON still names every unknown field")
        let again = try JSON.decode(Feed.self, from: JSON.encode(feed))
        expect(again == feed, "FL2 a decode/encode round trip is lossless")
        expect(again.apps["media-studio"]?.version == "0.1.122"
               && again.apps["media-studio"]?.type == "media"
               && again.published_at == "2026-11-22T10:00:00Z",
               "FL2 known fields are unchanged")
        expect(JSON.encode(feed).range(of: Data("\"bytes\" : 123".utf8)) != nil,
               "FL3 a whole number is written back as an integer, not 123.0")
    } catch { expect(false, "FL fixture: \(error)") }

    // FL4: a real publish over a feed carrying another build's row keeps that row's unknown fields.
    do {
        let root = tmpDir("feed-lossless")
        let keyFile = root.appendingPathComponent("fixture.key")
        try Signing.savePrivateKey(Curve25519.Signing.PrivateKey(), to: keyFile)
        let feedDir = root.appendingPathComponent("feed")
        try fm.createDirectory(at: feedDir, withIntermediateDirectories: true)
        let seed = try JSON.decode(Feed.self, from: data)
        try FeedPublisher.saveFeed(seed, to: feedDir, key: try Signing.loadPrivateKey(from: keyFile))
        let artifact = root.appendingPathComponent("story.bin")
        try Data("story bytes".utf8).write(to: artifact)
        try FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "story", version: "1.4.418",
                                  artifact: artifact, kind: "fake-for-tests", allowSame: false)
        let after = FeedPublisher.loadFeed(from: feedDir)
        expect(after?.extras["revision_note"] != nil, "FL4 a publish keeps the feed's unknown top-level field")
        expect(after?.apps["media-studio"]?.extras["extensions"] != nil,
               "FL4 a publish keeps another app's unknown fields")
        expect(after?.apps["story"]?.version == "1.4.418", "FL4 the published row is written as usual")
    } catch { expect(false, "FL4 publish fixture: \(error)") }
}
