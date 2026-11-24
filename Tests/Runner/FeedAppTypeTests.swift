import Foundation
import CryptoKit

/// Publisher-side feed category labels: only the five agreed lowercase labels may be written, a known
/// prior label survives a version or metadata publish that omits --type, and an old or unknown raw
/// tag stays in the signed feed for the consumer to read Unlabelled rather than breaking the feed.
func feedAppTypeTests() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("khu-test-app-type-\(UUID().uuidString.prefix(8))")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    let keyFile = root.appendingPathComponent("fixture.key")
    try! Signing.savePrivateKey(key, to: keyFile)
    let allowed = ["business", "entertainment", "extension", "media", "plugin", "system", "utility"]
    let refusedMessage = "--type must be business, entertainment, extension, media, plugin, system or utility"

    func dir(_ tag: String) -> URL {
        let url = root.appendingPathComponent(tag)
        try! fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func artifact(_ tag: String, _ bytes: String) -> URL {
        let url = root.appendingPathComponent("\(tag)-\(bytes.count).bin")
        try! Data(bytes.utf8).write(to: url)
        return url
    }
    func publish(_ dir: URL, _ version: String, _ bytes: String, type: String? = nil,
                 allowSame: Bool = false, shown: String? = nil) throws {
        try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "media", version: version,
                                  artifact: artifact(dir.lastPathComponent, bytes), kind: "app-dmg",
                                  allowSame: allowSame, displayName: shown, meta: nil, type: type,
                                  url: "http://example.test/artifacts/")
    }
    func loaded(_ dir: URL) -> Feed? {
        try? FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)
    }

    // FT1: every allowed label is written into the signed feed.
    for (index, label) in allowed.enumerated() {
        let feedDir = dir("explicit-\(index)")
        try! publish(feedDir, "1.0.0", "one", type: label)
        expect(loaded(feedDir)?.apps["media"]?.type == label, "FT1 \(label) is published")
    }

    // FT2/FT3: a version publish and a metadata-only re-publish both keep the known label.
    let carried = dir("carried")
    try! publish(carried, "1.0.0", "one", type: "entertainment")
    try! publish(carried, "1.0.1", "two")
    let feed = loaded(carried)
    expect(feed?.apps["media"]?.type == "entertainment" && feed?.previous?["media"]?.type == "entertainment",
           "FT2 a version publish without --type keeps the known entertainment label on both entries")
    try! publish(carried, "1.0.1", "two", allowSame: true, shown: "Media Studio KH")
    expect(loaded(carried)?.apps["media"]?.type == "entertainment" && loaded(carried)?.apps["media"]?.name == "Media Studio KH",
           "FT3 a metadata publish without --type keeps the known entertainment label")

    // FT4: an explicit label the publisher does not know is refused before anything is signed,
    // including every label from the abandoned three-value taxonomy.
    for (index, label) in ["studio", "service", "launcher", "video"].enumerated() {
        let feedDir = dir("refused-\(index)")
        expectThrows("FT4 an unknown explicit label (\(label)) is refused", contains: refusedMessage) {
            try publish(feedDir, "1.0.0", "bad", type: label)
        }
        expect(loaded(feedDir) == nil, "FT4 the refused \(label) publish signed nothing")
    }

    // FT5/FT6: a tag from an older feed is still a valid feed, reads Unlabelled in the consumer
    // because it is outside the allowlist, and is never a known prior label.
    let raw = dir("raw")
    var decoded = Feed(published_at: ISO.string(Date()))
    var entry = FeedApp(version: "1.0.0", file: "raw-artifact", sha256: Signing.sha256Hex(Data("raw".utf8)),
                        bytes: 3, kind: "app-dmg")
    entry.type = "studio"
    decoded.apps["media"] = entry
    try! FeedPublisher.saveFeed(decoded, to: raw, key: key)
    expect(loaded(raw)?.apps["media"]?.type == "studio", "FT5 an old raw tag does not break a verified feed")
    expect(!FeedPublisher.appTypes.contains("studio"), "FT5 an old raw tag reads Unlabelled in the consumer")
    try! publish(raw, "1.0.1", "next")
    expect(loaded(raw)?.apps["media"]?.type == nil, "FT6 an old raw tag is not carried forward as known")

    expect(FeedPublisher.appTypes == ["business", "entertainment", "extension", "media", "plugin", "system", "utility"],
           "FT7 only the five agreed lowercase labels are publisher labels")
}
