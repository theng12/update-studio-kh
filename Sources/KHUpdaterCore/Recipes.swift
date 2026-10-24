import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct RecipeResult: Sendable, Equatable {
    public var status: String
    public var reason: String?
    public init(status: String, reason: String? = nil) { self.status = status; self.reason = reason }
}

/// What a recipe does to the outside world, injectable so tests never touch real apps.
public struct AppControl {
    /// true/false, or nil when it cannot be told (treated as running: it must then quit).
    public var isRunning: () -> Bool?
    /// Ask the app to quit; true once no process of it is left.
    public var quit: () -> Bool
    public var launch: () -> Void
    /// Stop a service that outlives its app (the Gateway server); true once it is gone AND its
    /// endpoint stays quiet. Ordinary apps have none.
    public var stopService: () -> Bool
    /// Healthy *as this version*: the new one after an install, the previous one after a rollback.
    public var healthy: (_ expectedVersion: String) -> Bool
    public var healthTimeout: TimeInterval
    public var pollInterval: TimeInterval
    public init(isRunning: @escaping () -> Bool?, quit: @escaping () -> Bool, launch: @escaping () -> Void,
                stopService: @escaping () -> Bool = { true }, healthy: @escaping (String) -> Bool,
                healthTimeout: TimeInterval = 60, pollInterval: TimeInterval = 1) {
        self.isRunning = isRunning; self.quit = quit; self.launch = launch; self.stopService = stopService
        self.healthy = healthy; self.healthTimeout = healthTimeout; self.pollInterval = pollInterval
    }
}

/// The parts of an app bundle an install is judged on, read from its Info.plist directly.
public struct BundleInfo: Equatable, Sendable {
    public var version: String
    public var identifier: String
    public var executable: String

    public static func read(_ appPath: String) throws -> BundleInfo {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw khuFail("\(appPath) has no readable Info.plist")
        }
        guard let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let identifier = dict["CFBundleIdentifier"] as? String, isBundleID(identifier),
              let executable = dict["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/") else {
            throw khuFail("\(appPath) is missing its version, a valid bundle identifier or its executable name")
        }
        return BundleInfo(version: version, identifier: identifier, executable: executable)
    }

    /// Reverse-DNS characters only: never anything that could close a quote in a script.
    public static func isBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 255 && id.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0)
        }
    }

    public func executableIsRunnable(in appPath: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: appPath + "/Contents/MacOS/" + executable)
    }
}

/// One install in flight, written before anything running is stopped and moved forward at each
/// step. A process killed half way leaves this behind, and the next run finishes or undoes it.
public struct InstallJournal: Codable, Sendable, Equatable {
    public var phase: String          // staged → moving → promoting → promoted
    public var installed: String
    public var staged: String
    public var rollback: String
    public var previousVersion: String?
    public var wasRunning: Bool
}

