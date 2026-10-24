import Foundation

public struct RecipeResult: Sendable, Equatable {
    public var status: String
    public var reason: String?
    public init(status: String, reason: String? = nil) { self.status = status; self.reason = reason }
}

/// What a recipe does to the outside world, injectable so tests never touch real apps.
///
/// Order of an install is the safety contract (owner, 2026-10-24):
/// 1. verify the DMG (one .app, the feed's exact version) BEFORE anything running is touched;
/// 2. quit the app, then `stopService` (the Gateway server, which outlives its app); if either will
///    not stop, the old app is relaunched and nothing is replaced;
/// 3. the installed bundle moves to the rollback folder (the one before it goes to `_trash`, never
///    deleted), the new bundle is copied in, the app is relaunched and must pass `healthy` in time;
/// 4. otherwise the new bundle goes to `_trash`, the previous one is put back, relaunched and
///    checked again, and the result says which of the two happened.
public struct AppControl {
    public var quit: () -> Bool
    public var launch: () -> Void
    public var stopService: () -> Bool
    public var healthy: () -> Bool
    public var healthTimeout: TimeInterval
    public var pollInterval: TimeInterval
    public init(quit: @escaping () -> Bool, launch: @escaping () -> Void,
                stopService: @escaping () -> Bool = { true }, healthy: @escaping () -> Bool,
                healthTimeout: TimeInterval = 60, pollInterval: TimeInterval = 1) {
        self.quit = quit; self.launch = launch; self.stopService = stopService
        self.healthy = healthy; self.healthTimeout = healthTimeout; self.pollInterval = pollInterval
    }
}

public enum Recipe {
    public static func appDmg(shell: Shell, installedPath: String, artifactPath: String, feedVersion: String,
                              rollbackDir: String, trashDir: String, control: AppControl,
                              fileManager fm: FileManager = .default) throws -> RecipeResult {
        let attach = try shell.run("/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", artifactPath], timeout: 120)
        guard attach.exitCode == 0 else { throw khuFail("hdiutil attach failed: \(attach.stderr)") }
        let mount = mountPoint(from: attach.stdout)
        guard !mount.isEmpty else { throw khuFail("could not determine the DMG mount point") }
        func detach() { _ = try? shell.run("/usr/bin/hdiutil", arguments: ["detach", mount], timeout: 60) }

        // 1. Verify the artifact before touching anything that is running.
        let found = try shell.run("/usr/bin/find", arguments: [mount, "-maxdepth", "1", "-type", "d", "-name", "*.app"], timeout: 60)
        let apps = found.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard apps.count == 1 else { detach(); throw khuFail("expected exactly one .app in the DMG, found \(apps.count)") }
        let source = apps[0]
        let version = try shell.run("/usr/bin/defaults", arguments: ["read", source + "/Contents/Info.plist", "CFBundleShortVersionString"], timeout: 30)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == feedVersion else { detach(); throw khuFail("DMG holds \(version), the feed says \(feedVersion); nothing was changed") }

        // 2. Stop what is running; on refusal, leave the old app running.
        guard control.quit() else { detach(); throw khuFail("the app did not quit; nothing was changed") }
        guard control.stopService() else {
            control.launch(); detach()
            throw khuFail("the service did not stop; the old app was relaunched and nothing was changed")
        }

        // 3. Keep one previous bundle, copy the new one in.
        let name = (installedPath as NSString).lastPathComponent
        let rollback = URL(fileURLWithPath: rollbackDir).appendingPathComponent(name)
        let installed = URL(fileURLWithPath: installedPath)
        let trash = URL(fileURLWithPath: trashDir)
        try fm.createDirectory(at: rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: rollback.path) { try Trash.move(rollback, into: trash, fileManager: fm) }
        let hadPrevious = fm.fileExists(atPath: installed.path)
        if hadPrevious { try fm.moveItem(at: installed, to: rollback) }

        func restorePrevious() {
            if fm.fileExists(atPath: installed.path) { _ = try? Trash.move(installed, into: trash, fileManager: fm) }
            if hadPrevious { try? fm.moveItem(at: rollback, to: installed) }
        }

        let copy = try shell.run("/usr/bin/ditto", arguments: [source, installedPath], timeout: 600)
        detach()
        guard copy.exitCode == 0 else {
            restorePrevious(); if hadPrevious { control.launch() }
            throw khuFail("copying the new app failed (\(copy.stderr)); the previous app was put back")
        }

