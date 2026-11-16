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
    public var network: FeedNetwork?
    /// How many days an owner's order waits for an app whose build predates its hold to close
    /// before it is refused. nil = 14.
    public var waitForCloseDays: Int?
    public init(feedURL: String, publicKey: String, stateDir: String, machine: String, token: String,
                apps: [String: AppConfig] = [:], intervalMinutes: Int = 5, once: Bool = false) {
        self.feedURL = feedURL; self.publicKey = publicKey; self.stateDir = stateDir
        self.machine = machine; self.token = token; self.apps = apps
        self.intervalMinutes = intervalMinutes; self.once = once
    }

    /// Pick up an explicit address/re-pair save between runs without changing the running helper's identity or layout.
    public func reloadingConnection(from file: URL) throws -> AgentConfig {
        let saved = try JSON.decode(AgentConfig.self, from: Data(contentsOf: file))
        guard saved.publicKey == publicKey, saved.machine == machine,
              saved.stateDir == stateDir, saved.stubBase == stubBase else {
            throw khuFail("the saved connection changed this Mac's identity, key or paths; restart with the intended settings")
        }
        var current = self
        current.feedURL = saved.feedURL
        current.token = saved.token
        current.network = saved.network
        return current
    }

    private enum CodingKeys: String, CodingKey {
        case feedURL, publicKey, stateDir, machine, token, apps, intervalMinutes, once, stubBase, updaterVersion, network, waitForCloseDays
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
        network = try c.decodeIfPresent(FeedNetwork.self, forKey: .network)
        waitForCloseDays = try c.decodeIfPresent(Int.self, forKey: .waitForCloseDays)
    }
}

public struct MachineState: Codable, Sendable, Equatable {
    public var machine: String
    public var displayName: String?
    public var reportedName: String?
    public var name: String { displayName ?? machine }
    public var tokenHash: String?
    public var installed: [String: String]
    /// Latest reported bundle identity; absent means the Mac did not check it.
    public var installedBuild: [String: String]?
    public var installedExecutableSha256: [String: String]?
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
    /// When each `automatic` value was set and whether the Mac's own menu set it.
    public var automaticSet: [String: AutomaticChange]?
    /// Automatic is paused from the Mac's menu until then (reported by the agent).
    public var pausedUntil: String?
    /// app → why an update is waiting for that app to close (reported by the agent).
    public var waiting: [String: String]?
    /// The capabilities the agent advertised on its most recent /commands fetch. Used by the
    /// status page to warn when a pending rollback order cannot be delivered to an older agent.
    public var capabilities: [String]?
    /// When this Mac was enrolled, and how. `enrolmentSource` is `MachineState.windowSource` for a
    /// Mac that claimed its own token over the network during a window the owner opened, so the
    /// page can list exactly those for the owner to review. Absent for `khu enrol` and for state
    /// written before a window existed.
    public var enrolledAt: String?
    public var enrolmentSource: String?
    /// The sha256 of the nonce a window enrolment was minted for, never the nonce itself (it is not
    /// a secret, but nothing here needs it and a hash cannot be confused with a token). A Mac whose
    /// signed reply was lost resends the SAME machine and nonce; matching this lets the publisher
    /// answer that resend with a fresh token instead of a 409 that would strand the Mac for ever.
    public var enrolNonceHash: String?
    /// The Mac's last results, newest first, for the owner's page (absent in older state).
    public var history: [HistoryEntry]?
    /// This Mac's last read-only hardware/network/app snapshot, as its agent reported it on
    /// `/status` (absent until an agent that knows the field has reported once).
    public var inventory: MacInventory?
    /// The owner's own label for where this Mac sits. Set only from the publisher's page, never
    /// from a report and never derived from the Mac's name (absent until the owner sets one).
    public var site: String?
    /// The owner's own tags for this Mac, from the publisher's page (absent until set).
    public var tags: [String]?
    /// Optional vendor assignments are off until explicitly enabled for this Mac.
    public var vendorAssignments: [String: Bool]?
    /// The one enrolment source the status page lists.
    public static let windowSource = "window"
    /// A Mac that claimed its own token with the pairing code.
    public static let pairingSource = "pairing"
    public init(machine: String) {
        self.machine = machine; self.installed = [:]; self.health = [:]
        self.pending = []; self.automatic = [:]
    }

