import Foundation

/// What the person at a Mac set from the menu-bar icon: an Automatic switch per app, each with the
/// moment it was flipped, and a pause. Kept in `<stateDir>/helper.json`. The publisher is told on
/// every report, and between the Mac's switch and the page's, the later one wins.
public struct HelperSettings: Codable, Sendable, Equatable {
    public struct Switch: Codable, Sendable, Equatable {
        public var on: Bool
        public var at: String
        public init(on: Bool, at: String = "") { self.on = on; self.at = at }
        enum CodingKeys: String, CodingKey { case on, at }
        /// A hand-written helper.json may carry a bare `true`/`false` instead of `{on, at}`; it is
        /// a valid Mac switch with no time rather than a reason to fail the whole file.
        public init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
                on = try keyed.decode(Bool.self, forKey: .on)
                at = try keyed.decodeIfPresent(String.self, forKey: .at) ?? ""
            } else {
                on = try decoder.singleValueContainer().decode(Bool.self)
                at = ""
            }
        }
    }
    public var automatic: [String: Switch]
    public var pausedUntil: String?
    /// The Launcher's settings. Each is optional; nil is its default.
    public var checkManually: Bool?
    public var autoInstall: Bool?
    public var notify: Bool?
    public var appearance: String?
    public var menuBarWhenClosed: Bool?
    public var hidden: [String]?
    /// Rotating-log verbosity on this Mac: quiet, normal (the default) or verbose. AgentLog reads
    /// it from helper.json, so a change takes effect on the next start without a rebuild.
    public var logVerbosity: String?
    /// The version each app was last announced at, so one update is announced once — and a
    /// dismissed notice never returns for that version.
    public var notified: [String: String]?
    /// `grid` or `list`, this Mac's own choice; nil is grid, the fresh-install default.
    public var viewMode: String?
    /// App ids whose "manage it?" offer was declined, so it is not asked again on this Mac.
    public var adoptionDeclined: [String]?
    /// Automatic installs happen unless the person chose "Manually" or switched them off.
    public var installsAutomatically: Bool { checkManually != true && autoInstall != false }
    public init(automatic: [String: Switch] = [:], pausedUntil: String? = nil) {
        self.automatic = automatic; self.pausedUntil = pausedUntil
    }

    public static func file(in stateDir: URL) -> URL { stateDir.appendingPathComponent("helper.json") }
    /// An unreadable file is no settings rather than a stopped agent: the page's setting then rules.
    public static func load(from stateDir: URL) -> HelperSettings {
        var settings = (try? AtomicFile.readJSON(HelperSettings.self, from: file(in: stateDir))) ?? HelperSettings()
        // "Default" was a fourth choice until 2026-11-12; a stored one means System now, mapped on
        // read so no screen has to know the old name.
        if settings.appearance == "default" { settings.appearance = "system" }
        return settings
    }
    public func save(to stateDir: URL) throws { try AtomicFile.writeJSON(self, to: Self.file(in: stateDir)) }

    public func paused(at now: Date) -> Bool { pausedUntil.flatMap(ISO.date).map { now < $0 } ?? false }

    /// Which of the three inputs the Automatic decision below takes its value from. It names the
    /// rule's own branches, so a screen can say who set what it shows without working out a second,
    /// competing policy.
    public enum AutomaticOrigin: String, Codable, Sendable {
        /// This Mac's switch, flipped from the menu-bar icon or the Launcher.
        case mac
        /// The controller page's value, which was the later change.
        case page
        /// Neither has it: this Mac's own configured default rules.
        case config
    }

    /// The Automatic setting to follow, and where it came from.
    public struct AutomaticDecision: Sendable {
        public var on: Bool
        public var origin: AutomaticOrigin
        public init(on: Bool, origin: AutomaticOrigin) { self.on = on; self.origin = origin }
    }

    /// The Automatic setting to follow and where it comes from. `automatic(_:page:pageAt:config:)`
    /// is this same decision's value, so the explanation cannot drift from what the agent does.
    public func automaticDecision(_ app: String, page: Bool?, pageAt: String?, config: Bool) -> AutomaticDecision {
        if let mine = automatic[app] {
            // A switch with no usable time (a bare bool, or a missing/unparseable `at`) has nothing
            // to lose by, so it always wins. A timed one loses only to a page value provably later
            // than it: a tie or a page with no time is not later, so the Mac's switch decides.
            let pageLater = ISO.date(mine.at).map { mineAt in
                pageAt.flatMap(ISO.date).map { $0 > mineAt } ?? false
            } ?? false
            if page == nil || !pageLater {
                return AutomaticDecision(on: mine.on, origin: .mac)
            }
        }
        return AutomaticDecision(on: page ?? config, origin: page == nil ? .config : .page)
    }

    /// The Automatic setting to follow: this Mac's switch when it is later than the page's (a page
    /// value with no time is older than any switch), else the page's, else the Mac's config.
    public func automatic(_ app: String, page: Bool?, pageAt: String?, config: Bool) -> Bool {
        automaticDecision(app, page: page, pageAt: pageAt, config: config).on
    }
}

