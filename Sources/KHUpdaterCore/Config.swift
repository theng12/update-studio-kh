import Foundation
import CryptoKit

public struct AppConfig: Codable, Sendable, Equatable {
    public var bundlePath: String
    public var recipe: String
    public var automatic: Bool
    public init(bundlePath: String, recipe: String = "app-dmg", automatic: Bool = false) {
        self.bundlePath = bundlePath; self.recipe = recipe; self.automatic = automatic
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
    /// This updater's own version, reported as the `updater` app.
    public var updaterVersion: String?
    public init(feedURL: String, publicKey: String, stateDir: String, machine: String, token: String,
                apps: [String: AppConfig] = [:], intervalMinutes: Int = 5, once: Bool = false) {
        self.feedURL = feedURL; self.publicKey = publicKey; self.stateDir = stateDir
        self.machine = machine; self.token = token; self.apps = apps
        self.intervalMinutes = intervalMinutes; self.once = once
    }
}

public struct MachineState: Codable, Sendable, Equatable {
    public var machine: String
    public var tokenHash: String?
    public var installed: [String: String]
    public var health: [String: String]
    public var lastSeen: String?
    public var pending: [ServerCommand]
    public var lastResult: CommandResult?
    /// The newest result per app (absent in state written before it existed).
    public var lastResults: [String: CommandResult]?
    public var automatic: [String: Bool]
    public init(machine: String) {
        self.machine = machine; self.installed = [:]; self.health = [:]
        self.pending = []; self.automatic = [:]
    }
}

public struct ServerCommand: Codable, Sendable, Equatable {
    public var id: String
    public var machine: String
    public var app: String
    public var createdAt: String
    public init(id: String = UUID().uuidString, machine: String, app: String, createdAt: String = ISO.string(Date())) {
        self.id = id; self.machine = machine; self.app = app; self.createdAt = createdAt
    }
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

public enum StateStore {
    public static func stateFile(in dir: URL) -> URL { dir.appendingPathComponent("state.json") }
    public static func load(from dir: URL) throws -> ServerState {
        if let v: ServerState = try AtomicFile.readJSON(ServerState.self, from: stateFile(in: dir)) { return v }
        return ServerState()
    }
    public static func save(_ state: ServerState, to dir: URL) throws {
        try AtomicFile.writeJSON(state, to: stateFile(in: dir))
    }
}

public enum Enrolment {
    public static func token() -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
    public static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    public static func enrol(stateDir: URL, machine: String) throws -> String {
        let tok = token()
        var state = try StateStore.load(from: stateDir)
        var m = state.machines[machine] ?? MachineState(machine: machine)
        m.tokenHash = sha256Hex(tok)
        state.machines[machine] = m
        try StateStore.save(state, to: stateDir)
        return tok
    }
}

public enum OwnerAccess {
    public static func isSameOrigin(_ origin: String, port: Int) -> Bool {
        origin == "http://127.0.0.1:\(port)" || origin == "http://localhost:\(port)" || origin == "http://[::1]:\(port)"
    }

    /// The body's fields, from JSON (`on` may be a bool) or a urlencoded form.
    public static func fields(_ req: HTTPRequest) -> [String: String] {
        if let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
            return obj.reduce(into: [:]) { out, kv in
                if let s = kv.value as? String { out[kv.key] = s } else if let b = kv.value as? Bool { out[kv.key] = b ? "true" : "false" }
            }
        }
        let text = String(decoding: req.body, as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    public static func isLoopback(_ remote: String) -> Bool {
        remote == "127.0.0.1" || remote == "::1" || remote == "localhost"
    }
}
