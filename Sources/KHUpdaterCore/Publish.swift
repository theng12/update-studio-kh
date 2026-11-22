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

    /// How many verified versions of each app the feed keeps: the owner's setting, next to the feed,
    /// 2 — the current version and its previous — unless it says otherwise. A value below 2 is
    /// refused when it is set and never used when read: a rollback needs the previous one.
    public enum KeepCount {
        public static let defaultsTo = 2
        public static func file(in feedDir: URL) -> URL { feedDir.appendingPathComponent("retention-settings.json") }
        public static func keep(in feedDir: URL) -> Int {
            let saved = (try? AtomicFile.readJSON([String: Int].self, from: file(in: feedDir)))?["keep"]
            return max(saved ?? defaultsTo, defaultsTo)
        }
        public static func set(_ keep: Int, in feedDir: URL) throws {
            guard keep >= defaultsTo else {
                throw khuFail("a feed keeps at least \(defaultsTo) verified versions (current + previous), not \(keep)")
            }
            try AtomicFile.writeJSON(["keep": keep], to: file(in: feedDir))
        }
    }

    private struct Retention: Decodable {
        struct Entry: Decodable { var current: FeedApp; var previous: FeedApp? }
        var apps: [String: Entry]
    }

    /// Adopt the publisher's existing pins once, without selecting or rebuilding versions.
    public static func withPreviousInstallers(_ feed: Feed, in dir: URL) throws -> Feed {
        guard feed.previous == nil else { return feed }
        var result = feed
        result.previous = [:]
        let ledger = dir.appendingPathComponent("artifact-retention.json")
        if FileManager.default.fileExists(atPath: ledger.path) {
            let saved = try JSON.decode(Retention.self, from: Data(contentsOf: ledger))
            for (app, current) in feed.apps {
                guard let entry = saved.apps[app] else { continue }
                if VersionCompare.isNewer(current.version, than: entry.current.version) {
                    // A publish may finish before the operator refreshes its ledger.
                    result.previous?[app] = entry.current
                } else {
                    guard entry.current.version == current.version, entry.current.sha256 == current.sha256,
                          entry.current.file == current.file, entry.current.bytes == current.bytes else {
                        throw khuFail("\(app) retention ledger does not match the signed current installer")
                    }
                    result.previous?[app] = entry.previous
                }
            }
        }
        if result.previous?.isEmpty == true { result.previous = nil }
        _ = try result.validated()
        for (app, entry) in result.previous ?? [:] {
            let file = dir.appendingPathComponent("artifacts").appendingPathComponent(entry.file)
            let measured = try Signing.sha256Hex(fileAt: file)
            guard measured.hex == entry.sha256, measured.bytes == entry.bytes else {
                throw khuFail("\(app) retained previous installer hash or size mismatch")
            }
        }
        return result
    }

    /// For display only (the status page). Unverified.
    public static func loadFeed(from dir: URL) -> Feed? {
        guard let release = try? AtomicFile.readJSON(Release.self, from: releaseFile(in: dir)),
              let data = release.feedData else { return nil }
        return try? JSON.decode(Feed.self, from: data)
    }

    /// The app ids this fleet publishes. A publish is checked against these and against the ids
    /// the feed already names, so a typo ("printer" beside "printer-studio") cannot create a second
    /// entry; a genuinely new app is published once with `--new-app`.
    public static let fleetApps: Set<String> = Set(AppNames.names.keys).union(["launcher"])

    /// The only labels a publisher may write: `business`, `entertainment`, `media`, `system` and
    /// `utility`. A feed can still decode any raw label: an old or unknown one stays in the signed
    /// bytes for the consumer to read Unlabelled, and is never carried forward as though this
    /// publisher had chosen it.
    public static let appTypes: Set<String> = ["business", "entertainment", "extension", "media", "plugin", "system", "utility"]

    public static func validateAppType(_ raw: String) throws {
        guard appTypes.contains(raw) else {
            throw khuFail("--type must be business, entertainment, extension, media, plugin, system or utility, not \(raw)")
        }
    }

    private static func knownAppType(_ raw: String?) -> String? {
        guard let raw, appTypes.contains(raw) else { return nil }
        return raw
    }

    /// Whether a publish may name `app` in `feedDir`. `allowNew` is the CLI's explicit statement
    /// that this is a genuinely new app, not a mistyped one.
    public static func isKnownApp(_ app: String, in feedDir: URL, allowNew: Bool = false) -> Bool {
        allowNew || fleetApps.contains(app) || (loadFeed(from: feedDir)?.apps[app] != nil)
    }

    /// Removes one app key from the signed feed — used to repair a mis-keyed duplicate entry.
    /// Artifacts stay on disk so the next publish's retention pass decides what is unreferenced.
    public static func unpublish(feedDir: URL, keyFile: URL, app: String) throws {
        let key = try Signing.loadPrivateKey(from: keyFile)
        try FileLock.withExclusive(feedDir.appendingPathComponent("publish.lock")) {
            guard var feed = try loadVerifiedFeed(from: feedDir, publicKey: key.publicKey) else {
                throw khuFail("nothing is published in \(feedDir.path)")
            }
            guard feed.apps.removeValue(forKey: app) != nil else { throw khuFail("the feed has no \(app)") }
            if feed.previous?.removeValue(forKey: app) != nil, feed.previous?.isEmpty == true { feed.previous = nil }
            var priors = priorMap(in: feedDir)
            priors.removeValue(forKey: app)
            try AtomicFile.writeJSON(priors, to: feedDir.appendingPathComponent("priors.json"))
            feed.published_at = ISO.string(Date())
            try saveFeed(feed, to: feedDir, key: key)
        }
    }

    public static func saveFeed(_ feed: Feed, to dir: URL, key: Curve25519.Signing.PrivateKey) throws {
        let data = JSON.encode(feed)
        try AtomicFile.writeJSON(Release(feed: data, signature: try Signing.sign(data, with: key)), to: releaseFile(in: dir))
    }

    /// Publish one app. Serialised across processes; the artifact is stored under its own hash
    /// (`<sha12>-<name>`), so two apps' files can never overwrite each other and bytes an older
    /// feed still names are never replaced. After the signed release commits, installers and
    /// icons no pin names any more retire to `retireArtifact` — the native macOS Trash when
    /// nothing is injected (`## Feed`), never the operator's Trash from a fixture feed in `Tests`.
    /// What an app row must carry before it reaches the fleet, as one list: a later widening or
    /// narrowing is one line here, never a second copy of the rule at the call site. `type` groups
    /// the app; the two words are what its card renders. The hold pair is conditional — only a row
    /// that already served a hold must keep one, so a client-only app is never made to grow a hold
    /// endpoint in order to publish. Version, sha256 and bytes come from the sealed artifact, never
    /// from a flag, so they are not in this list.
    static func missingAppFields(_ entry: FeedApp, holdServing: Bool, holdSinceKnown: Bool) -> [String] {
        var missing: [String] = []
        if entry.type == nil {
            missing.append("type — pass --type business|entertainment|media|plugin|system|utility")
        }
        if (entry.tagline ?? "").isEmpty { missing.append(#"tagline — pass --tagline "…""#) }
        if (entry.description ?? "").isEmpty { missing.append(#"description — pass --description "…""#) }
        // Both halves of a hold are required of a row that serves one. `holdSince` is derived below
        // from the version when it is not named, so judging the row as written is what keeps the
        // three registry apps with a null `holdSince` publishable; an explicit empty value is refused.
        if holdServing && (entry.holdURL ?? "").isEmpty {
            missing.append("hold — this app serves an update hold; pass --hold-url …")
        }
        if holdServing && !holdSinceKnown {
            missing.append("hold since — this app serves an update hold; pass --hold-since <version>")
        }
        return missing
    }

    /// The apps that serve an update hold, from `hold-apps.json` beside the feed, generated from
    /// `_orchestra/developer-handoff/registry/apps.json`. A missing or unreadable file is not a
    /// reason to skip the rule for a row that already served a hold: the caller passes that in.
    public static func holdApps(in feedDir: URL) -> Set<String> {
        let file = feedDir.appendingPathComponent("hold-apps.json")
        guard let data = try? Data(contentsOf: file),
              let ids = try? JSON.decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    public static func publish(feedDir: URL, keyFile: URL, app: String, version: String, artifact: URL,
                               kind: String?, allowSame: Bool, notes: String? = nil, displayName: String? = nil, words: AppWords? = nil, mainMacOnly: Bool? = nil,
                               meta: ((String) throws -> AppMeta)? = { try AppMeta.read(dmg: $0) }, holdURL: String? = nil, holdSince: String? = nil,
                               security: Bool = false, type: String? = nil,
                               keep: Int? = nil, now: Date = Date(),
                               requireComplete: Bool = false,
                               retireArtifact: ((URL) throws -> Void)? = nil) throws {
        _ = try SafeName.component(app, what: "app id")
        guard VersionCompare.isValid(version) else { throw khuFail("\(version) is not a dotted numeric version") }
        if let type { try FeedPublisher.validateAppType(type) }
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
            feed = try withPreviousInstallers(feed, in: feedDir)
            // Captured before this publish replaces `previous` with the displaced current version:
            // this *is* the generation that drops out of current+previous and becomes the prior.
            let retiringPriors = feed.previous
            let (sha, bytes) = try Signing.sha256Hex(fileAt: artifact)
            guard bytes > 0 else { throw khuFail("\(artifact.path) is empty") }
            // One published version is one artifact, forever. `--allow-same` exists to fix a row or
            // its words, not to swap the bytes a version already names: a Mac that fetched the old
            // bytes would never be offered the new ones under the same version.
            if let existing = feed.apps[app], VersionCompare.compare(version, existing.version) == 0,
               existing.sha256 != sha {
                throw khuFail("refused \(version): --allow-same re-publishes a version only with its own bytes — "
                              + "the feed has \(existing.sha256), this artifact is \(sha). Bump the version.")
            }
            let base = String(try SafeName.component(artifact.lastPathComponent, what: "artifact").prefix(100))
            // A file already named for its own bytes — the artifact as it sits in artifacts/ — keeps
            // its name. Prefixing it again produced f4f8af7b9770-f4f8af7b9770-… and retired the
            // correctly named file as replaced (row 20261122-336).
            let name = base.hasPrefix("\(sha.prefix(12))-") ? base
                : try SafeName.component("\(sha.prefix(12))-\(base)", what: "artifact")
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
            let old = feed.apps[app]
            entry.extras = old?.extras ?? [:]
            entry.name = displayName ?? old?.name; entry.bundleID = old?.bundleID; entry.bundleName = old?.bundleName
            entry.icon = old?.icon; entry.iconSha256 = old?.iconSha256
            if kindNow == "updater" {
                // The `updater` entry is the `khu` helper binary, never an app bundle: an app's
                // identity and icon here would make the Launcher app look like the helper (and the
                // helper look like the app it is showing).
                entry.name = "Studio Launcher KH Helper"
                entry.bundleID = nil; entry.bundleName = nil; entry.icon = nil; entry.iconSha256 = nil
            }
            // The card's words are carried over unless this publish names new ones.
            // A named word replaces only that field: `--tagline X` used to clear description,
            // features and accent wholesale, which is how rows lost their words silently.
            entry.tagline = words?.tagline ?? old?.tagline
            entry.description = words?.description ?? old?.description
            entry.features = words?.features ?? old?.features
            entry.accent = words?.accent ?? old?.accent
            entry.released = ISO.string(now)
            // Only a known prior label is carried: a version or metadata publish that omits --type
            // keeps it, while an unrecognised raw label from an older feed is never re-written.
            entry.type = Self.knownAppType(type) ?? Self.knownAppType(old?.type)
            entry.mainMacOnly = mainMacOnly ?? old?.mainMacOnly
            entry.holdURL = holdURL ?? old?.holdURL
            // A security update skips the Mac-side rollout stagger. Publishing without the flag
            // keeps the previous value, so a routine re-publish never silently arms or disarms it.
            entry.security = security || (old?.security ?? false) ? true : nil
            // Carried like holdURL; a new address starts at this version. An entry published before
            // holdSince existed stays unknown unless --hold-since names it.
            // Named, or carried from the same hold address. `written` below is what the row will
            // say; `known` is whether anyone actually stated since when — the pair rule judges
            // `known`, so a row backfilled only by this line's version is still refused.
            let writtenSince = holdSince ?? (old?.holdURL == entry.holdURL ? old?.holdSince : version)
            let knownSince = holdSince ?? (old?.holdURL == entry.holdURL ? old?.holdSince : nil)
            entry.holdSince = writtenSince
            // A DMG that installs an app carries that app's own name and identity whatever kind of
            // app it is — `status` included: the hand route still offers it, so it needs an identity.
            if ["app-dmg", "gateway", "status"].contains(kindNow), let read = meta {
                guard let info = try? read(dest.path) else {
                    throw khuFail("\(artifact.lastPathComponent) cannot be read as an app DMG, so its version is unknown; nothing was published")
                }
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
            if let old, VersionCompare.isNewer(version, than: old.version) {
                var previous = feed.previous ?? [:]
                // The displaced version's own patch is meaningless now: the bytes it was built
                // from are no longer kept, so only the current version carries one.
                var displaced = old
                displaced.delta = nil
                previous[app] = displaced
                feed.previous = previous
                // The patch from the displaced version's exact bytes to this one, when it saves
                // bytes: a Mac that already has the older artifact then fetches the patch alone.
                entry.delta = try delta(from: displaced, to: dest, artifactsDir: artifactsDir, feedDir: feedDir)
            }
            // A row that reaches the fleet must be complete: a row with no label is invisible to the
            // grouping a page or the Launcher draws, and a row with no words renders as a blank card.
            // This judges the row being written, after carry-forward, so a routine republish of a
            // complete row that names no flags still passes. The sentence names the field and the
            // flag that fills it; "incomplete row" would send someone to read source. The CLI asks
            // for this; fixtures that publish directly are not fleet publishes and are not gated.
            // The catalogue rows are the discriminator's own shape, not incomplete apps: an extension
            // carries no type and no tagline by design (`kind` is the discriminator, `summary` is its
            // description), and a plugin row has no download to describe. Gating them would refuse
            // the catalogue for being what it is meant to be (X001, 2026-11-22).
            let catalogue = ["extension", "plugin"].contains(kindNow)
            if requireComplete && !catalogue {
                // Registry first, so a first publish of a hold-serving app is refused for the
                // missing field instead of passing because there was nothing to inherit. The
                // Launcher and its helper are exempt by name, as they are in the agent's own hold
                // path (Agent.swift:1743): neither serves a hold.
                let holdExempt = ["updater", "launcher"].contains(app)
                let holdServing = !holdExempt && (Self.holdApps(in: feedDir).contains(app) || old?.holdURL != nil)
                let missing = Self.missingAppFields(entry, holdServing: holdServing, holdSinceKnown: (knownSince ?? "").isEmpty == false)
                guard missing.isEmpty else {
                    throw khuFail("refused: \(app) would be published incomplete — \(missing.joined(separator: "; ")). Nothing was published.")
                }
            }
            feed.apps[app] = entry
            // Strictly later than the last release, so an agent's high-water mark always moves forward.
            let previous = feed.publishedAt ?? .distantPast
            feed.published_at = ISO.string(max(now, previous.addingTimeInterval(0.001)))
            let signed = try feed.validated()
            // Rollback must always name the release that was live immediately before this one. Only
            // a mirror host used to write this file, so on a primary host it could name a release
            // whose artifacts were retired long ago. Rotated from the file on disk, before the new
            // release replaces it, and before the keep-set is read below.
            try rotateRollbackRelease(in: feedDir)
            // `release` + `previous` cover two of the kept versions; the retiring `previous`
            // generations beyond that stay pinned in priors.json, up to the owner's keep count.
            try rotatePriors(from: retiringPriors, in: feedDir, keeping: max(keep ?? KeepCount.keep(in: feedDir), KeepCount.defaultsTo))
            // Every pin this signed release carries, plus what the retention ledger still holds
            // as a recovery copy, read before the commit so an unreadable ledger refuses the
            // publish itself rather than quietly retiring the pins it names.
            var keep = Set<String>()
            for entry in Array(signed.apps.values) + Array((signed.previous ?? [:]).values) {
                keep.insert(entry.file)
                if let icon = entry.icon { keep.insert(icon) }
                if let delta = entry.delta { keep.insert(delta.file) }
            }
            keep.formUnion(try ledgerNames(in: feedDir))
            // A mirror host keeps the release before its last sync in previous-release.json for
            // rollback. Publishing used to retire exactly the artifacts that file names, leaving a
            // rollback that pointed at nothing; its pins are kept now.
            keep.formUnion(rollbackNames(in: feedDir))
            keep.formUnion(priorNames(in: feedDir))
            try saveFeed(signed, to: feedDir, key: key)
            // `## Feed`: the signed release is committed first; only now may installers it no
            // longer names leave the feed directory. A failure here cannot undo the release or
            // any pin — it is reported loudly, and the next publish retires whatever was left.
            let retireOne: (URL) throws -> Void = retireArtifact ?? { try retireToTrash($0, in: feedDir) }
            for file in try FileManager.default.contentsOfDirectory(atPath: artifactsDir.path) {
                guard !keep.contains(file) else { continue }
                do { try retireOne(artifactsDir.appendingPathComponent(file)) }
                catch {
                    throw khuFail("\(app) \(version) is published and its signed pins are live, but \(file) cannot be "
                                  + "moved to the Trash: \(error). Publishing any app again finishes this retirement.")
                }
            }
        }
    }

    /// A metadata-only update: rewrites one row's words or label under the publish lock, with no
    /// artifact and no version. The row keeps its version, file, sha256, bytes, icon, hold, delta and
    /// any unknown fields — only the named fields change. `published_at` moves strictly forward so an
    /// agent's rollback guard still accepts the feed. This is how a lost tagline or label is fixed
    /// without rebuilding a version that is already published.
    public static func setMetadata(feedDir: URL, keyFile: URL, app: String, words: AppWords?, type: String?,
                                   now: Date = Date()) throws {
        _ = try SafeName.component(app, what: "app id")
        if let type { try FeedPublisher.validateAppType(type) }
        let key = try Signing.loadPrivateKey(from: keyFile)
        try FileLock.withExclusive(feedDir.appendingPathComponent("publish.lock")) {
            guard var feed = try loadVerifiedFeed(from: feedDir, publicKey: key.publicKey) else {
                throw khuFail("refused: the feed at \(feedDir.path) has no verified release")
            }
            guard var entry = feed.apps[app] else {
                throw khuFail("refused: the feed has no \(app) row; publish an artifact first")
            }
            // A named word replaces only itself, exactly as a publish does.
            if let words {
                if let v = words.tagline { entry.tagline = v }
                if let v = words.description { entry.description = v }
                if let v = words.features { entry.features = v }
                if let v = words.accent { entry.accent = v }
            }
            if let type { entry.type = type }
            feed.apps[app] = entry
            let previous = feed.publishedAt ?? .distantPast
            feed.published_at = ISO.string(max(now, previous.addingTimeInterval(0.001)))
            try saveFeed(try feed.validated(), to: feedDir, key: key)
        }
    }

    /// The patch that turns the displaced version's exact bytes into this one, when it is smaller
    /// than the whole artifact: a Mac that already has the older artifact then fetches the patch
    /// alone. A patch that saves nothing is not published — that Mac downloads the whole signed
    /// artifact as before, and nothing promises it a saving.
    private static func delta(from old: FeedApp, to target: URL, artifactsDir: URL, feedDir: URL) throws -> ArtifactDelta? {
        let fm = FileManager.default
        let base = artifactsDir.appendingPathComponent(old.file)
        guard fm.fileExists(atPath: base.path) else { return nil }
        // The patch is only ever built for the exact bytes the signed feed names.
        let measured = try Signing.sha256Hex(fileAt: base)
        guard measured.hex == old.sha256, measured.bytes == old.bytes else { return nil }
        let staging = artifactsDir.appendingPathComponent(".delta-\(UUID().uuidString).khu-tmp")
        defer { _ = try? Trash.move(staging, into: Trash.root(in: feedDir)) }
        try ArtifactDeltaPatch.build(base: base, target: target, to: staging)
        let patch = try Signing.sha256Hex(fileAt: staging)
        let targetSize = try ArtifactDeltaPatch.size(of: target)
        guard patch.bytes > 0, patch.bytes < targetSize else { return nil }
        let name = "\(patch.hex.prefix(12))-delta"
        let destination = artifactsDir.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) {
            let existing = try Signing.sha256Hex(fileAt: destination)
            guard existing.hex == patch.hex else {
                throw khuFail("\(destination.path) exists with different bytes; move it to _trash and publish again")
            }
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        return ArtifactDelta(file: name, sha256: patch.hex, bytes: patch.bytes,
                             baseSHA256: old.sha256, baseBytes: old.bytes)
    }

    /// The names the retention ledger pins: recovery copies that can outlive a signed feed's own
    /// references, and whose bytes `withPreviousInstallers` verifies before adopting them.
    private static func ledgerNames(in dir: URL) throws -> Set<String> {
        let file = dir.appendingPathComponent("artifact-retention.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let saved = try JSON.decode(Retention.self, from: Data(contentsOf: file))
        var names = Set<String>()
        for entry in saved.apps.values {
            names.insert(entry.current.file)
            if let icon = entry.current.icon { names.insert(icon) }
            if let previous = entry.previous {
                names.insert(previous.file)
                if let icon = previous.icon { names.insert(icon) }
            }
        }
        return names
    }

    /// `previous-release.json` becomes a copy of the release that is live right now, so a rollback
    /// always lands on the release before this one. Nothing is rotated on a first publish.
    private static func rotateRollbackRelease(in dir: URL) throws {
        let live = dir.appendingPathComponent("release.json")
        let previous = dir.appendingPathComponent("previous-release.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: live.path) else { return }
        let temporary = dir.appendingPathComponent(".previous-release.json.khu-tmp-\(UUID().uuidString)")
        // A rotation that silently no-ops would leave the stale pointer exactly as it is, so a
        // failure here refuses the publish.
        try fm.copyItem(at: live, to: temporary)
        if fm.fileExists(atPath: previous.path) {
            _ = try fm.replaceItemAt(previous, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: previous)
        }
        _ = try? fm.removeItem(at: temporary)
    }

    /// Generations that have left `previous` but are still kept, newest first; a generation is its
    /// artifact and icon. Never a name `release`/`previous` already covers.
    private static func rotatePriors(from previous: [String: FeedApp]?, in dir: URL, keeping keep: Int) throws {
        var priors = priorMap(in: dir)
        let older = max(keep - 2, 0)
        if let previous {
            // Per app: other apps keep their own prior generations untouched by this publish.
            for (app, entry) in previous {
                let generation = [entry.file] + (entry.icon.map { [$0] } ?? [])
                priors[app] = Array(([generation] + (priors[app] ?? [])).prefix(older))
                if priors[app]?.isEmpty == true { priors.removeValue(forKey: app) }
            }
        }
        _ = try AtomicFile.writeJSON(priors, to: dir.appendingPathComponent("priors.json"))
    }

    private static func priorMap(in dir: URL) -> [String: [[String]]] {
        let url = dir.appendingPathComponent("priors.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let generations = try? JSON.decode([String: [[String]]].self, from: data) { return generations }
        // 0.1.60 and earlier wrote one flat generation per app.
        return (try? JSON.decode([String: [String]].self, from: data))?.mapValues { [$0] } ?? [:]
    }

    private static func priorNames(in dir: URL) -> Set<String> { Set(priorMap(in: dir).values.flatMap { $0.flatMap { $0 } }) }

    /// The artifacts a mirror's rollback release still names. A missing or unreadable file keeps
    /// nothing (and blocks nothing): the next mirror sync rewrites it.
    private static func rollbackNames(in dir: URL) -> Set<String> {
        let file = dir.appendingPathComponent("previous-release.json")
        guard let release = try? AtomicFile.readJSON(Release.self, from: file),
              let data = release.feedData,
              let feed = try? JSON.decode(Feed.self, from: data) else { return [] }
        // Only the rollback release's own pins: rolling back to it needs what it installs, not the
        // generation before that, which is what keeps exactly one recoverable step rather than two.
        var names = Set<String>()
        for entry in feed.apps.values {
            names.insert(entry.file)
            if let icon = entry.icon { names.insert(icon) }
            if let delta = entry.delta { names.insert(delta.file) }
        }
        return names
    }

    /// Where an artifact with no pin left goes: the native macOS Trash — except for a feed inside
    /// the system's temporary directory, which every test fixture uses, where the bytes stay
    /// restorable under the feed's own `_trash` so a test run never touches the operator's Trash.
    private static func retireToTrash(_ file: URL, in feedDir: URL) throws {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let base = temp.hasSuffix("/") ? temp : temp + "/"
        if feedDir.standardizedFileURL.path.hasPrefix(base) {
            _ = try Trash.move(file, into: Trash.root(in: feedDir))
        } else {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }
}

/// What a release says about itself, read from its app's CHANGELOG: one `## <version> — <date>`
/// entry and its "- " lines, or its "### " headings when it has no such lines. "### Technical
/// notes" and what follows it are for developers and left out. One rule for every app, so the
/// feed, the SSD and each app's own What's New say the same thing.
public enum ReleaseNotes {
    public struct Entry: Equatable, Sendable {
        public var version: String, date: String?, notes: String
    }

    /// `path` is the CHANGELOG itself, or a repository folder holding CHANGELOG.md. A heading that
    /// is not `## <version> — <date>` becomes an entry with an empty version.
    public static func entries(of path: URL) throws -> [Entry] {
        var isDir: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue
        let file = isFolder ? path.appendingPathComponent("CHANGELOG.md") : path
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw khuFail("cannot read \(file.path)") }
        var found: [Entry] = [], headings: [[String]] = [], technical = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let parts = line.dropFirst(3).components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
                let version = parts[0].hasPrefix("v") ? String(parts[0].dropFirst()) : parts[0]
                found.append(Entry(version: VersionCompare.isValid(version) ? version : "", date: parts.count > 1 ? parts[1] : nil, notes: ""))
                headings.append([]); technical = false
            } else if line.lowercased().hasPrefix("### technical") {
                technical = true
            } else if line.hasPrefix("### "), !technical, !found.isEmpty {
                headings[headings.count - 1].append("- " + line.dropFirst(4))
            } else if line.hasPrefix("- "), !technical, let last = found.indices.last {
                found[last].notes += (found[last].notes.isEmpty ? "" : "\n") + line
            }
        }
        for i in found.indices where found[i].notes.isEmpty { found[i].notes = headings[i].joined(separator: "\n") }
        return found
    }

    /// The notes to publish: the top entry's, once it is known to be this version, and one optional
    /// extra line.
    public static func forRelease(changelog: URL, version: String, extra: String?) throws -> String {
        guard let top = try entries(of: changelog).first else { throw khuFail("\(changelog.path) has no \"## <version> — <date>\" entry; nothing was published") }
        guard !top.version.isEmpty, top.date != nil else { throw khuFail("the top heading of \(changelog.path) is not \"## <version> — <date>\"; nothing was published") }
        guard top.version == version else {
            throw khuFail("the top entry of \(changelog.path) is \(top.version), not \(version); add the \(version) entry first. Nothing was published")
        }
        guard !top.notes.isEmpty else { throw khuFail("the \(version) entry of \(changelog.path) has no \"- \" lines; nothing was published") }
        let line = (extra ?? "").trimmingCharacters(in: .whitespaces)
        guard !line.contains("\n") else { throw khuFail("--note is one line; nothing was published") }
        return line.isEmpty ? top.notes : top.notes + "\n" + (line.hasPrefix("- ") ? line : "- " + line)
    }
}

