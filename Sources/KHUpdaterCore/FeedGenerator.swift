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
public struct RepoAppMeta: Codable, Sendable, Equatable {
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
    public init(name: String? = nil, bundle_id: String? = nil, bundle_name: String? = nil, type: String? = nil,
                tagline: String? = nil, description: String? = nil, hold_url: String? = nil,
                hold_since: String? = nil, kind: String? = nil, main_mac_only: Bool? = nil) {
        self.name = name; self.bundle_id = bundle_id; self.bundle_name = bundle_name; self.type = type
        self.tagline = tagline; self.description = description; self.hold_url = hold_url
        self.hold_since = hold_since; self.kind = kind; self.main_mac_only = main_mac_only
    }
}

/// One entry in the Launcher repo's words registry. It is a **dated stopgap** (RELEASE-POLICY §2c):
/// the app's own `app-meta.json` at its release tag wins, and when a repo gains one its entry is
/// deleted in the same change — so a leftover entry is reported as stale, never silently used.
///
/// `asset` selects which asset of the release becomes the row: a suffix (`.dmg`, the default) or an
/// exact asset name (`khu`, the helper published from the same Launcher release). It is a field, not
/// a special case in code, because one repo really publishes two feed rows.
public struct RegistryEntry: Codable, Sendable, Equatable {
    public var asset: String?
    /// The row's `file`: the local artifact name this fleet keeps (`Displays Studio KH-0.1.6.dmg`),
    /// never derived from the asset's address name (`Displays.Studio.KH-0.1.6.dmg`). Absent = the
    /// asset's own name.
    public var file: String?
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
    public init(asset: String? = nil, file: String? = nil, name: String? = nil, bundle_id: String? = nil, bundle_name: String? = nil,
                type: String? = nil, tagline: String? = nil, description: String? = nil, hold_url: String? = nil,
                hold_since: String? = nil, kind: String? = nil, main_mac_only: Bool? = nil) {
        self.asset = asset; self.file = file; self.name = name; self.bundle_id = bundle_id; self.bundle_name = bundle_name
        self.type = type; self.tagline = tagline; self.description = description; self.hold_url = hold_url
        self.hold_since = hold_since; self.kind = kind; self.main_mac_only = main_mac_only
    }
    public var meta: RepoAppMeta {
        RepoAppMeta(name: name, bundle_id: bundle_id, bundle_name: bundle_name, type: type, tagline: tagline,
                    description: description, hold_url: hold_url, hold_since: hold_since, kind: kind,
                    main_mac_only: main_mac_only)
    }
}

/// The whole registry: app id → its words and asset selector.
public struct FeedRegistry: Codable, Sendable, Equatable {
    public var apps: [String: RegistryEntry]
    public init(apps: [String: RegistryEntry] = [:]) { self.apps = apps }
    public static func load(from url: URL) throws -> FeedRegistry {
        do { return try JSONDecoder().decode(FeedRegistry.self, from: Data(contentsOf: url)) }
        catch { throw khuFail("cannot read the registry \(url.path): \(error)") }
    }
}

/// What one generation produced, and what it had to say about where the words came from.
public struct FeedGeneration: Sendable {
    public var feed: Feed
    /// app → `tag:<version>` or `registry`: which ref supplied that row's words.
    public var sources: [String: String]
    /// Apps whose repo has no published release: no row, and the reason a row may disappear.
    public var unpublished: [String]
    /// One line per registry entry that was ignored because the tag now carries `app-meta.json`.
    public var stale: [String]
    public init(feed: Feed, sources: [String: String] = [:], unpublished: [String] = [], stale: [String] = []) {
        self.feed = feed; self.sources = sources; self.unpublished = unpublished; self.stale = stale
    }
}

/// Raw JSON for one `gh api <path>` call. Production runs `gh`; fixtures answer from a table.
public protocol GitHubReader: Sendable {
    func json(_ path: String) throws -> Data
}