extension HelperSettings.AutomaticOrigin {
    /// The origin in the words a person reads, said once here so the menu-bar icon and the Launcher
    /// page describe the one rule above rather than each inventing their own.
    public var words: String {
        switch self {
        case .mac: return "Set on this Mac"
        case .page: return "Set in Update Studio"
        case .config: return "This Mac’s default"
        }
    }
}

/// When the page last changed a Mac's Automatic setting for one app, or the Mac reported a switch
/// that was later — so the page can say "changed on this Mac".
public struct AutomaticChange: Codable, Sendable, Equatable {
    public var at: String
    public var byMac: Bool
    public init(at: String, byMac: Bool) { self.at = at; self.byMac = byMac }
}

/// What a row's notes carry, and the cap the Launcher applies to them. Owner, 2026-11-24: Story's
/// 1.4.419 body is 29,955 characters and the feed went 21 KB to 54 KB. The feed carrying the whole
/// body is the app line's problem; rendering all of it is this screen's, so a row keeps whole lines
/// up to `limit` and says, in one line, how much it left in the release.
public enum NotesClamp {
    public static let limit = 4_000
    /// Whole lines, trimmed, bullets stripped — and when anything was left out, one last line that
    /// says so. A single line longer than the cap is cut to the cap rather than dropped.
    public static func lines(_ text: String?, limit: Int = NotesClamp.limit) -> [String] {
        guard limit > 0 else { return [] }
        let all = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var kept: [String] = [], used = 0
        for line in all {
            let cost = line.count + (kept.isEmpty ? 0 : 1)
            if used + cost > limit {
                if kept.isEmpty { kept.append(String(line.prefix(limit))); used = limit }
                break
            }
            kept.append(line); used += cost
        }
        let left = all.count - kept.count
        if left > 0 { kept.append("…and \(left) more line\(left == 1 ? "" : "s") in the release notes.") }
        return kept
    }
}

/// One app as the menu-bar icon shows it after a run.
public struct HelperApp: Sendable, Equatable {
    public var app: String
    public var installed: String?
    public var available: String?
    public var statusOnly: Bool
    public var automatic: Bool
    public var status: String
    public var reason: String?
    /// What the Launcher window shows besides the menu's line.
    public var name = ""
    public var feedType: String?
    public var source: String?
    public var notes: String?
    public var icon: String?
    public var bundlePath: String?
    public var setupFolder: String?
    /// False for an app on offer that this Mac does not have.
    public var managed = true
    public var words = AppWords()
    public var released: String?
    public var installedAt: String?
    public var bytes: Int64?
    /// The SSD the install would copy from, when it is not the feed.
    public var fromSSD: String?
    /// Why an SSD's copy could not be used, in `Catalog`'s own words. nil when nothing was refused.
    public var ssdNote: String?
    /// Where the `automatic` value shown here comes from, in `AutomaticOrigin.words`. nil for an app
    /// this Mac has no Automatic switch for (it updates itself, or it is not managed here).
    public var automaticOrigin: String?
    public var serverVersion: String?
    public var ssdVersion: String?
    public var initialSSD: String?
    /// True when the drive's copy is newer than the feed's (or the feed carries none). The page
    /// offers that copy first; an older one is offered only as a deliberate choice, never as the
    /// update (owner, 2026-11-24: "it shouldn't just offer to downgrade").
    public var initialSSDNewer = false
    /// Every source compared once with what this Mac has, in the words the page shows. Nil when the
    /// feed is the only source and says nothing the version line does not already say.
    public var sourcesText: String?
    public var canRollBack = false
    /// The bundle's own `CFBundleVersion`: nil when it carries none, so a row can never claim an
    /// exact build its bundle does not state (a marketing version is shown beside it, not as it).
    public var installedBuild: String?
    /// SHA-256 of the installed executable's bytes as read from the bundle, nil when unreadable.
    public var installedExecutableSha256: String?
    /// True when the person at this Mac may install or update this app by choosing it, even though
    /// the app updates itself: KH Updater never does that on its own, the Launcher does it on request.
    public var manuallyInstallable = false
    /// True when a first Install or an Update has a recipe the agent will really run for this app.
    public var installable = true
    /// Set on an app that has been retired into another, in plain words, when this Mac still has its
    /// bundle: the row is shown once, says what happened, and offers nothing but the manual actions.
    public var retired: String?

