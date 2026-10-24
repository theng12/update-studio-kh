import Foundation
import CryptoKit

public enum FeedPublisher {
    public static func loadFeed(from dir: URL) -> Feed? {
        try? AtomicFile.readJSON(Feed.self, from: dir.appendingPathComponent("feed.json"))
    }
    public static func saveFeed(_ feed: Feed, to dir: URL, key: Curve25519.Signing.PrivateKey) throws {
        let data = JSON.encode(feed)
        try AtomicFile.write(data, to: dir.appendingPathComponent("feed.json"))
        let sig = Signing.sign(data, with: key)
        try AtomicFile.write(sig, to: dir.appendingPathComponent("feed.json.sig"))
    }
    public static func publish(feedDir: URL, keyFile: URL, app: String, version: String, artifact: URL, kind: String?, allowSame: Bool) throws {
        let key = try Signing.loadPrivateKey(from: keyFile)
        let artifactsDir = feedDir.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        var feed = loadFeed(from: feedDir) ?? Feed(published_at: ISO.string(Date()), apps: [:])
        // version check
        if let existing = feed.apps[app] {
            if !allowSame && !VersionCompare.isNewer(version, than: existing.version) {
                throw khuFail("refused non-newer version \(version) (current \(existing.version))")
            }
        }
        // copy artifact
        let name = artifact.lastPathComponent
        _ = try SafeName.component(name, what: "artifact")
        let dest = artifactsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try Trash.move(dest, into: Trash.root(in: feedDir), at: Date())
        }
        try FileManager.default.copyItem(at: artifact, to: dest)
        let data = try Data(contentsOf: dest)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let appEntry = FeedApp(version: version, file: name, sha256: sha, bytes: Int64(data.count), kind: kind ?? (feed.apps[app]?.kind ?? "app-dmg"), notes: feed.apps[app]?.notes)
        feed.apps[app] = appEntry
        feed.published_at = ISO.string(Date())
        try saveFeed(feed, to: feedDir, key: key)
    }
}
