import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where the stub keeps its version tree. `versions/<version>/khu` are real files; `current` and
/// `previous` are symlinks the stub owns.
public struct StubLayout: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    public var versionsDirectory: URL { base.appendingPathComponent("versions", isDirectory: true) }
    public var currentLink: URL { base.appendingPathComponent("current") }
    public var previousLink: URL { base.appendingPathComponent("previous") }
    public var stateFile: URL { base.appendingPathComponent("stub-state.json") }
    public var heartbeatFile: URL { base.appendingPathComponent("heartbeat.json") }
    public var trash: URL { Trash.root(in: base) }
    public var logFile: URL { base.appendingPathComponent("stub.log") }
    /// Held by whoever moves `current`/`previous` (the stub's rollback, the agent's self-update).
    public var switchLock: URL { base.appendingPathComponent("switch.lock") }

    public func binary(for version: String) throws -> URL {
        let safe = try SafeName.component(version, what: "version")
        return versionsDirectory.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("khu")
    }

    /// The helper bundle that wraps this version's binary. It exists only to give the process a
    /// product name; the binary in `versions/<v>/khu` stays the one the tree switches between.
    public func helperBundle(for version: String) throws -> URL {
        let safe = try SafeName.component(version, what: "version")
        return versionsDirectory.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("Update Studio KH Helper.app", isDirectory: true)
    }

    /// What to launch for a version: its helper bundle's executable when that exists, else the
    /// plain binary. Never invents a path that is not executable.
    public func runnable(for binary: URL, fileManager: FileManager = .default) -> URL {
        let version = Self.version(of: binary)
        guard let bundle = try? helperBundle(for: version) else { return binary }
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(HelperBundle.helperExecutable)")
        return fileManager.isExecutableFile(atPath: executable.path) ? executable : binary
    }

    /// The executable `current` points at, or nil when the link is missing, dangling or not executable.
    public func currentBinary(fileManager: FileManager = .default) -> URL? {
        resolve(link: currentLink, fileManager: fileManager)
    }

    public func previousBinary(fileManager: FileManager = .default) -> URL? {
        resolve(link: previousLink, fileManager: fileManager)
    }

    /// The version directory a binary lives in (`versions/<v>/khu` → `<v>`), including when it runs
    /// from the helper bundle inside that folder.
    public static func version(of binary: URL) -> String {
        let parts = binary.pathComponents
        if let index = parts.lastIndex(of: "versions"), index + 1 < parts.count { return parts[index + 1] }
        return binary.deletingLastPathComponent().lastPathComponent
    }

    private func resolve(link: URL, fileManager: FileManager) -> URL? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let url = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                                        : URL(fileURLWithPath: target, relativeTo: base).standardizedFileURL
        // A link to nothing, or to something that cannot run, is no version at all.
        return fileManager.isExecutableFile(atPath: url.path) ? url.standardizedFileURL : nil
    }
}

/// Moves the version tree between `current` and `previous`. The stub and the agent's `updater`
/// recipe share this code so the two can never disagree about the layout.
///
/// Each link changes by one `rename(2)` of a fresh symlink over the old one, so a kill at any
/// instant leaves every link pointing at a whole version. `install` moves `previous` first and
/// `current` second: interrupted between the two, both name the old version, which still runs.
public struct StubSwitcher: @unchecked Sendable {
    public let layout: StubLayout
    public let fileManager: FileManager

    public init(layout: StubLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    /// Point `previous` at whatever `current` is today, then `current` at `versions/<version>/khu`.
    /// Returns false when `current` already runs that version: nothing moves, and `previous` keeps
    /// the real fallback instead of becoming a second copy of `current`.
    @discardableResult
    public func install(version: String, at date: Date = Date()) throws -> Bool {
        let binary = try layout.binary(for: version).standardizedFileURL
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw khuFail("no executable at \(binary.path)")
        }
        // Every version directory carries its full helper bundle, built from that version's
        // binary. A version whose bundle cannot run is never promoted.
        try ensureHelperBundle(for: version, binary: binary)
        let current = layout.currentBinary(fileManager: fileManager)
        if current?.path == binary.path { return false }
        if let current { try point(layout.previousLink, at: current, at: date) }
        try point(layout.currentLink, at: binary, at: date)
        recordTarget(binary, at: date)
        return true
    }

