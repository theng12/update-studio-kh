import Foundation

public struct StubState: Codable, Sendable, Equatable {
    /// When `current` last changed to `target`. The rollback rules are all relative to this instant;
    /// nil once the switch has settled (a quiet probation window with a heartbeat).
    public var switched_at: String?
    /// The executable `current` resolved to when that switch was recorded. A different one on the
    /// next start is a new switch, with its own probation — however long ago the last one was.
    public var target: String?
    /// ISO timestamps of non-zero exits recorded since that switch.
    public var exits: [String]
    public var heartbeat_at: String?
    public var rollbacks: Int
    /// The version the stub last rolled back *from* (its directory name). It is how the agent
    /// learns that a version it installed never came up, so Automatic cannot install those same
    /// bytes here again on every run. Absent in state written before it existed.
    public var rolledBack: String? = nil

    public init(switched_at: String? = nil, target: String? = nil, exits: [String] = [],
                heartbeat_at: String? = nil, rollbacks: Int = 0, rolledBack: String? = nil) {
        self.switched_at = switched_at
        self.target = target
        self.exits = exits
        self.heartbeat_at = heartbeat_at
        self.rollbacks = rollbacks
        self.rolledBack = rolledBack
    }

    public var switchedAt: Date? { switched_at.flatMap(ISO.date) }
    public var heartbeatAt: Date? { heartbeat_at.flatMap(ISO.date) }
    public var exitDates: [Date] { exits.compactMap(ISO.date) }

    /// The one reader for `stub-state.json`, shared by the stub and the switcher so both write
    /// the same file. An absent or unreadable file is a fresh state, never a crash at startup.
    public static func load(from url: URL) -> StubState {
        guard let data = try? Data(contentsOf: url) else { return StubState() }
        return (try? JSONDecoder().decode(StubState.self, from: data)) ?? StubState()
    }
}

public enum StubDecision: Sendable, Equatable {
    case keepRunning
    case switchBack(reason: String)
}

/// The whole rollback policy, with no clock, no processes and no files — so it can be tested
/// directly and never grows network code.
///
/// A switch is on probation for `crashWindow`: three non-zero exits in that window, or no
/// heartbeat from the new child within `heartbeatGrace`, put `previous` back. A quiet window with
/// a heartbeat settles it, and a settled version is never rolled back by these rules.
public struct StubPolicy: Sendable, Equatable {
    public var crashWindow: TimeInterval
    public var crashLimit: Int
    public var heartbeatGrace: TimeInterval
    public init(crashWindow: TimeInterval = 5 * 60, crashLimit: Int = 3, heartbeatGrace: TimeInterval = 2 * 60) {
        self.crashWindow = crashWindow; self.crashLimit = crashLimit; self.heartbeatGrace = heartbeatGrace
    }
}

public struct StubSupervisor: Sendable {
    /// A beat stamped further ahead than this is impossible for a live child and is ignored.
    public static let clockSlack: TimeInterval = 60

    public var state: StubState
    public let policy: StubPolicy

    public init(state: StubState = StubState(), policy: StubPolicy = StubPolicy()) { self.state = state; self.policy = policy }

    public var onProbation: Bool { state.switchedAt != nil }

    /// Called whenever `current` resolves to a new executable, and after a rollback: everything
    /// before this instant stops counting, including any heartbeat.
    public mutating func recordSwitch(at date: Date, target: String?) {
        state.switched_at = ISO.string(date)
        state.target = target
        state.exits = []
        state.heartbeat_at = nil
    }

    /// Only for a beat already matched to the running child (nonce and pid) by the caller.
    public mutating func recordHeartbeat(at date: Date, now: Date) {
        guard let switched = state.switchedAt, date >= switched,
              date <= now.addingTimeInterval(Self.clockSlack) else { return }
        if let current = state.heartbeatAt, current >= date { return }
        state.heartbeat_at = ISO.string(date)
    }

    public mutating func recordExit(code: Int32, at date: Date) {
        clearHeartbeat()
        guard code != 0, let switched = state.switchedAt else { return }
        // A crash after the window can never justify a rollback, and nothing before the switch belongs to it.
        let dates = (state.exitDates + [date])
            .filter { $0 >= switched && $0 <= switched.addingTimeInterval(policy.crashWindow) }
        state.exits = dates.map(ISO.string)
    }

    /// A new child has no heartbeat of its own: a beat the child *before* it wrote must never
    /// vouch for it. Crashes already recorded stay — they belong to this same probation.
    public mutating func clearHeartbeat() { state.heartbeat_at = nil }

    /// `rejected` is the version rolled back from, recorded so the agent can stop offering it.
    public mutating func recordRollback(at date: Date, target: String?, rejected: String? = nil) {
        state.rollbacks += 1
        if let rejected { state.rolledBack = rejected }
        recordSwitch(at: date, target: target)
    }

    /// `elapsed` is the time since the switch on a monotonic clock when the caller has one (the
    /// switch happened in this process); otherwise wall-clock time since `switched_at` is used.
    public func decide(at date: Date, elapsed: TimeInterval? = nil) -> StubDecision {
        guard let switched = state.switchedAt else { return .keepRunning }
        let sinceSwitch = elapsed ?? date.timeIntervalSince(switched)

        let crashes = state.exitDates.filter { $0 >= switched && $0 <= switched.addingTimeInterval(policy.crashWindow) }
        if crashes.count >= policy.crashLimit {
            return .switchBack(reason: "\(crashes.count) non-zero exits within \(Int(policy.crashWindow)) s of the switch")
        }
        if sinceSwitch >= policy.heartbeatGrace, state.heartbeatAt == nil {
            return .switchBack(reason: "no heartbeat from the new version within \(Int(policy.heartbeatGrace)) s of the switch")
        }
        return .keepRunning
    }

    /// Once the window has passed with a heartbeat and fewer crashes than the limit, the switch is
    /// settled. Returns true when that changed the state (so the caller persists it).
    @discardableResult
    public mutating func settleIfStable(at date: Date, elapsed: TimeInterval? = nil) -> Bool {
        guard let switched = state.switchedAt else { return false }
        guard (elapsed ?? date.timeIntervalSince(switched)) >= policy.crashWindow else { return false }
        guard state.heartbeatAt != nil, decide(at: date, elapsed: elapsed) == .keepRunning else { return false }
        state.switched_at = nil
        state.exits = []
        return true
    }
}
