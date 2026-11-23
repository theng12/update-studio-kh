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
    /// True when the app was asked to quit without an update hold because its build predates one.
    public var quitWithoutHold = false
    /// True when the installed build predates its app's update hold: it has no hold route, or it
    /// answered 401/403/404 and the feed's `holdSince` is newer than what is installed.
    public var predatesHold = false
    /// True when the app's update hold could not be taken: it refused, did not answer, or the feed
    /// names no endpoint. Asking again seconds later cannot change that answer, so the attempt ends
    /// and the artifact is remembered — never a retry loop on a production Mac (issue 20261120-151).
    public var holdRefused = false
    /// The unattended quit's own log lines: what the idle check answered, whether the app exited and
    /// how long it took, whether its services started, and whether it came back. Kept as separate
    /// lines so a Mac that stalls or half-restarts says which of the four failed.
    public var quitTrace: [String] = []
    public init(status: String, reason: String? = nil, version: String? = nil) {
        self.status = status; self.reason = reason; self.version = version
    }
}

/// What happened when the app's own services were put back: launchd's answer, read back.
public struct ServiceResume: Equatable {
    public var ok: Bool
    public var reason: String?
    public init(ok: Bool = true, reason: String? = nil) { self.ok = ok; self.reason = reason }
    public static let none = ServiceResume()
}

/// What a recipe does to the outside world, injectable so tests never touch real apps.
public struct AppControl {
    /// true/false, or nil when it cannot be told (treated as running: it must then quit).
    public var isRunning: () -> Bool?
    /// Ask the desktop app to quit; a separately verified service is stopped by stopService.
    public var quit: () -> Bool
    /// Launch the installed app. Always background/hidden: an install never takes the desktop.
    public var launch: () -> Void
    /// True when the running instance is a test/hidden run (extra launch arguments or an isolated
    /// HOME), not the owner's ordinary launch. It is replaced but never relaunched in their profile.
    public var isTestInstance: () -> Bool
    /// Stop verified services that outlive their desktop app; true only once the bundle is quiet.
    /// Gateway also verifies its service endpoint and listener ownership.
    public var stopService: () -> Bool
    /// Persist only services that were running, so recovery never starts an intentionally stopped job.
    public var serviceLabels: () -> [String]
    public var restoreServices: ([String]) -> Void
    /// Put this app's own services back after a swap or a rollback, without opening the app. A job
    /// the install had to unload is bootstrapped again; a loaded-but-stopped job is kickstarted.
    /// The result is read back from launchd: a refused or ineffective call is a failure the recipe
    /// must report, never a silent success.
    public var resumeServices: () -> ServiceResume
    /// Healthy *as this version*: the new one after an install, the previous one after a rollback.
    public var healthy: (_ expectedVersion: String) -> Bool
    /// Which requirement a failed health check is missing, in words — a version mismatch, the app
    /// not running, or the name of the service that is not running — or nil when it is healthy or
    /// cannot tell. A failure that says only "not healthy within 60 s" sends someone digging
    /// through logs; the updater already knows the answer and must say it.
    public var healthRequirement: (_ expectedVersion: String) -> String?
    public var healthTimeout: TimeInterval
    public var pollInterval: TimeInterval
    /// How long the app must stay healthy without a break before an install is accepted: an app that
    /// launches and dies a moment later was once reported "updated" (live proof, 2026-10-25).
    public var healthSettle: TimeInterval
    public init(isRunning: @escaping () -> Bool?, quit: @escaping () -> Bool, launch: @escaping () -> Void,
                stopService: @escaping () -> Bool = { true }, healthy: @escaping (String) -> Bool,
                healthRequirement: @escaping (String) -> String? = { _ in nil },
                healthTimeout: TimeInterval = 60, pollInterval: TimeInterval = 1, healthSettle: TimeInterval = 10,
                serviceLabels: @escaping () -> [String] = { [] }, restoreServices: @escaping ([String]) -> Void = { _ in },
                resumeServices: @escaping () -> ServiceResume = { .none },
                isTestInstance: @escaping () -> Bool = { false }) {
        self.isRunning = isRunning; self.quit = quit; self.launch = launch; self.stopService = stopService
        self.serviceLabels = serviceLabels; self.restoreServices = restoreServices; self.resumeServices = resumeServices
        self.healthy = healthy; self.healthRequirement = healthRequirement
        self.healthTimeout = healthTimeout; self.pollInterval = pollInterval
        self.healthSettle = healthSettle
        self.isTestInstance = isTestInstance
    }
}

