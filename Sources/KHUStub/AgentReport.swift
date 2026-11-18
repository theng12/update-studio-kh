import Foundation

/// What the helper's last check actually did, written beside its memory so the stub — and a person
/// reading the log — can tell "running" from "reaching the publisher". A heartbeat proves the
/// process is alive; it says nothing about whether anything reached the publisher, and 15 Macs went
/// quiet for 9.5 h while their helper kept beating.
public struct AgentReport: Codable, Sendable, Equatable {
    /// `ok` (the publisher accepted this Mac's report), `refused` (the publisher answered and
    /// rejected it), `unreachable` (nothing answered), `error` (the check itself failed).
    public var kind: String
    public var reason: String?
    public var at: String
    /// The last time a check was accepted, kept across runs. This is the fact a rollback may be
    /// keyed on: a version that has not reported since it was switched in, on a Mac that was
    /// reporting fine before, is the version's fault. A Mac that was already silent is not.
    public var lastOkAt: String?

    public init(kind: String, reason: String? = nil, at: String, lastOkAt: String? = nil) {
        self.kind = kind; self.reason = reason; self.at = at; self.lastOkAt = lastOkAt
    }

    public static func url(stateDir: URL) -> URL { stateDir.appendingPathComponent("last-report.json") }

    public static func read(stateDir: URL) -> AgentReport? {
        guard let data = try? Data(contentsOf: url(stateDir: stateDir)) else { return nil }
        return try? JSONDecoder().decode(AgentReport.self, from: data)
    }

    public func write(stateDir: URL) throws {
        try AtomicFile.writeJSON(self, to: Self.url(stateDir: stateDir))
    }

    /// Records one finished check and carries the previous success forward.
    public static func record(kind: String, reason: String?, stateDir: URL, now: Date) {
        let previous = read(stateDir: stateDir)
        let report = AgentReport(kind: kind, reason: reason.map { String($0.prefix(240)) },
                                 at: ISO.string(now),
                                 lastOkAt: kind == "ok" ? ISO.string(now) : previous?.lastOkAt)
        try? report.write(stateDir: stateDir)
    }
}
