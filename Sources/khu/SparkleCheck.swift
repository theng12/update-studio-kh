import AppKit
import Foundation

/// Thread-safe state tracker for `Studio Launcher KH sparkle-check`.
private final class SparkleCheckState: @unchecked Sendable {
    static let shared = SparkleCheckState()
    private let lock = NSLock()
    private var stateDir: URL?
    private var fromVersion = "unknown"
    private var holdURL = LauncherHold.url
    private var tokenFile = ""
    private var currentState: Int32 = 0
    private var sawUpdating = false
    private var sawRelaunching = false
    private var settledAt: Date?

    func configure(stateDir: URL, fromVersion: String, holdURL: String, tokenFile: String) {
        lock.lock()
        self.stateDir = stateDir
        self.fromVersion = fromVersion
        self.holdURL = holdURL
        self.tokenFile = tokenFile
        self.currentState = 0
        self.sawUpdating = false
        self.sawRelaunching = false
        self.settledAt = nil
        lock.unlock()
    }

    func onState(_ state: Int32) {
        lock.lock()
        currentState = state
        if state == 1 || state == 2 { sawUpdating = true }
        let wasRelaunching = sawRelaunching
        if state == 2 { sawRelaunching = true }
        if state == 0 { settledAt = Date() }
        let dir = stateDir
        let version = fromVersion
        let url = holdURL
        let token = tokenFile
        lock.unlock()

        if state == 1 {
            FileHandle.standardError.write(Data("sparkle-check: updating\n".utf8))
        } else if state == 2 {
            if let dir {
                SparkleRelaunchMarker.write(fromVersion: version, holdURL: url, tokenFile: token, in: dir)
            }
            FileHandle.standardError.write(Data("sparkle-check: relaunching\n".utf8))
        } else if state == 0, wasRelaunching, let dir {
            SparkleRelaunchMarker.clear(in: dir)
        }
    }

    func snapshot() -> (state: Int32, sawUpdating: Bool, sawRelaunching: Bool, settledAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        return (currentState, sawUpdating, sawRelaunching, settledAt)
    }
}

private func sparkleCheckCallback(_ state: Int32) {
    SparkleCheckState.shared.onState(state)
}

/// Headless Sparkle 2 self-update runner hosted by the packaged `Studio Launcher KH.app`, plus
/// the silent-relaunch handler that keeps a background self-update from popping up a window.
enum SparkleCheck {
    static let defaultIdleTimeout: TimeInterval = 60
    static let updatingTimeout: TimeInterval = 300
    static let settleGraceSeconds: TimeInterval = 0.5
    /// Sparkle 2's `checkForUpdatesInBackground` updates `SULastCheckTime` when the appcast check
    /// completes, and only calls `SPUUserDriver` if an update is found or an error occurs (it is
    /// silent on "no update found"). Waiting this grace window after `SULastCheckTime` advances
    /// lets any `state == 1` callback fire first, then cleanly releases the hold and exits 0.
    static let noUpdateGraceSeconds: TimeInterval = 2.0

    /// Called at the very start of `FrontDoor.run()` before AppKit shows any window or talks to
    /// the Helper. If a fresh `sparkle-relaunch` marker is present, removes it, releases the
    /// Helper's hold so queued work resumes right away, records a log line, and returns `true`
    /// so the relaunched app exits silently.
    static func handleSilentRelaunchIfPending() -> Bool {
        let info = Bundle.main.infoDictionary
        let stateDir = SparkleRelaunchMarker.stateDir(info: info)
        guard let record = SparkleRelaunchMarker.consumeIfFresh(in: stateDir) else {
            return false
        }
        let holdURL = record.holdURL.isEmpty
            ? ((info?["KHHoldURL"] as? String) ?? LauncherHold.url)
            : record.holdURL
        let tokenFile = record.tokenFile.isEmpty
            ? (info?["KHHoldTokenFile"] as? String)
            : record.tokenFile
        let released = SparkleRelaunchMarker.releaseHold(urlString: holdURL, tokenFile: tokenFile)
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let message = "sparkle: relaunched silently at \(version) (from \(record.fromVersion)); hold released=\(released)"
        appendLog(message, in: stateDir)
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return true
    }

