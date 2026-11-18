import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Written by the SIGTERM handler, which may run on any thread. `sig_atomic_t` is the one kind of
/// storage a signal handler may touch.
private final class ShutdownSignal: @unchecked Sendable {
    private let flag = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)
    init() { flag.initialize(to: 0) }
    deinit { flag.deinitialize(count: 1); flag.deallocate() }
    var requested: Bool { flag.pointee != 0 }
    func clear() { flag.pointee = 0 }
    func request() { flag.pointee = 1 }
}

private let shutdownSignal = ShutdownSignal()

private func stubShutdownHandler(_ signalNumber: Int32) { shutdownSignal.request() }

/// The stub's whole job: keep `current` alive, watch a new version on probation, and put the
/// previous binary back when it goes bad. Foundation only — no network, no recipes, no feed.
public final class StubRunner: @unchecked Sendable {
    /// 128 + SIGTERM, the status a shell reports for a process stopped by TERM.
    private static let shutdownExitCode: Int32 = 128 + SIGTERM
    /// How long an orderly SIGTERM waits for the child to leave. Never escalates past TERM.
    private static let shutdownGrace: TimeInterval = 5
    public let layout: StubLayout
    public let childArguments: [String]
    public let pollInterval: TimeInterval
    public let restartDelay: TimeInterval
    public let policy: StubPolicy
    /// Wall clock for persisted timestamps; injectable so tests can start "an hour after" a switch.
    public let now: () -> Date

    public init(layout: StubLayout,
                childArguments: [String]? = nil,
                pollInterval: TimeInterval = 2,
                restartDelay: TimeInterval = 2,
                policy: StubPolicy = StubPolicy(),
                now: @escaping () -> Date = Date.init) {
        self.layout = layout
        self.childArguments = childArguments ?? ["agent", "--config", layout.base.appendingPathComponent("config.json").path]
        self.pollInterval = pollInterval
        self.restartDelay = restartDelay
        self.policy = policy
        self.now = now
    }

    /// The helper's own report, from the state dir its config file names. Nil when the config or
    /// the report is not there yet: an absent report is never read as a failure.
    public func agentReport() -> AgentReport? {
        guard let flag = childArguments.firstIndex(of: "--config"), flag + 1 < childArguments.count,
              let data = try? Data(contentsOf: URL(fileURLWithPath: childArguments[flag + 1])),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stateDir = config["stateDir"] as? String else { return nil }
        return AgentReport.read(stateDir: URL(fileURLWithPath: stateDir))
    }

    public func loadState() -> StubState { StubState.load(from: layout.stateFile) }

