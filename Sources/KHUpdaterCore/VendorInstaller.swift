import Foundation

/// One of the owner's optional "other apps", installed from the vendor's own official source.
///
/// The order here is the contract: the assignment gate and the official HTTPS source are checked
/// before a single byte is fetched, the downloaded payload has to prove the pinned vendor identity
/// through `VendorTrust` before anything executes or is replaced, and only the app path — the one
/// with a rollback, a journal and a health check — ever touches what is installed. A package is
/// never run: it comes back `needs_admin` with the verified file, because installing one needs an
/// administrator's own credentials and this tool has no business asking for it.
public enum VendorInstaller {
    /// What the bytes are, said by the CALLER: a source URL is often a redirecting link with no
    /// extension (`https://telegram.org/dl/desktop/mac`) and a query string is not evidence of
    /// anything, so the file kind is never inferred from the URL.
    public enum Kind: String, Codable, Sendable, Equatable {
        case dmg
        case pkg
    }

    /// What happened, honestly. `installed` is claimed only after the bundle at `destination` was
    /// read back and proved to be the version that went in; `needs_admin` / `needs_person` carry
    /// `installerPath` — the verified file a later explicit "Open installer" button can hand to the
    /// owner — and never claim an install.
    public struct Outcome: Sendable, Equatable {
        public var status: String
        public var reason: String?
        /// The version on disk, only when it was proven there. nil for a package, which was not run.
        public var version: String?
        public var installerPath: String?
        public init(status: String, reason: String? = nil, version: String? = nil, installerPath: String? = nil) {
            self.status = status; self.reason = reason; self.version = version; self.installerPath = installerPath
        }
    }

