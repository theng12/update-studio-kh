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
    /// When this Mac was enrolled, and how. `enrolmentSource` is `MachineState.windowSource` for a
    /// Mac that claimed its own token over the network during a window the owner opened, so the
    /// page can list exactly those for the owner to review. Absent for `khu enrol` and for state
    /// written before a window existed.
    public var enrolledAt: String?
    public var enrolmentSource: String?
    /// The one enrolment source the status page lists.
    public static let windowSource = "window"
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

/// Everything the publisher decides about a Mac enrolling itself over the network, in one place.
/// The numbers here are policy, not values published by anybody else: they bound what a device on
/// the tailnet can write into the owner's state while a window is open.
public enum EnrolPolicy {
    /// The most new Macs one open window may enrol. The status page shows this figure beside the
    /// count, so a limit that refuses is never a limit nobody was told about.
    public static let maxPerWindow = 200
    /// The longest window the owner may open, and the default the page offers.
    public static let maxMinutes = 240
    public static let defaultMinutes = 30
    /// A `/enrol` body is two short strings. Anything larger is refused before it is parsed, so a
    /// flood cannot make the publisher hold or decode megabytes per connection.
    public static let maxBodyBytes = 4 << 10
    /// `/enrol` attempts one client address may make per minute. The window's cap bounds the
    /// enrolments that SUCCEED; this bounds the attempts that do not.
    public static let attemptsPerMinute = 30
    /// A nonce is `secrets.token_hex(32)` at the Mac: 64 hexadecimal characters, echoed back
    /// verbatim inside the signed reply.
    public static let nonceCharacters = 64
}

/// A period during which Macs may enrol themselves over the network; closed the rest of the time.
/// It is stored in state.json under state.lock, and its end time is the only thing that decides
/// whether it is open — there is no second flag that can disagree with it.
public struct EnrolWindow: Codable, Sendable, Equatable {
    public var openedAt: String
    public var until: String
    public var minutes: Int
    /// New enrolments this window has already minted (reset when a window is opened).
    public var enrolled: Int

    public init(openedAt: String, until: String, minutes: Int, enrolled: Int = 0) {
        self.openedAt = openedAt; self.until = until; self.minutes = minutes; self.enrolled = enrolled
    }

    public var untilDate: Date? { ISO.date(until) }

    /// An end time that cannot be read is NOT an open window: "I could not work out the answer" and
    /// "the answer is yes" must never be the same value.
    public func isOpen(at now: Date = Date()) -> Bool {
        guard let end = untilDate else { return false }
        return end > now
    }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        guard let end = untilDate else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }
}

public enum EnrolmentWindow {
    /// Open a window for `minutes` (1...`EnrolPolicy.maxMinutes`) from now. Opening a window while
    /// one is already open replaces it and resets its count: the owner asking for a fresh window is
    /// exactly what a fresh count is for.
    @discardableResult
    public static func open(stateDir: URL, minutes: Int, now: Date = Date()) throws -> EnrolWindow {
        guard (1...EnrolPolicy.maxMinutes).contains(minutes) else {
            throw khuFail("an enrolment window is 1 to \(EnrolPolicy.maxMinutes) minutes, not \(minutes); 0 closes it")
        }
        let window = EnrolWindow(openedAt: ISO.string(now),
                                 until: ISO.string(now.addingTimeInterval(Double(minutes) * 60)),
                                 minutes: minutes, enrolled: 0)
        try StateStore.update(in: stateDir) { $0.enrolWindow = window }
        return window
    }

    /// Closing drops the record: a closed window is the absence of one, so nothing can read a stale
    /// end time as an open door.
    public static func close(stateDir: URL) throws {
        try StateStore.update(in: stateDir) { $0.enrolWindow = nil }
    }
}

/// A Mac the owner removed. The live record is gone — its token hash with it, so the token can no
/// longer be used, and its orders are not pending any more — and what it had reported is kept here
/// with the moment of the removal. Only the owner can add one of these, from this Mac.
public struct RemovedMachine: Codable, Sendable, Equatable {
    public var machine: String
    public var removedAt: String
    public var installed: [String: String]
    public var health: [String: String]
    public var lastSeen: String?
    public var enrolledAt: String?
    /// The source the record was enrolled through, when the publisher knows it.
    public var enrolmentSource: String?
    /// Orders the Mac never answered, kept as history: they are not pending, and the Mac can no
    /// longer fetch them.
    public var droppedOrders: [ServerCommand]

