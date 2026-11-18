import Foundation

/// The updater's own space: the only files it removes instead of retiring them.
///
/// `state/_trash` belongs to the updater, not to the owner. Every entry in it is a copy of an app
/// that is already installed or was never installed, so only the newest few are worth keeping. A
/// bundle copied with `ditto` carries its own immutable flag, and `rm` answers "Permission denied"
/// on it — which is why this folder grew to 130 GB on the publisher instead of ever being emptied.
/// Clearing the flag first makes the copy removable.
public enum Space {
    /// Superseded copies kept in the state trash, newest first: only the one the last settled
    /// install made, so a rollback or a retry still has the copy it just retired.
    public static let defaultBucketsKept = 1
    /// Room an update leaves free beyond its own artifact, for staging and promotion, in decimal GB
    /// (the unit the refusal shows).
    public static let defaultReserveGB = 2
    public static var defaultReserveBytes: UInt64 { UInt64(defaultReserveGB) * 1_000_000_000 }

    /// What one cleanup did. `left` counts entries that are still there because even a cleared copy
    /// would not go: that is said in the run note, never swallowed.
    public struct Swept: Sendable, Equatable {
        public var removed = 0
        public var bytes: UInt64 = 0
        public var left = 0
        public init() {}
        public var isEmpty: Bool { removed == 0 && left == 0 }

        /// The line a run (or a result) shows for this cleanup.
        public var words: String {
            let cleared = "cleared \(removed) retired \(removed == 1 ? "copy" : "copies") (\(Space.gigabytes(bytes)))"
            return left == 0 ? cleared : cleared + "; \(left) could not be removed and stay in the trash"
        }
    }

    /// An update this disk cannot hold. `description` is the result row: the free-space number is
    /// the point, not an afterthought.
    public struct NoSpace: Error, CustomStringConvertible, Sendable {
        public let app: String, version: String
        public let artifact: UInt64, reserve: UInt64, free: UInt64
        public var description: String {
            "not downloading \(app) \(version): this disk has \(Space.gigabytes(free)) free and the update needs "
            + "\(Space.gigabytes(artifact + reserve)) (\(Space.gigabytes(artifact)) for the installer plus "
            + "\(Space.gigabytes(reserve)) kept free). Free up space, then it tries again."
        }
    }

    public static func gigabytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
    }

    /// Free space on the volume holding `url`, counting space macOS would purge. The path may not
    /// exist yet (`downloads/<app>`), so the nearest folder above it is what is measured.
    public static func freeBytes(at url: URL) -> UInt64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        if let space = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage {
            return UInt64(max(space, 0))
        }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map { UInt64(max($0, 0)) }
    }

    /// Bytes a file or bundle occupies on disk.
    public static func size(of url: URL, fileManager fm: FileManager = .default) -> UInt64 {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return UInt64(clamping: ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: keys)
            total += UInt64(max(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0, 0))
        }
        return total
    }

    /// Remove one file or bundle, clearing the flags that stop a removal first: the immutable flag
    /// AND read-only mode bits. Returns the bytes freed, and 0 when it is still there.
    ///
    /// The mode bits matter: Hub ships `Contents/Resources/runtimes/music-yue2` as 0544/0555 (1071
    /// read-only folders, 7867 read-only files), and `unlink` inside a 0555 folder fails for the
    /// owner too. `chflags nouchg` alone left that tree in place while reporting success, so the
    /// next `ditto` into it failed with "Permission denied" and the install looped for ever
    /// (2026-11-17, the owner's 1409 Mac).
    @discardableResult
    public static func remove(_ url: URL, shell: Shell = SystemShell(), fileManager fm: FileManager = .default) -> UInt64 {
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let bytes = size(of: url, fileManager: fm)
        _ = try? shell.run("/usr/bin/chflags", arguments: ["-R", "nouchg", url.path], timeout: 120)
        // `/bin/chmod`: this macOS has no /usr/bin/chmod, and a wrong path would silently no-op.
        _ = try? shell.run("/bin/chmod", arguments: ["-R", "u+w", url.path], timeout: 300)
        do { try fm.removeItem(at: url) }
        catch { _ = try? shell.run("/bin/rm", arguments: ["-rf", url.path], timeout: 900) }
        guard fm.fileExists(atPath: url.path) else { return bytes }
        // The fallback can still meet a tree whose owner bits would not change: it must not report
        // success, and the caller decides — most callers keep going, `Recipe.stage` refuses.
        _ = try? shell.run("/bin/chmod", arguments: ["-R", "u+w", url.path], timeout: 300)
        _ = try? shell.run("/bin/rm", arguments: ["-rf", url.path], timeout: 900)
        return fm.fileExists(atPath: url.path) ? 0 : bytes
    }

    /// Keep the newest `keeping` entries of the updater's own state trash and remove the rest. Bucket
    /// names are ISO timestamps, so newest-first is their name order.
    @discardableResult
    public static func pruneTrash(in stateDir: URL, keeping: Int = defaultBucketsKept,
                                  shell: Shell = SystemShell(), fileManager fm: FileManager = .default) -> Swept {
        let root = Trash.root(in: stateDir)
        let entries = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var swept = Swept()
        for url in entries.dropFirst(max(keeping, 0)) {
            let bytes = size(of: url, fileManager: fm)
            _ = remove(url, shell: shell, fileManager: fm)
            if fm.fileExists(atPath: url.path) { swept.left += 1 } else { swept.removed += 1; swept.bytes += bytes }
        }
        return swept
    }

    /// Remove everything in `folder` except `keeping`. A superseded download is signed bytes this Mac
    /// can fetch once more, so it is removed rather than retired into a trash that then fills.
    @discardableResult
    public static func sweep(_ folder: URL, keeping: Set<String>, shell: Shell = SystemShell(),
                             fileManager fm: FileManager = .default) -> Swept {
        var swept = Swept()
        for url in ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        where !keeping.contains(url.lastPathComponent) {
            guard fm.fileExists(atPath: url.path) else { continue }
            let bytes = size(of: url, fileManager: fm)
            _ = remove(url, shell: shell, fileManager: fm)
            if fm.fileExists(atPath: url.path) { swept.left += 1 } else { swept.removed += 1; swept.bytes += bytes }
        }
        return swept
    }
}
