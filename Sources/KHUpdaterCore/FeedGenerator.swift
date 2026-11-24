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
    /// The release's own body: the app's changelog, used as the row's notes when it has none.
    public var body: String?
    public var assets: [Asset]
    public init(tag: String, publishedAt: String?, body: String? = nil, assets: [Asset]) {
        self.tag = tag; self.publishedAt = publishedAt; self.body = body; self.assets = assets
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
    /// The app's own local artifact name, spaces and all (RELEASE-POLICY §229): `file` keeps it while
    /// `url` is how GitHub stores the bytes, and the divergence is evidence the bytes were checked
    /// against the right name. Nil keeps today's behaviour, so no row rewrites itself in the meantime.
    public var localFile: String?
    public init(name: String? = nil, bundle_id: String? = nil, bundle_name: String? = nil, type: String? = nil,
                tagline: String? = nil, description: String? = nil, hold_url: String? = nil,
                hold_since: String? = nil, kind: String? = nil, main_mac_only: Bool? = nil,
                localFile: String? = nil) {
        self.name = name; self.bundle_id = bundle_id; self.bundle_name = bundle_name; self.type = type
        self.tagline = tagline; self.description = description; self.hold_url = hold_url
        self.hold_since = hold_since; self.kind = kind; self.main_mac_only = main_mac_only
        self.localFile = localFile
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
    /// One line per word this run changed, by app and field with the source that supplied it:
    /// `file-studio: type utility (tag)`. A publish that changes nothing prints nothing.
    public var wordChanges: [String]
    /// Stray releases skipped by name, and anything else the run decided instead of doing.
    public var notes: [String]
    public init(feed: Feed, sources: [String: String] = [:], unpublished: [String] = [], stale: [String] = [],
                wordChanges: [String] = [], notes: [String] = []) {
        self.feed = feed; self.sources = sources; self.unpublished = unpublished; self.stale = stale
        self.wordChanges = wordChanges; self.notes = notes
    }
}

/// Proof that a row's asset really downloads: a tokenless GET whose bytes hash and count to what the
/// release names. GitHub shows a release and its assets to a token-holder while every anonymous GET
/// returns 404 (drafts, deleted tags), so a row built without this proof is the 2026-11-23 outage one
/// step along — a link that looks right and downloads nothing. Issue rows 20261123-53/-54.
public protocol AssetVerifier: Sendable {
    func prove(url: String, repo: String, tag: String, asset: String, expectedSha: String, expectedBytes: Int64) throws
}

/// The real one: URLSession with no credentials, hashing what arrives.
///
/// Measured 2026-11-23: three publishes in a row died on a transient `NSURLErrorNetworkConnectionLost`
/// (file-studio's asset once, media-studio's 255 MB one twice) while `curl` fetched the same URL in
/// 33 s with a matching sha. A dropped connection is not a bad asset, so the proof tries again — and
/// the refusal when every attempt has failed is exactly the one it always was.
public struct AnonymousAsset: AssetVerifier {
    let attempts: Int
    let backoff: TimeInterval
    let session: URLSession

    public init(attempts: Int = 3, backoff: TimeInterval = 1, session: URLSession = .shared) {
        self.attempts = attempts; self.backoff = backoff; self.session = session
    }

    public func prove(url: String, repo: String, tag: String, asset: String, expectedSha: String, expectedBytes: Int64) throws {
        guard let address = URL(string: url) else {
            throw khuFail("refused: \(repo) \(tag)'s \(asset) is not a URL; nothing was generated")
        }
        var outcome: Result<(String, Int64), Error> = .failure(khuFail("no answer"))
        for attempt in 1...max(1, attempts) {
            outcome = download(address)
            if case .success = outcome { break }
            if attempt < attempts, backoff > 0 { Thread.sleep(forTimeInterval: backoff * Double(attempt)) }
        }
        switch outcome {
        case .failure(let error):
            throw khuFail("refused: \(repo) \(tag)'s \(asset) did not download anonymously (\(error)); nothing was generated")
        case .success(let held):
            guard held.0 == expectedSha, held.1 == expectedBytes else {
                throw khuFail("refused: \(repo) \(tag)'s \(asset) downloaded \(held.0) (\(held.1) B), not the \(expectedSha) (\(expectedBytes) B) the release names; nothing was generated")
            }
        }
    }

    /// One attempt. A failure is returned, never thrown, so the caller decides whether to retry.
    private func download(_ address: URL) -> Result<(String, Int64), Error> {
        var request = URLRequest(url: address, timeoutInterval: 600)
        request.setValue("Studio Launcher KH feed check", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(String, Int64), Error> = .failure(khuFail("no answer"))
        session.downloadTask(with: request) { file, response, error in
            defer { semaphore.signal() }
            if let error { outcome = .failure(error); return }
            guard let file, let http = response as? HTTPURLResponse else {
                outcome = .failure(khuFail("no response")); return
            }
            guard http.statusCode == 200 else {
                outcome = .failure(khuFail("answered \(http.statusCode)")); return
            }
            do {
                let held = try Signing.sha256Hex(fileAt: file)
                try? FileManager.default.removeItem(at: file)
                outcome = .success((held.hex, held.bytes))
            } catch { outcome = .failure(error) }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 660)
        return outcome
    }
}

/// For fixtures: proves nothing, so a table's rows need no download. Tests that check the guard pass
/// their own verifier.
public struct UnverifiedAsset: AssetVerifier {
    public init() {}
    public func prove(url: String, repo: String, tag: String, asset: String, expectedSha: String, expectedBytes: Int64) throws {}
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
        return RepoRelease(tag: tag, publishedAt: object["published_at"] as? String,
                           body: (object["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           assets: assets)
    }

    /// `owner/repo` from a GitHub release asset address, or nil when the address is not one.
    static func repoName(from url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let parts = parsed.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "releases" else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// A tag's verdict: the version it names, or why it is not this app's release. A prefixed tag
    /// (`wire-0.5.0`) is this app's only when the prefix is its own; a repo carrying another app's
    /// tag is a stray release, skipped by name — never a row, never an estate-wide refusal.
    static func verdict(_ tag: String, app: String, repo: String) -> (version: String?, reason: String?) {
        let bare = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if VersionCompare.isValid(bare) { return (bare, nil) }
        if let dash = tag.lastIndex(of: "-") {
            let prefix = String(tag[tag.startIndex..<dash])
            let candidate = String(tag[tag.index(after: dash)...])
            // Only the app's own ids count: a repo whose name happens to match another app's prefix
            // must not launder that app's release into this one.
            let own = [app, app.replacingOccurrences(of: "-studio", with: "")]
            if VersionCompare.isValid(candidate) {
                return own.contains(prefix) ? (candidate, nil) : (nil, "another app's prefix")
            }
        }
        return (nil, "not a version tag")
    }

    /// The newest release this app may become a row from. A stray release (another app's tag) is
    /// printed and skipped, and the repo's next-most-recent release is tried; if nothing acceptable
    /// remains the app gets no row, which is printed too. One accident in one repo never costs the
    /// other apps their publish, and the exclusion still guarantees wrong bytes cannot ship.
    static func release(for app: String, repo: String, gh: GitHubReader) throws -> (release: RepoRelease?, notes: [String]) {
        guard let latest = try latestRelease(repo: repo, gh: gh) else { return (nil, []) }
        if verdict(latest.tag, app: app, repo: repo).version != nil { return (latest, []) }
        var notes: [String] = []
        var seen = Set<String>()
        for candidate in [latest] + (try olderReleases(repo: repo, gh: gh)) {
            guard seen.insert(candidate.tag).inserted else { continue }
            let said = verdict(candidate.tag, app: app, repo: repo)
            if said.version != nil { return (candidate, notes) }
            notes.append("stray release ignored: \(repo) \(candidate.tag) — \(said.reason ?? "not a version tag")")
        }
        return (nil, notes)
    }

    /// Older published releases, newest first. Only fetched when the newest one is a stray.
    static func olderReleases(repo: String, gh: GitHubReader) throws -> [RepoRelease] {
        guard let data = try? gh.json("repos/\(repo)/releases?per_page=20"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { object -> RepoRelease? in
            guard object["draft"] as? Bool != true,
                  let tag = object["tag_name"] as? String else { return nil }
            let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset -> RepoRelease.Asset? in
                guard let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String else { return nil }
                return RepoRelease.Asset(name: name, url: url, digest: asset["digest"] as? String,
                                         bytes: (asset["size"] as? NSNumber)?.int64Value ?? 0)
            }
            return RepoRelease(tag: tag, publishedAt: object["published_at"] as? String,
                               body: (object["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                               assets: assets)
        }
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

    /// A row's words come from that app's own released metadata (RELEASE-POLICY §2d): the tag's
    /// `app-meta.json` first, the registry only where the tag has no field, and the word the feed
    /// already serves when neither does. A row whose words come from its own release cannot drift
    /// from the thing it describes — the same argument that retired a shared registry. Nothing is
    /// invented or blanked, and every change is printed with the source that supplied it, because a
    /// silent rewrite is what makes people stop trusting a feed.
    static func words(app: String, repo: String, tag: String, entry: RegistryEntry?, served: FeedApp?,
                      gh: GitHubReader) throws -> (meta: RepoAppMeta, sources: [String: String],
                                                   changes: [String], stale: String?) {
        var fromTag: RepoAppMeta?
        if let data = try? gh.json("repos/\(repo)/contents/app-meta.json?ref=\(tag)"),
           let encoded = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let content = encoded["content"], let decoded = Data(base64Encoded: content.filter { !$0.isWhitespace }),
           let meta = try? JSON.decode(RepoAppMeta.self, from: decoded),
           // One repo can publish two rows (the Launcher and the helper inside it). The tag's file
           // describes the app whose bundle id it names; another app's row keeps its own words.
           entry?.bundle_id == nil || meta.bundle_id == nil || meta.bundle_id == entry?.bundle_id {
            fromTag = meta
        }
        func clean(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        var sources: [String: String] = [:], changes: [String] = []
        func pick(_ field: String, _ tagValue: String?, _ registryValue: String?, _ servedValue: String?) -> String? {
            let tagText = clean(tagValue), registryText = clean(registryValue), servedText = clean(servedValue)
            let value: String?, source: String
            if let tagText { (value, source) = (tagText, "tag") }
            else if let registryText { (value, source) = (registryText, "registry") }
            else if let servedText { (value, source) = (servedText, "served") }
            else { (value, source) = (nil, "none") }
            sources[field] = source
            if let value, source != "served", value != servedValue {
                changes.append("\(app): \(field) \(value) (\(source))")
            }
            return value
        }
        var meta = RepoAppMeta(
            name: pick("name", fromTag?.name, entry?.name, served?.name),
            bundle_id: pick("bundle_id", fromTag?.bundle_id, entry?.bundle_id, served?.bundleID),
            bundle_name: pick("bundle_name", fromTag?.bundle_name, entry?.bundle_name, served?.bundleName),
            type: pick("type", fromTag?.type, entry?.type, served?.type),
            tagline: pick("tagline", fromTag?.tagline, entry?.tagline, served?.tagline),
            description: pick("description", fromTag?.description, entry?.description, served?.description),
            hold_url: pick("hold_url", fromTag?.hold_url, entry?.hold_url, served?.holdURL),
            hold_since: pick("hold_since", fromTag?.hold_since, entry?.hold_since, served?.holdSince),
            kind: pick("kind", fromTag?.kind, entry?.kind, served?.kind),
            main_mac_only: fromTag?.main_mac_only ?? entry?.main_mac_only ?? served?.mainMacOnly)
        // The app's own local artifact name is a statement by the release, never a fallback: a tag
        // that does not name one keeps today's behaviour, so nothing rewrites itself meanwhile.
        meta.localFile = fromTag?.localFile
        let missing = requiredMetaFields.filter { clean($0.1(meta)) == nil }.map(\.0)
        guard missing.isEmpty else {
            throw khuFail("refused: \(repo) \(tag) has no \(missing.joined(separator: ", ")) in its app-meta.json, the registry, or the served feed. Nothing was generated.")
        }
        // The tag now covers every field the registry could supply: the entry is a leftover.
        let stale = fromTag != nil && entry != nil && !sources.values.contains("registry")
            ? "\(app): words from tag \(tag); registry entry is stale and was ignored — delete it in the commit that added the tag file"
            : nil
        return (meta, sources, changes, stale)
    }

    /// The tool's own sentence, written when a release has no changelog. A card showing exactly this
    /// has no changelog to show; anything else is a sentence a person wrote.
    public static let placeholderNotes = "Signed release from the KH Studio feed."

    /// The opening line of a notes string, short enough to read in a change line.
    static func firstLine(_ text: String?) -> String {
        guard let text else { return "none" }
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    /// One row, or nil when the repo has no published release.
    public static func row(app: String, repo: String, registry: FeedRegistry?, served: FeedApp? = nil,
                           gh: GitHubReader, verifier: AssetVerifier = AnonymousAsset(),
                           refreshNotes: Bool = false)
        throws -> (row: FeedApp?, source: String?, stale: String?, changes: [String]) {
        let chosen = try release(for: app, repo: repo, gh: gh)
        var repair: [String] = []
        guard let release = chosen.release else { return (nil, nil, nil, chosen.notes) }
        guard let version = verdict(release.tag, app: app, repo: repo).version else {
            throw khuFail("refused: \(repo) publishes \(release.tag); nothing was generated")
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
        // `file` is the local artifact name and is never normalised: a row whose version did not move
        // keeps the served name exactly. A changed row takes the local name from the registry only
        // when that name carries this release's version; a stale pin is reported and the row falls
        // back to the asset's own name, so a version and its file name can never disagree.
        var fileNote: String?
        let untouched = served?.version == version
        var rowFile: String
        if untouched {
            rowFile = served?.file ?? asset.name
        } else if let pinned = entry?.file, !pinned.isEmpty, pinned.contains(version) {
            rowFile = pinned
        } else {
            rowFile = asset.name
            if let pinned = entry?.file, !pinned.isEmpty {
                fileNote = "\(app): registry file \(pinned) does not name \(version) and is ignored; the row uses \(asset.name)"
            }
        }
        // The asset must really download, tokenless, to the bytes the release names, or there is no
        // row — a draft or an orphan release passes every check but this one.
        try verifier.prove(url: asset.url, repo: repo, tag: release.tag, asset: asset.name,
                           expectedSha: sha, expectedBytes: asset.bytes)
        let made = try words(app: app, repo: repo, tag: release.tag, entry: entry, served: served, gh: gh)
        let meta = made.meta
        // A release tag that names the app's own local artifact file wins over the registry pin and
        // over GitHub's stored name — measured 2026-11-23, the generator wrote the dotted stored name
        // into `file` and split a row from the name it had served for months. `url` keeps the stored
        // name; the two differing is the evidence the bytes were matched to the right local file.
        if let stated = meta.localFile, !stated.isEmpty { rowFile = stated }
        var row = FeedApp(version: version, file: rowFile, sha256: sha, bytes: asset.bytes,
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
        // Only a version change owns that release's notes: the release body is this version's
        // changelog. An untouched row keeps the notes it already serves, whatever its release body
        // says — six rows' curated notes are not replaced by a 39-character body.
        // `--refresh-notes` is the one named exception, and it cannot overwrite a person: the row's
        // notes must be exactly the tool's placeholder, byte for byte.
        // `GATE PASS …` is the machine line the release convention puts at the top of every body; it
        // stays in the body as audit and never reaches a card, which would open with jargon.
        // Byte for byte, not "looks like": the same words with one stray space are refused too, because
        // a comparison loose enough to accept them is loose enough to overwrite someone's sentence.
        let placeholder = refreshNotes && served?.notes == Self.placeholderNotes
        if served?.version != version || placeholder, let body = release.body {
            let prose = body.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("GATE PASS") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty {
                if placeholder, prose != served?.notes {
                    repair = ["notes refreshed: \(app) — \"\(Self.firstLine(served?.notes))\" → \"\(Self.firstLine(prose))\""]
                }
                row.notes = prose
            }
        }
        // The row's summary source: what supplied the words it actually has. Fields no source had
        // are left out, so "tag" means every word came from the release, not just most of them.
        let used = made.sources.values.filter { $0 != "none" }
        let source: String
        if used.contains("registry") { source = "registry" }
        else if !used.isEmpty && used.allSatisfy({ $0 == "tag" }) { source = "tag:\(release.tag)" }
        else if used.contains("served") { source = "served" }
        else { source = "none" }
        return (row, source, made.stale ?? fileNote, chosen.notes + made.changes + repair)
    }

    /// The whole feed: one row per repo with a published release, no compatibility row. Every app
    /// with no published release is reported by name — that list is the only thing that may legally
    /// disappear from a published feed.
    /// `previous` is the feed the world reads now, when there is one. A publish may change the row
    /// it publishes, but it may never lose a field: what the publisher host added to a row of the
    /// same version (its icon, notes, features, delta) is carried forward, and the top level keeps
    /// its `network` block and pins. A new version drops the version-specific ones — the integrity
    /// check then says so, which is the point.
    public static func generate(apps: [String: String], registry: FeedRegistry? = nil, previous: Feed? = nil,
                                gh: GitHubReader, verifier: AssetVerifier = AnonymousAsset(),
                                refreshNotes: Set<String> = [], now: Date = Date()) throws -> FeedGeneration {
        // A named repair that names an app this run does not generate is a typo, not a no-op.
        if let unknown = refreshNotes.subtracting(apps.keys).sorted().first {
            throw khuFail("refused: --refresh-notes names \(unknown), which this run does not generate; nothing was generated")
        }
        var feed = Feed(published_at: ISO.string(now))
        var sources: [String: String] = [:], unpublished: [String] = [], stale: [String] = [], wordChanges: [String] = []
        var notes: [String] = []
        for (app, repo) in apps.sorted(by: { $0.key < $1.key }) {
            let made = try row(app: app, repo: repo, registry: registry, served: previous?.apps[app], gh: gh,
                               verifier: verifier, refreshNotes: refreshNotes.contains(app))
            guard var row = made.row else {
                unpublished.append(app)
                notes += made.changes
                continue
            }
            if let old = previous?.apps[app] {
                // An icon is the app's identity and its name is content-hashed, so it stays valid
                // across releases: dropping it on a version bump loses the card's artwork.
                if row.icon == nil { row.icon = old.icon; row.iconSha256 = old.iconSha256 }
            }
            // The release body is this version's own notes when it carries one; otherwise the notes
            // a publish does not own carry forward, exactly as the icon does.
            if row.notes == nil, let old = previous?.apps[app] { row.notes = old.notes }
            // Fields no repo can author are never re-derived: `khu publish` writes features, accent,
            // delta, security and unknown extras, and a bulk run reading a repo cannot know them.
            // Measured 2026-11-23: regenerating for gateway 0.2.305 dropped file-studio's features
            // and delta and printer-studio's delta, and the integrity guard rightly refused the
            // whole publish — a version bump is not a reason to forget what a person wrote.
            if let old = previous?.apps[app] {
                if row.features == nil || row.features?.isEmpty == true { row.features = old.features }
                if row.accent == nil { row.accent = old.accent }
                if row.delta == nil { row.delta = old.delta }
                if row.security == nil { row.security = old.security }
                for (key, value) in old.extras where row.extras[key] == nil { row.extras[key] = value }
            }
            // A named row that was not replaced says why, so a named app with no change is never silence.
            if refreshNotes.contains(app), let old = previous?.apps[app], old.version == row.version {
                if old.notes != placeholderNotes {
                    notes += ["notes kept: \(app) — its notes are not the placeholder; nothing was replaced"]
                } else if row.notes == old.notes {
                    notes += ["notes kept: \(app) — its release body carries nothing but the placeholder"]
                }
            }
            feed.apps[app] = row
            if let source = made.source { sources[app] = source }
            if let note = made.stale { stale.append(note) }
            wordChanges += made.changes.filter { !$0.hasPrefix("notes refreshed:") }
            notes += made.changes.filter { $0.hasPrefix("stray release ignored:") || $0.hasPrefix("notes refreshed:") }
        }
        if let previous {
            // A row may not disappear while its repo still publishes: an app dropped from the list
            // while its release exists is a finding, never a quiet disappearance.
            for app in previous.apps.keys.sorted() where feed.apps[app] == nil {
                guard let raw = previous.apps[app]?.url, let repo = repoName(from: raw) else {
                    throw khuFail("refused: row \(app) would disappear and its address names no repo; nothing was generated")
                }
                if let release = try latestRelease(repo: repo, gh: gh) {
                    throw khuFail("refused: row \(app) would disappear while \(repo) still publishes \(release.tag); nothing was generated")
                }
            }
            feed.network = previous.network
            feed.extras = previous.extras
            // No `previous` block, ever (owner/Main, 2026-11-23): a fallback pin whose artifact is
            // gone reads as a rollback path that works and installs nothing, and clients never read
            // it. A downgrade, when it matters, is a per-app question, not a feed field.
        }
        return FeedGeneration(feed: try feed.validated(), sources: sources, unpublished: unpublished,
                              stale: stale, wordChanges: wordChanges.filter { !$0.hasPrefix("stray release ignored:") },
                              notes: notes)
    }

    /// The feed alone, for callers that do not need the report.
    public static func feed(apps: [String: String], gh: GitHubReader, verifier: AssetVerifier = AnonymousAsset(),
                            now: Date = Date()) throws -> Feed {
        try generate(apps: apps, gh: gh, verifier: verifier, now: now).feed
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
