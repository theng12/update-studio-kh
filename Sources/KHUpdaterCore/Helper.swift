import Foundation

/// What the person at a Mac set from the menu-bar icon: an Automatic switch per app, each with the
/// moment it was flipped, and a pause. Kept in `<stateDir>/helper.json`. The publisher is told on
/// every report, and between the Mac's switch and the page's, the later one wins.
public struct HelperSettings: Codable, Sendable, Equatable {
    public struct Switch: Codable, Sendable, Equatable {
        public var on: Bool
        public var at: String
        public init(on: Bool, at: String) { self.on = on; self.at = at }
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
    /// The version each app was last announced at, so one update is announced once.
    public var notified: [String: String]?
    /// Automatic installs happen unless the person chose "Manually" or switched them off.
    public var installsAutomatically: Bool { checkManually != true && autoInstall != false }
    public init(automatic: [String: Switch] = [:], pausedUntil: String? = nil) {
        self.automatic = automatic; self.pausedUntil = pausedUntil
    }

    public static func file(in stateDir: URL) -> URL { stateDir.appendingPathComponent("helper.json") }
    /// An unreadable file is no settings rather than a stopped agent: the page's setting then rules.
    public static func load(from stateDir: URL) -> HelperSettings {
        (try? AtomicFile.readJSON(HelperSettings.self, from: file(in: stateDir))) ?? HelperSettings()
    }
    public func save(to stateDir: URL) throws { try AtomicFile.writeJSON(self, to: Self.file(in: stateDir)) }

    public func paused(at now: Date) -> Bool { pausedUntil.flatMap(ISO.date).map { now < $0 } ?? false }

    /// The Automatic setting to follow: this Mac's switch when it is later than the page's (a page
    /// value with no time is older than any switch), else the page's, else the Mac's config.
    public func automatic(_ app: String, page: Bool?, pageAt: String?, config: Bool) -> Bool {
        if let mine = automatic[app], let at = ISO.date(mine.at),
           page == nil || pageAt.flatMap(ISO.date).map({ at > $0 }) ?? true {
            return mine.on
        }
        return page ?? config
    }
}

/// When the page last changed a Mac's Automatic setting for one app, or the Mac reported a switch
/// that was later — so the page can say "changed on this Mac".
public struct AutomaticChange: Codable, Sendable, Equatable {
    public var at: String
    public var byMac: Bool
    public init(at: String, byMac: Bool) { self.at = at; self.byMac = byMac }
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
    public var serverVersion: String?
    public var ssdVersion: String?
    public var initialSSD: String?
    public var canRollBack = false
    /// The bundle's own `CFBundleVersion`: nil when it carries none, so a row can never claim an
    /// exact build its bundle does not state (a marketing version is shown beside it, not as it).
    public var installedBuild: String?
    /// SHA-256 of the installed executable's bytes as read from the bundle, nil when unreadable.
    public var installedExecutableSha256: String?

    public static let upToDate = "Up to date", updateAvailable = "Update available", updating = "Updating…",
                      failed = "Failed", updatesItself = "Updates itself", notInstalled = "Not installed",
                      notInFeed = "Not in the feed"

    /// One state per app, and nothing this Mac cannot vouch for reads as fine.
    public static func status(installed: String?, available: String?, statusOnly: Bool,
                              last: (status: String, reason: String)?) -> (String, String?) {
        if statusOnly { return (updatesItself, nil) }
        guard let available else { return (installed == nil ? notInstalled : notInFeed, nil) }
        let behind = installed.map { VersionCompare.isNewer(available, than: $0) } ?? true
        if behind, let last, failures.contains(last.status) { return (failed, last.reason) }
        if installed == nil { return (notInstalled, nil) }
        return behind ? (updateAvailable, nil) : (upToDate, nil)
    }
    static let failures: Set<String> = ["failed", "install_failed", "rolled_back", "rollback_failed", "rollback_unhealthy",
                                        "rollback_blocked", "download_failed", "refused", "unresolved"]
}

public enum AppNames {
    // shortcut: display names for the apps this fleet runs; any other id shows as itself. App ids and bundle IDs stay.
    static let names = ["hub": "Hub Studio KH", "story": "Story Studio KH", "gateway": "Gateway Studio KH", "updater": "Studio Launcher KH",
                        "printer-studio": "Printer Studio KH", "media-studio": "Media Studio KH", "music-studio": "Music Studio KH",
                        "kh-updater-app": "Update Studio KH"]
    public static func display(_ app: String) -> String { names[app] ?? app }
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
}