    public func save(_ supervisor: StubSupervisor) {
        do { try AtomicFile.writeJSON(supervisor.state, to: layout.stateFile) }
        catch { log("could not save stub state: \(error)") }
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

    /// Runs until the child exits zero (nothing left to supervise). Returns 2 when there is no
    /// version that can run at all, so launchd's throttle — not a busy loop — paces the retry.
    public func run() -> Int32 {
        // launchd stops this process with SIGTERM and does not signal the child it started. Take
        // the TERM ourselves so the one child this supervisor owns is stopped first — and so no
        // replacement is started after shutdown has begun.
        shutdownSignal.clear()
        let previousTerm = signal(SIGTERM, stubShutdownHandler)
        defer { signal(SIGTERM, previousTerm) }
        var supervisor = StubSupervisor(state: loadState(), policy: policy)
        let switcher = StubSwitcher(layout: layout)
        var switchMono: TimeInterval?      // set when the switch happened in this process
        var warnedNoFallback = false

        // A probation a previous process left open gets its whole window again here: time that
        // passed while no child of ours was running is not this version misbehaving, and must not
        // roll it back before it has been given the grace the window promises.
        if supervisor.onProbation {
            supervisor.recordSwitch(at: now(), target: supervisor.state.target)
            switchMono = Mono.now()
            save(supervisor)
        }

        func elapsed() -> TimeInterval? { switchMono.map { Mono.now() - $0 } }

        /// Put `previous` back. Checked before anything is stopped: with no usable fallback the
        /// running child is left alone rather than killed for nothing.
        func rollBack(_ reason: String) -> Bool {
            guard switcher.usablePrevious() != nil else {
                if !warnedNoFallback { log("would roll back (\(reason)) but there is no usable previous version; keeping current"); warnedNoFallback = true }
                return false
            }
            log("rolling back: \(reason)")
            let rejected = layout.currentBinary()?.path      // what is being rolled back FROM
            do {
                let restored = try FileLock.withExclusive(layout.switchLock) { try switcher.switchBack(at: now()) }
                guard restored != nil else { return false }
            } catch {
                log("rollback failed: \(error)")
                return false
            }
            supervisor.recordRollback(at: now(), target: layout.currentBinary()?.path,
                                      rejected: rejected.map { StubLayout.version(of: URL(fileURLWithPath: $0)) })
            switchMono = Mono.now()
            warnedNoFallback = false
            save(supervisor)
            return true
        }

        /// `current` wins whenever it resolves to an executable. The recorded target is only the
        /// last thing this stub ran: it is what to run when the link itself is missing or broken.
        func chosenBinary() -> (binary: URL, reason: String)? {
            if let current = layout.currentBinary() { return (current, "current") }
            if let recorded = supervisor.state.target,
               FileManager.default.isExecutableFile(atPath: recorded) {
                return (URL(fileURLWithPath: recorded).standardizedFileURL,
                        "recorded target (current is missing or cannot run)")
            }
            return nil
        }

        while true {
            if shutdownSignal.requested {
                log("shutdown requested; no child running, not starting one")
                return Self.shutdownExitCode
            }
            guard let choice = chosenBinary() else {
                // Neither the link nor a recorded target can run: the fallback is the last resort.
                if rollBack("current is missing or cannot run") { continue }
                log("no runnable version under \(layout.base.path) — cannot start")
                return 2
            }
            let binary = choice.binary
            log("launch decision: \(choice.reason), \(binary.path)")
            if supervisor.state.target != binary.path {
                // A new target — first start, a self-update, or a hand switch — gets a fresh window.
                supervisor.recordSwitch(at: now(), target: binary.path)
                switchMono = Mono.now()
                warnedNoFallback = false
                save(supervisor)
            }

            let runnable = namedBinary(binary)
            let nonce = UUID().uuidString
            // Only a beat carrying THIS child's nonce counts, and one the child before it wrote
            // must not be left standing to vouch for this one.
            if supervisor.state.heartbeat_at != nil { supervisor.clearHeartbeat(); save(supervisor) }
            log("starting \(runnable.path) \(childArguments.joined(separator: " "))")
            guard let child = spawn(runnable, nonce: nonce) else {
                // Cannot even launch: counted as a crash, so three of them roll back like any other.
                supervisor.recordExit(code: 127, at: now())
                save(supervisor)
                if case .switchBack(let reason) = supervisor.decide(at: now(), elapsed: elapsed(), report: agentReport()), rollBack(reason) { continue }
                if waitOrShutdown(restartDelay) {
                    log("shutdown requested; not retrying the child")
                    return Self.shutdownExitCode
                }
                continue
            }

            var rolledBack = false
            var switchedUnderneath = false
            while child.isRunning {
                if waitOrShutdown(pollInterval) {
                    stopOwnedChildForShutdown(child)
                    return Self.shutdownExitCode
                }
                if let live = layout.currentBinary(), RealPath.of(live.path) != RealPath.of(binary.path) {
                    // The link moved (an update, a hand switch). Whatever the recorded target says,
                    // `current` is what must run: stop this child and start the new one.
                    log("current now names \(live.path); restarting to run it")
                    switchedUnderneath = true
                    stop(child)
                    break
                }
                if let beat = readHeartbeat(from: layout.heartbeatFile), beat.nonce == nonce,
                   beat.pid == child.processIdentifier, let date = beat.date {
                    let before = supervisor.state.heartbeat_at
                    supervisor.recordHeartbeat(at: date, now: now())
                    if supervisor.state.heartbeat_at != before { save(supervisor) }
                }
                if supervisor.settleIfStable(at: now(), elapsed: elapsed()) {
                    log("\(StubLayout.version(of: binary)) settled")
                    switchMono = nil
                    save(supervisor)
                }
                if case .switchBack(let reason) = supervisor.decide(at: now(), elapsed: elapsed(), report: agentReport()),
                   switcher.usablePrevious() != nil {
                    stop(child)
                    if shutdownSignal.requested {
                        log("shutdown: child stopped; not rolling back")
                        return Self.shutdownExitCode
                    }
                    rolledBack = rollBack(reason)
                    break
                } else if case .switchBack(let reason) = supervisor.decide(at: now(), elapsed: elapsed(), report: agentReport()) {
                    _ = rollBack(reason)  // only logs: there is nothing to fall back to
                }
            }
            // A child we stopped ourselves for a switch did not crash; the new version gets its
            // own probation in the next iteration.
            if rolledBack || switchedUnderneath { continue }

            if shutdownSignal.requested {
                child.waitUntilExit()
                log("shutdown: child exited; not restarting")
                return Self.shutdownExitCode
            }

            let status = child.terminationStatus
            supervisor.recordExit(code: status, at: now())
            save(supervisor)
            if case .switchBack(let reason) = supervisor.decide(at: now(), elapsed: elapsed(), report: agentReport()), rollBack(reason) {
                continue
            }
            if status == 0 { return 0 }
            log("child exited \(status); restarting in \(restartDelay)s")
            if waitOrShutdown(restartDelay) {
                log("shutdown requested; not restarting")
                return Self.shutdownExitCode
            }
        }
    }

    /// Waits in short slices so a pending SIGTERM is noticed promptly. True means shutdown was
    /// requested and the caller must stop its child and leave.
    private func waitOrShutdown(_ seconds: TimeInterval) -> Bool {
        let deadline = Mono.now() + max(0, seconds)
        while true {
            if shutdownSignal.requested { return true }
            let remaining = deadline - Mono.now()
            if remaining <= 0 { return false }
            Thread.sleep(forTimeInterval: min(0.1, remaining))
        }
    }

    /// Forward SIGTERM to the one child this supervisor started and wait a bounded time for it to
    /// leave. Deliberately no SIGKILL: a child that ignores TERM is reported, not escalated to.
    private func stopOwnedChildForShutdown(_ child: Process) {
        let pid = child.processIdentifier
        log("shutdown: sending SIGTERM to child \(pid)")
        child.terminate()
        let deadline = Mono.now() + Self.shutdownGrace
        while child.isRunning && Mono.now() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard !child.isRunning else {
            log("shutdown: child \(pid) is still running after \(Int(Self.shutdownGrace))s; refusing to escalate")
            return
        }
        child.waitUntilExit()
        log("shutdown: child \(pid) exited \(child.terminationStatus)")
    }

    private func stop(_ child: Process) {
        child.terminate()
        let deadline = Mono.now() + 5
        while child.isRunning && Mono.now() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }

    /// Wraps a version binary in its helper bundle so the process has a product name. Naming is a
    /// convenience: when it cannot be done, the version still runs from its plain path.
    private func namedBinary(_ binary: URL) -> URL {
        let version = StubLayout.version(of: binary)
        let icon = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
        do {
            let spec = HelperBundle.Spec(name: "Studio Launcher KH Helper", bundleID: "com.khupdater.agent",
                                         executableName: HelperBundle.helperExecutable, version: version,
                                         icon: FileManager.default.fileExists(atPath: icon.path) ? icon : nil)
            return try HelperBundle.ensure(spec, source: binary, out: layout.helperBundle(for: version))
        } catch {
            log("could not name \(version) in a helper bundle: \(error); running it by path")
            return binary
        }
    }

    private func spawn(_ binary: URL, nonce: String) -> Process? {
        let process = Process()
        process.executableURL = binary
        process.arguments = childArguments
        var environment = ProcessInfo.processInfo.environment
        environment[heartbeatNonceVariable] = nonce
        process.environment = environment
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
