import Foundation
import CryptoKit
import Security

public struct AppConfig: Codable, Sendable, Equatable {
    public var bundlePath: String
    public var recipe: String
    public var automatic: Bool
    /// The CFBundleIdentifier this app must have. When set, a DMG holding any other app is refused
    /// even with the right version; when unset, the installed app's own identifier is the rule.
    public var bundleID: String?
    public init(bundlePath: String, recipe: String = "app-dmg", automatic: Bool = false, bundleID: String? = nil) {
        self.bundlePath = bundlePath; self.recipe = recipe; self.automatic = automatic; self.bundleID = bundleID
    }

    private enum CodingKeys: String, CodingKey { case bundlePath, recipe, automatic, bundleID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundlePath = try c.decode(String.self, forKey: .bundlePath)
        recipe = try c.decodeIfPresent(String.self, forKey: .recipe) ?? "app-dmg"
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
    }
}

public struct AgentConfig: Codable, Sendable, Equatable {
    public var feedURL: String
    public var publicKey: String
    public var stateDir: String
    public var machine: String
    public var token: String
    public var apps: [String: AppConfig]
    public var intervalMinutes: Int
    public var once: Bool
    /// The stub's base folder (versions/, current, previous) for self-update; nil = not managed by a stub.
    public var stubBase: String?
    /// Fallback only: when this agent runs from `<stubBase>/versions/<v>/khu`, `<v>` is its version.
    public var updaterVersion: String?
    public init(feedURL: String, publicKey: String, stateDir: String, machine: String, token: String,
                apps: [String: AppConfig] = [:], intervalMinutes: Int = 5, once: Bool = false) {
        self.feedURL = feedURL; self.publicKey = publicKey; self.stateDir = stateDir
        self.machine = machine; self.token = token; self.apps = apps
        self.intervalMinutes = intervalMinutes; self.once = once
    }

    private enum CodingKeys: String, CodingKey {
        case feedURL, publicKey, stateDir, machine, token, apps, intervalMinutes, once, stubBase, updaterVersion
    }
    /// Optional fields really are optional: a hand-written config may leave them out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feedURL = try c.decode(String.self, forKey: .feedURL)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        stateDir = try c.decode(String.self, forKey: .stateDir)
        machine = try c.decode(String.self, forKey: .machine)
        token = try c.decode(String.self, forKey: .token)
        apps = try c.decodeIfPresent([String: AppConfig].self, forKey: .apps) ?? [:]
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
        once = try c.decodeIfPresent(Bool.self, forKey: .once) ?? false
        stubBase = try c.decodeIfPresent(String.self, forKey: .stubBase)
        updaterVersion = try c.decodeIfPresent(String.self, forKey: .updaterVersion)
    }
}

public struct MachineState: Codable, Sendable, Equatable {
    public var machine: String
    public var tokenHash: String?
    public var installed: [String: String]
    public var health: [String: String]
    public var lastSeen: String?
    /// Kept until the Mac reports a result for each one (by id): a dropped reply or a crash
    /// mid-install never loses an order.
    public var pending: [ServerCommand]
    public var lastResult: CommandResult?
    /// The newest result per app (absent in state written before it existed).
    public var lastResults: [String: CommandResult]?
    /// The owner's per-app override from the status page; absent = the Mac's own config decides.
    public var automatic: [String: Bool]
    /// What the Mac's own config says when there is no override (reported by the agent).
    public var automaticDefault: [String: Bool]?
    /// The capabilities the agent advertised on its most recent /commands fetch. Used by the
    /// status page to warn when a pending rollback order cannot be delivered to an older agent.
    public var capabilities: [String]?
    public init(machine: String) {
        self.machine = machine; self.installed = [:]; self.health = [:]
        self.pending = []; self.automatic = [:]
    }

    /// The setting the agent will actually follow.
    public func effectiveAutomatic(_ app: String) -> Bool { automatic[app] ?? automaticDefault?[app] ?? false }
}

public struct ServerCommand: Codable, Sendable, Equatable {
    /// What this order asks for. Absent means `update`: an order signed before the field existed
    /// must keep meaning what it meant when the owner gave it, and an agent that does not know an
    /// action refuses it rather than guessing.
    public static let update = "update"
    public static let rollback = "rollback"

    public var id: String
    public var machine: String
    public var app: String
    public var createdAt: String
    public var action: String
    public init(id: String = UUID().uuidString, machine: String, app: String, createdAt: String = ISO.string(Date()),
                action: String = ServerCommand.update) {
        self.id = id; self.machine = machine; self.app = app; self.createdAt = createdAt; self.action = action
    }

    private enum CodingKeys: String, CodingKey { case id, machine, app, createdAt, action }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decode(String.self, forKey: .machine)
        app = try c.decode(String.self, forKey: .app)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ServerCommand.update
    }
}

/// What an agent tells the publisher it can carry out, on `GET /commands`. A rollback order is
/// handed out only to an agent that names this capability: an older agent, which has no notion of
/// `ServerCommand.action`, would read the same order as an update and install the feed's version
/// instead — the opposite of what the owner asked for.
public enum AgentCapability {
    public static let ownerRollback = "owner-rollback-v1"
}

public struct CommandResult: Codable, Sendable, Equatable {
    public var commandId: String
    public var status: String
    public var reason: String?
    public var at: String
    public init(commandId: String, status: String, reason: String? = nil, at: String = ISO.string(Date())) {
        self.commandId = commandId; self.status = status; self.reason = reason; self.at = at
    }
}

public struct ServerState: Codable, Sendable, Equatable {
    public var machines: [String: MachineState]
    public init(machines: [String: MachineState] = [:]) { self.machines = machines }
}

/// The publisher's state file. Every change is one read-modify-write under a lock shared by all
/// processes (the server's listeners, `khu enrol`), and an unreadable file is an error, never an
/// empty fleet.
public enum StateStore {
    public static func stateFile(in dir: URL) -> URL { dir.appendingPathComponent("state.json") }
    public static func lockFile(in dir: URL) -> URL { dir.appendingPathComponent("state.lock") }

    public static func load(from dir: URL) throws -> ServerState {
        if let v: ServerState = try AtomicFile.readJSON(ServerState.self, from: stateFile(in: dir)) { return v }
        return ServerState()
    }
    public static func save(_ state: ServerState, to dir: URL) throws {
        try AtomicFile.writeJSON(state, to: stateFile(in: dir), permissions: 0o600)
    }

    /// Read, change and write the state as one transaction across every process on this Mac.
    public static func update<T>(in dir: URL, _ change: (inout ServerState) throws -> T) throws -> T {
        try FileLock.withExclusive(lockFile(in: dir)) {
            var state = try load(from: dir)
            let result = try change(&state)
            try save(state, to: dir)
            return result
        }
    }

    public static func read(in dir: URL) throws -> ServerState {
        try FileLock.withExclusive(lockFile(in: dir)) { try load(from: dir) }
    }
}

public enum Enrolment {
    public static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("no system randomness")
        }
        return Data(bytes).base64EncodedString()
    }
    public static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    public static func enrol(stateDir: URL, machine: String) throws -> String {
        _ = try SafeName.component(machine, what: "machine id")
        let tok = token()
        try StateStore.update(in: stateDir) { state in
            var m = state.machines[machine] ?? MachineState(machine: machine)
            m.tokenHash = sha256Hex(tok)
            state.machines[machine] = m
        }
        return tok
    }
}