    public static let upToDate = "Up to date", updateAvailable = "Update available", updating = "Updating…",
                      receiving = "Receiving update…", failed = "Failed", needsAttention = "Needs attention",
                      downloaded = "Downloaded", updatesItself = "Updates itself", notInstalled = "Not installed",
                      notInFeed = "Not in the feed", shipsWithLauncher = "Ships with the Launcher"

    /// Default retry ceiling for a row before it stops offering Update all / primary Update.
    public static let failureCeiling = 3

    /// True when "Update all" includes this row: managed, feed-driven, not retired, and either
    /// behind the offered version, failed below the retry ceiling, or downloaded and waiting.
    public static func updateAllEligible(_ app: HelperApp) -> Bool {
        app.managed && !app.statusOnly && app.retired == nil && app.available != nil
            && (app.status == updateAvailable || app.status == failed || app.status == downloaded)
    }

    /// One state per app, and nothing this Mac cannot vouch for reads as fine.
    public static func status(installed: String?, available: String?, statusOnly: Bool, manual: Bool = false,
                              last: (status: String, reason: String)?,
                              consecutiveFailures: Int = 0, failureCeiling: Int = HelperApp.failureCeiling) -> (String, String?) {
        func failure(_ reason: String) -> (String, String?) {
            let terminal = failureCeiling > 0 && consecutiveFailures >= failureCeiling
            return (terminal ? needsAttention : failed, reason)
        }
        if statusOnly {
            // An app that updates itself is still installed by hand when the person asks for it: the
            // state says what is true on this Mac, not who would do it.
            guard manual, let available else { return (updatesItself, nil) }
            // A version already on disk can still be unsettled (its service did not come back).
            if let last, ["install_failed", "unresolved"].contains(last.status) { return failure(last.reason) }
            let behind = installed.map { VersionCompare.isNewer(available, than: $0) } ?? true
            if behind, let last, failures.contains(last.status) { return failure(last.reason) }
            if installed == nil { return (notInstalled, nil) }
            return behind ? (updateAvailable, nil) : (updatesItself, nil)
        }
        guard let available else { return (installed == nil ? notInstalled : notInFeed, nil) }
        // The new version may be on disk while its install is unresolved: never "Up to date" then.
        if let last, ["install_failed", "unresolved"].contains(last.status) { return failure(last.reason) }
        let behind = installed.map { VersionCompare.isNewer(available, than: $0) } ?? true
        if behind, let last, failures.contains(last.status) { return failure(last.reason) }
        if installed == nil { return (notInstalled, nil) }
        return behind ? (updateAvailable, nil) : (upToDate, nil)
    }
    public static let failures: Set<String> = ["failed", "install_failed", "rolled_back", "rollback_failed", "rollback_unhealthy",
                                               "rollback_blocked", "download_failed", "refused", "unresolved"]
}