    static func run(args: [String]) -> Never {
        var idleTimeout = ProcessInfo.processInfo.environment["KHU_SPARKLE_CHECK_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? defaultIdleTimeout
        var i = 1
        while i < args.count {
            if args[i] == "--timeout", i + 1 < args.count, let parsed = TimeInterval(args[i + 1]), parsed > 0 {
                idleTimeout = parsed
                i += 2
            } else {
                FileHandle.standardError.write(Data("usage: Studio Launcher KH sparkle-check [--timeout <seconds>]\n".utf8))
                exit(64)
            }
        }
        guard NSClassFromString("SPUUpdater") != nil else {
            FileHandle.standardError.write(Data("sparkle: Sparkle.framework is not in Contents/Frameworks; self-update is off, this app still updates through the feed\n".utf8))
            exit(2)
        }
        // Headless child: never activate, never appear in the Dock, zero windows.
        // Run NSApp.run() (not a bare CFRunLoop) so Sparkle's terminate request during swap
        // (`[NSApp terminate:nil]` / `kAEQuitApplication`) terminates this process promptly so
        // `Autoupdate` can replace the bundle and relaunch.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let info = Bundle.main.infoDictionary
        let stateDir = SparkleRelaunchMarker.stateDir(info: info)
        let holdURL = (info?["KHHoldURL"] as? String) ?? LauncherHold.url
        let tokenFile = (info?["KHHoldTokenFile"] as? String) ?? ""
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        SparkleCheckState.shared.configure(stateDir: stateDir, fromVersion: version,
                                           holdURL: holdURL, tokenFile: tokenFile)
        kh_sparkle_set_state_callback(sparkleCheckCallback)
        let rc = kh_sparkle_start()
        if rc != 0 {
            let why = String(cString: kh_sparkle_last_error())
            FileHandle.standardError.write(Data("sparkle-check: not started (\(why))\n".utf8))
            exit(1)
        }

        let startedAt = Date()
        let checkTimeBefore = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date
        var noUpdateCandidateAt: Date? = nil
        let watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let snap = SparkleCheckState.shared.snapshot()
            if let settledAt = snap.settledAt, Date().timeIntervalSince(settledAt) >= settleGraceSeconds {
                let why = String(cString: kh_sparkle_last_error())
                if why.contains("startUpdater failed") || why.contains("could not create an updater") {
                    _ = SparkleRelaunchMarker.releaseHold(urlString: holdURL, tokenFile: tokenFile)
                }
                if why.isEmpty {
                    FileHandle.standardError.write(Data("sparkle-check: settled (no update)\n".utf8))
                    exit(0)
                } else {
                    FileHandle.standardError.write(Data("sparkle-check: settled (\(why))\n".utf8))
                    exit(1)
                }
            }
            if !snap.sawUpdating && snap.settledAt == nil {
                if let checkTimeNow = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date,
                   checkTimeNow != checkTimeBefore,
                   checkTimeNow >= startedAt.addingTimeInterval(-1) {
                    if noUpdateCandidateAt == nil { noUpdateCandidateAt = Date() }
                    if let candidateAt = noUpdateCandidateAt,
                       Date().timeIntervalSince(candidateAt) >= noUpdateGraceSeconds {
                        let why = String(cString: kh_sparkle_last_error())
                        _ = SparkleRelaunchMarker.releaseHold(urlString: holdURL, tokenFile: tokenFile)
                        if why.isEmpty {
                            FileHandle.standardError.write(Data("sparkle-check: settled (no update)\n".utf8))
                            exit(0)
                        } else {
                            FileHandle.standardError.write(Data("sparkle-check: settled (\(why))\n".utf8))
                            exit(1)
                        }
                    }
                }
            } else {
                noUpdateCandidateAt = nil
            }
            let ceiling = snap.sawUpdating ? max(idleTimeout, updatingTimeout) : idleTimeout
            if Date().timeIntervalSince(startedAt) >= ceiling {
                SparkleRelaunchMarker.clear(in: stateDir)
                _ = SparkleRelaunchMarker.releaseHold(urlString: holdURL, tokenFile: tokenFile)
                FileHandle.standardError.write(Data("sparkle-check: timed out after \(Int(ceiling))s (state=\(snap.state))\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        app.run()
        exit(0)
    }

    private static func appendLog(_ message: String, in stateDir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let logFile = stateDir.appendingPathComponent("sparkle.log")
        LogFile.rotateIfNeeded(logFile)
        let line = "\(ISO.string(Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !fm.fileExists(atPath: logFile.path) {
            fm.createFile(atPath: logFile.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: logFile) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}