    /// Every field this record has ever had decodes as optional, with the empty value it had when it
    /// was absent. A state file written before a field existed (a field added by a later build) must
    /// keep loading: a publisher that cannot decode its own state serves 503 to every Mac for ever,
    /// which is a worse fault than any single missing field.
    private enum CodingKeys: String, CodingKey {
        case machine, displayName, reportedName, tokenHash, installed, installedBuild, installedExecutableSha256, health, lastSeen, pending, lastResult, lastResults,
             automatic, automaticDefault, capabilities, enrolledAt, enrolmentSource, enrolNonceHash, history,
             automaticSet, pausedUntil, inventory, site, tags, vendorAssignments, waiting
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(String.self, forKey: .machine)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        reportedName = try c.decodeIfPresent(String.self, forKey: .reportedName)
        tokenHash = try c.decodeIfPresent(String.self, forKey: .tokenHash)
        installed = try c.decodeIfPresent([String: String].self, forKey: .installed) ?? [:]
        installedBuild = try c.decodeIfPresent([String: String].self, forKey: .installedBuild)
        installedExecutableSha256 = try c.decodeIfPresent([String: String].self, forKey: .installedExecutableSha256)
        health = try c.decodeIfPresent([String: String].self, forKey: .health) ?? [:]
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen)
        pending = try c.decodeIfPresent([ServerCommand].self, forKey: .pending) ?? []
        lastResult = try c.decodeIfPresent(CommandResult.self, forKey: .lastResult)
        lastResults = try c.decodeIfPresent([String: CommandResult].self, forKey: .lastResults)
        automatic = try c.decodeIfPresent([String: Bool].self, forKey: .automatic) ?? [:]
        automaticDefault = try c.decodeIfPresent([String: Bool].self, forKey: .automaticDefault)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)
        enrolledAt = try c.decodeIfPresent(String.self, forKey: .enrolledAt)
        enrolmentSource = try c.decodeIfPresent(String.self, forKey: .enrolmentSource)
        enrolNonceHash = try c.decodeIfPresent(String.self, forKey: .enrolNonceHash)
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history)
        automaticSet = try c.decodeIfPresent([String: AutomaticChange].self, forKey: .automaticSet)
        pausedUntil = try c.decodeIfPresent(String.self, forKey: .pausedUntil)
        inventory = try c.decodeIfPresent(MacInventory.self, forKey: .inventory)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        vendorAssignments = try c.decodeIfPresent([String: Bool].self, forKey: .vendorAssignments)
        waiting = try c.decodeIfPresent([String: String].self, forKey: .waiting)
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
    public static let vendorInstall = "vendor-install"

    public var id: String
    public var machine: String
    public var app: String
    public var createdAt: String
    public var action: String
    public var vendor: VendorOrder?
    public init(id: String = UUID().uuidString, machine: String, app: String, createdAt: String = ISO.string(Date()),
                action: String = ServerCommand.update, vendor: VendorOrder? = nil) {
        self.id = id; self.machine = machine; self.app = app; self.createdAt = createdAt; self.action = action
        self.vendor = vendor
    }

    private enum CodingKeys: String, CodingKey { case id, machine, app, createdAt, action, vendor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        machine = try c.decode(String.self, forKey: .machine)
        app = try c.decode(String.self, forKey: .app)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ServerCommand.update
        vendor = try c.decodeIfPresent(VendorOrder.self, forKey: .vendor)
    }
}

/// What an agent tells the publisher it can carry out, on `GET /commands`. A rollback order is
/// handed out only to an agent that names this capability: an older agent, which has no notion of
/// `ServerCommand.action`, would read the same order as an update and install the feed's version
/// instead — the opposite of what the owner asked for.
public enum AgentCapability {
    public static let ownerRollback = "owner-rollback-v1"
    public static let vendorInstall = "vendor-install-v1"
}

