import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct RecipeResult: Sendable, Equatable {
    public var status: String
    public var reason: String?
    /// The version the app was on *before* this result, when the recipe knows it: an owner rollback
    /// names the version it moved away from, so the agent can reject that exact artifact.
    public var version: String?
    public init(status: String, reason: String? = nil, version: String? = nil) {
        self.status = status; self.reason = reason; self.version = version
    }
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
    /// How long the app must stay healthy without a break before an install is accepted: an app that
    /// launches and dies a moment later was once reported "updated" (live proof, 2026-10-25).
    public var healthSettle: TimeInterval
    public init(isRunning: @escaping () -> Bool?, quit: @escaping () -> Bool, launch: @escaping () -> Void,
                stopService: @escaping () -> Bool = { true }, healthy: @escaping (String) -> Bool,
                healthTimeout: TimeInterval = 60, pollInterval: TimeInterval = 1, healthSettle: TimeInterval = 10) {
        self.isRunning = isRunning; self.quit = quit; self.launch = launch; self.stopService = stopService
        self.healthy = healthy; self.healthTimeout = healthTimeout; self.pollInterval = pollInterval
        self.healthSettle = healthSettle
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

    /// A runnable executable, and a real file: a symlinked one runs as its *target*, so
    /// `proc_pidpath` would report a path outside the bundle — the app could never be seen running,
    /// asked to quit, or judged healthy, and an install could replace it while it was up.
    public func executableIsRunnable(in appPath: String) -> Bool {
        let path = appPath + "/Contents/MacOS/" + executable
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              RealPath.of(path).hasPrefix(RealPath.of(appPath) + "/Contents/") else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

/// One install in flight, written before anything running is stopped and moved forward at each
/// step. A process killed half way leaves this behind, and the next run finishes or undoes it.
public struct InstallJournal: Codable, Sendable, Equatable {
    public var phase: String          // staged → moving → promoting → promoted → rolling_back
    public var installed: String
    public var staged: String
    public var rollback: String
    public var previousVersion: String?
    public var wasRunning: Bool
    /// The version this install is putting in place, so a recovered journal can prove which side it
    /// found at `installed`. Absent in a journal written before it existed.
    public var version: String? = nil
    /// The owner order this swap belongs to, when there was one: recovery answers that order from
    /// what it finds on disk instead of running it again.
    public var order: String? = nil
    /// `owner_rollback` for a swap the owner ordered; absent for an install.
    public var intent: String? = nil
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
    /// 6. otherwise both must stop before the previous bundle goes back, and it must then be healthy
    ///    *as the previous version*. A rollback that cannot be finished — the bad version will not
    ///    stop, the previous bundle cannot be put back, or there is no previous bundle at all —
    ///    leaves the journal in place, so the next run retries instead of reporting an app that is
    ///    merely the new version as settled.
    public static func appDmg(shell: Shell, installedPath: String, artifactPath: String, feedVersion: String,
                              expectedBundleID: String?, stateDir: String, app: String, control: AppControl,
                              fileManager fm: FileManager = .default,
                              verifyStaged: ((String) throws -> Void)? = nil) throws -> RecipeResult {
        let paths = Paths(installedPath: installedPath, stateDir: stateDir, app: app)
        let recovered = try recover(paths, control: control, fileManager: fm)
        guard !fm.fileExists(atPath: paths.journal.path) else {
            throw khuFail("the earlier install is unresolved; journal kept at \(paths.journal.path)")
        }

        // 2. Verify and stage while the old app keeps running.
        let (mount, device) = try attach(shell, artifactPath)
        var mounted = true
        defer { if mounted { _ = detach(shell, device) } }
        let source = try singleApp(in: mount, fileManager: fm)
        let info: BundleInfo
        do { info = try BundleInfo.read(source) }
        catch { throw ArtifactFailure(description: "the DMG's bundle is invalid: \(error)") }
        guard info.version == feedVersion else {
            throw ArtifactFailure(description: "DMG holds \(info.version), the feed says \(feedVersion); nothing was changed")
        }
        let installedInfo = fm.fileExists(atPath: installedPath) ? try? BundleInfo.read(installedPath) : nil
        if let want = expectedBundleID ?? installedInfo?.identifier, info.identifier != want {
            throw ArtifactFailure(description: "DMG holds \(info.identifier), this Mac's app is \(want); nothing was changed")
        }
        guard info.executableIsRunnable(in: source) else { throw ArtifactFailure(description: "the DMG's app has no runnable executable; nothing was changed") }

        try stage(paths, from: source, info: info, shell: shell, fileManager: fm)
        do { try verifyStaged?(paths.staged.path) }
        catch {
            _ = try? Trash.move(paths.staged, into: paths.trash, fileManager: fm)
            throw error
        }
        mounted = false
        let detachNote = detach(shell, device)  // the staged copy is all that is needed from here

        return try promoteAndSettle(paths: paths, targetVersion: feedVersion, installedInfo: installedInfo,
                                    order: nil, control: control, fileManager: fm, notes: [recovered, detachNote])
    }

    /// The owner's order to put this app's kept previous version back. It is the same swap as an
    /// install — the same journal, the same quit/stop, the same promotion and the same health
    /// window — with two differences: the source is the bundle this Mac already kept instead of a
    /// DMG, and what has to come up healthy is the OLDER version. Everything is verified before
    /// anything running is touched, so a refusal costs the app nothing.
    public static func ownerRollback(shell: Shell, installedPath: String, stateDir: String, app: String,
                                     expectedBundleID: String?, order: String, control: AppControl,
                                     fileManager fm: FileManager = .default) throws -> RecipeResult {
        let paths = Paths(installedPath: installedPath, stateDir: stateDir, app: app)
        let recovered = try recover(paths, control: control, fileManager: fm)
        if fm.fileExists(atPath: paths.journal.path) {
            return RecipeResult(status: "unresolved", reason: "an earlier install of \(app) could not be finished or undone; "
                               + "\(paths.journal.path) is kept and the next run tries it again")
        }
        guard let installedInfo = try? BundleInfo.read(installedPath) else {
            return RecipeResult(status: "refused", reason: "\(app) has no readable app at \(installedPath), so there is no version to roll back from")
        }
        let kept: BundleInfo
        do { kept = try BundleInfo.read(paths.rollback.path) }
        catch {
            return RecipeResult(status: "refused", reason: "no previous version is kept on this Mac for \(app) "
                               + "(\(paths.rollback.path): \(error))")
        }
        let want = expectedBundleID ?? installedInfo.identifier
        if kept.identifier != want {
            return RecipeResult(status: "refused", reason: "the kept bundle is \(kept.identifier), this Mac's app is \(want); refused")
        }
        guard kept.executableIsRunnable(in: paths.rollback.path) else {
            return RecipeResult(status: "refused", reason: "the kept bundle at \(paths.rollback.path) has no runnable executable; refused")
        }
        guard let order_ = VersionCompare.compare(kept.version, installedInfo.version) else {
            return RecipeResult(status: "refused", reason: "the kept version \(kept.version) and the installed \(installedInfo.version) cannot be compared; refused")
        }
        guard order_ < 0 else {
            return RecipeResult(status: "refused", reason: "the kept version \(kept.version) is not older than \(installedInfo.version) installed here; refused")
        }
        // What goes back is a bundle this Mac stopped running some time ago, so it has to be proven
        // to be the same signed app — the one the system will let run. The bundle that will RUN is
        // the one strictly verified here; the installed side only has to be identifiable, because a
        // locally built or linker-signed app can fail `--verify --strict` while still being exactly
        // the app this Mac is running.
        guard let keptIdentity = signingIdentity(paths.rollback.path, shell: shell) else {
            return RecipeResult(status: "refused", reason: "the kept bundle at \(paths.rollback.path) is not code-signed; refused")
        }
        guard signatureVerifies(paths.rollback.path, shell: shell) else {
            return RecipeResult(status: "refused", reason: "the kept bundle at \(paths.rollback.path) does not verify: it has been altered "
                               + "since it was signed; refused")
        }
        guard let installedIdentity = signingIdentity(installedPath, shell: shell) else {
            return RecipeResult(status: "refused", reason: "\(installedPath) is not code-signed, so this Mac cannot prove the kept bundle "
                               + "is the same app; refused")
        }
        guard keptIdentity == installedIdentity else {
            return RecipeResult(status: "refused", reason: "the kept bundle at \(paths.rollback.path) is \(keptIdentity), and the app installed "
                               + "at \(installedPath) is \(installedIdentity); refused")
        }
        try stage(paths, from: paths.rollback.path, info: kept, shell: shell, fileManager: fm)
        guard signingIdentity(paths.staged.path, shell: shell) == keptIdentity,
              signatureVerifies(paths.staged.path, shell: shell) else {
            _ = try? Trash.move(paths.staged, into: paths.trash, fileManager: fm)
            return RecipeResult(status: "refused", reason: "the staged copy of \(kept.version) at \(paths.staged.path) does not verify as "
                               + "\(keptIdentity); nothing was changed")
        }
        return try promoteAndSettle(paths: paths, targetVersion: kept.version, installedInfo: installedInfo,
                                    order: order, control: control, fileManager: fm, notes: [recovered])
    }

    /// Copy a verified bundle into the staging path beside the installed one and check the copy —
    /// always before anything running is stopped. `ditto` carries the bundle's own signature over.
    static func stage(_ paths: Paths, from source: String, info: BundleInfo, shell: Shell, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: paths.staged.path) { try Trash.move(paths.staged, into: paths.trash, fileManager: fm) }
        let copy = try shell.run("/usr/bin/ditto", arguments: [source, paths.staged.path], timeout: 900)
        guard copy.exitCode == 0, let stagedInfo = try? BundleInfo.read(paths.staged.path), stagedInfo == info,
              stagedInfo.executableIsRunnable(in: paths.staged.path) else {
            _ = try? Trash.move(paths.staged, into: paths.trash, fileManager: fm)
            throw khuFail("copying the new app failed (\(copy.stderr.prefix(200))); nothing was changed")
        }
    }

    /// The code signature identity of a bundle (`Identifier|TeamIdentifier`), read from `codesign -dvv`
    /// whether or not the bundle's seal is intact. A linker-signed or locally-rebuilt app can fail
    /// `--verify --strict` while still being exactly the app this Mac is running, so identity is
    /// read without a verify gate; the verify gate is its own call (`signatureVerifies`), applied
    /// only to the bundle that will actually run.
    public static func signingIdentity(_ appPath: String, shell: Shell) -> String? {
        guard let described = try? shell.run("/usr/bin/codesign", arguments: ["-dvv", appPath], timeout: 60) else { return nil }
        let text = described.stdout + described.stderr
        func field(_ name: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard let identifier = field("Identifier"), !identifier.isEmpty else { return nil }
        return identifier + "|" + (field("TeamIdentifier") ?? "")
    }

    /// `codesign --verify --strict` passed on this bundle. The system's own verdict on whether the
    /// bytes on disk match the signature — applied to the bundle that will RUN (the kept bundle,
    /// and again on its staged copy), not to the installed one: an installed app that was locally
    /// rebuilt or linker-signed still has a readable identity, and a rollback must not refuse
    /// because of it.
    public static func signatureVerifies(_ appPath: String, shell: Shell) -> Bool {
        (try? shell.run("/usr/bin/codesign", arguments: ["--verify", "--strict", appPath], timeout: 60))?.exitCode == 0
    }

    /// From the journal onward: stop what is running, promote the staged bundle, and require the
    /// version that went in to be healthy and to stay healthy. An owner order runs through exactly
    /// this path, so its swap and its fallback are the install's own.
    static func promoteAndSettle(paths: Paths, targetVersion: String, installedInfo: BundleInfo?,
                                 order: String?, control: AppControl, fileManager fm: FileManager,
                                 notes: [String]) throws -> RecipeResult {
        let installedPath = paths.installedPath
        let wasRunning = control.isRunning() ?? true
        var journal = InstallJournal(phase: "staged", installed: installedPath, staged: paths.staged.path,
                                     rollback: paths.rollback.path,
                                     // Nothing installed: a rollback bundle kept from before is the previous version.
                                     previousVersion: installedInfo?.version ?? (try? BundleInfo.read(paths.rollback.path))?.version,
                                     wasRunning: wasRunning, version: targetVersion)
        journal.order = order
        journal.intent = order == nil ? nil : "owner_rollback"
        // The version this swap moves away from: an owner rollback reports it, so the agent can
        // reject that exact artifact instead of the one it installs.
        let displaced = journal.previousVersion
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
            let cause = error
            let restored: String
            do { restored = try restoreAfterFailure(journal, fileManager: fm) }
            catch { throw khuFail("installing failed (\(cause)); \(error); recovery journal kept at \(paths.journal.path)") }
            if wasRunning { control.launch() }
            try Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            throw khuFail("installing failed (\(cause)); \(restored)")
        }

        func finish(_ result: RecipeResult) -> RecipeResult {
            _ = try? Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            let all = notes.filter { !$0.isEmpty }
            guard !all.isEmpty else { return result }
            return RecipeResult(status: result.status,
                                reason: ([result.reason ?? ""] + all).filter { !$0.isEmpty }.joined(separator: "; "),
                                version: result.version)
        }
        /// An owner order reports the owner's question: `\(targetVersion)` coming back, not an
        /// install of it. The fallback version going back healthy is a failed rollback, not a
        /// successful install.
        func settled(_ result: RecipeResult) -> RecipeResult {
            guard order != nil else { return result }
            func answered(_ status: String, _ reason: String?) -> RecipeResult {
                RecipeResult(status: status, reason: reason, version: displaced)
            }
            switch result.status {
            case "updated": return answered("rolled_back_by_owner", result.reason)
            case "rolled_back": return answered("rollback_failed", "\(targetVersion) was not healthy within "
                                                + "\(Int(control.healthTimeout)) s, so \(displaced ?? "the version this Mac was running") was put back")
            case "rollback_unhealthy": return answered("rollback_unhealthy", "\(targetVersion) was not healthy, and putting "
                                                       + "\(displaced ?? "the version this Mac was running") back did not come up healthy either")
            default: return result
            }
        }

        // 5. Preserve stopped updates; a first install always needs a live health check.
        guard wasRunning || journal.previousVersion == nil else {
            return finish(settled(RecipeResult(status: "updated", reason: "it was not running, so it was left stopped")))
        }
        control.launch()
        if waitHealthy(control, version: targetVersion) { return finish(settled(RecipeResult(status: "updated"))) }

        // 6. Roll back — only once both the app and its service are really gone.
        guard control.quit(), control.stopService() else {
            // Both bundles stay, and so does the journal: the next run asks the bad version to stop
            // again instead of finding the new version in place and calling the app settled.
            return settled(RecipeResult(status: "rollback_blocked", reason:
                "\(targetVersion) was unhealthy and would not stop; both versions were kept (previous at "
                + "\(paths.rollback.path)) and \(paths.journal.path) with them — the next run tries again"))
        }
        do {
            let result = try rollBack(paths, journal: journal, control: control, fileManager: fm)
            return result.status == "rolled_back" ? finish(settled(result)) : settled(result)
        } catch {
            // Nothing was written away: the journal stays exactly as it is, and a later run picks
            // the rollback up again rather than reporting a Mac whose app is simply the new version.
            return settled(RecipeResult(status: "rollback_failed", reason:
                "\(targetVersion) was unhealthy and \(displaced ?? "the version this Mac was running") could not be put back (\(error)); "
                + "nothing was reported as settled and \(paths.journal.path) is kept — the next run tries again"))
        }
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
            journal = Recipe.journalURL(stateDir: stateDir, app: app)
        }
    }

    /// Where one app's install journal lives: `recover` reads it, a rollback that could not be
    /// finished keeps it, and the agent refuses to call that app settled while it is there.
    public static func journalURL(stateDir: String, app: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent("install-\(app).json")
    }

    /// True while an install this Mac could not finish or undo is still outstanding — the journal is
    /// kept for exactly that reason, so nothing may report that app as settled until it is gone.
    public static func isUnresolved(stateDir: String, app: String) -> Bool {
        FileManager.default.fileExists(atPath: journalURL(stateDir: stateDir, app: app).path)
    }

    /// Finish or undo what a killed run left behind. Returns a note for the result ("" if nothing).
    @discardableResult
    public static func recover(installedPath: String, stateDir: String, app: String, control: AppControl,
                               fileManager fm: FileManager = .default,
                               controlForPath: ((String) -> AppControl)? = nil) throws -> String {
        let paths = Paths(installedPath: installedPath, stateDir: stateDir, app: app)
        if let journal = try AtomicFile.readJSON(InstallJournal.self, from: paths.journal),
           RealPath.of(journal.installed) != RealPath.of(installedPath) {
            if let controlForPath {
                return try recover(paths, control: controlForPath(journal.installed), fileManager: fm)
            }
            // A control for a different app cannot safely launch or judge the journal's app.
            if !fm.fileExists(atPath: journal.installed) { _ = try restoreAfterFailure(journal, fileManager: fm) }
            return "recovery restored or kept the app at \(journal.installed); its journal is kept until a control for that path can verify it"
        }
        return try recover(paths, control: control, fileManager: fm)
    }

    /// Recovery is a decision about the *journal's* app, on the journal's own paths: this Mac's
    /// configuration may have changed since, and that must never make recovery judge, launch or
    /// replace a different app — nor throw the journal away because the wrong path looked fine.
    static func recover(_ paths: Paths, control: AppControl, fileManager fm: FileManager) throws -> String {
        guard let journal = try AtomicFile.readJSON(InstallJournal.self, from: paths.journal) else { return "" }
        let found = try? BundleInfo.read(journal.installed)
        let previousIsInPlace = found?.version == journal.previousVersion && found?.executableIsRunnable(in: journal.installed) == true
        let expectedNew = journal.version ?? (try? BundleInfo.read(journal.staged).version)
        let newIsInPlace = expectedNew != nil && expectedNew == found?.version
            && found?.executableIsRunnable(in: journal.installed) == true
        var note: String
        var resolved = false
        if !fm.fileExists(atPath: journal.installed) {
            // F5: For an owner rollback killed in the "moving" phase, the staged copy IS the
            // rollback target (already verified). Promote it instead of restoring from the
            // rollback path (which now holds the displaced version). For a regular install,
            // the staged copy is the new version and must not be promoted when the install
            // was interrupted — undo it instead.
            if journal.intent == "owner_rollback",
               !journal.staged.isEmpty, fm.fileExists(atPath: journal.staged),
               let stagedInfo = try? BundleInfo.read(journal.staged),
               let expectedNew = journal.version ?? stagedInfo.version as String?,
               stagedInfo.version == expectedNew,
               stagedInfo.executableIsRunnable(in: journal.staged) {
                do {
                    try fm.moveItem(atPath: journal.staged, toPath: journal.installed)
                    note = "an interrupted owner rollback was recovered by promoting the staged \(expectedNew)"
                    if journal.wasRunning { control.launch() }
                    resolved = !journal.wasRunning || waitHealthy(control, version: expectedNew)
                } catch {
                    note = try restoreAfterFailure(journal, fileManager: fm)
                    if journal.wasRunning { control.launch() }
                    resolved = !journal.wasRunning || journal.previousVersion.map { waitHealthy(control, version: $0) } == true
                }
            } else {
                note = try restoreAfterFailure(journal, fileManager: fm)
                if journal.wasRunning { control.launch() }
                resolved = !journal.wasRunning || journal.previousVersion.map { waitHealthy(control, version: $0) } == true
            }
        } else if previousIsInPlace {
            if journal.wasRunning { control.launch() }
            resolved = !journal.wasRunning || waitHealthy(control, version: found!.version)
            note = "an interrupted install was undone; the previous app was put back"
        } else if journal.phase == "rolling_back", newIsInPlace {
            guard control.quit(), control.stopService() else { return "rollback remains blocked; journal kept" }
            let result = try rollBack(paths, journal: journal, control: control, fileManager: fm)
            note = result.reason ?? result.status
            resolved = result.status == "rolled_back"
        } else if newIsInPlace, let version = found?.version {
            (note, resolved) = finishPromotion(paths, journal: journal, newVersion: version,
                                              control: control, fileManager: fm)
        } else {
            throw khuFail("recovery found \(found?.version ?? "no readable bundle") at \(journal.installed), neither the expected new nor previous version; journal kept")
        }
        if resolved {
            if !journal.staged.isEmpty, fm.fileExists(atPath: journal.staged) {
                try Trash.move(URL(fileURLWithPath: journal.staged), into: paths.trash, fileManager: fm)
            }
            try Trash.move(paths.journal, into: paths.trash, fileManager: fm)
        } else { note += "; unresolved, journal kept for the next run" }
        return note
    }

    /// The install died with the new version in place (or just as it went in): the same health check
    /// and the same rollback a live install would do. Returns the note and whether the app is
    /// settled — a rollback that could not be put back keeps the journal for the next run.
    static func finishPromotion(_ paths: Paths, journal: InstallJournal, newVersion: String, control: AppControl,
                                fileManager fm: FileManager) -> (note: String, resolved: Bool) {
        guard journal.wasRunning || journal.previousVersion == nil else {
            return ("an interrupted install had finished putting \(newVersion) in place while the app was "
                    + "not running; it was left stopped", true)
        }
        control.launch()
        if waitHealthy(control, version: newVersion) {
            return ("an interrupted install had finished putting \(newVersion) in place, and it is running and healthy", true)
        }
        guard control.quit(), control.stopService() else {
            return ("\(newVersion) is not healthy and would not stop; both versions were kept (previous at "
                    + "\(journal.rollback)) and the journal with them, so the next run tries again", false)
        }
        do {
            let result = try rollBack(paths, journal: journal, control: control, fileManager: fm)
            return (result.reason ?? "\(newVersion) was unhealthy and the previous version was put back", result.status == "rolled_back")
        } catch {
            return ("\(newVersion) is not healthy and the previous version could not be put back (\(error)); "
                    + "the journal is kept and the next run tries again", false)
        }
    }

    /// The rollback half of an install, live and in recovery: the unhealthy version is already
    /// stopped, the previous bundle goes back — proven to be the previous version — and has to come
    /// up healthy as that version. Throws when the previous bundle could not be put back, and in
    /// that case nothing was written away: the caller keeps the journal.
    static func rollBack(_ paths: Paths, journal: InstallJournal, control: AppControl,
                         fileManager fm: FileManager) throws -> RecipeResult {
        guard let previousVersion = journal.previousVersion else {
            throw khuFail("nothing was installed here before, so there is no previous version to put back")
        }
        var pending = journal
        pending.phase = "rolling_back"
        try AtomicFile.writeJSON(pending, to: paths.journal)
        try putBack(paths, journal: pending, expectedVersion: previousVersion, fileManager: fm)
        control.launch()
        return waitHealthy(control, version: previousVersion)
            ? RecipeResult(status: "rolled_back", reason: "the new version was not healthy within \(Int(control.healthTimeout)) s; \(previousVersion) is running again")
            : RecipeResult(status: "rollback_unhealthy", reason: "the new version was unhealthy, and the restored \(previousVersion) is not healthy either")
    }

    /// The installed path is empty or wrong: put the rollback bundle back if there is one.
    static func restoreAfterFailure(_ journal: InstallJournal, fileManager fm: FileManager) throws -> String {
        if fm.fileExists(atPath: journal.installed) {
            guard let info = try? BundleInfo.read(journal.installed),
                  info.version == journal.previousVersion,
                  info.executableIsRunnable(in: journal.installed) else {
                throw khuFail("the installed bundle is not either journal version; journal kept")
            }
            return "the previous app was not touched"
        }
        guard let expected = journal.previousVersion,
              let info = try? BundleInfo.read(journal.rollback), info.version == expected,
              info.executableIsRunnable(in: journal.rollback) else {
            throw khuFail("NO APP IS INSTALLED at \(journal.installed); no verified previous bundle to put back at \(journal.rollback); journal kept")
        }
        do { try fm.moveItem(atPath: journal.rollback, toPath: journal.installed) }
        catch { throw khuFail("NO APP IS INSTALLED at \(journal.installed): putting the previous one back failed (\(error)); it is at \(journal.rollback); journal kept") }
        return "the previous app was put back"
    }

    /// Keep the rollback untouched until its verified sibling is installed; a failed rename restores
    /// the unhealthy app too, and a killed run can retry from the original rollback and journal.
    static func putBack(_ paths: Paths, journal: InstallJournal, expectedVersion: String, fileManager fm: FileManager) throws {
        let installed = URL(fileURLWithPath: journal.installed)
        let rollback = URL(fileURLWithPath: journal.rollback)
        let prepared = installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).khu-previous")
        let displaced = installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).khu-unhealthy")
        guard let info = try? BundleInfo.read(rollback.path), info.version == expectedVersion,
              info.executableIsRunnable(in: rollback.path) else { throw khuFail("rollback is not runnable version \(expectedVersion)") }
        if fm.fileExists(atPath: prepared.path) { try Trash.move(prepared, into: paths.trash, fileManager: fm) }
        try fm.copyItem(at: rollback, to: prepared)
        guard (try? BundleInfo.read(prepared.path)) == info else { throw khuFail("the prepared rollback does not match") }
        if fm.fileExists(atPath: installed.path) {
            if fm.fileExists(atPath: displaced.path) { try Trash.move(displaced, into: paths.trash, fileManager: fm) }
            try fm.moveItem(at: installed, to: displaced)
        }
        do { try fm.moveItem(at: prepared, to: installed) }
        catch {
            if !fm.fileExists(atPath: installed.path), fm.fileExists(atPath: displaced.path) {
                try? fm.moveItem(at: displaced, to: installed)
            }
            throw error
        }
        if fm.fileExists(atPath: displaced.path) { try Trash.move(displaced, into: paths.trash, fileManager: fm) }
    }

    static func waitHealthy(_ control: AppControl, version: String, clock: () -> TimeInterval = Mono.now) -> Bool {
        // Healthy must start within healthTimeout and then hold, unbroken, for healthSettle.
        let deadline = clock() + control.healthTimeout
        var healthySince: TimeInterval?
        repeat {
            let now = clock()
            if control.healthy(version) {
                if healthySince == nil { healthySince = now }
                if now - healthySince! >= control.healthSettle { return true }
            } else {
                healthySince = nil
                if now > deadline { return false }
            }
            Thread.sleep(forTimeInterval: control.pollInterval)
        } while clock() < deadline + control.healthSettle
        return false
    }

    static func attach(_ shell: Shell, _ artifactPath: String) throws -> (mount: String, device: String) {
        let attach = try shell.run("/usr/bin/hdiutil",
                                   arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", artifactPath], timeout: 180)
        // hdiutil prints a deprecation WARNING first on newer macOS; the reason is in the other lines.
        let reason = attach.stderr.split(separator: "\n").filter { !$0.contains("WARNING") }.joined(separator: " ")
        guard attach.exitCode == 0 else { throw khuFail("hdiutil attach failed: \(reason.prefix(200))") }
        let devices = devEntries(fromPlist: attach.stdout)
        guard let mount = mountPoint(fromPlist: attach.stdout), devices.count == 1 else {
            for device in devices { _ = detach(shell, device) }
            throw khuFail("could not determine the DMG mount point and device")
        }
        return (mount, devices[0])
    }

    /// Returns "" on success, or a note saying the image is still mounted.
    static func detach(_ shell: Shell, _ device: String) -> String {
        guard device.range(of: #"^/dev/disk[0-9]+(?:s[0-9]+)*$"#, options: .regularExpression) != nil else {
            return "refused to detach an unrecognized DMG device"
        }
        for arguments in [["detach", device], ["detach", "-force", device]] {
            if let result = try? shell.run("/usr/bin/hdiutil", arguments: arguments, timeout: 60), result.exitCode == 0 { return "" }
        }
        return "the DMG device is still mounted at \(device)"
    }

    static func mountPoint(fromPlist output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first { $0.hasPrefix("/") }
    }

    /// The whole-disk device nodes an attach created (`/dev/diskN`), for detaching without a mount point.
    static func devEntries(fromPlist output: String) -> [String] {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        let devices = entities.compactMap { $0["dev-entry"] as? String }.filter { $0.hasPrefix("/dev/disk") }
        let whole = devices.filter { !$0.dropFirst("/dev/disk".count).contains("s") }
        return Array(Set(whole.isEmpty ? devices : whole)).sorted()
    }

    static func singleApp(in mount: String, fileManager fm: FileManager) throws -> String {
        let names = (try? fm.contentsOfDirectory(atPath: mount)) ?? []
        let apps = names.filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }
        guard apps.count == 1 else { throw ArtifactFailure(description: "expected exactly one .app in the DMG, found \(apps.count); nothing was changed") }
        return mount + "/" + apps[0]
    }
}