    public init(machine: String, removedAt: String = ISO.string(Date()), installed: [String: String] = [:],
                health: [String: String] = [:], lastSeen: String? = nil, enrolledAt: String? = nil,
                enrolmentSource: String? = nil, droppedOrders: [ServerCommand] = []) {
        self.machine = machine; self.removedAt = removedAt; self.installed = installed; self.health = health
        self.lastSeen = lastSeen; self.enrolledAt = enrolledAt; self.enrolmentSource = enrolmentSource
        self.droppedOrders = droppedOrders
    }

    public init(from state: MachineState, at date: Date) {
        self.init(machine: state.machine, removedAt: ISO.string(date), installed: state.installed, health: state.health,
                  lastSeen: state.lastSeen, enrolledAt: state.enrolledAt, enrolmentSource: state.enrolmentSource,
                  droppedOrders: state.pending)
    }
}

public struct ServerState: Codable, Sendable, Equatable {
    public var machines: [String: MachineState]
    /// The enrolment window the owner opened, or nil when enrolment is closed (the default, and
    /// what state written before this existed decodes to).
    public var enrolWindow: EnrolWindow?
    /// Every removal the owner has made, newest last. Nothing is lost: a Mac removed by mistake can
    /// be seen here with what it had reported. A machine id in this list is NOT barred from
    /// enrolling again — resetting a Mac and enrolling it afresh is the point of removing it.
    public var removed: [RemovedMachine]
    public init(machines: [String: MachineState] = [:], enrolWindow: EnrolWindow? = nil,
                removed: [RemovedMachine] = []) {
        self.machines = machines; self.enrolWindow = enrolWindow; self.removed = removed
    }

    /// The newest removal of this machine id, if it has ever been removed.
    public func removal(of machine: String) -> RemovedMachine? { removed.last { $0.machine == machine } }
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
    /// `bytes` bytes from the system's randomness, base64. The one source of randomness here, used
    /// for enrolment tokens and for the owner page's CSP nonce.
    public static func randomBase64(bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
            preconditionFailure("no system randomness")
        }
        return Data(buffer).base64EncodedString()
    }

    public static func token() -> String { randomBase64(bytes: 32) }

    public static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Store a minted token the way every enrolment does: the sha256 of the token, never the token
    /// itself, plus when it happened and how it got here. An existing record keeps everything else
    /// it had (installed versions, health, pending orders).
    public static func store(_ token: String, for machine: String, at date: Date, source: String?,
                             in state: inout ServerState) {
        var record = state.machines[machine] ?? MachineState(machine: machine)
        record.tokenHash = sha256Hex(token)
        record.enrolledAt = ISO.string(date)
        record.enrolmentSource = source
        state.machines[machine] = record
    }

    public static func enrol(stateDir: URL, machine: String, now: Date = Date()) throws -> String {
        _ = try SafeName.component(machine, what: "machine id")
        let tok = token()
        try StateStore.update(in: stateDir) { store(tok, for: machine, at: now, source: nil, in: &$0) }
        return tok
    }

    /// Drop a Mac's live record — its token hash and its pending orders with it — and keep what it
    /// reported in the removed list with the moment of the removal. One read-modify-write under
    /// state.lock, shared with `khu enrol`, the server and the page.
    ///
    /// A machine id is NOT barred from enrolling again by this: the owner's day for resetting and
    /// re-enrolling Macs depends on it. `khu enrol` (or a new enrolment window) is how it comes
    /// back.
    @discardableResult
    public static func remove(stateDir: URL, machine: String, now: Date = Date()) throws -> RemovedMachine {
        _ = try SafeName.component(machine, what: "machine id")
        return try StateStore.update(in: stateDir) { state in
            guard let record = state.machines[machine] else {
                throw khuFail("no enrolled Mac named \(machine)")
            }
            let removal = RemovedMachine(from: record, at: now)
            state.machines.removeValue(forKey: machine)
            state.removed.append(removal)
            return removal
        }
    }
}