/// The parts of an app bundle an install is judged on, read from its Info.plist directly.
public struct BundleInfo: Equatable, Sendable {
    public var version: String
    public var identifier: String
    public var executable: String
    /// `CFBundleVersion`, which a build sets and a bumped marketing version does not imply, so two
    /// bundles can share `version` and still be different builds. Nil (never guessed) when the plist
    /// has no usable value; an install/rollback judged on `version` alone is unaffected.
    public var build: String? = nil

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
        return BundleInfo(version: version, identifier: identifier, executable: executable, build: buildValue(dict["CFBundleVersion"]))
    }

    /// A build number as it can be reported: one bounded line, or nil when there is none — a report
    /// never invents a build from the marketing version.
    private static func buildValue(_ raw: Any?) -> String? {
        guard let value = raw as? String ?? (raw as? NSNumber).map({ $0.stringValue }) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= ReportPolicy.maxVersionCharacters,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    /// The SHA-256 of the bundle's own executable — bytes read from the installed bundle now, which
    /// is the strongest identity an already-installed app can report about itself. It says nothing
    /// about the artifact the publisher signed: a release archive hash never proves these bytes.
    public func executableSha256(in appPath: String) -> String? {
        var status = stat()
        let path = appPath + "/Contents/MacOS/" + executable
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? Signing.sha256Hex(fileAt: URL(fileURLWithPath: path)).hex
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
    /// The running instance was a test/hidden run: replace it, but never relaunch it in the owner's
    /// profile. Nil in journals written before it existed (treated as the owner's app).
    public var testInstance: Bool? = nil
    /// Whether the install that wrote this journal was allowed to relaunch afterwards. False for
    /// every unattended install; nil for journals written before it existed (old behaviour).
    public var relaunchAfterwards: Bool? = nil
    /// The version this install is putting in place, so a recovered journal can prove which side it
    /// found at `installed`. Absent in a journal written before it existed.
    public var version: String? = nil
    /// The owner order this swap belongs to, when there was one: recovery answers that order from
    /// what it finds on disk instead of running it again.
    public var order: String? = nil
    /// `owner_rollback` for a swap the owner ordered; absent for an install.
    public var intent: String? = nil
    /// The already-running owned services to restart after promotion, rollback or process recovery.
    public var serviceLabels: [String]? = nil
}

public enum Recipe {
    /// Both looks the hand route takes at the running app answer with the same plain reason: the app
    /// is kept as it is, because nothing here proved a quiet point.
    static let handKeepsRunningApp = "This app is running now, so nothing was changed. "
        + "Quit it when its work is finished, then try again. No quiet point was proved."
    /// An app that would not quit within the quit's own ceiling: nothing was swapped, so the caller
    /// reports a refusal and the reason it failed, instead of a stalled row.
    public static let didNotQuit = "the app did not quit; the installed app was kept"
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
    /// `refuseIfRunning` is the hand route's second look: an app that updates itself proves no quiet
    /// point, so one that came up while its installer was prepared is kept running and nothing is
    /// stopped or replaced. Every other install keeps its own quit-and-promote contract.
    public static func appDmg(shell: Shell, installedPath: String, artifactPath: String, feedVersion: String,
                              expectedBundleID: String?, stateDir: String, app: String, control: AppControl,
                              refuseIfRunning: Bool = false, relaunchAfterInstall: Bool = true,
                              relaunchIfClosed: Bool = false,
                              appearCeiling: TimeInterval = Recipe.appearCeiling,
                              fileManager fm: FileManager = .default,
                              verifyStaged: ((String) throws -> Void)? = nil,
                              clock: @escaping () -> TimeInterval = Mono.now,
                              beforeStop: (() throws -> Void)? = nil,
                              exchange: (String, String) -> Bool = Recipe.exchange) throws -> RecipeResult {
        let paths = Paths(installedPath: installedPath, stateDir: stateDir, app: app)
        let recovered = try recover(paths, control: control, fileManager: fm)
        guard !fm.fileExists(atPath: paths.journal.path) else {
            throw khuFail("the earlier install is unresolved; journal kept at \(paths.journal.path) — clear it only while the helper is stopped")
        }

        // 2. Verify and stage while the old app keeps running.
        let (mount, device) = try attach(shell, artifactPath)
        var detachedDevice = device
        var mounted = true
        defer { if mounted { _ = detach(shell, detachedDevice) } }
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
        // The update must be the same signed app this Mac already runs — the expected signing
        // identity, not merely a bundle whose signature validates. That is the local question a
        // writable config key cannot answer: any signed bundle can carry the right name. A bundle
        // that carries no signing identity at all is not this check's case; the feed's signed
        // SHA-256 and the staged signature check remain its proof.
        if installedInfo != nil, let installedIdentity = signingIdentity(installedPath, shell: shell),
           let sourceIdentity = signingIdentity(source, shell: shell), sourceIdentity != installedIdentity {
            throw ArtifactFailure(description: "the DMG's app is signed as \(sourceIdentity), and the app installed here is \(installedIdentity); nothing was changed")
        }
        guard info.executableIsRunnable(in: source) else { throw ArtifactFailure(description: "the DMG's app has no runnable executable; nothing was changed") }

        // A copy that starts with no source, or that finds the image gone, re-attaches it: the
        // image was measured detaching itself between attach and copy. The re-attached device is
        // detached by the defer below through `detachedDevice`.
        try stage(paths, from: source, info: info, shell: shell, fileManager: fm, reattach: {
            _ = detach(shell, device)
            let again = try attach(shell, artifactPath)
            detachedDevice = again.device
            return try singleApp(in: again.mount, fileManager: fm)
        })
        do { try verifyStaged?(paths.staged.path) }
        catch {
            _ = Space.remove(paths.staged, shell: shell, fileManager: fm)
            throw error
        }
        mounted = false
        let detachNote = detach(shell, detachedDevice)  // the staged copy is all that is needed from here

        // The person at this Mac may have started the app while its installer was being fetched and
        // staged. Stopping it now is the one thing this route promised not to do, so the second look
        // happens here — before the journal exists and before anything is quit: the staged copy goes
        // back to `_trash`, the installed bundle is untouched and nothing is stopped or started.
        if refuseIfRunning, control.isRunning() != false {
            _ = Space.remove(paths.staged, shell: shell, fileManager: fm)
            return RecipeResult(status: "refused", reason: handKeepsRunningApp)
        }

        return try promoteAndSettle(paths: paths, targetVersion: feedVersion, installedInfo: installedInfo,
                                    order: nil, control: control, fileManager: fm, notes: [recovered, detachNote],
                                    refuseIfRunning: refuseIfRunning, relaunchAfterInstall: relaunchAfterInstall,
                                    relaunchIfClosed: relaunchIfClosed,
                                    clock: clock, appearCeiling: appearCeiling, beforeStop: beforeStop,
                                    exchange: exchange)
    }

    /// The owner's order to put this app's kept previous version back. It is the same swap as an
    /// install — the same journal, the same quit/stop, the same promotion and the same health
    /// window — with two differences: the source is the bundle this Mac already kept instead of a
    /// DMG, and what has to come up healthy is the OLDER version. Everything is verified before
    /// anything running is touched, so a refusal costs the app nothing.
    public static func ownerRollback(shell: Shell, installedPath: String, stateDir: String, app: String,
                                     expectedBundleID: String?, order: String, control: AppControl,
                                     fileManager fm: FileManager = .default,
                                     beforeStop: (() throws -> Void)? = nil) throws -> RecipeResult {
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
            _ = Space.remove(paths.staged, shell: shell, fileManager: fm)
            return RecipeResult(status: "refused", reason: "the staged copy of \(kept.version) at \(paths.staged.path) does not verify as "
                               + "\(keptIdentity); nothing was changed")
        }
        return try promoteAndSettle(paths: paths, targetVersion: kept.version, installedInfo: installedInfo,
                                    order: order, control: control, fileManager: fm, notes: [recovered],
                                    beforeStop: beforeStop)
    }

    /// Copy a verified bundle into the staging path beside the installed one and check the copy —
    /// always before anything running is stopped. `ditto` carries the bundle's own signature over.
    ///
    /// `ditto`'s exit code is not the signal (measured 2026-11-19 on one Hub bundle: macOS 27.2.1
    /// returns 0 for a complete copy, 27.0.1 returns 1 for the same complete copy and once stopped
    /// partway, 26.6.2 stopped on a symlink). Completeness is: every entry the source has, the same
    /// version and identifier, a runnable executable. An incomplete copy is cleared, re-attached
    /// and copied once more (4 of 5 copies complete on the measured Mac, so one retry takes an
    /// install from 80% to 96%; the agent's next run covers the rest). `Not a directory`,
    /// `No such file` and `I/O error` are a broken source, not flakiness: they stay fatal.
    ///
    /// `reattach` returns a fresh mount path, or throws; it is called only when a retry needs it.
    static func stage(_ paths: Paths, from source: String, info: BundleInfo, shell: Shell, fileManager fm: FileManager,
                      reattach: (() throws -> String)? = nil) throws {
        var from = source
        var attempts = 0
        var lastSaid = ""
        while true {
            attempts += 1
            if fm.fileExists(atPath: paths.staged.path) { _ = Space.remove(paths.staged, shell: shell, fileManager: fm) }
            // Copying into a leftover tree is what made the loop: `ditto` then fails on the first
            // read-only file inside it, every retry fails the same way, and the row never changes.
            guard !fm.fileExists(atPath: paths.staged.path) else {
                throw khuFail("an unfinished copy of the new app was left beside it and could not be cleared (\(paths.staged.path)); nothing was changed — move it aside by hand and try again")
            }
            let (wantEntries, _) = entryCount(from)
            let copy = try shell.run("/usr/bin/ditto", arguments: [from, paths.staged.path], timeout: 900)
            let stagedInfo = try? BundleInfo.read(paths.staged.path)
            let (gotEntries, _) = entryCount(paths.staged.path)
            let complete = stagedInfo == info && stagedInfo?.executableIsRunnable(in: paths.staged.path) == true
                && wantEntries > 0 && gotEntries == wantEntries
            if complete { return }
            lastSaid = "copied \(gotEntries) of \(wantEntries) entries, \(copy.stderr.split(separator: "\n").count) stderr line(s)"
            _ = Space.remove(paths.staged, shell: shell, fileManager: fm)
            if copy.stderr.contains("Not a directory") || copy.stderr.contains("No such file")
                || copy.stderr.contains("Input/output error") || copy.stderr.contains("I/O error") {
                throw khuFail("copying the new app could not read its source (\(copy.stderr.prefix(200))); nothing was changed")
            }
            guard attempts == 1 else {
                throw khuFail("copying the new app failed twice (\(lastSaid)); nothing was changed")
            }
            // The image was measured detaching itself between attach and copy; a copy that starts
            // with no source copies nothing. Re-attach before the one retry when the caller can.
            if let reattach { from = try reattach() }
        }
    }

    /// How many entries a bundle tree holds, and its size; nil-safe (0) when it cannot be walked.
    static func entryCount(_ path: String) -> (entries: Int, bytes: UInt64) {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                        options: [], errorHandler: { _, _ in true }) else { return (0, 0) }
        var entries = 0, bytes: UInt64 = 0
        for case let url as URL in walk {
            entries += 1
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
               let size = values.fileSize { bytes += UInt64(max(0, size)) }
        }
        return (entries, bytes)
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
    static func bundleIdentifier(at path: String) -> String? {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Retires every other bundle with the same identifier, in `/Applications` and `~/Applications`.
    /// A move that fails is ignored here: the install already succeeded and must not be undone by
    /// housekeeping.
    static func retireDuplicateBundles(bundleID: String, keeping installedPath: String, trash: URL,
                                       roots: [URL]? = nil, fileManager fm: FileManager = .default) {
        // The target is never a candidate. Paths are resolved through symlinks before comparing, so a
        // second spelling of the same bundle (a link, a root reached twice) can never retire the app
        // that was just installed. If the target itself cannot be read as the expected bundle, nothing
        // is retired at all: the safe state is "leave every copy alone".
        let keep = URL(fileURLWithPath: installedPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard fm.fileExists(atPath: keep), Self.bundleIdentifier(at: keep) == bundleID else { return }
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"),
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var visited = Set<String>()
        for root in roots {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard visited.insert(rootPath).inserted else { continue }
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.pathExtension == "app" {
                let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard candidate != keep, Self.bundleIdentifier(at: candidate) == bundleID else { continue }
                _ = try? Trash.move(url, into: trash, fileManager: fm)
            }
        }
    }

    /// An install that renamed a bundle can leave a LaunchAgent naming a path that no longer
    /// exists: that job can never start, and its app never runs to repair it. Only the
    /// unambiguous case is fixed — same executable basename, old bundle path gone.
    static func repairLaunchAgents(installedPath: String, fileManager fm: FileManager) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: url),
                  var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  var args = plist["ProgramArguments"] as? [String], let first = args.first,
                  first.contains("/Contents/MacOS/"), !fm.fileExists(atPath: first) else { continue }
            let executable = URL(fileURLWithPath: first).lastPathComponent
            let repaired = URL(fileURLWithPath: installedPath).appendingPathComponent("Contents/MacOS/\(executable)").path
            guard fm.fileExists(atPath: repaired) else { continue }
            args[0] = repaired
            plist["ProgramArguments"] = args
            guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { continue }
            _ = try? out.write(to: url, options: .atomic)
        }
    }

    /// Atomic exchange of two existing paths on the same volume: `renamex_np(RENAME_SWAP)` is a
    /// rename, so it needs no extra space and leaves both entries where they were when it fails.
    /// False means the platform or the volume refused, and the caller falls back to two moves.
    static func exchange(_ a: String, _ b: String) -> Bool {
        // Test seam: a child process can die exactly here, which is the window an interrupted
        // install occupies. Nothing in the app sets these variables.
        let kill = ProcessInfo.processInfo.environment["KHU_TEST_EXCHANGE_KILL"]
        if kill == "before" { raise(SIGKILL) }
        let swapped = renamex_np(a, b, UInt32(RENAME_SWAP)) == 0
        if kill == "after" { raise(SIGKILL) }
        return swapped
    }

    static func promoteAndSettle(paths: Paths, targetVersion: String, installedInfo: BundleInfo?,
                                 order: String?, control: AppControl, fileManager fm: FileManager,
                                 notes: [String], refuseIfRunning: Bool = false,
                                 relaunchAfterInstall: Bool = true, relaunchIfClosed: Bool = false,
                                 clock: @escaping () -> TimeInterval = Mono.now,
                                 appearCeiling: TimeInterval = Recipe.appearCeiling,
                                 beforeStop: (() throws -> Void)? = nil,
                                 exchange: (String, String) -> Bool = Recipe.exchange) throws -> RecipeResult {
        let installedPath = paths.installedPath
        // The gap's own timeline: each step's offset from the moment the install began, so the next
        // estimate is measured rather than guessed. It travels in the result, so the helper's log
        // and the fleet record carry it.
        let started = Date()
        var marks: [(String, TimeInterval)] = []
        func mark(_ step: String) { marks.append((step, Date().timeIntervalSince(started))) }
        // The last read before anything would be stopped is the one that decides: the app may have
        // been opened (or closed) while the installer was being prepared.
        let wasRunning = control.isRunning() ?? true
        // A test/hidden instance (extra launch arguments or an isolated HOME) is not the owner's
        // app: it may be replaced, but it is never relaunched into the owner's profile afterwards.
        // Any other app that was running is relaunched after the swap and health-checked, so an
        // unattended update comes back by itself — `relaunchAfterInstall` is the caller's choice
        // (the agent passes this Mac's `relaunchAfterwards`; only a test instance is excluded).
        let testInstance = wasRunning && control.isTestInstance()
        let mayRelaunch = relaunchAfterInstall && !testInstance
        // An app that updates itself came up between the staging look and here: this route proves no
        // quiet point, so it is kept exactly as it is — no journal, no quit, no service stop.
        if refuseIfRunning, wasRunning {
            _ = Space.remove(paths.staged, shell: SystemShell(), fileManager: fm)
            return RecipeResult(status: "refused", reason: Recipe.handKeepsRunningApp)
        }
        // The replacement must be proven present and readable before anything is stopped or moved:
        // a missing or corrupt staged app leaves the installed one exactly where it is, so a failed
        // install can never leave the machine with no app. No journal exists yet for this path.
        guard fm.fileExists(atPath: paths.staged.path), (try? BundleInfo.read(paths.staged.path)) != nil else {
            _ = Space.remove(paths.staged, shell: SystemShell(), fileManager: fm)
            return RecipeResult(status: "install_failed",
                                reason: "the staged app is missing or unreadable; the installed app was kept; nothing was replaced")
        }
        // The update hold is validated at the mutation boundary, before the journal exists: a
        // refusal here (or a hold that cannot be taken for an app opened mid-download) leaves no
        // journal and no staged copy behind. An app that exited needs no renewal: it cannot be
        // interrupted, and its pause expires by itself.
        if !refuseIfRunning, wasRunning, let beforeStop {
            do { try beforeStop() } catch {
                _ = Space.remove(paths.staged, shell: SystemShell(), fileManager: fm)
                throw error
            }
        }
        var journal = InstallJournal(phase: "staged", installed: installedPath, staged: paths.staged.path,
                                     rollback: paths.rollback.path,
                                     // Nothing installed: a rollback bundle kept from before is the previous version.
                                     previousVersion: installedInfo?.version ?? (try? BundleInfo.read(paths.rollback.path))?.version,
                                     wasRunning: wasRunning, testInstance: testInstance,
                                     relaunchAfterwards: relaunchAfterInstall, version: targetVersion)
        journal.order = order
        journal.intent = order == nil ? nil : "owner_rollback"
        journal.serviceLabels = control.serviceLabels()
        control.restoreServices(journal.serviceLabels ?? [])
        // The version this swap moves away from: an owner rollback reports it, so the agent can
        // reject that exact artifact instead of the one it installs.
        let displaced = journal.previousVersion
        try AtomicFile.writeJSON(journal, to: paths.journal)

        // 3. Stop what is running; on refusal, leave the old app as it was.
        var appQuit = false
        func abandon(_ message: String) throws -> Never {
            // A stop that got as far as unloading a job is undone here: the old app keeps its own
            // services whether or not it is relaunched.
            let resumed = control.resumeServices()
            if wasRunning && mayRelaunch && (appQuit || control.isRunning() != true) { control.launch() }
            _ = Space.remove(paths.staged, shell: SystemShell(), fileManager: fm)
            // Only a stop that really began (the app was quit) can have left a service down; a
            // refusal before that leaves nothing to recover, so no journal is kept for it.
            let keepJournal = !resumed.ok && appQuit
            if !keepJournal { _ = try? Trash.move(paths.journal, into: paths.trash, fileManager: fm) }
            throw khuFail(resumed.ok ? message
                          : message + "; and its background service did not restart (\(resumed.reason ?? "launchd refused"))"
                          + (keepJournal ? "; the install is kept and the next run tries again" : ""))
        }
        // The hand route never asks anything to stop: it proved no quiet point, so an app or service
        // that started after the last look is left running while the swap goes ahead without it.
        if !refuseIfRunning {
            // It was running at the boundary; if it exited on its own the hold is moot and there is
            // nothing to quit, so the swap simply goes ahead (the pause expires by itself).
            if wasRunning {
                guard control.quit() else { try abandon(Recipe.didNotQuit + "; it is still running and keeps its work. The next check tries again") }
                appQuit = true
            }
            guard control.stopService() else { try abandon("the background service did not stop safely; the installed app was kept and restart was requested") }
        }
        mark("gone")

        // 4. Promote. Every throw from here restores the previous bundle before it is reported.
        do {
            if fm.fileExists(atPath: installedPath) {
                try fm.createDirectory(at: paths.rollback.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Our own bookkeeping must never fail an install: a rollback copy left from an
                // earlier update is retired into this Mac's own trash (recoverable, never deleted)
                // before the new one takes its place. The old code removed it with a best-effort
                // helper whose failure was ignored, so the move then hit an existing item and the
                // whole install failed on NSCocoaErrorDomain 516.
                if fm.fileExists(atPath: paths.rollback.path) {
                    // The move must actually happen: a container or a locked item can keep it there,
                    // and proceeding would only trade one 516 for another.
                    guard (try? Trash.move(paths.rollback, into: paths.trash, fileManager: fm)) != nil,
                          !fm.fileExists(atPath: paths.rollback.path) else {
                        throw khuFail("the previous rollback copy could not be moved aside, so the app was left where it was")
                    }
                }
                journal.phase = "moving"; try AtomicFile.writeJSON(journal, to: paths.journal)
                // The replacement exists before the thing it replaces is removed. Measured
                // 2026-11-23: the two-move order left this Mac with no Launcher at all — the old
                // bundle went to the rollback path, the promote then failed, and nothing put the app
                // back. An exchange is a rename: atomic, and space-neutral, so an update that fitted
                // before still fits.
                if exchange(paths.staged.path, installedPath) {
                    journal.phase = "promoted"; try AtomicFile.writeJSON(journal, to: paths.journal)
                    // `staged` now holds the previous bundle; it becomes this Mac's fallback. A
                    // failure here costs the fallback copy, never the installed app, so it is kept
                    // where it is and reported rather than thrown.
                    do { try fm.moveItem(at: paths.staged, to: paths.rollback) }
                    catch {
                        FileHandle.standardError.write(Data("note: the previous version stayed at \(paths.staged.path) instead of the rollback copy (\(error)); it is still on disk and nothing was deleted\n".utf8))
                    }
                } else {
                    // Different volume, or the platform refused the exchange: the old order, but
                    // every step restores before it reports, so the app is never in neither place.
                    do { try fm.moveItem(atPath: installedPath, toPath: paths.rollback.path) }
                    catch {
                        throw khuFail("the previous rollback copy was in the way and the app could not be kept as the fallback; the app was left where it was")
                    }
                    journal.phase = "promoting"; try AtomicFile.writeJSON(journal, to: paths.journal)
                    do { try fm.moveItem(at: paths.staged, to: URL(fileURLWithPath: installedPath)) }
                    catch let promoteError {
                        do { try fm.moveItem(at: paths.rollback, to: URL(fileURLWithPath: installedPath)) }
                        catch {
                            throw khuFail("NO APP IS INSTALLED at \(installedPath): the new bundle could not be put in place (\(promoteError)) and the previous one could not be put back (\(error)); the previous bundle is kept at \(paths.rollback.path)")
                        }
                        throw khuFail("the new bundle could not be put in place (\(promoteError)), so the previous app was put back; nothing changed")
                    }
                }
            } else {
                // With nothing installed, an existing rollback bundle is kept: it is the only fallback.
                journal.phase = "promoting"; try AtomicFile.writeJSON(journal, to: paths.journal)
                try fm.moveItem(at: paths.staged, to: URL(fileURLWithPath: installedPath))
            }
            journal.phase = "promoted"; try AtomicFile.writeJSON(journal, to: paths.journal)
            // One bundle per bundle id: a leftover copy can start its own services and fight over
            // ports, so an install retires any other copy to the feed's Trash.
            if let bundleID = Self.bundleIdentifier(at: installedPath) {
                Self.retireDuplicateBundles(bundleID: bundleID, keeping: installedPath, trash: paths.trash, fileManager: fm)
            }
            Self.repairLaunchAgents(installedPath: installedPath, fileManager: fm)
            // The app's own services belong to the bundle that is now installed — also when an
            // unattended install leaves the app itself closed. A job launchd would not take back is
            // reported, and the journal stays so the next run retries instead of calling it settled.
            let resumed = control.resumeServices()
            guard resumed.ok else {
                return RecipeResult(status: "install_failed", reason:
                    "the app was installed but its background service did not restart "
                    + "(\(resumed.reason ?? "launchd refused")); the install is kept and the next run tries again")
            }
            mark("promoted")
        } catch {
            let cause = error
            let restored: String
            do { restored = try restoreAfterFailure(journal, fileManager: fm) }
            catch { throw khuFail("installing failed (\(cause)); \(error); recovery journal kept at \(paths.journal.path)") }
            let resumed = control.resumeServices()
            if wasRunning && mayRelaunch { control.launch() }
            if !resumed.ok {
                throw khuFail("installing failed (\(cause)); \(restored); and its background service did not restart "
                              + "(\(resumed.reason ?? "launchd refused")); the install is kept and the next run tries again")
            }
            try Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            throw khuFail("installing failed (\(cause)); \(restored)")
        }

        func finish(_ result: RecipeResult) -> RecipeResult {
            _ = try? Trash.move(paths.journal, into: paths.trash, fileManager: fm)
            let timeline = marks.isEmpty ? "" : "timings: "
                + marks.map { "\($0.0) \(String(format: "%.1f", $0.1))s" }.joined(separator: " · ")
            let all = notes.filter { !$0.isEmpty } + [timeline]
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
            case "rolled_back":
                // Keep the install's own sentence: it names the requirement that was missing.
                return answered("rollback_failed", result.reason ?? "\(targetVersion) was not healthy within "
                                + "\(Int(control.healthTimeout)) s, so \(displaced ?? "the version this Mac was running") was put back")
            case "rollback_unhealthy": return answered("rollback_unhealthy", "\(targetVersion) was not healthy, and putting "
                                                       + "\(displaced ?? "the version this Mac was running") back did not come up healthy either")
            default: return result
            }
        }

        // 5. An install puts back what it stopped: the app is relaunched, hidden, and required to be
        // healthy as the new version. Only a test/hidden instance is never relaunched in the
        // owner's profile, and a caller may ask for no relaunch (tests do).
        if testInstance {
            return finish(settled(RecipeResult(status: "updated",
                reason: "it was running as a test instance, so it was left stopped")))
        }
        if !relaunchAfterInstall {
            return finish(settled(RecipeResult(status: "updated",
                reason: wasRunning ? "it was closed for the update and left closed" : "it was left stopped")))
        }
        // A waiting update installs on the tick after its app is closed, and reopens it: the person
        // was told it would install by itself, so it comes back rather than arriving silently closed.
        let reopens = wasRunning || relaunchIfClosed
        // A first install is launched and health-checked even when nothing was running: it has no
        // earlier version to fall back to, so "the bundle is in place" is not the same as "the app
        // works", and calling it done would leave an unhealthy install recorded as current (R2-5).
        // The retry storm this once seemed to explain was the missing interval floor, not this.
        guard reopens || journal.previousVersion == nil else {
            return finish(settled(RecipeResult(status: "updated", reason: "it was not running, so it was left stopped")))
        }
        control.launch()
        mark("launched")
        // The health window starts when the new process is there, not when the quit began: Gateway
        // spends most of its gap draining and stopping, and that time must not be charged to the
        // app's own start (measured on 1301, 2026-11-17: 127 s quit-to-healthy, the health clock
        // had already nearly expired).
        mark("appear-ceiling \(Int(appearCeiling))s")
        // Only a process this install stopped has to come back; a first install has none to wait for.
        let appeared = !reopens || waitForRunning(control, clock: clock, ceiling: appearCeiling)
        mark(appeared ? "appeared" : "did-not-appear")
        mark("health-window \(Int(control.healthTimeout))s")
        if appeared, waitHealthy(control, version: targetVersion, clock: clock) {
            mark("healthy")
            // Installed and running — but an older start-at-login entry may still be unable to
            // start, and that middle state is said rather than folded into a plain success. The
            // app is what re-registers it, and opening it once is the whole recovery.
            if !control.isTestInstance(), let label = LiveControl.staleAppTypeItems(installedPath, shell: SystemShell()).first {
                return finish(settled(RecipeResult(status: "updated",
                    reason: "installed and running; the start-at-login entry \(label) is not running — opening the app once re-registers it")))
            }
            return finish(settled(RecipeResult(status: "updated")))
        }

        // 6. Roll back — only once both the app and its service are really gone. The sentence names
        // what actually happened: a process that never existed did not fail a health check, and on
        // the fleet page "never started" is its own status, not a rollback.
        // What the check was missing, not just how long it waited: the version on disk, the app
        // process, or the name of the service that is not running. This sentence is the only
        // diagnostic anyone at a site Mac has.
        let healthGap = appeared ? (control.healthRequirement(targetVersion) ?? "health check did not pass") : nil
        if let healthGap { mark("health \(healthGap)") }
        let why = appeared ? "the new version was not healthy within \(Int(control.healthTimeout)) s"
            + (healthGap.map { " (health: \($0))" } ?? "")
            : "the new version did not start within \(Int(appearCeiling)) s"
        guard control.quit(), control.stopService() else {
            // Both bundles stay, and so does the journal: the next run asks the bad version to stop
            // again instead of finding the new version in place and calling the app settled.
            return settled(RecipeResult(status: "rollback_blocked", reason:
                "\(targetVersion) \(why) and it would not stop; both versions were kept (previous at "
                + "\(paths.rollback.path)) and \(paths.journal.path) with them — the next run tries again"))
        }
        do {
            let result = try rollBack(paths, journal: journal, control: control, fileManager: fm, why: why)
            guard appeared else {
                var out = result
                out.status = "did_not_start"
                out.reason = result.reason.map { $0.hasPrefix(why) ? $0 : "\(why); \($0)" } ?? why
                return finish(settled(out))
            }
            return result.status == "rolled_back" ? finish(settled(result)) : settled(result)
        } catch {
            // Nothing was written away: the journal stays exactly as it is, and a later run picks
            // the rollback up again rather than reporting a Mac whose app is simply the new version.
            return settled(RecipeResult(status: "rollback_failed", reason:
                "\(targetVersion) \(why) and \(displaced ?? "the version this Mac was running") could not be put back (\(error)); "
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
        control.restoreServices(journal.serviceLabels ?? [])
        // A test/hidden instance and an unattended install are never relaunched in the owner's
        // profile, even during recovery.
        let relaunch = journal.wasRunning && !(journal.testInstance ?? false) && (journal.relaunchAfterwards ?? true)
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
                    if relaunch { control.launch() }
                    resolved = !relaunch || waitHealthy(control, version: expectedNew)
                } catch {
                    note = try restoreAfterFailure(journal, fileManager: fm)
                    if relaunch { control.launch() }
                    resolved = !relaunch || journal.previousVersion.map { waitHealthy(control, version: $0) } == true
                }
            } else {
                note = try restoreAfterFailure(journal, fileManager: fm)
                if relaunch { control.launch() }
                resolved = !relaunch || journal.previousVersion.map { waitHealthy(control, version: $0) } == true
            }
        } else if previousIsInPlace {
            if relaunch { control.launch() }
            resolved = !relaunch || waitHealthy(control, version: found!.version)
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
        // The app's own services come back on every recovery path: the bundle in place is the one
        // that should be running, and a job an interrupted run unloaded would otherwise stay down.
        // A service launchd would not take back keeps the journal, so the next run retries it.
        let resumed = control.resumeServices()
        if !resumed.ok {
            note += "; the app's background service did not restart (\(resumed.reason ?? "launchd refused")); journal kept"
            resolved = false
        }
        if resolved {
            if !journal.staged.isEmpty, fm.fileExists(atPath: journal.staged) {
                _ = Space.remove(URL(fileURLWithPath: journal.staged), shell: SystemShell(), fileManager: fm)
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
        // The services are put back once, by the caller's own resume after this returns (recover),
        // so one launchd answer decides the journal: a second call here could disagree with it.
        if journal.testInstance == true || journal.relaunchAfterwards == false {
            return ("an interrupted install had finished putting \(newVersion) in place without a "
                    + "relaunch; it was left stopped", true)
        }
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
                         fileManager fm: FileManager, why: String = "the new version was not healthy") throws -> RecipeResult {
        guard let previousVersion = journal.previousVersion else {
            throw khuFail("nothing was installed here before, so there is no previous version to put back")
        }
        var pending = journal
        pending.phase = "rolling_back"
        try AtomicFile.writeJSON(pending, to: paths.journal)
        try putBack(paths, journal: pending, expectedVersion: previousVersion, fileManager: fm)
        if journal.testInstance == true || journal.relaunchAfterwards == false {
            let resumed = control.resumeServices()
            // A service that did not come back is not an artifact judgement: the previous version
            // was put back, so the feed's artifact is not marked rejected by this.
            return resumed.ok
                ? RecipeResult(status: "rolled_back", reason: "\(why); \(previousVersion) was put back and left stopped")
                : RecipeResult(status: "install_failed", reason: "\(why); \(previousVersion) was put back, "
                               + "but its background service did not restart (\(resumed.reason ?? "launchd refused")); \(previousVersion) was put back and its journal is kept, so the next run tries again")
        }
        let resumed = control.resumeServices()
        guard resumed.ok else {
            return RecipeResult(status: "install_failed", reason: "\(why); \(previousVersion) was put back, "
                               + "but its background service did not restart (\(resumed.reason ?? "launchd refused")); \(previousVersion) was put back and its journal is kept, so the next run tries again")
        }
        control.launch()
        return waitHealthy(control, version: previousVersion)
            ? RecipeResult(status: "rolled_back", reason: "\(why); \(previousVersion) is running again")
            : RecipeResult(status: "rollback_unhealthy", reason: "\(why), and the restored \(previousVersion) is not healthy either")
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
        if fm.fileExists(atPath: prepared.path) { _ = Space.remove(prepared, shell: SystemShell(), fileManager: fm) }
        try fm.copyItem(at: rollback, to: prepared)
        guard (try? BundleInfo.read(prepared.path)) == info else { throw khuFail("the prepared rollback does not match") }
        if fm.fileExists(atPath: installed.path) {
            if fm.fileExists(atPath: displaced.path) { _ = Space.remove(displaced, shell: SystemShell(), fileManager: fm) }
            try fm.moveItem(at: installed, to: displaced)
        }
        do { try fm.moveItem(at: prepared, to: installed) }
        catch {
            if !fm.fileExists(atPath: installed.path), fm.fileExists(atPath: displaced.path) {
                try? fm.moveItem(at: displaced, to: installed)
            }
            throw error
        }
        if fm.fileExists(atPath: displaced.path) { _ = Space.remove(displaced, shell: SystemShell(), fileManager: fm) }
    }

    /// The default for how long a relaunched app has to exist at all — its own ceiling, not the
    /// health one: a launch that never produces a process is a different fault from one that starts
    /// and stays unhealthy, and it must not consume the health budget. 120 s is twice what the
    /// Gateway's relaunch took on 1301 (about 60 s from launch to process, 2026-11-17). A Mac may
    /// raise or lower it per app with `appearCeilingSeconds`; the value used is in every timings line.
    public static let appearCeiling: TimeInterval = 120

    /// The relaunched process is there. Bounded by its own ceiling, and the health clock starts
    /// only after this returns: a slow quit-and-stop is the app draining, not its start failing.
    static func waitForRunning(_ control: AppControl, clock: () -> TimeInterval, ceiling: TimeInterval) -> Bool {
        let deadline = clock() + ceiling
        repeat {
            if control.isRunning() == true { return true }
            Thread.sleep(forTimeInterval: control.pollInterval)
        } while clock() < deadline
        return control.isRunning() == true
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
        let data = attach.stdout.data(using: .utf8) ?? Data()
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        let mounts = (plist?["system-entities"] as? [[String: Any]] ?? []).filter { $0["mount-point"] is String }
        // APFS adds a synthesized disk; detach the device belonging to the mounted volume.
        guard mounts.count == 1, let mount = mounts[0]["mount-point"] as? String, mount.hasPrefix("/"),
              let device = mounts[0]["dev-entry"] as? String,
              device.range(of: #"^/dev/disk[0-9]+(?:s[0-9]+)*$"#, options: .regularExpression) != nil else {
            for device in devices { _ = detach(shell, device) }
            throw khuFail("could not determine the DMG mount point and device")
        }
        return (mount, device)
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

    /// The argv and environment a same-user process was started with, or nil when the kernel table
    /// cannot be read. Used only to tell a test/hidden instance from the owner's ordinary launch.
    public static func launchDetails(_ pid: pid_t) -> (argv: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0, argc < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // executable path
        while index < size && buffer[index] == 0 { index += 1 }   // alignment NULs
        func strings(limit: Int) -> [String] {
            var out: [String] = []
            while out.count < limit, index < size {
                var end = index
                while end < size && buffer[end] != 0 { end += 1 }
                guard end > index else { index += 1; break }   // an empty entry ends this region
                out.append(String(decoding: buffer[index..<end], as: UTF8.self))
                index = end + 1
            }
            return out
        }
        return (strings(limit: argc), strings(limit: 4096))
    }

    /// Whether these arguments are a test/hidden run's, not the owner's app. A flag alone is not
    /// that: launchd starts the Gateway as `Gateway Studio KH --background`, which is how the
    /// owner's app runs and must be put back by an install. A test says so (`--test-mode`, …) or
    /// carries its own data location — any argument naming a path, absolute, relative or `~`.
    /// Reading a path where there is none is the safe direction: the app is then left closed.
    public static func isTestLaunch(_ arguments: [String]) -> Bool {
        for argument in arguments.dropFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(parts[0]).lowercased()
            if ["--test", "--test-mode", "--headless", "--snapshot"].contains(flag) { return true }
            if argument.contains("/") || argument.hasPrefix("~") { return true }
        }
        return false
    }

    /// The login job that starts this bundle's own app (not one of its helpers), so an install can
    /// put the app back exactly as launchd started it — the Gateway's job carries `--background`.
    public static func owningJob(_ installedPath: String, agents: URL) -> (label: String, plist: URL)? {
        guard let info = try? BundleInfo.read(installedPath) else { return nil }
        let desktop = realPath(installedPath + "/Contents/MacOS/" + info.executable)
        let entries = (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []
        for url in entries where url.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: url),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let label = plist["Label"] as? String,
                  let first = (plist["ProgramArguments"] as? [String])?.first,
                  realPath(first) == desktop else { continue }
            return (label, url)
        }
        return nil
    }

    /// A test/hidden run says so, or was started with its own data location or an isolated HOME.
    /// The bundle's service processes are not the app and are ignored.
    public static func isTestInstance(_ installedPath: String, shell: Shell, agents: URL) -> Bool {
        guard let info = try? BundleInfo.read(installedPath) else { return false }
        let desktop = realPath(installedPath + "/Contents/MacOS/" + info.executable)
        let home = realPath(FileManager.default.homeDirectoryForCurrentUser.path)
        let services = Set(serviceProcesses(installedPath, shell: shell, agents: agents).values)
        for pid in processes(inBundle: installedPath) ?? [] where !services.contains(pid) {
            guard let details = launchDetails(pid), let first = details.argv.first,
                  realPath(first) == desktop else { continue }
            if isTestLaunch(details.argv) { return true }
            if let entry = details.environment.first(where: { $0.hasPrefix("HOME=") }),
               realPath(String(entry.dropFirst("HOME=".count))) != home { return true }
        }
        return false
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

    /// A launchd job the app owns. Ownership is proven from the plist and the live process, never
    /// from a name. Its restart policy is checked when it is found: only `KeepAlive: true` and
    /// `KeepAlive: {SuccessfulExit: false}` are jobs this updater can stop and put back.
    struct OwnedService {
        let label: String
        let pid: pid_t
        let plist: URL
    }

    /// The app's own loaded jobs, by label: the label is a bundle ID, its program lives inside the
    /// bundle and is not the desktop executable, and a live pid runs exactly that program. Scheduled
    /// or socket-activated jobs, and any other restart policy, are refused rather than guessed at —
    /// they can start themselves again during a bundle exchange.
    static func serviceJobs(_ installedPath: String, shell: Shell, agents: URL) -> [String: OwnedService] {
        guard let info = try? BundleInfo.read(installedPath),
              let files = try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil),
              let listed = try? shell.run("/bin/launchctl", arguments: ["list"], timeout: 15), listed.exitCode == 0 else { return [:] }
        let prefix = realPath(installedPath) + "/Contents/"
        let desktop = realPath(installedPath + "/Contents/MacOS/" + info.executable)
        var live: [String: pid_t] = [:]
        for line in listed.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 3, Int(fields[1]) != nil {
                if let pid = pid_t(fields[0]), pid > 1 { live[String(fields[2])] = pid }
                else if fields[0] == "-" { live[String(fields[2])] = 0 }
            }
        }
        var owned: [String: OwnedService] = [:]
        for file in files where file.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: file),
                  let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = job["Label"] as? String, BundleInfo.isBundleID(label),
                  let pid = live[label] else { continue }
            // Scheduled/socket activation can restart a stopped job during a bundle exchange.
            guard ["StartInterval", "StartCalendarInterval", "WatchPaths", "QueueDirectories", "StartOnMount", "PathState", "EventMonitor", "Sockets", "MachServices"].allSatisfy({ job[$0] == nil }) else { continue }
            let keepAlive = job["KeepAlive"]
            let always = (keepAlive as? Bool) == true
            let onFailure = (keepAlive as? [String: Any]).map {
                $0.count == 1 && $0["SuccessfulExit"] as? Bool == false
            } ?? false
            guard always || onFailure else { continue }  // not a policy this updater can stop and put back on its own
            let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/"),
                  realPath(program).hasPrefix(prefix), realPath(program) != desktop else { continue }
            if pid > 1 {
                guard let actual = executablePath(pid), realPath(actual) == realPath(program) else { continue }
            }
            owned[label] = OwnedService(label: label, pid: pid, plist: file)
        }
        return owned
    }

    /// The app's start-at-login items that launchd still lists but cannot start. An app-type item
    /// (`application.local.<bundle-id>.*`) records its code requirement when it is registered, so
    /// after an update replaces the signed app the item can refuse to spawn ("needs LWCR update").
    /// Only the app can register again — opening it once does — so this is **reported, never
    /// repaired here**: removing the record would delete a working login path on an app that still
    /// registers that way (2026-11-19).
    static func staleAppTypeItems(_ installedPath: String, shell: Shell) -> [String] {
        guard let info = try? BundleInfo.read(installedPath),
              let listed = try? shell.run("/bin/launchctl", arguments: ["list"], timeout: 15),
              listed.exitCode == 0 else { return [] }
        let prefix = "application.local.\(info.identifier)."
        var stale: [String] = []
        for line in listed.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let label = fields.last.map(String.init),
                  label.hasPrefix(prefix), fields[0] == "-" else { continue }
            stale.append(label)
        }
        return stale.sorted()
    }

    /// The pids of the app's own jobs, for the rules that only need "is this process the app or one
    /// of its services" (the quit wait, the service ownership check, the health check).
    static func serviceProcesses(_ installedPath: String, shell: Shell, agents: URL) -> [String: pid_t] {
        serviceJobs(installedPath, shell: shell, agents: agents).mapValues(\.pid)  // zero = loaded, not running
    }

    /// The saved plist of an owned job, by label, even while the job is unloaded — the same
    /// ownership proof and the same refusal of scheduled/socket activation as `serviceJobs`. Used
    /// only to put back a job an interrupted install had unloaded.
    static func ownedPlist(_ label: String, installedPath: String, agents: URL) -> URL? {
        guard let info = try? BundleInfo.read(installedPath),
              let files = try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil) else { return nil }
        let prefix = realPath(installedPath) + "/Contents/"
        let desktop = realPath(installedPath + "/Contents/MacOS/" + info.executable)
        for file in files where file.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: file),
                  let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  job["Label"] as? String == label, BundleInfo.isBundleID(label),
                  ["StartInterval", "StartCalendarInterval", "WatchPaths", "QueueDirectories", "StartOnMount", "PathState", "EventMonitor", "Sockets", "MachServices"].allSatisfy({ job[$0] == nil }) else { continue }
            // The saved plist must still carry a policy this updater owns: a job rewritten as
            // scheduled or with an unknown policy is not started back from a stale journal.
            let supported: Bool
            if let always = job["KeepAlive"] as? Bool {
                supported = always
            } else if let rules = job["KeepAlive"] as? [String: Any], rules.count == 1,
                      rules["SuccessfulExit"] as? Bool == false {
                supported = true
            } else {
                supported = false
            }
            guard supported else { continue }
            let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/"),
                  realPath(program).hasPrefix(prefix), realPath(program) != desktop else { continue }
            return file
        }
        return nil
    }

    /// launchd's own view of these labels: loaded (any state) and running (a live pid). Nil when
    /// `launchctl list` could not be read — that is a failure to report, never an empty list.
    static func launchdState(_ labels: Set<String>, shell: Shell) -> (loaded: Set<String>, running: Set<String>)? {
        guard let result = try? shell.run("/bin/launchctl", arguments: ["list"], timeout: 15), result.exitCode == 0 else { return nil }
        var loaded: Set<String> = [], running: Set<String> = []
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 3 else { continue }
            let label = String(fields[2])
            guard labels.contains(label) else { continue }
            loaded.insert(label)
            if let pid = pid_t(fields[0]), pid > 1 { running.insert(label) }
        }
        return (loaded, running)
    }

    /// Reads launchd's view again until `done` holds or `seconds` pass; the last state is returned
    /// (nil when the list itself cannot be read). A service starts asynchronously, so a single
    /// immediate read would call a healthy job a failure.
    static func waitLaunchd(_ labels: Set<String>, shell: Shell, seconds: TimeInterval,
                            until done: (Set<String>, Set<String>) -> Bool) -> (loaded: Set<String>, running: Set<String>)? {
        let deadline = Mono.now() + seconds
        while true {
            guard let state = launchdState(labels, shell: shell) else { return nil }
            if done(state.loaded, state.running) || Mono.now() >= deadline { return state }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Every label is stopped: either loaded with no pid (`- 0`), or — for a job this install booted
    /// out — absent from `launchctl list` entirely, which is the unloaded state bootout leaves.
    static func servicesStopped(_ labels: Set<String>, shell: Shell, unloaded: Set<String> = []) -> Bool {
        if labels.isEmpty { return true }
        guard let result = try? shell.run("/bin/launchctl", arguments: ["list"], timeout: 15), result.exitCode == 0 else { return false }
        var stopped: Set<String> = []
        var present: Set<String> = []
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 3 else { continue }
            let label = String(fields[2])
            present.insert(label)
            // A signal/crash exit could be waiting for KeepAlive's restart throttle.
            if fields[0] == "-" && fields[1] == "0" { stopped.insert(label) }
        }
        // A booted-out job is stopped only once launchd has dropped it from its list entirely; while
        // it is still listed (`- 0` included) the unload is in progress and starting it back would
        // race the teardown. A signalled job is stopped when it is listed with no pid.
        return labels.allSatisfy { label in
            unloaded.contains(label) ? !present.contains(label) : stopped.contains(label)
        }
    }

    public static func appDmg(_ installedPath: String, shell: Shell, agentsDirectory: URL? = nil,
                              quitWait: TimeInterval = 60) -> AppControl {
        let agents = agentsDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        var requiredServices: Set<String> = []
        var servicePlanFrozen = false
        /// Labels this run unloaded. Only bootout leaves a job here; a SIGTERM does not.
        var unloaded: Set<String> = []
        func jobs() -> [String: OwnedService] { serviceJobs(installedPath, shell: shell, agents: agents) }
        func appGone() -> Bool {
            guard let all = processes(inBundle: installedPath) else { return false }
            let owned = jobs()
            if !servicePlanFrozen {
                requiredServices = Set(owned.filter { $0.value.pid > 1 }.keys)
                servicePlanFrozen = true
            }
            return Set(all).subtracting(owned.filter { requiredServices.contains($0.key) }.values.map(\.pid)).isEmpty
        }
        func resume() -> ServiceResume {
            // Put back only the jobs this install owns and had running: one it unloaded is
            // bootstrapped from its saved plist (its policy re-checked first); a loaded job the stop
            // left without a pid is kickstarted. launchd's answer is read back with a bounded wait,
            // and the first failure is reported — a job that did not come back is never a silent
            // success. A job the owner had already stopped is never started: it is not in the plan.
            let wanted = unloaded.union(requiredServices)
            guard !wanted.isEmpty else { return .none }
            guard let start = launchdState(wanted, shell: shell) else {
                return ServiceResume(ok: false, reason: "launchctl list could not be read")
            }
            var failure: String?
            var loaded = start.loaded, running = start.running
            // Every job the install touched is reloaded — bootout, then bootstrap from its plist —
            // never kickstarted. A swap changes the binary's CDHash, and launchd caches the code
            // requirement a loaded job was spawned with: kickstart -k re-spawns against that stale
            // requirement and macOS kills it (OS_REASON_CODESIGNING, "needs LWCR update"), however
            // healthy the app is on disk. Only a real unload clears it (macmini-angkor, 2026-11-19).
            // A job that was running must come back with a pid; loaded-with-no-pid is not success.
            for label in wanted.sorted() {
                if loaded.contains(label) {
                    let out = try? shell.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
                    guard out?.exitCode == 0 else {
                        failure = failure ?? "launchctl bootout \(label) failed, so its code requirement was not refreshed"
                            + (out.map { " (exited \($0.exitCode))" } ?? " (failed)")
                        continue
                    }
                    loaded.remove(label)
                }
                guard let plist = ownedPlist(label, installedPath: installedPath, agents: agents) else {
                    failure = failure ?? "no owned plist to restart \(label)"
                    continue
                }
                let answer = try? shell.run("/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", plist.path], timeout: 30)
                let mustRun = requiredServices.contains(label)
                let state = waitLaunchd([label], shell: shell, seconds: mustRun ? 8 : 3) { loaded, running in
                    loaded.contains(label) && (!mustRun || running.contains(label))
                }
                guard let state, state.loaded.contains(label), !mustRun || state.running.contains(label) else {
                    failure = failure ?? "launchctl bootstrap \(label) did not bring the job back running"
                        + (answer.map { " (exited \($0.exitCode))" } ?? " (failed)")
                    continue
                }
                unloaded.remove(label)
                loaded = state.loaded
                running = state.running
            }
            return ServiceResume(ok: failure == nil, reason: failure)
        }
        return AppControl(
            isRunning: { isRunning(installedPath) },
            quit: { quit(installedPath, shell: shell, wait: quitWait, gone: { appGone() }) },
            launch: {
                _ = resume()
                // Background and hidden: an install never brings an app or window to the desktop.
                _ = try? shell.run("/usr/bin/open", arguments: ["-g", "-j", installedPath], timeout: 30)
            },
            stopService: {
                guard let all = processes(inBundle: installedPath) else { return false }
                // Only jobs that were running when the plan was frozen are stopped: a job the owner
                // had already stopped is not ours to start again, so it is left exactly as it is.
                let owned = serviceJobs(installedPath, shell: shell, agents: agents)
                    .filter { requiredServices.contains($0.key) }
                // Every process left in the bundle must be one of this app's own proven jobs.
                guard Set(all).isSubset(of: Set(owned.values.map(\.pid).filter { $0 > 1 })) else { return false }
                // Every job this app owns is unloaded, not only unconditional-KeepAlive ones: the swap
                // changes the binary's CDHash and a merely signalled job keeps launchd's old code
                // requirement, which refuses the next spawn however valid the app on disk is
                // (OS_REASON_CODESIGNING, "needs LWCR update"; macmini-angkor, 2026-11-19). Ownership
                // is re-proven immediately before: a job that is no longer provably ours is never
                // booted out.
                for (label, job) in owned.sorted(by: { $0.key < $1.key }) {
                    let again = serviceJobs(installedPath, shell: shell, agents: agents)
                    guard let current = again[label], current.plist == job.plist else { return false }
                    let result = try? shell.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
                    guard result?.exitCode == 0 else { return false }
                    unloaded.insert(label)
                }
                let unloadedPids = Set(owned.filter { unloaded.contains($0.key) }.values.map(\.pid))
                for pid in all where !unloadedPids.contains(pid) {
                    // Recheck ownership immediately before signalling; never use an old job PID.
                    if !serviceProcesses(installedPath, shell: shell, agents: agents).values.contains(pid) {
                        if kill(pid, 0) != 0 && errno == ESRCH { continue }
                        return false
                    }
                    guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
                }
                let labels = requiredServices.union(unloaded)
                let deadline = Mono.now() + quitWait
                while Mono.now() < deadline {
                    if isRunning(installedPath) == false && servicesStopped(labels, shell: shell, unloaded: unloaded) { return true }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return isRunning(installedPath) == false && servicesStopped(labels, shell: shell, unloaded: unloaded)
            },
            healthy: { expected in
                (try? BundleInfo.read(installedPath).version) == expected && isRunning(installedPath) == true
                    && (requiredServices.isEmpty || requiredServices.isSubset(of: Set(serviceProcesses(installedPath, shell: shell, agents: agents).filter { $0.value > 1 }.keys)))
            },
            // The same three conditions `healthy` checks, said one at a time so a failed install
            // names the one that was missing. Order = cheapest first, and the first failure is the
            // one the person needs.
            healthRequirement: { expected in
                let onDisk = try? BundleInfo.read(installedPath).version
                if onDisk != expected { return "version \(onDisk ?? "unknown") on disk, expected \(expected)" }
                if isRunning(installedPath) != true { return "app not running" }
                let running = Set(serviceProcesses(installedPath, shell: shell, agents: agents).filter { $0.value > 1 }.keys)
                if let missing = requiredServices.subtracting(running).sorted().first { return "service \(missing) not running" }
                return nil
            },
            healthTimeout: 60,
            serviceLabels: { Array(requiredServices.union(serviceProcesses(installedPath, shell: shell, agents: agents).filter { $0.value > 1 }.keys)).sorted() },
            restoreServices: { requiredServices = Set($0.filter(BundleInfo.isBundleID)); servicePlanFrozen = true },
            resumeServices: { resume() },
            isTestInstance: { isTestInstance(installedPath, shell: shell, agents: agents) })
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
        // Gateway retains its separate health-PID/listening-port lifecycle.
        control.serviceLabels = { [] }
        control.restoreServices = { _ in }
        control.quit = { quit(installedPath, shell: shell, wait: quitWait, gone: { appGone() }) }
        // Put the app back the way it was started: its login job carries `--background`, and
        // launching the bundle bare would start a windowed copy. Hidden either way.
        control.launch = {
            let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            guard let job = owningJob(installedPath, agents: agents) else {
                _ = try? shell.run("/usr/bin/open", arguments: ["-g", "-j", installedPath], timeout: 30)
                return
            }
            // A job the stop left unloaded is bootstrapped from its own plist first: starting the
            // bundle bare would drop `--background` and run a windowed copy.
            if launchdState([job.label], shell: shell)?.loaded.contains(job.label) != true {
                _ = try? shell.run("/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", job.plist.path], timeout: 30)
            }
            _ = try? shell.run("/bin/launchctl", arguments: ["kickstart", "gui/\(getuid())/\(job.label)"], timeout: 15)
        }
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
        // Measured on 1301 (2026-11-17): quit-to-server-healthy is 127 s, most of it the drain and
        // stop. The clock now starts when the process appears, so this is the app's own start with
        // margin — 300 s, 2.3x the measurement. It is written into every result's timings line.
        control.healthTimeout = 300
        return control
    }
}
