import Foundation

public struct StubState: Codable, Sendable, Equatable {
    /// When `current` last changed. The rollback rules are all relative to this instant.
    public var switched_at: String?
    /// ISO timestamps of non-zero exits recorded since that switch.
    public var exits: [String]
    public var heartbeat_at: String?
    public var rollbacks: Int

    public init(switched_at: String? = nil, exits: [String] = [], heartbeat_at: String? = nil, rollbacks: Int = 0) {
        self.switched_at = switched_at
        self.exits = exits
        self.heartbeat_at = heartbeat_at
        self.rollbacks = rollbacks
    }

    public var switchedAt: Date? { switched_at.flatMap(ISO.date) }
    public var heartbeatAt: Date? { heartbeat_at.flatMap(ISO.date) }
    public var exitDates: [Date] { exits.compactMap(ISO.date) }
}

public enum StubDecision: Sendable, Equatable {
    case keepRunning
    case switchBack(reason: String)
}

/// The whole rollback policy, with no clock, no processes and no files — so it can be tested
/// directly and never grows network code.
public struct StubSupervisor: Sendable {
    public static let crashWindow: TimeInterval = 5 * 60
    public static let crashLimit = 3
    public static let heartbeatGrace: TimeInterval = 2 * 60

    public var state: StubState

    public init(state: StubState = StubState()) { self.state = state }

    /// Called on launch and again after a rollback: everything before this instant stops counting.
    public mutating func recordSwitch(at date: Date) {
        state.switched_at = ISO.string(date)
        state.exits = []
        state.heartbeat_at = nil
    }

    public mutating func recordHeartbeat(at date: Date) {
        if let current = state.heartbeatAt, current >= date { return }
        state.heartbeat_at = ISO.string(date)
    }

    public mutating func recordExit(code: Int32, at date: Date) {
        guard code != 0 else { return }
        guard let switched = state.switchedAt else { return }
        var dates = state.exitDates
        // A crash after the window can never justify a rollback, and nothing before the switch belongs to it.
        dates.append(date)
        dates = dates.filter { $0 >= switched.addingTimeInterval(-2) }
                            .filter { $0 <= switched.addingTimeInterval(Self.crashWindow) }
        state.exits = dates.map(ISO.string)
    }

    public mutating func recordRollback(at date: Date) {
        state.rollbacks += 1
        recordSwitch(at: date)
    }

    public func decide(at date: Date) -> StubDecision {
        guard let switched = state.switchedAt else { return .keepRunning }

        let crashes = state.exitDates.filter { $0 >= switched }
                                     .filter { $0 <= switched.addingTimeInterval(Self.crashWindow) }
        if crashes.count >= Self.crashLimit {
            return .switchBack(reason: "\(crashes.count) non-zero exits within 5 minutes of the switch")
        }

        if date.timeIntervalSince(switched) >= Self.heartbeatGrace {
            guard let heartbeat = state.heartbeatAt, heartbeat >= switched else {
                return .switchBack(reason: "no heartbeat within 2 minutes of the switch")
            }
        }

        return .keepRunning
    }

    /// Once the window has passed quietly, the switch is settled and stops being a rollback candidate.
    public mutating func settleIfStable(at date: Date) {
        guard let switched = state.switchedAt else { return }
        guard date.timeIntervalSince(switched) >= Self.crashWindow else { return }
        guard let heartbeat = state.heartbeatAt, heartbeat >= switched else { return }
        guard state.exitDates.allSatisfy({ $0 < switched }) else { return }
        state.switched_at = nil
        state.exits = []
    }
}