/// One install result as the page shows it: which app, the version it was on, the version the feed
/// offered (nil for a rollback), and what the Mac said.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public static let kept = 10
    public var app: String
    public var from: String?
    public var to: String?
    public var status: String
    public var reason: String?
    public var at: String
    public init(app: String, from: String?, to: String?, status: String, reason: String?, at: String) {
        self.app = app; self.from = from; self.to = to; self.status = status; self.reason = reason; self.at = at
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

/// Everything the publisher decides about a Mac enrolling itself over the network, in one place.
/// The numbers here are policy, not values published by anybody else: they bound what a device on
/// the tailnet can write into the owner's state while a window is open.
public enum EnrolPolicy {
    /// Wrong pairing codes before every code try is refused, and for how long. The page shows both.
    public static let pairingWrongTries = 5
    public static let pairingLockMinutes = 5
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
    /// How long a window enrolment may sit with no report before a NEW window treats it as
    /// abandoned. It is longer than any agent's run interval by a wide margin: the Mac has the token
    /// the moment the reply reached it, and only the passage of time can tell a Mac that has not
    /// reported YET from one that never will.
    public static let abandonedAfterSeconds: TimeInterval = 15 * 60
    /// A nonce is `secrets.token_hex(32)` at the Mac: 64 hexadecimal characters, echoed back
    /// verbatim inside the signed reply.
    public static let nonceCharacters = 64
}

/// What an enrolled Mac may write into the owner's state through `/status`, `/commands/<id>/result`
/// and `/automatic/<id>/result`. A token minted through a window is held by a Mac nobody has
/// inspected yet, so every collection it can add to has a bound: without one, a single Mac's
/// reports grow `state.json` for ever, and every write is a whole-file rewrite under the one state
/// lock that every other Mac is waiting on.
public enum ReportPolicy {
    /// Distinct apps one Mac's report may name, in `installed`, `health`, `automatic_default` and
    /// the per-app results together. A real Mac runs a handful.
    public static let maxApps = 64
    /// The longest app id accepted in a report's maps or in a result. `SafeName` is the harder rule
    /// for a name that becomes a file name; this bounds the rest.
    public static let maxNameCharacters = 128
    /// A per-app value in a report's maps: an app's marketing version or its reported
    /// `installed_build`. A build appears only when the bundle carries one — never derived from a
    /// marketing version — and a report that cannot read one carries no entry at all.
    public static let maxVersionCharacters = 64
    public static let maxHealthCharacters = 64
    /// A result's `status` and `reason`, which the page shows. A reason is one sentence.
    public static let maxStatusCharacters = 64
    public static let maxReasonCharacters = 400
    /// The order id a result names: a UUID, or `auto-` and a UUID, and nothing longer. It is stored
    /// with the result and comes out of the URL path, so it needs a bound of its own.
    public static let maxCommandIdCharacters = 128
    /// What `GET /commands?capabilities=` may carry. The string is stored on the Mac's record, so it
    /// needs the same kind of bound as every other report: a few short names, never a paragraph.
    public static let maxCapabilities = 16
    public static let maxCapabilityCharacters = 64
    public static let maxCapabilitiesQueryBytes = 512
    /// `/status` plus result posts one Mac may make per minute. The agent posts status once per run
    /// (every five minutes) and a result per order, so this is far above any real Mac's rate and
    /// only bounds a loop.
    public static let perMachinePerMinute = 60
    /// The `inventory` snapshot a report may carry: a bounded hardware/network/app picture, not a
    /// catalogue of the disk. The page shows these numbers when the listing is incomplete — the
    /// cap is policy, so the owner is told what it is.
    public static let maxInventoryApps = 128
    public static let maxInventoryStringCharacters = 128
    public static let maxInventoryAppPathCharacters = 512
    public static let maxInventoryAddresses = 16
    public static let maxInventoryAddressCharacters = 64
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

    /// A window written by a build with fewer fields is still a window: a field it does not have is
    /// the value it had when it was absent. An absent `until` is an end time that cannot be read,
    /// which `isOpen` already treats as closed — never as open.
    private enum CodingKeys: String, CodingKey { case openedAt, until, minutes, enrolled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openedAt = try c.decodeIfPresent(String.self, forKey: .openedAt) ?? ""
        until = try c.decodeIfPresent(String.self, forKey: .until) ?? ""
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 0
        enrolled = try c.decodeIfPresent(Int.self, forKey: .enrolled) ?? 0
    }

    /// A window of `minutes` starting at `now`. One constructor for every caller (the owner route,
    /// the CLI and the page): two copies of this arithmetic are two chances for the window the page
    /// shows and the window the server enforces to disagree.
    public static func starting(minutes: Int, now: Date = Date()) -> EnrolWindow {
        EnrolWindow(openedAt: ISO.string(now),
                    until: ISO.string(now.addingTimeInterval(Double(minutes) * 60)),
                    minutes: minutes, enrolled: 0)
    }

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
    ///
    /// Opening also drops window enrolments that never reported and are older than
    /// `EnrolPolicy.abandonedAfterSeconds`. Such a record is either a Mac whose signed reply was
    /// lost — it cannot use the token it never received — or an id a device on the tailnet claimed
    /// and abandoned; either way it holds one of the window's cap slots and 409s the real Mac that
    /// wants that id. The age is what makes this safe: a Mac that was handed a token seconds ago
    /// has not had its first agent run yet, and deleting its record would leave it answering 401
    /// with a token it was legitimately given. A record that HAS reported is never dropped here.
    @discardableResult
    public static func open(stateDir: URL, minutes: Int, now: Date = Date()) throws -> EnrolWindow {
        guard (1...EnrolPolicy.maxMinutes).contains(minutes) else {
            throw khuFail("an enrolment window is 1 to \(EnrolPolicy.maxMinutes) minutes, not \(minutes); 0 closes it")
        }
        let window = EnrolWindow.starting(minutes: minutes, now: now)
        try StateStore.update(in: stateDir) { state in
            state.pruneAbandonedWindowEnrolments(now: now)
            state.enrolWindow = window
        }
        return window
    }

    /// Closing drops the record: a closed window is the absence of one, so nothing can read a stale
    /// end time as an open door. It drops nothing else — a Mac that enrolled through this window may
    /// not have run its agent yet, and its token has to keep working, so only a new window (after the
    /// abandonment age) or Remove Mac ever drops a record.
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

    /// Same rule as every other record in the state file: a field this build does not find is the
    /// value it had when it was absent, so a newer build's file (or an older one) never makes the
    /// whole publisher unreadable.
    private enum CodingKeys: String, CodingKey {
        case machine, removedAt, installed, health, lastSeen, enrolledAt, enrolmentSource, droppedOrders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(String.self, forKey: .machine)
        removedAt = try c.decodeIfPresent(String.self, forKey: .removedAt) ?? ""
        installed = try c.decodeIfPresent([String: String].self, forKey: .installed) ?? [:]
        health = try c.decodeIfPresent([String: String].self, forKey: .health) ?? [:]
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen)
        enrolledAt = try c.decodeIfPresent(String.self, forKey: .enrolledAt)
        enrolmentSource = try c.decodeIfPresent(String.self, forKey: .enrolmentSource)
        droppedOrders = try c.decodeIfPresent([ServerCommand].self, forKey: .droppedOrders) ?? []
    }
}

