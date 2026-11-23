import Foundation

/// The published feed is generated, never maintained by hand (owner spec, 2026-11-23).
///
/// For each app repository: its latest **published, non-draft** release becomes one row — the tag's
/// version, the DMG asset's absolute address, GitHub's own sha256 digest and size, the bundle
/// identity, and the words (`type`, `tagline`, `description`, `holdURL`, `holdSince`) from
/// `app-meta.json` at that tag. A repo with no published release has no row. A repo that publishes a
/// release but carries no metadata refuses the whole run, naming the repo and the field, because a
/// guessed or partial feed is worse than no feed.
public struct RepoRelease: Sendable, Equatable {
    public struct Asset: Sendable, Equatable {
        public var name: String
        public var url: String
        /// GitHub's own digest (`sha256:…`), never a hash this tool computed from a download.
        public var digest: String?
        public var bytes: Int64
        public init(name: String, url: String, digest: String?, bytes: Int64) {
            self.name = name; self.url = url; self.digest = digest; self.bytes = bytes
        }
    }
    public var tag: String
    public var publishedAt: String?
    public var assets: [Asset]
    public init(tag: String, publishedAt: String?, assets: [Asset]) {
        self.tag = tag; self.publishedAt = publishedAt; self.assets = assets
    }
}

/// What `app-meta.json` at a release tag carries. `bundle_name` is optional (the bundle id is the
/// identity; the name is what a person sees).
public struct AppMeta: Codable, Sendable, Equatable {
    public var name: String?
    public var bundle_id: String?
    public var bundle_name: String?
    public var type: String?
    public var tagline: String?
    public var description: String?
    public var hold_url: String?
    public var hold_since: String?
    public var kind: String?
    public var main_mac_only: Bool?
    public init() {}
}

/// Raw JSON for one `gh api <path>` call. Production runs `gh`; fixtures answer from a table.
public protocol GitHubReader: Sendable {
    func json(_ path: String) throws -> Data
}

public enum FeedGenerator {
    /// Every field a row takes from `app-meta.json`, with the flag-free name the refusal uses.
    static let requiredMetaFields: [(String, (AppMeta) -> String?)] = [
        ("name", { $0.name }), ("bundle_id", { $0.bundle_id }), ("type", { $0.type }),
        ("tagline", { $0.tagline }), ("description", { $0.description }),
    ]

    /// The latest published non-draft release of one repo, or nil when it has none.
    public static func latestRelease(repo: String, gh: GitHubReader) throws -> RepoRelease? {
        let data: Data
        do { data = try gh.json("repos/\(repo)/releases/latest") }
        catch { return nil }   // GitHub answers 404 for a repo with nothing published
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true,
              let tag = object["tag_name"] as? String else { return nil }
        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> RepoRelease.Asset? in
            guard let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String else { return nil }
            return RepoRelease.Asset(name: name, url: url, digest: asset["digest"] as? String,
                                     bytes: (asset["size"] as? NSNumber)?.int64Value ?? 0)
        }
        return RepoRelease(tag: tag, publishedAt: object["published_at"] as? String, assets: assets)
    }

    /// One row, or nil when the repo has no published release.
    public static func row(for repo: String, gh: GitHubReader) throws -> FeedApp? {
        guard let release = try latestRelease(repo: repo, gh: gh) else { return nil }
        var version = release.tag
        if version.hasPrefix("v") { version = String(version.dropFirst()) }
        guard VersionCompare.isValid(version) else {
            throw khuFail("refused: \(repo) publishes tag \(release.tag), which is not a dotted numeric version; nothing was generated")
        }
        guard let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw khuFail("refused: \(repo) publishes \(release.tag) with no .dmg asset; nothing was generated")
        }
        guard let digest = dmg.digest?.lowercased(), digest.hasPrefix("sha256:") else {
            throw khuFail("refused: \(repo) \(release.tag)'s \(dmg.name) has no sha256 digest from GitHub; nothing was generated")
        }
        let sha = String(digest.dropFirst("sha256:".count))
        guard sha.count == 64, dmg.bytes > 0 else {
            throw khuFail("refused: \(repo) \(release.tag)'s \(dmg.name) names no usable digest or size; nothing was generated")
        }
        guard let metaData = try? gh.json("repos/\(repo)/contents/app-meta.json?ref=\(release.tag)") else {
            throw khuFail("refused: \(repo) publishes \(release.tag) but has no app-meta.json at that tag; add name, bundle_id, type, tagline and description there. Nothing was generated.")
        }
        guard let encoded = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
              let content = encoded["content"], let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }),
              let meta = try? JSON.decode(AppMeta.self, from: decoded) else {
            throw khuFail("refused: \(repo) \(release.tag)'s app-meta.json cannot be read; nothing was generated")
        }
        let missing = requiredMetaFields.filter { $0.1(meta)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }.map(\.0)
        guard missing.isEmpty else {
            throw khuFail("refused: \(repo) app-meta.json at \(release.tag) is missing \(missing.joined(separator: ", ")). Nothing was generated.")
        }
        var entry = FeedApp(version: version, file: dmg.name, sha256: sha, bytes: dmg.bytes,
                            kind: meta.kind ?? "app-dmg")
        entry.url = dmg.url
        entry.name = meta.name
        entry.bundleID = meta.bundle_id
        entry.bundleName = meta.bundle_name
        entry.type = meta.type
        entry.tagline = meta.tagline
        entry.description = meta.description
        entry.holdURL = meta.hold_url
        entry.holdSince = meta.hold_since
        entry.mainMacOnly = meta.main_mac_only
        entry.released = release.publishedAt
        return entry
    }

    /// The whole feed: one row per repo with a published release. No `previous`, no `network`, no
    /// compatibility row — the generated feed is the only feed.
    public static func feed(apps: [String: String], gh: GitHubReader, now: Date = Date()) throws -> Feed {
        var feed = Feed(published_at: ISO.string(now))
        for (app, repo) in apps.sorted(by: { $0.key < $1.key }) {
            if let entry = try row(for: repo, gh: gh) { feed.apps[app] = entry }
        }
        return try feed.validated()
    }

    /// The signed envelope for those bytes, exactly what a client verifies.
    public static func signed(_ feed: Feed, keyFile: URL) throws -> Data {
        let key = try Signing.loadPrivateKey(from: keyFile)
        let data = try JSON.encode(feed.validated())
        return try JSON.encode(Release(feed: data, signature: try Signing.sign(data, with: key)))
    }
}