    /// Install `entry`'s payload of `kind` at `destination` (`/Applications/…/X.app` for a DMG; a
    /// package has no destination here — it is handed back for the owner to run).
    ///
    /// `sourceURL` is the URL the CALLER resolved for this entry (`VendorSource.resolve`): the
    /// entry's own `sourceURL` may be a vendor page or a "latest" alias, and the bytes come from
    /// where that points right now. `byteCap` is the visible bound on the download: passed in,
    /// never invented here, so the limit enforced is the limit the caller said. `stateDir` must be
    /// the agent's own state (in real operation under `~/Library`); the payload lands in a folder
    /// this run owns under it, and the previous one moves to `_trash` — nothing is deleted.
    /// `control` is injected: a real call hands in the live control for `destination`, tests hand
    /// in a fake, and no path here launches an app on its own.
    public static func install(entry: VendorEntry, kind: Kind, sourceURL: URL, stateDir: String, destination: String,
                               http: HTTPClient, shell: Shell, control: AppControl,
                               byteCap: Int64, fileManager fm: FileManager = .default) -> Outcome {
        // 1. Gate BEFORE any download: an assignment left off costs nothing but one sentence.
        guard entry.enabled else {
            return Outcome(status: "blocked",
                           reason: "\(entry.name) is not enabled: optional assignments are off until the owner turns one on")
        }
        guard sourceURL.scheme?.lowercased() == "https",
              let host = sourceURL.host?.lowercased(), !host.isEmpty else {
            return Outcome(status: "blocked",
                           reason: "\(entry.name) source is not the official HTTPS URL: \(sourceURL.absoluteString)")
        }
        guard entry.officialHosts.contains(host) else {
            return Outcome(status: "blocked",
                           reason: "\(entry.name) source host \(host) is not an official host "
                                   + "\(entry.officialHosts.joined(separator: ", "))")
        }
        // The owner requires signatures: a published hash alone is not enough to install anything,
        // because a hash only says "these bytes" and not "this vendor made them".
        guard let team = entry.teamID, !team.isEmpty else {
            return Outcome(status: "blocked",
                           reason: "\(entry.name) has no Apple Team ID pin: installs need the vendor's signature, "
                                   + "not only a hash.\(entry.notes.map { " \($0)" } ?? "")")
        }
        guard let evidence = entry.teamIDEvidence, !evidence.isEmpty else {
            return Outcome(status: "blocked",
                           reason: "\(entry.name) has a Team ID with no evidence of where it came from")
        }
        let id: String
        do { id = try SafeName.component(entry.id, what: "vendor id") }
        catch { return Outcome(status: "blocked", reason: "\(error)") }

        // 2. One owned folder per entry; the previous download moves to `_trash` so it stays restorable.
        let state = URL(fileURLWithPath: stateDir)
        let dir = state.appendingPathComponent("vendor-downloads").appendingPathComponent(id)
        let trash = Trash.root(in: state)
        do {
            if fm.fileExists(atPath: dir.path) { try Trash.move(dir, into: trash, fileManager: fm) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return Outcome(status: "failed",
                           reason: "the download folder \(dir.path) could not be prepared (\(error)); nothing was changed")
        }
        // The name comes from the caller's kind, never from the URL: `?file=installer` proves nothing.
        let file = dir.appendingPathComponent("\(id).\(kind.rawValue)")
        let part = dir.appendingPathComponent(file.lastPathComponent + ".part")

        // The agent's HTTP client enforces official HTTPS hosts on every redirect too.
        do {
            let code = try http.download(sourceURL, headers: [:], to: part, limit: byteCap)
            guard code == 200 else {
                _ = try? Trash.move(part, into: trash, fileManager: fm)
                return Outcome(status: "download_failed",
                               reason: "\(entry.name) download answered \(code); nothing was changed")
            }
            if fm.fileExists(atPath: file.path) { try Trash.move(file, into: trash, fileManager: fm) }
            try fm.moveItem(at: part, to: file)
        } catch let error as DeliveryMismatch {
            _ = try? Trash.move(part, into: trash, fileManager: fm)
            return Outcome(status: "download_mismatch", reason: "\(error); nothing was changed")
        } catch {
            _ = try? Trash.move(part, into: trash, fileManager: fm)
            return Outcome(status: "download_failed", reason: "\(error); nothing was changed")
        }

        switch kind {
        case .pkg:
            // 4a. The package itself is judged first — its signature or the vendor's published hash.
            if case .blocked(let why) = VendorTrust.verify(entry: entry, sourceURL: sourceURL, payload: file.path, shell: shell) {
                return Outcome(status: "blocked", reason: why, installerPath: file.path)
            }
            // Never run it: no sudo, no credentials, no `installer`, no privilege of any kind.
            return Outcome(status: "needs_admin",
                           reason: "\(entry.name)'s installer at \(file.path) is verified as the pinned vendor's, but installing a "
                                   + "package needs the administrator's own credentials — KH Updater never runs installers and never asks "
                                   + "for one. Open it yourself to install it.",
                           installerPath: file.path)
        case .dmg:
            return dmg(entry: entry, file: file, sourceURL: sourceURL, stateDir: stateDir, destination: destination,
                       shell: shell, control: control, fm: fm)
        }
    }

    /// The app path: trust and version are proven on the mounted payload BEFORE `Recipe.appDmg`
    /// takes over, and that recipe keeps its own journal, rollback, staging and health checks —
    /// this adds nothing to them and takes nothing away.
    private static func dmg(entry: VendorEntry, file: URL, sourceURL: URL, stateDir: String, destination: String,
                            shell: Shell, control: AppControl, fm: FileManager) -> Outcome {
        // `Recipe.appDmg` attaches again for its own verify-and-stage; this attach exists only so
        // the pinned identity can be judged before anything runs or is replaced.
        let attachment: (mount: String, device: String)
        do { attachment = try Recipe.attach(shell, file.path) }
        catch { return Outcome(status: "failed", reason: "\(error); nothing was changed", installerPath: file.path) }
        let mount = attachment.mount
        var mounted = true
        defer { if mounted { _ = Recipe.detach(shell, attachment.device) } }

        let source: String
        do { source = try Recipe.singleApp(in: mount, fileManager: fm) }
        catch { return Outcome(status: "failed", reason: "\(error)", installerPath: file.path) }

        // A .dmg cannot be judged as bytes, so the pinned identity is judged on the .app inside
        // it — the entry already has to carry a Team ID signature (a hash alone is refused above).
        if case .blocked(let why) = VendorTrust.verify(entry: entry, sourceURL: sourceURL, payload: source, shell: shell, checksumPayload: file.path) {
            return Outcome(status: "blocked", reason: why, installerPath: file.path)
        }

        let info: BundleInfo
        do { info = try BundleInfo.read(source) }
        catch { return Outcome(status: "failed", reason: "the DMG's bundle is invalid: \(error); nothing was changed",
                               installerPath: file.path) }
        guard VersionCompare.isValid(info.version) else {
            return Outcome(status: "failed",
                           reason: "the DMG's bundle names \(info.version), which is not a version this Mac can compare; nothing was changed",
                           installerPath: file.path)
        }
        if let want = entry.bundleID, info.identifier != want {
            return Outcome(status: "failed",
                           reason: "DMG holds \(info.identifier), the entry pins \(want); nothing was changed",
                           installerPath: file.path)
        }
        // A different app already at the destination is never replaced: Telegram from the App Store
        // (`ru.keepcoder.Telegram`) and Telegram from the vendor's own DMG (`com.tdesktop.Telegram`)
        // are two different bundles with two different sets of accounts, and swapping one over the
        // other would take those accounts with it. The owner decides which one stays.
        if let installedInfo = try? BundleInfo.read(destination) {
            if let want = entry.bundleID, installedInfo.identifier != want {
                return Outcome(status: "refused",
                               reason: "\(destination) already holds \(installedInfo.identifier), and this entry installs "
                                       + "\(want) — a different bundle with its own accounts; it is not replaced. Nothing was changed",
                               installerPath: file.path)
            }
            if VersionCompare.compare(info.version, installedInfo.version) == -1 {
                return Outcome(status: "refused",
                               reason: "\(entry.name) DMG holds \(info.version), this Mac has \(installedInfo.version); no downgrade",
                               installerPath: file.path)
            }
        }

        let detachNote = Recipe.detach(shell, attachment.device)
        guard detachNote.isEmpty else {
            return Outcome(status: "needs_person", reason: detachNote + "; nothing was changed", installerPath: file.path)
        }
        mounted = false

        let result: RecipeResult
        do {
            result = try Recipe.appDmg(shell: shell, installedPath: destination, artifactPath: file.path,
                                       feedVersion: info.version, expectedBundleID: entry.bundleID,
                                       stateDir: stateDir, app: "vendor-" + entry.id, control: control, fileManager: fm,
                                       verifyStaged: { staged in
                    if case .blocked(let why) = VendorTrust.verify(entry: entry, sourceURL: sourceURL,
                                                                   payload: staged, shell: shell, checksumPayload: file.path) {
                        throw khuFail("staged vendor signature refused: \(why); nothing was changed")
                    }
                })
        } catch {
            let journal = Recipe.journalURL(stateDir: stateDir, app: "vendor-" + entry.id)
            if Recipe.isUnresolved(stateDir: stateDir, app: "vendor-" + entry.id) {
                return Outcome(status: "needs_person",
                               reason: "\(error); \(journal.path) is kept — a person has to finish or undo this install",
                               installerPath: file.path)
            }
            return Outcome(status: "failed", reason: "\(error); nothing was changed", installerPath: file.path)
        }
        if result.status != "updated" {
            return Outcome(status: result.status, reason: result.reason,
                           version: (try? BundleInfo.read(destination))?.version, installerPath: file.path)
        }
        // The staged payload was verified before promotion; read back what actually settled.
        if result.status == "updated",
           let installedInfo = try? BundleInfo.read(destination),
           installedInfo.version == info.version,
           installedInfo.executableIsRunnable(in: destination) {
            return Outcome(status: "installed", reason: result.reason, version: installedInfo.version,
                           installerPath: file.path)
        }
        return Outcome(status: "needs_person",
                       reason: (result.reason.map { "\($0); " } ?? "")
                               + "\(entry.name) is not proven at \(destination) as \(info.version); nothing is claimed installed",
                       installerPath: file.path)
    }
}