public enum FeedGenerator {
    /// Every field a row takes from `app-meta.json`, with the flag-free name the refusal uses.
    static let requiredMetaFields: [(String, (RepoAppMeta) -> String?)] = [
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

    /// Which asset of the release becomes the row: a suffix (`.dmg`, the default) or an exact name.
    static func asset(entry: RegistryEntry?, release: RepoRelease, repo: String) throws -> RepoRelease.Asset {
        let want = entry?.asset ?? ".dmg"
        // The selector matches an exact asset name, else a suffix: `.dmg` picks the DMG (its names
        // carry a hash prefix), `khu` picks the helper's `10e22658328f-khu`. The address and the row
        // still take the asset's own name and url, so neither is ever derived from the selector.
        let match = release.assets.first { $0.name == want }
            ?? release.assets.first { $0.name.lowercased().hasSuffix(want.lowercased()) }
        guard let match else {
            throw khuFail("refused: \(repo) \(release.tag) has no \(want) asset; nothing was generated")
        }
        return match
    }

    /// The row's address must be absolute https on github.com, inside that repo's own releases.
    /// A relative or foreign address is refused for the whole run: publishing one makes every Mac
    /// on the feed download nothing, which is exactly how the fleet lost its install path on
    /// 2026-11-23.
    static func checkedURL(_ raw: String, repo: String, asset: String) throws -> String {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com" else {
            throw khuFail("refused: \(repo) \(asset) has no absolute https address on github.com (\(raw)); nothing was generated")
        }
        guard url.path.contains("/\(repo)/releases/download/") else {
            throw khuFail("refused: \(repo) \(asset)'s address is not in that repo's own releases (\(raw)); nothing was generated")
        }
        return raw
    }

