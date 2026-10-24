import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The stub's whole job: keep `current/khu` alive, watch for a switch going bad, and put the
/// previous binary back when it does. Foundation only — no network, no recipes, no feed.
public final class StubRunner: @unchecked Sendable {
    public let layout: StubLayout
    public let childArguments: [String]
    public let pollInterval: TimeInterval
    public let restartDelay: TimeInterval
    private var heartbeatSeen: Date?

    public init(layout: StubLayout,
                childArguments: [String]? = nil,
                pollInterval: TimeInterval = 2,
                restartDelay: TimeInterval = 2) {
        self.layout = layout
        self.childArguments = childArguments ?? ["agent", "--config", layout.base.appendingPathComponent("config.json").path]
        self.pollInterval = pollInterval
        self.restartDelay = restartDelay
    }

    public func loadState() -> StubState {
        guard let data = try? Data(contentsOf: layout.stateFile) else { return StubState() }
        return (try? JSONDecoder().decode(StubState.self, from: data)) ?? StubState()
    }

    public func save(_ supervisor: StubSupervisor) {
        try? AtomicFile.writeJSON(supervisor.state, to: layout.stateFile)
    }

    public func log(_ message: String) {
        let line = "\(ISO.string(Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: layout.logFile.path) {
            fileManager.createFile(atPath: layout.logFile.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: layout.logFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
        FileHandle.standardError.write(data)
    }

    /// Runs until the child exits zero (nothing left to supervise) or a rollback cannot be made.
    public func run() -> Int32 {
        var supervisor = StubSupervisor(state: loadState())
        // An initial launch counts as a switch: a version that never comes up must not spin forever.
        if supervisor.state.switched_at == nil {
            supervisor.recordSwitch(at: Date())
            save(supervisor)
        }

        while true {
            guard let binary = layout.currentBinary() else {
                log("no current binary under \(layout.base.path) — cannot start")
                return 2
            }
            log("starting \(binary.path) \(childArguments.joined(separator: " "))")
            guard let child = spawn(binary) else { return 2 }

            var rolledBack = false
            while child.isRunning {
                Thread.sleep(forTimeInterval: pollInterval)
                if let heartbeat = readHeartbeat(from: layout.heartbeatFile), let date = heartbeat.date {
                    if date != heartbeatSeen {
                        heartbeatSeen = date
                        supervisor.recordHeartbeat(at: date)
                        save(supervisor)
                    }
                }
                if case .switchBack(let reason) = supervisor.decide(at: Date()) {
                    log("rolling back: \(reason)")
                    child.terminate()
                    let deadline = Date().addingTimeInterval(5)
                    while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    guard (try? layout.switchBackToPrevious()) != nil else {
                        log("rollback impossible: there is no previous version")
                        return 3
                    }
                    supervisor.recordRollback(at: Date())
                    save(supervisor)
                    heartbeatSeen = nil
                    rolledBack = true
                    break
                }
            }

            if rolledBack { continue }

            let status = child.terminationStatus
            supervisor.recordExit(code: status, at: Date())
            save(supervisor)
            if case .switchBack(let reason) = supervisor.decide(at: Date()) {
                log("rolling back: \(reason)")
                guard (try? layout.switchBackToPrevious()) != nil else {
                    log("rollback impossible: there is no previous version")
                    return 3
                }
                supervisor.recordRollback(at: Date())
                save(supervisor)
                heartbeatSeen = nil
                continue
            }
            if status == 0 { return 0 }
            log("child exited \(status); restarting in \(restartDelay)s")
            Thread.sleep(forTimeInterval: restartDelay)
        }
    }

    private func spawn(_ binary: URL) -> Process? {
        let process = Process()
        process.executableURL = binary
        process.arguments = childArguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            return process
        } catch {
            log("cannot run \(binary.path): \(error)")
            return nil
        }
    }
}

private extension StubLayout {
    /// Same move the switcher makes, kept here so the stub needs nothing but this file.
    func switchBackToPrevious() throws -> String? {
        let switcher = StubSwitcher(layout: self)
        return try switcher.switchBack()
    }
}