public enum Recipe {
    /// Install a DMG's app over `installedPath`. The order is the safety contract:
    ///
    /// 1. finish or undo any install a killed run left behind (`recover`);
    /// 2. verify the DMG — one .app, the feed's exact version, the expected bundle identifier, a
    ///    runnable executable — and copy it into a staging bundle beside the installed one, all
    ///    BEFORE anything running is touched;
    /// 3. quit the app and stop its service; if either refuses, nothing is replaced and the app is
    ///    relaunched if it was running;
    /// 4. the installed bundle becomes the rollback (the one before it goes to `_trash`), the staged
    ///    one is renamed into place; any failure from here restores the previous bundle;
    /// 5. relaunch (only if it was running) and wait for it to be healthy *as the new version*;
    /// 6. otherwise both must stop before the previous bundle goes back (else `rollback_blocked`,
    ///    both kept), and it must then be healthy *as the previous version*.
    public static func appDmg(shell: Shell, installedPath: String, artifactPath: String, feedVersion: String,
                              expectedBundleID: String?, stateDir: String, app: String, control: AppControl,
                              fileManager fm: FileManager = .default) throws -> RecipeResult {
        let paths = Paths(installedPath: installedPath, stateDir: stateDir, app: app)
        let recovered = try recover(paths, control: control, fileManager: fm)

        // 2. Verify and stage while the old app keeps running.
        let mount = try attach(shell, artifactPath)
        var mounted = true
        defer { if mounted { _ = detach(shell, mount) } }
        let source = try singleApp(in: mount, fileManager: fm)
        let info = try BundleInfo.read(source)
        guard info.version == feedVersion else {
            throw khuFail("DMG holds \(info.version), the feed says \(feedVersion); nothing was changed")
        }
        let installedInfo = fm.fileExists(atPath: installedPath) ? try? BundleInfo.read(installedPath) : nil
        if let want = expectedBundleID ?? installedInfo?.identifier, info.identifier != want {
            throw khuFail("DMG holds \(info.identifier), this Mac's app is \(want); nothing was changed")
        }
        guard info.executableIsRunnable(in: source) else { throw khuFail("the DMG's app has no runnable executable; nothing was changed") }

        if fm.fileExists(atPath: paths.staged.path) { try Trash.move(paths.staged, into: paths.trash, fileManager: fm) }
        let copy = try shell.run("/usr/bin/ditto", arguments: [source, paths.staged.path], timeout: 900)
        guard copy.exitCode == 0, let stagedInfo = try? BundleInfo.read(paths.staged.path), stagedInfo == info,
              stagedInfo.executableIsRunnable(in: paths.staged.path) else {
            _ = try? Trash.move(paths.staged, into: paths.trash, fileManager: fm)
            throw khuFail("copying the new app failed (\(copy.stderr.prefix(200))); nothing was changed")
        }
        mounted = false
        let detachNote = detach(shell, mount)  // the staged copy is all that is needed from here

        let wasRunning = control.isRunning() ?? true
        var journal = InstallJournal(phase: "staged", installed: installedPath, staged: paths.staged.path,
                                     rollback: paths.rollback.path,
                                     // Nothing installed: a rollback bundle kept from before is the previous version.
                                     previousVersion: installedInfo?.version ?? (try? BundleInfo.read(paths.rollback.path))?.version,
                                     wasRunning: wasRunning)
        try AtomicFile.writeJSON(journal, to: paths.journal)

        // 3. Stop what is running; on refusal, leave the old app as it was.
        func abandon(_ message: String) throws -> Never {
            if wasRunning && control.isRunning() != true { control.launch() }
            _ = try? Trash.move(paths.staged, into: paths.trash, fileManager: fm)
            _ = try? Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            throw khuFail(message)
        }
        guard control.quit() else { try abandon("the app did not quit; nothing was changed") }
        guard control.stopService() else { try abandon("the service did not stop; the old app was relaunched and nothing was changed") }

        // 4. Promote. Every throw from here restores the previous bundle before it is reported.
        do {
            if fm.fileExists(atPath: installedPath) {
                try fm.createDirectory(at: paths.rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: paths.rollback.path) { try Trash.move(paths.rollback, into: paths.trash, fileManager: fm) }
                journal.phase = "moving"; try AtomicFile.writeJSON(journal, to: paths.journal)
                try fm.moveItem(atPath: installedPath, toPath: paths.rollback.path)
            }
            // With nothing installed, an existing rollback bundle is kept: it is the only fallback.
            journal.phase = "promoting"; try AtomicFile.writeJSON(journal, to: paths.journal)
            try fm.moveItem(at: paths.staged, to: URL(fileURLWithPath: installedPath))
            journal.phase = "promoted"; try AtomicFile.writeJSON(journal, to: paths.journal)
        } catch {
            let restored = restoreAfterFailure(paths, journal: journal, fileManager: fm)
            if wasRunning { control.launch() }
            _ = try? Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            throw khuFail("installing failed (\(error)); \(restored)")
        }

        func finish(_ result: RecipeResult) -> RecipeResult {
            _ = try? Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            let notes = [recovered, detachNote].filter { !$0.isEmpty }
            guard !notes.isEmpty else { return result }
            return RecipeResult(status: result.status, reason: ([result.reason ?? ""] + notes).filter { !$0.isEmpty }.joined(separator: "; "))
        }

        // 5. Start it again only if it was running before.
        guard wasRunning else {
            return finish(RecipeResult(status: "updated", reason: "it was not running, so it was left stopped"))
        }
        control.launch()
        if waitHealthy(control, version: feedVersion) { return finish(RecipeResult(status: "updated")) }

        // 6. Roll back — only once both the app and its service are really gone.
        guard control.quit(), control.stopService() else {
            return finish(RecipeResult(status: "rollback_blocked", reason:
                "the new version was unhealthy and would not stop; both versions were kept (previous at \(paths.rollback.path))"))
        }
        guard let previousVersion = journal.previousVersion, fm.fileExists(atPath: paths.rollback.path) else {
            control.launch()
            return finish(RecipeResult(status: "rollback_failed", reason: "the new version was unhealthy and there was no previous version; it was started again"))
        }
        do {
            try putBack(paths, expectedVersion: previousVersion, fileManager: fm)
        } catch {
            return finish(RecipeResult(status: "rollback_failed", reason: "the new version was unhealthy and the previous one could not be put back: \(error)"))
        }
        control.launch()
        return finish(waitHealthy(control, version: previousVersion)
            ? RecipeResult(status: "rolled_back", reason: "the new version was not healthy within \(Int(control.healthTimeout)) s; \(previousVersion) is running again")
            : RecipeResult(status: "rollback_unhealthy", reason: "the new version was unhealthy, and the restored \(previousVersion) is not healthy either"))
    }