    /// The words, and where they came from: the tag's own `app-meta.json` first, else the registry.
    /// A registry entry that the tag now supersedes is reported, never silently used.
    static func words(app: String, repo: String, tag: String, entry: RegistryEntry?,
                      gh: GitHubReader) throws -> (RepoAppMeta, String, String?) {
        if let data = try? gh.json("repos/\(repo)/contents/app-meta.json?ref=\(tag)"),
           let encoded = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let content = encoded["content"], let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }),
           let meta = try? JSON.decode(RepoAppMeta.self, from: decoded),
           // One repo can publish two rows (the Launcher and the helper inside it). The tag's file
           // describes the app whose bundle id it names; another app's row keeps its registry words.
           entry == nil || entry?.bundle_id == nil || meta.bundle_id == nil || meta.bundle_id == entry?.bundle_id {
            try requireMeta(meta, repo: repo, where: "app-meta.json at \(tag)")
            let stale = entry == nil ? nil
                : "\(app): words from tag \(tag); registry entry is stale and was ignored — delete it in the commit that added the tag file"
            return (meta, "tag:\(tag)", stale)
        }
        guard let entry else {
            throw khuFail("refused: \(repo) publishes \(tag) but has no app-meta.json at that tag and no registry entry for \(app). Nothing was generated.")
        }
        try requireMeta(entry.meta, repo: repo, where: "\(app)'s registry entry")
        return (entry.meta, "registry", nil)
    }

    static func requireMeta(_ meta: RepoAppMeta, repo: String, where at: String) throws {
        let missing = requiredMetaFields.filter { $0.1(meta)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }.map(\.0)
        guard missing.isEmpty else {
            throw khuFail("refused: \(repo) \(at) is missing \(missing.joined(separator: ", ")). Nothing was generated.")
        }
    }

    /// One row, or nil when the repo has no published release.
    public static func row(app: String, repo: String, registry: FeedRegistry?,
                           gh: GitHubReader) throws -> (row: FeedApp?, source: String?, stale: String?) {
        guard let release = try latestRelease(repo: repo, gh: gh) else { return (nil, nil, nil) }
        var version = release.tag
        if version.hasPrefix("v") { version = String(version.dropFirst()) }
        guard VersionCompare.isValid(version) else {
            throw khuFail("refused: \(repo) publishes tag \(release.tag), which is not a dotted numeric version; nothing was generated")
        }
        let entry = registry?.apps[app]
        let asset = try asset(entry: entry, release: release, repo: repo)
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") else {
            throw khuFail("refused: \(repo) \(release.tag)'s \(asset.name) has no sha256 digest from GitHub; nothing was generated")
        }
        let sha = String(digest.dropFirst("sha256:".count))
        guard sha.count == 64, asset.bytes > 0 else {
            throw khuFail("refused: \(repo) \(release.tag)'s \(asset.name) names no usable digest or size; nothing was generated")
        }
        let (meta, source, stale) = try words(app: app, repo: repo, tag: release.tag, entry: entry, gh: gh)
        var row = FeedApp(version: version, file: entry?.file ?? asset.name, sha256: sha, bytes: asset.bytes,
                          kind: meta.kind ?? "app-dmg")
        // The address is the asset's own, as GitHub serves it; `file` keeps the local name. Both come
        // from the API, so neither is ever derived from the other.
        row.url = try checkedURL(asset.url, repo: repo, asset: asset.name)
        row.name = meta.name
        row.bundleID = meta.bundle_id
        row.bundleName = meta.bundle_name
        row.type = meta.type
        row.tagline = meta.tagline
        row.description = meta.description
        row.holdURL = meta.hold_url
        row.holdSince = meta.hold_since
        row.mainMacOnly = meta.main_mac_only
        row.released = release.publishedAt
        return (row, source, stale)
    }

    /// The whole feed: one row per repo with a published release, no `previous`, no `network`, no
    /// compatibility row. Every app with no published release is reported by name — that list is the
    /// only thing that may legally disappear from a published feed.
    /// `previous` is the feed the world reads now, when there is one. A publish may change the row
    /// it publishes, but it may never lose a field: what the publisher host added to a row of the
    /// same version (its icon, notes, features, delta) is carried forward, and the top level keeps
    /// its `network` block and pins. A new version drops the version-specific ones — the integrity
    /// check then says so, which is the point.
    public static func generate(apps: [String: String], registry: FeedRegistry? = nil, previous: Feed? = nil,
                                gh: GitHubReader, now: Date = Date()) throws -> FeedGeneration {
        var feed = Feed(published_at: ISO.string(now))
        var sources: [String: String] = [:], unpublished: [String] = [], stale: [String] = []
        for (app, repo) in apps.sorted(by: { $0.key < $1.key }) {
            let made = try row(app: app, repo: repo, registry: registry, gh: gh)
            guard var row = made.row else { unpublished.append(app); continue }
            if let old = previous?.apps[app], old.version == row.version {
                if row.icon == nil { row.icon = old.icon; row.iconSha256 = old.iconSha256 }
                if row.notes == nil { row.notes = old.notes }
                if row.features == nil { row.features = old.features }
                if row.accent == nil { row.accent = old.accent }
                if row.delta == nil { row.delta = old.delta }
                if row.security == nil { row.security = old.security }
                for (key, value) in old.extras where row.extras[key] == nil { row.extras[key] = value }
            }
            feed.apps[app] = row
            if let source = made.source { sources[app] = source }
            if let note = made.stale { stale.append(note) }
        }
        if let previous {
            feed.network = previous.network
            feed.extras = previous.extras
            // `previous` is a fallback a distributor may install: a pin with no address is a dead
            // downgrade path, so only pins that carry their own url are kept. The 2026-11-23 pins
            // all pointed at artifacts that no longer exist (kh-releases holds no releases), and
            // none can be given one, so the generated feed carries no `previous` at all.
            var pins = (previous.previous ?? [:]).filter {
                feed.apps[$0.key] != nil && ($0.value.url?.isEmpty == false)
            }
            for (app, row) in feed.apps {
                if let before = previous.apps[app], before.version != row.version,
                   let url = before.url, !url.isEmpty { pins[app] = before }
            }
            feed.previous = pins.isEmpty ? nil : pins
        }
        return FeedGeneration(feed: try feed.validated(), sources: sources, unpublished: unpublished, stale: stale)
    }

    /// The feed alone, for callers that do not need the report.
    public static func feed(apps: [String: String], gh: GitHubReader, now: Date = Date()) throws -> Feed {
        try generate(apps: apps, gh: gh, now: now).feed
    }

    /// The signed envelope for those bytes, exactly what a client verifies. The signature is
    /// verified here with the key's own public half before anything can be written: a bad key or a
    /// mis-encoded feed fails before it reaches `main`, never after.
    public static func signed(_ feed: Feed, keyFile: URL) throws -> Data {
        let key = try Signing.loadPrivateKey(from: keyFile)
        let data = try JSON.encode(feed.validated())
        let release = Release(feed: data, signature: try Signing.sign(data, with: key))
        guard let feedData = release.feedData, let signature = release.signatureData,
              Signing.verify(feedData, signature: signature, publicKey: key.publicKey) else {
            throw khuFail("the signed feed does not verify with the key's own public half; nothing was written")
        }
        return try JSON.encode(release)
    }
}