    /// Create (or repair) `versions/<version>/Update Studio KH Helper.app` around this version's
    /// binary. The executable inside is a hard link to the same file, so it cannot drift.
    private func ensureHelperBundle(for version: String, binary: URL) throws {
        let executable: URL
        do {
            executable = try HelperBundle.ensure(
                HelperBundle.Spec(name: "Update Studio KH Helper", bundleID: "com.khupdater.agent",
                                  executableName: HelperBundle.helperExecutable, version: version),
                source: binary, out: try layout.helperBundle(for: version), fileManager: fileManager)
        } catch {
            throw khuFail("cannot build the helper bundle for \(version): \(error); nothing was switched")
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw khuFail("the helper bundle for \(version) has no runnable executable; nothing was switched")
        }
    }

    /// `current` and the recorded `target` move together. The stub re-reads `current` at every
    /// start and rewrites this on the next one, so a failed write here is corrected by the stub.
    private func recordTarget(_ target: URL, at date: Date) {
        var state = StubState.load(from: layout.stateFile)
        state.switched_at = ISO.string(date)
        state.target = target.standardizedFileURL.path
        state.exits = []
        state.heartbeat_at = nil
        try? AtomicFile.writeJSON(state, to: layout.stateFile)
    }

    /// Put `current` back on `previous`. Returns the version restored, or nil when there is no
    /// usable fallback (missing, dangling, not executable, or the very binary `current` runs).
    @discardableResult
    public func switchBack(at date: Date = Date()) throws -> String? {
        guard let previous = usablePrevious() else { return nil }
        try point(layout.currentLink, at: previous, at: date)
        recordTarget(previous, at: date)
        return StubLayout.version(of: previous)
    }

    /// The fallback a rollback would use — checked before anything is stopped for it. It is judged
    /// on the binaries themselves, not on the link paths: an alias pointing at whatever `current`
    /// already runs is not a fallback, and rolling back to it would replace nothing.
    public func usablePrevious() -> URL? {
        guard let previous = layout.previousBinary(fileManager: fileManager) else { return nil }
        if let current = layout.currentBinary(fileManager: fileManager),
           RealPath.of(current.path) == RealPath.of(previous.path) { return nil }
        return previous
    }

    private func point(_ link: URL, at target: URL, at date: Date) throws {
        try fileManager.createDirectory(at: layout.base, withIntermediateDirectories: true)
        let fresh = layout.base.appendingPathComponent(".\(link.lastPathComponent).khu-tmp-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(atPath: fresh.path, withDestinationPath: target.path)
        // Never delete: a copy of the superseded link goes to _trash/ first, then the swap is atomic.
        if let old = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            let keep = Trash.bucket(in: layout.base, at: date).appendingPathComponent(link.lastPathComponent)
            try? fileManager.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.destinationOfSymbolicLink(atPath: keep.path)) == nil {
                try? fileManager.createSymbolicLink(atPath: keep.path, withDestinationPath: old)
            }
        }
        guard rename(fresh.path, link.path) == 0 else {
            let code = errno
            _ = try? Trash.move(fresh, into: layout.trash, at: date, fileManager: fileManager)
            throw khuFail("cannot switch \(link.lastPathComponent) (errno \(code))")
        }
        AtomicFile.syncDirectory(layout.base)
    }
}

/// What the agent writes every 30 s while it runs. `nonce` is the one the stub handed this child
/// in `KHU_HEARTBEAT_NONCE`, so a beat from an earlier child (or an earlier version) never vouches
/// for the one running now.
public struct Heartbeat: Codable, Sendable, Equatable {
    public var at: String
    public var version: String?
    public var pid: Int32?
    public var nonce: String?

    public init(at: String, version: String? = nil, pid: Int32? = nil, nonce: String? = nil) {
        self.at = at
        self.version = version
        self.pid = pid
        self.nonce = nonce
    }

    public var date: Date? { ISO.date(at) }
}

public let heartbeatNonceVariable = "KHU_HEARTBEAT_NONCE"

public func writeHeartbeat(to url: URL, at date: Date, version: String?, pid: Int32?,
                           nonce: String? = ProcessInfo.processInfo.environment[heartbeatNonceVariable]) throws {
    try AtomicFile.writeJSON(Heartbeat(at: ISO.string(date), version: version, pid: pid, nonce: nonce), to: url)
}

public func readHeartbeat(from url: URL, fileManager: FileManager = .default) -> Heartbeat? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Heartbeat.self, from: data)
}
