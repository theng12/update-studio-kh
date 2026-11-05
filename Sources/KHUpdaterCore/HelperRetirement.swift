import Foundation

public struct HelperRetirementSettings: Codable, Sendable {
    public var enabled = true
    public var healthySeconds: TimeInterval = 300
    public init() {}
    public static func file(in state: URL) -> URL { state.appendingPathComponent("helper-retirement.json") }
    public static func load(from state: URL) throws -> Self {
        let value = try AtomicFile.readJSON(Self.self, from: file(in: state)) ?? Self()
        guard value.healthySeconds.isFinite && value.healthySeconds > 0 else {
            throw khuFail("helper cleanup needs a positive healthy-report duration")
        }
        return value
    }
    public func save(to state: URL) throws {
        guard healthySeconds.isFinite && healthySeconds > 0 else { throw khuFail("helper cleanup duration is invalid") }
        try AtomicFile.writeJSON(self, to: Self.file(in: state))
        try HelperRetirement.reset(in: state)
    }
}

/// Optional cleanup only after the publisher accepted fresh reports from the settled current child.
public enum HelperRetirement {
    private struct Observation: Codable {
        var binary: String
        var pid: Int32
        var nonce: String
        var first: String
        var last: String
        var reports: Int
        var rollbacks: Int
    }
    private static func observation(in state: URL) -> URL { state.appendingPathComponent("helper-retirement-health.json") }
    static func reset(in state: URL) throws {
        let file = observation(in: state)
        if FileManager.default.fileExists(atPath: file.path) { try Trash.move(file, into: Trash.root(in: state)) }
    }

    @discardableResult
    public static func observe(layout: StubLayout, stateDir: URL, executable: URL, now: Date = Date(),
                               maximumReportGap: TimeInterval, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> [String] {
        let settings = try HelperRetirementSettings.load(from: stateDir)
        guard settings.enabled else { try reset(in: stateDir); return [] }
        return try FileLock.withExclusive(layout.switchLock, wait: false) {
            let fm = FileManager.default
            let versions = layout.versionsDirectory.resolvingSymlinksInPath().standardizedFileURL
            let running = executable.resolvingSymlinksInPath().standardizedFileURL
            guard maximumReportGap.isFinite, maximumReportGap > 0,
                  let current = layout.currentBinary()?.resolvingSymlinksInPath().standardizedFileURL,
                  let previous = layout.previousBinary()?.resolvingSymlinksInPath().standardizedFileURL,
                  current == running, current != previous,
                  current.deletingLastPathComponent().deletingLastPathComponent() == versions,
                  previous.deletingLastPathComponent().deletingLastPathComponent() == versions,
                  let stub = try AtomicFile.readJSON(StubState.self, from: layout.stateFile),
                  stub.switched_at == nil, stub.target.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL }) == current,
                  let beat = try AtomicFile.readJSON(Heartbeat.self, from: layout.heartbeatFile),
                  beat.pid == pid, beat.version == StubLayout.version(of: current), beat.nonce?.isEmpty == false,
                  let at = beat.date, now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) <= 90 else {
                try reset(in: stateDir)
                return []
            }
            let file = observation(in: stateDir)
            var record = try AtomicFile.readJSON(Observation.self, from: file)
            if let old = record, old.binary == current.path, old.pid == pid, old.nonce == beat.nonce, old.rollbacks == stub.rollbacks,
               let last = ISO.date(old.last), let first = ISO.date(old.first),
               now >= first, now > last, now.timeIntervalSince(last) <= maximumReportGap {
                record?.reports += 1
                record?.last = ISO.string(now)
            } else {
                record = Observation(binary: current.path, pid: pid, nonce: beat.nonce!, first: ISO.string(now), last: ISO.string(now), reports: 1, rollbacks: stub.rollbacks)
            }
            let health = record!
            try AtomicFile.writeJSON(health, to: file)
            guard health.reports >= 2, let first = ISO.date(health.first), now.timeIntervalSince(first) >= settings.healthySeconds else { return [] }
            let protected = Set([current.deletingLastPathComponent().path, previous.deletingLastPathComponent().path])
            var retired: [String] = []
            for dir in try fm.contentsOfDirectory(at: layout.versionsDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let info = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true,
                      !protected.contains(dir.resolvingSymlinksInPath().path),
                      VersionCompare.compare(dir.lastPathComponent, StubLayout.version(of: current)).map({ $0 < 0 }) == true else { continue }
                try Trash.move(dir, into: layout.trash, at: now)
                retired.append(dir.lastPathComponent)
            }
            return retired.sorted()
        }
    }
}
