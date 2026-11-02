import Foundation
import CryptoKit

public enum FeedPublisher {
    public static func releaseFile(in dir: URL) -> URL { dir.appendingPathComponent("release.json") }

    /// The published feed, after checking its signature with the publisher's own key. nil when
    /// nothing has been published yet; throws when a release exists but is unreadable or does not
    /// verify — it is never quietly treated as empty, and never re-signed.
    public static func loadVerifiedFeed(from dir: URL, publicKey: Curve25519.Signing.PublicKey) throws -> Feed? {
        guard let release = try AtomicFile.readJSON(Release.self, from: releaseFile(in: dir)) else { return nil }
        guard let data = release.feedData, let signature = release.signatureData,
              Signing.verify(data, signature: signature, publicKey: publicKey) else {
            throw khuFail("\(releaseFile(in: dir).path) does not verify with this key; refusing to sign over it. "
                          + "Move it to _trash and publish every app again if it really is yours.")
        }
        return try JSON.decode(Feed.self, from: data).validated()
    }

    /// For display only (the status page). Unverified.
    public static func loadFeed(from dir: URL) -> Feed? {
        guard let release = try? AtomicFile.readJSON(Release.self, from: releaseFile(in: dir)),
              let data = release.feedData else { return nil }
        return try? JSON.decode(Feed.self, from: data)
    }

    public static func saveFeed(_ feed: Feed, to dir: URL, key: Curve25519.Signing.PrivateKey) throws {
        let data = JSON.encode(feed)
        try AtomicFile.writeJSON(Release(feed: data, signature: try Signing.sign(data, with: key)), to: releaseFile(in: dir))
    }

    /// Publish one app. Serialised across processes; the artifact is stored under its own hash
    /// (`<sha12>-<name>`), so two apps' files can never overwrite each other and bytes an older
    /// feed still names are never replaced.
    public static func publish(feedDir: URL, keyFile: URL, app: String, version: String, artifact: URL,
                               kind: String?, allowSame: Bool, notes: String? = nil, displayName: String? = nil, words: AppWords? = nil,
                               meta: ((String) throws -> AppMeta)? = { try AppMeta.read(dmg: $0) }, now: Date = Date()) throws {
        _ = try SafeName.component(app, what: "app id")
        guard VersionCompare.isValid(version) else { throw khuFail("\(version) is not a dotted numeric version") }
        let key = try Signing.loadPrivateKey(from: keyFile)
        try FileLock.withExclusive(feedDir.appendingPathComponent("publish.lock")) {
            let artifactsDir = feedDir.appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
            var feed = try loadVerifiedFeed(from: feedDir, publicKey: key.publicKey) ?? Feed(published_at: ISO.string(now))
            if let existing = feed.apps[app] {
                let order = VersionCompare.compare(version, existing.version) ?? -1
                if order < 0 || (order == 0 && !allowSame) {
                    throw khuFail("refused \(version): the feed already has \(existing.version) (--allow-same re-publishes the same version)")
                }
            }
            let (sha, bytes) = try Signing.sha256Hex(fileAt: artifact)
            guard bytes > 0 else { throw khuFail("\(artifact.path) is empty") }
            let base = String(try SafeName.component(artifact.lastPathComponent, what: "artifact").prefix(100))
            let name = try SafeName.component("\(sha.prefix(12))-\(base)", what: "artifact")
            let dest = artifactsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                guard try Signing.sha256Hex(fileAt: dest).hex == sha else {
                    throw khuFail("\(dest.path) exists with different bytes; move it to _trash and publish again")
                }
            } else {
                let staging = artifactsDir.appendingPathComponent(".\(name).khu-tmp-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: artifact, to: staging)
                guard try Signing.sha256Hex(fileAt: staging).hex == sha else {
                    _ = try? Trash.move(staging, into: Trash.root(in: feedDir))
                    throw khuFail("\(artifact.path) changed while it was being copied; nothing was published")
                }
                try FileManager.default.moveItem(at: staging, to: dest)
            }
            let kindNow = kind ?? (feed.apps[app]?.kind ?? "app-dmg")
            var entry = FeedApp(version: version, file: name, sha256: sha, bytes: bytes, kind: kindNow, notes: notes)
            // The app's own name, identity and icon, so the Launcher lists it with no code change.
            // A DMG that cannot be read is still published; the fields are then carried over.
            let old = feed.apps[app]
            entry.name = displayName ?? old?.name; entry.bundleID = old?.bundleID; entry.bundleName = old?.bundleName
            entry.icon = old?.icon; entry.iconSha256 = old?.iconSha256
            // The card's words are carried over unless this publish names new ones.
            let w = words ?? AppWords(tagline: old?.tagline, description: old?.description, features: old?.features, accent: old?.accent)
            entry.tagline = w.tagline; entry.description = w.description; entry.features = w.features; entry.accent = w.accent
            entry.released = ISO.string(now)
            if ["app-dmg", "gateway"].contains(kindNow), let read = meta, let info = try? read(dest.path) {
                guard info.version == version else {
                    throw khuFail("\(artifact.lastPathComponent) holds version \(info.version), not \(version); nothing was published")
                }
                entry.name = displayName ?? info.name; entry.bundleID = info.bundleID; entry.bundleName = info.bundleName
                if let png = info.iconPNG {
                    let iconSha = Signing.sha256Hex(png)
                    let iconName = "\(iconSha.prefix(12))-icon.png"
                    let iconURL = artifactsDir.appendingPathComponent(iconName)
                    if !FileManager.default.fileExists(atPath: iconURL.path) { try png.write(to: iconURL, options: .atomic) }
                    entry.icon = iconName; entry.iconSha256 = iconSha
                }
            }
            feed.apps[app] = entry
            // Strictly later than the last release, so an agent's high-water mark always moves forward.
            let previous = feed.publishedAt ?? .distantPast
            feed.published_at = ISO.string(max(now, previous.addingTimeInterval(0.001)))
            try saveFeed(try feed.validated(), to: feedDir, key: key)
        }
    }
}