    struct Paths {
        let installedPath: String
        let staged: URL
        let rollback: URL
        let trash: URL
        let journal: URL
        init(installedPath: String, stateDir: String, app: String) {
            let installed = URL(fileURLWithPath: installedPath)
            self.installedPath = installedPath
            // Beside the installed app, so promotion is a rename on the same volume.
            staged = installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).khu-staging")
            let state = URL(fileURLWithPath: stateDir)
            rollback = state.appendingPathComponent("rollback-\(app)").appendingPathComponent(installed.lastPathComponent)
            trash = Trash.root(in: state)
            journal = state.appendingPathComponent("install-\(app).json")
        }
    }

    /// Finish or undo what a killed run left behind. Returns a note for the result ("" if nothing).
    @discardableResult
    public static func recover(installedPath: String, stateDir: String, app: String, control: AppControl,
                               fileManager fm: FileManager = .default) throws -> String {
        try recover(Paths(installedPath: installedPath, stateDir: stateDir, app: app), control: control, fileManager: fm)
    }

    static func recover(_ paths: Paths, control: AppControl, fileManager fm: FileManager) throws -> String {
        guard let journal = try AtomicFile.readJSON(InstallJournal.self, from: paths.journal) else { return "" }
        var note: String
        if fm.fileExists(atPath: paths.installedPath) {
            // Either nothing was moved yet, or the new bundle was already in place.
            note = journal.phase == "staged" ? "an interrupted install was undone before anything moved"
                                             : "an interrupted install had finished putting the new version in place"
        } else {
            note = restoreAfterFailure(paths, journal: journal, fileManager: fm)
        }
        if fm.fileExists(atPath: paths.staged.path) { try Trash.move(paths.staged, into: paths.trash, fileManager: fm) }
        if journal.wasRunning && control.isRunning() == false { control.launch(); note += "; it was started again" }
        try Trash.move(paths.journal, into: paths.trash, fileManager: fm)
        return note
    }

    /// The installed path is empty or wrong: put the rollback bundle back if there is one.
    static func restoreAfterFailure(_ paths: Paths, journal: InstallJournal, fileManager fm: FileManager) -> String {
        guard !fm.fileExists(atPath: paths.installedPath) else {
            return journal.phase == "promoting" || journal.phase == "promoted"
                ? "the new version is in place" : "the previous app was not touched"
        }
        guard fm.fileExists(atPath: paths.rollback.path) else {
            return "NO APP IS INSTALLED at \(paths.installedPath) and there is no previous bundle to put back"
        }
        do {
            try fm.moveItem(at: paths.rollback, to: URL(fileURLWithPath: paths.installedPath))
            return "the previous app was put back"
        } catch {
            return "NO APP IS INSTALLED at \(paths.installedPath): putting the previous one back failed (\(error)); it is at \(paths.rollback.path)"
        }
    }

    /// Unhealthy new bundle to `_trash`, previous bundle back — and proven to be the previous version.
    static func putBack(_ paths: Paths, expectedVersion: String, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: paths.installedPath) {
            try Trash.move(URL(fileURLWithPath: paths.installedPath), into: paths.trash, fileManager: fm)
        }
        try fm.moveItem(at: paths.rollback, to: URL(fileURLWithPath: paths.installedPath))
        let restored = try BundleInfo.read(paths.installedPath)
        guard restored.version == expectedVersion else {
            throw khuFail("the bundle put back is \(restored.version), not \(expectedVersion)")
        }
    }

    static func waitHealthy(_ control: AppControl, version: String) -> Bool {
        let deadline = Mono.now() + control.healthTimeout
        repeat {
            if control.healthy(version) { return true }
            Thread.sleep(forTimeInterval: control.pollInterval)
        } while Mono.now() < deadline
        return control.healthy(version)
    }

    static func attach(_ shell: Shell, _ artifactPath: String) throws -> String {
        let attach = try shell.run("/usr/bin/hdiutil",
                                   arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", artifactPath], timeout: 180)
        guard attach.exitCode == 0 else { throw khuFail("hdiutil attach failed: \(attach.stderr.prefix(200))") }
        guard let mount = mountPoint(fromPlist: attach.stdout) else {
            // Attached but unreadable: detach whatever this DMG became before giving up.
            _ = try? shell.run("/usr/bin/hdiutil", arguments: ["detach", "-force", artifactPath], timeout: 60)
            throw khuFail("could not determine the DMG mount point")
        }
        return mount
    }

    /// Returns "" on success, or a note saying the image is still mounted.
    static func detach(_ shell: Shell, _ mount: String) -> String {
        for arguments in [["detach", mount], ["detach", "-force", mount]] {
            if let result = try? shell.run("/usr/bin/hdiutil", arguments: arguments, timeout: 60), result.exitCode == 0 { return "" }
        }
        return "the DMG is still mounted at \(mount)"
    }

    static func mountPoint(fromPlist output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first { $0.hasPrefix("/") }
    }

    static func singleApp(in mount: String, fileManager fm: FileManager) throws -> String {
        let names = (try? fm.contentsOfDirectory(atPath: mount)) ?? []
        let apps = names.filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }
        guard apps.count == 1 else { throw khuFail("expected exactly one .app in the DMG, found \(apps.count); nothing was changed") }
        return mount + "/" + apps[0]
    }
}

