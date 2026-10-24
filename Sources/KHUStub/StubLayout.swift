import Foundation

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

    public func binary(for version: String) throws -> URL {
        let safe = try SafeName.component(version, what: "version")
        return versionsDirectory.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("khu")
    }

    /// The executable `current` points at, or nil when the link is missing or dangling.
    public func currentBinary(fileManager: FileManager = .default) -> URL? {
        resolve(link: currentLink, fileManager: fileManager)
    }

    public func previousBinary(fileManager: FileManager = .default) -> URL? {
        resolve(link: previousLink, fileManager: fileManager)
    }

    private func resolve(link: URL, fileManager: FileManager) -> URL? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        return URL(fileURLWithPath: target, relativeTo: base).standardizedFileURL
    }
}

/// Moves the version tree between `current` and `previous`. The stub and the agent's `updater`
/// recipe share this code so the two can never disagree about the layout.
public struct StubSwitcher: @unchecked Sendable {
    public let layout: StubLayout
    public let fileManager: FileManager

    public init(layout: StubLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    /// Point `previous` at whatever `current` is today, then `current` at `versions/<version>/khu`.
    public func install(version: String, at date: Date = Date()) throws {
        let binary = try layout.binary(for: version)
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw khuFail("no executable at \(binary.path)")
        }
        if let current = layout.currentBinary(fileManager: fileManager) {
            try point(layout.previousLink, at: current, at: date)
        }
        try point(layout.currentLink, at: binary, at: date)
    }

    /// Put `current` back on `previous`. Returns the version directory name restored, or nil when
    /// there is nothing to fall back to.
    @discardableResult
    public func switchBack(at date: Date = Date()) throws -> String? {
        guard let previous = layout.previousBinary(fileManager: fileManager) else { return nil }
        try point(layout.currentLink, at: previous, at: date)
        return previous.deletingLastPathComponent().lastPathComponent
    }

    private func point(_ link: URL, at target: URL, at date: Date) throws {
        try fileManager.createDirectory(at: layout.base, withIntermediateDirectories: true)
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            // Never delete: the superseded link goes to _trash/ with the rest.
            try Trash.move(link, into: layout.trash, at: date, fileManager: fileManager)
        }
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }
}

public struct Heartbeat: Codable, Sendable, Equatable {
    public var at: String
    public var version: String?
    public var pid: Int32?

    public init(at: String, version: String? = nil, pid: Int32? = nil) {
        self.at = at
        self.version = version
        self.pid = pid
    }

    public var date: Date? { ISO.date(at) }
}

public func writeHeartbeat(to url: URL, at date: Date, version: String?, pid: Int32?) throws {
    try AtomicFile.writeJSON(Heartbeat(at: ISO.string(date), version: version, pid: pid), to: url)
}

public func readHeartbeat(from url: URL, fileManager: FileManager = .default) -> Heartbeat? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Heartbeat.self, from: data)
}
