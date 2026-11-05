import Foundation

public enum FeedMirror {
    private struct Item: Equatable {
        let sha: String
        let bytes: Int64?
        var limit: Int64 { bytes ?? 1_048_576 }
    }

    public static func sync(releaseData: Data, sourceBase: URL, root: URL, publicKey: String,
                            http: HTTPClient, now: Date = Date()) throws -> Feed {
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
                if incoming.publishedAt == baseline.publishedAt, let baselineData = oldData ?? priorData,
                   try JSON.decode(Release.self, from: baselineData).feedData != JSON.decode(Release.self, from: releaseData).feedData {
                    throw khuFail("mirror refused a different feed with the same published_at")
                }
            }
            let wanted = try items(in: incoming)
            let oldItems = try (old ?? prior).map(items(in:)) ?? [:]
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
                    if try matches(destination, item: item) { continue }
                    let partial = stage.appendingPathComponent(name)
                    let code = try http.download(sourceBase.appendingPathComponent("artifacts").appendingPathComponent(name),
                                                 headers: [:], to: partial, limit: item.limit)
                    guard code == 200 else { throw khuFail("mirror artifact download answered \(code)") }
                    try noSymlink(partial)
                    guard try matches(partial, item: item) else { throw khuFail("mirror artifact hash or size mismatch: \(name)") }
                }
                for file in try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
                    let destination = artifacts.appendingPathComponent(file.lastPathComponent)
                    try noSymlink(destination)
                    if fm.fileExists(atPath: destination.path) { try Trash.move(destination, into: trash) }
                    try fm.moveItem(at: file, to: destination)
                }
                let changed = old != incoming
                let keptPrevious = changed ? (old ?? prior) : prior
                let protected = Set(wanted.keys).union(try keptPrevious.map { Set(try items(in: $0).keys) } ?? [])
                let stored = try fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)
                for file in stored { try noSymlink(file) }
                for file in stored where !protected.contains(file.lastPathComponent) {
                    try Trash.move(file, into: trash)
                }
                try Trash.move(stage, into: trash)
                if changed, let oldData { try AtomicFile.write(oldData, to: previous) }
                // Publish last: a cleanup failure must leave the working release in place.
                try AtomicFile.write(releaseData, to: release)
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

    private static func items(in feed: Feed) throws -> [String: Item] {
        var result: [String: Item] = [:]
        func add(_ name: String, sha: String, bytes: Int64?) throws {
            _ = try SafeName.component(name, what: "mirror artifact")
            let item = Item(sha: sha, bytes: bytes)
            if let existing = result[name], existing != item { throw khuFail("conflicting signed mirror artifact: \(name)") }
            result[name] = item
        }
        for entry in feed.apps.values {
            try add(entry.file, sha: entry.sha256, bytes: entry.bytes)
            if let icon = entry.icon, let sha = entry.iconSha256 {
                try add(icon, sha: sha, bytes: nil)
            } else if entry.icon != nil || entry.iconSha256 != nil {
                throw khuFail("mirror icon needs its signed hash and filename")
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