/// The code a new Mac types to claim a token. Kept as plain digits in the 0600 state file, not
/// hashed like a token: the owner's page must keep showing it, and a hash of six digits is undone
/// in under a second anyway. Anyone who can read that file can already run `khu enrol`.
public struct PairingCode: Codable, Sendable, Equatable {
    public var code: String
    public var wrongTries: Int
    public var lockedUntil: String?

    public static func fresh(replacing old: String? = nil) -> PairingCode {
        var code: String
        repeat { code = String(format: "%06d", Int.random(in: 0...999_999)) } while code == old
        return PairingCode(code: code, wrongTries: 0, lockedUntil: nil)
    }
    public var shown: String { "\(code.prefix(3))-\(code.suffix(3))" }
    public func locked(at now: Date) -> Bool { lockedUntil.flatMap(ISO.date).map { now < $0 } ?? false }
    /// A person may type it with or without the dash.
    public func matches(_ typed: String) -> Bool { typed.filter { "0123456789".contains($0) } == code }
}

public struct ServerState: Codable, Sendable, Equatable {
    public var machines: [String: MachineState]
    /// Nil until `khu serve` first starts with this version.
    public var pairing: PairingCode?
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

    private enum CodingKeys: String, CodingKey { case machines, pairing, enrolWindow, removed }
    /// `machines` is REQUIRED: a state file without it is not an empty fleet, and answering an empty
    /// fleet would silently orphan every Mac that thinks it is enrolled. The two fields added later
    /// (`removed` with Remove Mac, `enrolWindow` with network enrolment) are optional, because
    /// everything written up to `2eaae0c` lacks them and a decoded-throw there makes every route a
    /// permanent 503.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machines = try c.decode([String: MachineState].self, forKey: .machines)
        pairing = try c.decodeIfPresent(PairingCode.self, forKey: .pairing)
        enrolWindow = try c.decodeIfPresent(EnrolWindow.self, forKey: .enrolWindow)
        removed = try c.decodeIfPresent([RemovedMachine].self, forKey: .removed) ?? []
    }

    /// The newest removal of this machine id, if it has ever been removed.
    public func removal(of machine: String) -> RemovedMachine? { removed.last { $0.machine == machine } }

    /// Drop window enrolments that never reported `now - olderThan`. Never on close: a Mac that was
    /// handed a token is not abandoned until time proves it. A record whose `enrolledAt` cannot be
    /// read is kept — "I could not work out how old this is" must never delete anything.
    public mutating func pruneAbandonedWindowEnrolments(olderThan: TimeInterval = EnrolPolicy.abandonedAfterSeconds,
                                                        now: Date = Date()) {
        for (machine, record) in machines
        where record.enrolmentSource == MachineState.windowSource && record.lastSeen == nil
            && record.enrolledAt.flatMap(ISO.date).map({ now.timeIntervalSince($0) > olderThan }) == true {
            machines.removeValue(forKey: machine)
        }
    }
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
    /// it had (installed versions, health, pending orders). `nonce` is recorded for a window
    /// enrolment so a resend of the same machine and nonce can be recognised as the same claim.
    public static func store(_ token: String, for machine: String, at date: Date, source: String?,
                             nonce: String? = nil, in state: inout ServerState) {
        var record = state.machines[machine] ?? MachineState(machine: machine)
        record.tokenHash = sha256Hex(token)
        record.enrolledAt = ISO.string(date)
        record.enrolmentSource = source
        record.enrolNonceHash = nonce.map(sha256Hex)
        state.machines[machine] = record
    }

    /// A publisher always has a code once it is serving. An unreadable state file throws here and
    /// is left untouched.
    public static func ensurePairingCode(stateDir: URL) throws {
        try StateStore.update(in: stateDir) { state in
            if state.pairing == nil { state.pairing = PairingCode.fresh() }
        }
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
    /// back, as is the pairing code.
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

    /// Labels never change the enrolment ID, token or queued orders.
    public static func rename(stateDir: URL, machine: String, to name: String) throws {
        guard MacName.valid(name) else { throw khuFail("Mac name must have 1 to \(MacName.maxCharacters) characters without control characters") }
        try StateStore.update(in: stateDir) { state in
            guard var record = state.machines[machine] else { throw khuFail("no enrolled Mac named \(machine)") }
            record.rename(to: name)
            state.machines[machine] = record
        }
    }
}

extension MachineState {
    public mutating func report(name newName: String) {
        // A page label stays until the Mac's actual name changes again.
        if reportedName.map({ $0 != newName }) ?? (displayName == nil) { rename(to: newName) }
        reportedName = newName
    }
    public mutating func rename(to newName: String) {
        guard newName != name else { return }
        let old = name
        displayName = newName
        history = Array(([HistoryEntry(app: "updater", from: nil, to: nil, status: "renamed",
                                      reason: "Renamed from \(old)", at: ISO.string(Date()))] + (history ?? [])).prefix(HistoryEntry.kept))
    }
}