        control.launch()
        if waitHealthy(control) { return RecipeResult(status: "updated") }

        // 4. Roll back.
        _ = control.quit()
        guard control.stopService() else {
            return RecipeResult(status: "rollback_failed", reason: "the new version was unhealthy and its service would not stop; nothing was restored")
        }
        restorePrevious()
        guard hadPrevious else { return RecipeResult(status: "rollback_failed", reason: "the new version was unhealthy and there was no previous version") }
        control.launch()
        return waitHealthy(control)
            ? RecipeResult(status: "rolled_back", reason: "the new version was not healthy within \(Int(control.healthTimeout)) s; the previous version is running")
            : RecipeResult(status: "rollback_unhealthy", reason: "the new version was unhealthy, and the restored previous version is not healthy either")
    }

    static func waitHealthy(_ control: AppControl) -> Bool {
        let deadline = Date().addingTimeInterval(control.healthTimeout)
        repeat {
            if control.healthy() { return true }
            Thread.sleep(forTimeInterval: control.pollInterval)
        } while Date() < deadline
        return control.healthy()
    }

    static func mountPoint(from output: String) -> String {
        // hdiutil prints tab-separated rows; the mount point is the last field of the row that has one.
        for line in output.split(separator: "\n").reversed() {
            if let field = line.split(separator: "\t").last.map({ String($0).trimmingCharacters(in: .whitespaces) }),
               field.hasPrefix("/") { return field }
        }
        return ""
    }
}

/// Real `AppControl`s for this Mac. Every external call is an absolute path with a bounded timeout.
public enum LiveControl {
    public static func bundleID(_ installedPath: String, shell: Shell) -> String? {
        let out = try? shell.run("/usr/bin/defaults", arguments: ["read", installedPath + "/Contents/Info.plist", "CFBundleIdentifier"], timeout: 15)
        let id = out?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    static func running(_ installedPath: String, shell: Shell) -> Bool {
        (try? shell.run("/usr/bin/pgrep", arguments: ["-f", installedPath + "/Contents/MacOS/"], timeout: 15))?.exitCode == 0
    }

    /// Ask the app to quit (by bundle id) and wait up to `wait` seconds for its process to leave.
    public static func quit(_ installedPath: String, shell: Shell, wait: TimeInterval = 60) -> Bool {
        guard running(installedPath, shell: shell) else { return true }
        guard let id = bundleID(installedPath, shell: shell) else { return false }
        _ = try? shell.run("/usr/bin/osascript", arguments: ["-e", "tell application id \"\(id)\" to quit"], timeout: 30)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if !running(installedPath, shell: shell) { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return !running(installedPath, shell: shell)
    }

    public static func appDmg(_ installedPath: String, feedVersion: String, shell: Shell) -> AppControl {
        AppControl(
            quit: { quit(installedPath, shell: shell) },
            launch: { _ = try? shell.run("/usr/bin/open", arguments: [installedPath], timeout: 30) },
            healthy: {
                let v = (try? shell.run("/usr/bin/defaults", arguments: ["read", installedPath + "/Contents/Info.plist", "CFBundleShortVersionString"], timeout: 15))?
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return v == feedVersion && running(installedPath, shell: shell)
            },
            healthTimeout: 60)
    }

    /// The Gateway: its server outlives the menu-bar app, so it is stopped by the PID its own /health
    /// reports, with SIGTERM only (never SIGKILL), and healthy means /health answers 200 again.
    public static func gateway(_ installedPath: String, feedVersion: String, shell: Shell, port: Int = 8787) -> AppControl {
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        func probe() -> (Int, [String: Any]?) {
            var req = URLRequest(url: health); req.timeoutInterval = 5
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: (Int, [String: Any]?) = (0, nil)
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                out = ((resp as? HTTPURLResponse)?.statusCode ?? 0,
                       data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
            return out
        }
        var control = appDmg(installedPath, feedVersion: feedVersion, shell: shell)
        control.stopService = {
            let (code, body) = probe()
            guard code == 200, let pid = (body?["pid"] as? NSNumber)?.int32Value, pid > 1 else { return code == 0 }
            guard kill(pid, SIGTERM) == 0 else { return kill(pid, 0) != 0 }
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if kill(pid, 0) != 0 { return true }
                Thread.sleep(forTimeInterval: 1)
            }
            return kill(pid, 0) != 0
        }
        let appHealthy = control.healthy
        control.healthy = { probe().0 == 200 && appHealthy() }
        control.healthTimeout = 120
        return control
    }
}