/// Text a menu-bar item can hold. The summary is cut at a whole word and the whole sentence is
/// kept in the log and the item's tooltip: an explanation that stops inside a word ("use the
/// publi…") reads as a fault of its own.
public enum MenuText {
    public static func short(_ text: String, limit: Int = 90) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        guard let space = head.lastIndex(of: " ") else { return String(text.prefix(limit - 1)) + "…" }
        return String(head[..<space]) + "…"
    }

    /// A menu line and the whole sentence behind it: the title is cut at a whole word and the
    /// tooltip carries every character, so a long operator message reaches the menu intact instead
    /// of ending mid-instruction (2026-11-19).
    public static func item(_ text: String, limit: Int = 90) -> (title: String, tooltip: String?) {
        let title = short(text, limit: limit)
        return (title, title == text ? nil : text)
    }
}

public enum AppNames {
    // shortcut: display names for the apps this fleet runs; any other id shows as itself. App ids and bundle IDs stay.
    static let names = ["hub": "Hub Studio KH", "story": "Story Studio KH", "gateway": "Gateway Studio KH", "updater": "Studio Launcher KH Helper",
                        "printer-studio": "Printer Studio KH", "media-studio": "Media Studio KH", "music-studio": "Music Studio KH",
                        "kh-updater-app": "Update Studio KH"]
    public static func display(_ app: String) -> String { names[app] ?? app }
}

/// Apps that were folded into another and are no longer presented as current (owner, 2026-11-17).
/// The id, its published versions and its feed entry stay: a published version is never withdrawn,
/// and nothing here is uninstalled for anyone — only the row says what it is now.
public enum RetiredApps {
    public static let notes = ["kh-updater-app": "Update Studio KH is retired into Studio Launcher KH. Its fleet window is the Launcher's Fleet window; nothing new is published for it."]
    public static func note(_ app: String) -> String? { notes[app] }
}

/// Release notes compiled from the shared CHANGELOG parser, never a target-side file.
public enum WhatsNew {
    public struct Entry: Decodable, Sendable {
        public var version: String
        public var date: String?
        public var items: [String]
    }
    public static let publisher = try! JSON.decode([Entry].self, from: Data(Changelog.textJSON.utf8))
    public static let launcher = try! JSON.decode([Entry].self, from: Data(Changelog.launcherJSON.utf8))
    public static func lines(for version: String) -> [String] {
        launcher.first { $0.version == version }?.items ?? []
    }

    /// The What's New dialog's body: the version being shown, its date and change count, its
    /// changes, then the four releases before it. Newest first; unknown versions say so.
    public static func dialogBody(app: String, shown: String, entries: [Entry], escape h: (String) -> String) -> String {
        // The changelog's Markdown marks (`**`, backticks) are not shown as characters.
        func list(_ items: [String]) -> String {
            "<ul class=newslist>" + items.map { "<li>\(h($0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")))</li>" }.joined() + "</ul>"
        }
        guard let index = entries.firstIndex(where: { $0.version == shown }) ?? (entries.isEmpty ? nil : 0) else {
            return "<p class=newshead><strong>\(h(app)) v\(h(shown))</strong></p><p class=newssum>Release notes are not available for this version.</p>"
        }
        let entry = entries[index]
        let count = entry.items.count
        let mismatch = entry.version == shown ? "" : " This window runs v\(h(shown)), which has no notes of its own; these are the newest."
        var out = "<p class=newshead><strong>\(h(app)) v\(h(entry.version))</strong>"
            + (entry.version == shown ? "<span class=tag>This version</span>" : "")
            + (entry.date.map { "<span class=when>\(h($0))</span>" } ?? "") + "</p>"
            + "<p class=newssum>\(count) change\(count == 1 ? "" : "s") in this release.\(mismatch)</p>"
            + (count == 0 ? "<p>Release notes are not available for this version.</p>" : list(entry.items))
        for earlier in entries.dropFirst(index + 1).prefix(4) {
            out += "<section class=rel><h3>v\(h(earlier.version))" + (earlier.date.map { " <span class=when>\(h($0))</span>" } ?? "")
                + "</h3>\(list(earlier.items))</section>"
        }
        return out
    }
}
