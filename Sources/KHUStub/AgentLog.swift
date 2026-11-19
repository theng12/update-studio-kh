import Foundation

/// The Launcher's own rotating log: this run plus the previous two, in the app's data folder.
/// Nothing is deleted — a fourth-oldest run moves to the folder's recoverable `_trash`.
public struct AgentLog {
    /// `quiet` writes only essential lines, `normal` the usual ones, `verbose` everything.
    public enum Verbosity: String, Sendable {
        case quiet, normal, verbose

        var rank: Int {
            switch self {
            case .quiet: return 0
            case .normal: return 1
            case .verbose: return 2
            }
        }
    }

    /// The `<home>/Library/KHUpdater/state` folder the helper keeps its own settings in.
    public static func dataFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/KHUpdater/state")
    }

    /// The file this sink writes: show `path` in the app so nobody has to guess where it went.
    public let url: URL
    public var path: String { url.path }
    public let verbosity: Verbosity

    public init(name: String, in directory: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let folder = directory ?? Self.dataFolder()
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = Self.file(name, generation: 0, in: folder)
        self.verbosity = Self.resolvedVerbosity(environment: environment,
                                                settings: folder.appendingPathComponent("helper.json"))
        Self.rotate(name, in: folder)
    }

    public func record(_ message: String, at level: Verbosity = .normal) {
        guard level.rank <= verbosity.rank else { return }
        let line = "\(ISO.string(Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    private static func file(_ name: String, generation: Int, in folder: URL) -> URL {
        folder.appendingPathComponent(generation == 0 ? "\(name).log" : "\(name).\(generation).log")
    }

    /// The environment wins over helper.json; an absent or unknown value means normal.
    private static func resolvedVerbosity(environment: [String: String], settings: URL) -> Verbosity {
        if let fromEnvironment = environment["KHU_LOG_VERBOSITY"]
            .flatMap({ Verbosity(rawValue: $0.lowercased()) }) { return fromEnvironment }
        guard let data = try? Data(contentsOf: settings),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let saved = json["logVerbosity"] as? String,
              let mode = Verbosity(rawValue: saved.lowercased()) else { return .normal }
        return mode
    }

    private static func rotate(_ name: String, in folder: URL) {
        let fm = FileManager.default
        let current = file(name, generation: 0, in: folder)
        // The agent and a --once request can start together: shift one generation at a time.
        try? FileLock.withExclusive(folder.appendingPathComponent("\(name).log.lock")) {
            for generation in stride(from: 2, through: 1, by: -1) {
                let from = file(name, generation: generation - 1, in: folder)
                let to = file(name, generation: generation, in: folder)
                guard fm.fileExists(atPath: from.path) else { continue }
                if fm.fileExists(atPath: to.path) { _ = try? Trash.move(to, into: Trash.root(in: folder)) }
                try? fm.moveItem(at: from, to: to)
            }
            if !fm.fileExists(atPath: current.path) { fm.createFile(atPath: current.path, contents: Data()) }
        }
    }
}