/// Real `AppControl`s for this Mac. Every external call is an absolute path with a bounded timeout,
/// and a process is only ever identified by its executable's real path inside the bundle.
public enum LiveControl {
    /// Processes whose executable lives inside this bundle, or nil when the table cannot be read.
    /// The kernel's own spelling of a path (`realpath(3)`), which is what `proc_pidpath` reports.
    /// Foundation's `resolvingSymlinksInPath` drops `/private` and would never match.
    public static func realPath(_ path: String) -> String { RealPath.of(path) }

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

    /// Ask the app to quit by bundle id — passed as an argument, never spliced into the script — and
    /// wait up to `wait` seconds until `gone()` says it has. By default that means no process of it
    /// is left; the Gateway passes a rule that ignores its own service process, which is stopped
    /// separately by the PID that owns the port.
    public static func quit(_ installedPath: String, shell: Shell, wait: TimeInterval = 60,
                            gone rule: (() -> Bool)? = nil) -> Bool {
        let gone = rule ?? { isRunning(installedPath) == false }
        if gone() { return true }
        guard let id = try? BundleInfo.read(installedPath).identifier else { return false }
        _ = try? shell.run("/usr/bin/osascript", arguments: [
            "-e", "on run argv", "-e", "tell application id (item 1 of argv) to quit", "-e", "end run", id,
        ], timeout: 30)
        let deadline = Mono.now() + wait
        while Mono.now() < deadline {
            if gone() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return gone()
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

    /// The pids owning the *listening* socket on `port`, asked of `lsof` by port (absolute path,
    /// bounded timeout, never by name). This is the only evidence that lets a stop signal a PID; an
    /// empty answer is a refusal, never a licence to signal whatever /health named.
    static func listeners(onPort port: Int, shell: Shell) -> [pid_t] {
        guard let result = try? shell.run("/usr/sbin/lsof",
                                          arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"],
                                          timeout: 15),
              result.exitCode == 0 else { return [] }
        return result.stdout.split(separator: "\n").compactMap { line in
            line.hasPrefix("p") ? pid_t(line.dropFirst()) : nil
        }
    }

    /// The Gateway: its server outlives the menu-bar app, and both run from inside the same bundle.
    /// The server is stopped by the PID its /health reports — only after checking that this PID
    /// really runs from this bundle AND really owns the listening socket on the port — with SIGTERM
    /// only, and counts as stopped once the port stays quiet. Quitting therefore means *the app*
    /// has quit, not that the bundle has no processes left: the service is stopped separately, and
    /// otherwise a menu-bar app could never be quit while its own server is up. Healthy means
    /// /health answers 200 from a process of this bundle, the bundle on disk is the expected
    /// version, and the app runs.
    public static func gateway(_ installedPath: String, shell: Shell, port: Int = 8787, quitWait: TimeInterval = 60) -> AppControl {
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
        /// This app's own service process: the PID /health names, and only when it is one of ours.
        func servicePid() -> pid_t? { let named = probe().pid; return ours(named) ? named : nil }
        /// The app is gone once the only process of this bundle left is its service (or none is).
        func appGone() -> Bool {
            guard let all = processes(inBundle: installedPath) else { return false }  // cannot tell: keep waiting
            guard let service = servicePid() else { return all.isEmpty }
            return all.allSatisfy { $0 == service }
        }
        var control = appDmg(installedPath, shell: shell)
        control.quit = { quit(installedPath, shell: shell, wait: quitWait, gone: { appGone() }) }
        control.stopService = {
            let answer = probe()
            if answer.code == 0 { return quiet() }
            // Something answers that is not this Gateway: never signal it, and do not install over it.
            guard ours(answer.pid), let pid = answer.pid else { return false }
            // The PID /health names is the service only when it is also the PID that owns the
            // listening socket: a local server naming any other process inside this bundle must not
            // turn a stop into a signal to an unrelated process.
            let owners = listeners(onPort: port, shell: shell)
            guard !owners.isEmpty, owners.allSatisfy({ $0 == pid }) else { return false }
            guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
            let deadline = Mono.now() + 60
            while Mono.now() < deadline, kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 1) }
            return kill(pid, 0) != 0 && quiet()
        }
        let appHealthy = control.healthy
        control.healthy = { expected in
            let answer = probe()
            let owners = listeners(onPort: port, shell: shell)
            return answer.code == 200 && ours(answer.pid) && !owners.isEmpty
                && owners.allSatisfy { $0 == answer.pid } && appHealthy(expected)
        }
        control.healthTimeout = 120
        return control
    }
}