/// Real `AppControl`s for this Mac. Every external call is an absolute path with a bounded timeout,
/// and a process is only ever identified by its executable's real path inside the bundle.
public enum LiveControl {
    /// Processes whose executable lives inside this bundle, or nil when the table cannot be read.
    /// The kernel's own spelling of a path (`realpath(3)`), which is what `proc_pidpath` reports.
    /// Foundation's `resolvingSymlinksInPath` drops `/private` and would never match.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func processes(inBundle installedPath: String) -> [pid_t]? {
        let prefix = realPath(installedPath) + "/Contents/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        return pids.prefix(Int(got)).filter { $0 > 0 && (executablePath($0)?.hasPrefix(prefix) ?? false) }
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func isRunning(_ installedPath: String) -> Bool? {
        processes(inBundle: installedPath).map { !$0.isEmpty }
    }

    /// Ask the app to quit by bundle id — passed as an argument, never spliced into the script —
    /// and wait up to `wait` seconds for every process of it to leave.
    public static func quit(_ installedPath: String, shell: Shell, wait: TimeInterval = 60) -> Bool {
        guard isRunning(installedPath) != false else { return true }
        guard let id = try? BundleInfo.read(installedPath).identifier else { return false }
        _ = try? shell.run("/usr/bin/osascript", arguments: [
            "-e", "on run argv", "-e", "tell application id (item 1 of argv) to quit", "-e", "end run", id,
        ], timeout: 30)
        let deadline = Mono.now() + wait
        while Mono.now() < deadline {
            if isRunning(installedPath) == false { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return isRunning(installedPath) == false
    }

    public static func appDmg(_ installedPath: String, shell: Shell) -> AppControl {
        AppControl(
            isRunning: { isRunning(installedPath) },
            quit: { quit(installedPath, shell: shell) },
            launch: { _ = try? shell.run("/usr/bin/open", arguments: [installedPath], timeout: 30) },
            healthy: { expected in
                (try? BundleInfo.read(installedPath).version) == expected && isRunning(installedPath) == true
            },
            healthTimeout: 60)
    }

    /// The Gateway: its server outlives the menu-bar app. It is stopped by the PID its /health
    /// reports — only after checking that PID really runs from this bundle — with SIGTERM only, and
    /// counts as stopped once the port stays quiet. Healthy means /health answers 200 from a
    /// process of this bundle, the bundle on disk is the expected version, and the app runs.
    public static func gateway(_ installedPath: String, shell: Shell, port: Int = 8787) -> AppControl {
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let prefix = realPath(installedPath) + "/Contents/"
        func probe() -> (code: Int, pid: pid_t?) {
            var req = URLRequest(url: health); req.timeoutInterval = 5
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: (Int, pid_t?) = (0, nil)
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, (body?["pid"] as? NSNumber)?.int32Value)
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
            return out
        }
        func ours(_ pid: pid_t?) -> Bool { pid.map { $0 > 1 && (executablePath($0)?.hasPrefix(prefix) ?? false) } ?? false }
        func quiet() -> Bool {
            for _ in 0..<3 {
                if probe().code != 0 { return false }
                Thread.sleep(forTimeInterval: 1)
            }
            return true
        }
        var control = appDmg(installedPath, shell: shell)
        control.stopService = {
            let answer = probe()
            if answer.code == 0 { return quiet() }
            // Something answers that is not this Gateway: never signal it, and do not install over it.
            guard ours(answer.pid), let pid = answer.pid else { return false }
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
            let deadline = Mono.now() + 60
            while Mono.now() < deadline, kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 1) }
            return kill(pid, 0) != 0 && quiet()
        }
        let appHealthy = control.healthy
        control.healthy = { expected in
            let answer = probe()
            return answer.code == 200 && ours(answer.pid) && appHealthy(expected)
        }
        control.healthTimeout = 120
        return control
    }
}
