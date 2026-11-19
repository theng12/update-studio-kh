import Foundation

public enum FeedMirror {
    /// A release page holds its own names for the same bytes, so this feed is the publisher's live
    /// feed restated for that page: every file it names is looked up in `names` (tab-separated app
    /// id, tag, feed file, stored asset name, sha256) and replaced by the stored name, and the entry
    /// carries that file's full address under `base`. Size and checksum are not touched, so the
    /// release is the same one; `network` (the publisher's own hosts) and each patch (which the page
    /// does not hold) are left out. Signed with the publisher's key. Returns the addresses written.
    /// `currentOnly` writes a feed with no `previous` at all: a page anyone can download from needs
    /// no downgrade path, and the builds before a release are exactly the ones a safety fix retired.
    /// `previousOmitted` is told each app whose previous entry was left out, so the caller can say so.
    public static func export(feedDir: URL, keyFile: URL, out: URL, base: String, names: URL,
                              apps: [String], currentOnly: Bool = false,
                              previousOmitted: ((String) -> Void)? = nil) throws -> [(app: String, version: String, url: String, bytes: Int64)] {
        let key = try Signing.loadPrivateKey(from: keyFile)
        guard var feed = try FeedPublisher.loadVerifiedFeed(from: feedDir, publicKey: key.publicKey) else {
            throw khuFail("nothing is published in \(feedDir.path)")
        }
        var root = base.trimmingCharacters(in: .whitespaces)
        while root.hasSuffix("/") { root.removeLast() }
        _ = try Feed.artifactURL(root + "/release.json", app: "the release page")
        guard !apps.isEmpty else { throw khuFail("name at least one app to mirror") }

        struct Row: Equatable { var tag: String; var name: String; var sha: String }
        var rows: [String: Row] = [:]
        let text = try String(contentsOf: names, encoding: .utf8)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let fields = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 5 else {
                throw khuFail("\(names.lastPathComponent) line \(index + 1) is not five tab-separated fields (app id, tag, feed file, stored asset name, sha256)")
            }
            let sha = fields[4].lowercased()
            // A first line of headings ("app  tag  feed file  stored asset  sha256") is skipped.
            if rows.isEmpty, !(sha.count == 64 && sha.unicodeScalars.allSatisfy({ hex.contains($0) })) { continue }
            guard sha.count == 64, sha.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
                throw khuFail("\(names.lastPathComponent) line \(index + 1) has no 64-character sha256")
            }
            _ = try SafeName.component(fields[1], what: "release tag")
            _ = try SafeName.component(fields[0], what: "app id")
            _ = try SafeName.component(fields[3], what: "stored asset name")
            let row = Row(tag: fields[1], name: fields[3], sha: sha)
            let key = fields[0] + "\u{0}" + fields[2]
            if let existing = rows[key], existing != row {
                throw khuFail("\(names.lastPathComponent) names \(fields[0]) \(fields[2]) twice with different assets")
            }
            rows[key] = row
        }

        func mirrored(_ app: String, _ entry: inout FeedApp) throws -> String {
            guard let row = rows[app + "\u{0}" + entry.file] else {
                throw khuFail("\(names.lastPathComponent) has no row for \(app)'s \(entry.file); nothing was written")
            }
            guard row.sha == entry.sha256.lowercased() else {
                throw khuFail("the release page's \(entry.file) is not the signed installer (sha256 \(row.sha), the feed says \(entry.sha256)); nothing was written")
            }
            if let icon = entry.icon {
                guard let iconRow = rows[app + "\u{0}" + icon] else {
                    throw khuFail("\(names.lastPathComponent) has no row for \(app)'s icon \(icon); nothing was written")
                }
                guard iconRow.sha == (entry.iconSha256 ?? "").lowercased() else {
                    throw khuFail("the release page's \(icon) is not the signed icon; nothing was written")
                }
                entry.icon = iconRow.name
            }
            entry.file = row.name
            entry.delta = nil
            entry.url = root + "/" + encoded(row.tag) + "/" + encoded(row.name)
            guard let url = entry.url else { throw khuFail("\(app)'s address could not be formed; nothing was written") }
            return url
        }

        var current: [String: FeedApp] = [:]
        var chosen: [String: String] = [:]
        for app in apps {
            guard var entry = feed.apps[app] else { throw khuFail("the feed has no \(app)") }
            chosen[app] = try mirrored(app, &entry)
            current[app] = entry
        }
        var previous: [String: FeedApp] = [:]
        for app in apps {
            guard var entry = feed.previous?[app] else { continue }
            if currentOnly { previousOmitted?(app); continue }
            _ = try mirrored(app, &entry)
            previous[app] = entry
        }
        feed.apps = current
        feed.previous = previous.isEmpty ? nil : previous
        feed.network = nil
        let signed = try feed.validated()
        let data = JSON.encode(signed)
        try AtomicFile.writeJSON(Release(feed: data, signature: try Signing.sign(data, with: key)), to: out)
        // Read back what was written: the same release, signed with the publisher's key, now naming
        // the release page's addresses.
        guard let written = try AtomicFile.readJSON(Release.self, from: out), let body = written.feedData,
              let signature = written.signatureData,
              Signing.verify(body, signature: signature, publicKey: key.publicKey) else {
            throw khuFail("the signed feed written to \(out.path) does not verify; nothing was handed out")
        }
        let back = try JSON.decode(Feed.self, from: body).validated()
        guard back.network == nil, back.artifactIdentity == signed.artifactIdentity else {
            throw khuFail("the signed feed written to \(out.path) does not read back as this release")
        }
        return apps.sorted().compactMap { app in
            back.apps[app].flatMap { entry in chosen[app].map { (app, entry.version, $0, entry.bytes) } }
        }
    }

    /// A release page's own asset name, as one URL path piece.
    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
    }

    private struct Item: Equatable {
        let sha: String
        let bytes: Int64?
        var limit: Int64 { bytes ?? 1_048_576 }
    }

    /// `only` names the apps this Mac actually has: a mirror then keeps those apps' installers and
    /// no others, which is what turns 4.2 GB of twelve apps into Hub's pair on a worker Mac. The
    /// feed it serves is still the whole signed release (byte-identical); a client that asks for an
    /// app the mirror does not keep answers 404 and falls back to the publisher, as it always could.
    public static func sync(releaseData: Data, sourceBase: URL, root: URL, publicKey: String,
                            http: HTTPClient, now: Date = Date(), only: Set<String>? = nil,
                            retireArtifact: (URL) throws -> Void = {
                                try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                            }) throws -> Feed {
        let incoming = try verified(releaseData, publicKey: publicKey, now: now)
        try noSymlink(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent("mirror.lock")
        try noSymlink(lock)
        return try FileLock.withExclusive(lock) {
            let fm = FileManager.default
            let release = root.appendingPathComponent("release.json")
            let previous = root.appendingPathComponent("previous-release.json")
            let artifacts = root.appendingPathComponent("artifacts")
            let trash = Trash.root(in: root)
            for path in [release, previous, artifacts, trash] { try noSymlink(path) }
            let oldData = fm.fileExists(atPath: release.path) ? try Data(contentsOf: release) : nil
            let old = try oldData.map { try verified($0, publicKey: publicKey, now: now) }
            let priorData = fm.fileExists(atPath: previous.path) ? try Data(contentsOf: previous) : nil
            let prior = try priorData.map { try verified($0, publicKey: publicKey, now: now) }
            if let baseline = old ?? prior {
                guard incoming.publishedAt! >= baseline.publishedAt! else { throw khuFail("mirror feed rollback refused") }
                // Same artifacts packaged differently (a re-signed mirror copy) is the same release.
                if incoming.publishedAt == baseline.publishedAt, baseline.artifactIdentity != incoming.artifactIdentity {
                    throw khuFail("mirror refused a different feed with the same published_at")
                }
            }
            let wanted = try items(in: incoming, only: only)
            let entries = try (Array(incoming.apps) + Array(incoming.previous ?? [:]))
                .filter { only?.contains($0.key) ?? true }.map(\.value)
            let required = Set(entries.flatMap { [$0.file] + ($0.icon.map { [$0] } ?? []) })
            let optional = Set(entries.compactMap { $0.delta?.file }).subtracting(required)
            let oldItems = try (old ?? prior).map { try items(in: $0) } ?? [:]
            // Published names are content-addressed; never change bytes an existing release names.
            for (name, item) in wanted {
                if let existing = oldItems[name], existing != item {
                    throw khuFail("mirror artifact name reused with different signed bytes: \(name)")
                }
            }
            try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
            let stage = root.appendingPathComponent("mirror-stage-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            do {
                for (name, item) in wanted.sorted(by: { $0.key < $1.key }) {
                    let destination = artifacts.appendingPathComponent(name)
                    try noSymlink(destination)
                    let partial = stage.appendingPathComponent(name)
                    do {
                        if try matches(destination, item: item) { continue }
                        let code = try http.download(sourceBase.appendingPathComponent("artifacts").appendingPathComponent(name),
                                                     headers: [:], to: partial, limit: item.limit)
                        guard code == 200 || code == 206 else { throw khuFail("mirror artifact download answered \(code)") }
                        try noSymlink(partial)
                        guard try matches(partial, item: item) else { throw khuFail("mirror artifact hash or size mismatch: \(name)") }
                    } catch {
                        guard optional.contains(name), !DownloadControl.cancelled else { throw error }
                        // Clients can fetch the full signed installer if this optional patch is unavailable.
                        try Trash.move(partial, into: trash)
                    }
                }
                for file in try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
                    let destination = artifacts.appendingPathComponent(file.lastPathComponent)
                    try noSymlink(destination)
                    if fm.fileExists(atPath: destination.path) { try retireArtifact(destination) }
                    try fm.moveItem(at: file, to: destination)
                }
                let changed = old != incoming
                let keptPrevious = changed ? (old ?? prior) : prior
                let protected = incoming.previous != nil ? Set(wanted.keys)
                    : Set(wanted.keys).union(try keptPrevious.map { Set(try items(in: $0, only: only).keys) } ?? [])
                let stored = try fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)
                for file in stored { try noSymlink(file) }
                let retired = stored.filter { !protected.contains($0.lastPathComponent) }
                if incoming.previous == nil {
                    for file in retired { try retireArtifact(file) }
                }
                try Trash.move(stage, into: trash)
                if incoming.previous != nil {
                    // Recovery must name the same two versions that will remain after retirement.
                    try AtomicFile.write(releaseData, to: previous)
                } else if changed, let oldData {
                    try AtomicFile.write(oldData, to: previous)
                }
                try AtomicFile.write(releaseData, to: release)
                if incoming.previous != nil {
                    // A Trash failure can leave extra bytes, never break the live signed pins.
                    for file in retired { try retireArtifact(file) }
                }
                return incoming
            } catch {
                _ = try? Trash.move(stage, into: trash)
                throw error
            }
        }
    }

    private static func verified(_ data: Data, publicKey: String, now: Date) throws -> Feed {
        let release = try JSON.decode(Release.self, from: data)
        let key = try Signing.loadPublicKey(base64: publicKey)
        guard let body = release.feedData, let signature = release.signatureData,
              Signing.verify(body, signature: signature, publicKey: key) else { throw khuFail("invalid mirror feed signature") }
        let feed = try JSON.decode(Feed.self, from: body).validated()
        guard feed.publishedAt! <= now.addingTimeInterval(Agent.futureSlack) else { throw khuFail("mirror feed is dated in the future") }
        return feed
    }

    private static func items(in feed: Feed, only: Set<String>? = nil) throws -> [String: Item] {
        var result: [String: Item] = [:]
        func add(_ name: String, sha: String, bytes: Int64?) throws {
            _ = try SafeName.component(name, what: "mirror artifact")
            let item = Item(sha: sha, bytes: bytes)
            if let existing = result[name], existing != item { throw khuFail("conflicting signed mirror artifact: \(name)") }
            result[name] = item
        }
        for entry in (Array(feed.apps) + Array(feed.previous ?? [:]))
            .filter({ only?.contains($0.key) ?? true }).map(\.value) {
            try add(entry.file, sha: entry.sha256, bytes: entry.bytes)
            if let icon = entry.icon, let sha = entry.iconSha256 {
                try add(icon, sha: sha, bytes: nil)
            } else if entry.icon != nil || entry.iconSha256 != nil {
                throw khuFail("mirror icon needs its signed hash and filename")
            }
            // The patch is an auxiliary artifact of the entry it belongs to: a Mac at the mirror
            // fetches it instead of the whole installer, so the mirror has to serve it too.
            if let delta = entry.delta {
                try add(delta.file, sha: delta.sha256, bytes: delta.bytes)
            }
        }
        return result
    }

    private static func matches(_ file: URL, item: Item) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let measured = try Signing.sha256Hex(fileAt: file)
        return measured.hex == item.sha && measured.bytes <= item.limit && (item.bytes == nil || measured.bytes == item.bytes)
    }

    private static func noSymlink(_ path: URL) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil else {
            throw khuFail("mirror refuses symbolic link: \(path.path)")
        }
    }
}
