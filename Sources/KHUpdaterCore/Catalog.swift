import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// What an app's own bundle says about it: the name people see, its identity, the bundle's file
/// name and its icon. Read from the bundle itself, so a new app needs no code here.
public struct AppMeta: Sendable, Equatable {
    public var name: String
    public var bundleID: String
    public var bundleName: String
    public var version: String
    public var iconPNG: Data?

    public static func read(app path: String) throws -> AppMeta {
        let info = try BundleInfo.read(path)
        let plist = (try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let file = URL(fileURLWithPath: path).lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? String(file.dropLast(4))
        return AppMeta(name: name, bundleID: info.identifier, bundleName: file, version: info.version, iconPNG: iconPNG(forFile: path))
    }

    /// The single app inside a DMG, read read-only and detached again.
    public static func read(dmg path: String, shell: Shell = SystemShell()) throws -> AppMeta {
        let (mount, device) = try Recipe.attach(shell, path)
        defer { _ = Recipe.detach(shell, device) }
        return try read(app: try Recipe.singleApp(in: mount, fileManager: .default))
    }

    /// 128-point PNG of what Finder shows for this file (Assets.car and .icns alike).
    public static func iconPNG(forFile path: String) -> Data? {
        #if canImport(AppKit)
        let icon = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 128, height: 128)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

/// `apps.json` at an SSD's root: what that SSD can install. Written by `khu ssd-index` at every
/// SSD refresh; paths are relative to the SSD's root. Hand edits to `id`, `name`,
/// `updatesItself` and `setup` survive the next index.
public struct SSDIndex: Codable, Sendable, Equatable {
    public static let fileName = "apps.json"
    public var format: String
    public var apps: [SSDApp]
    public init(apps: [SSDApp]) { format = "kh.apps.v1"; self.apps = apps }
}

public struct SSDApp: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var bundleID: String
    public var bundleName: String?
    public var file: String?
    public var sha256: String?
    public var updatesItself: Bool
    public var setup: String?
    public var icon: String?
    public var notes: String?
    public var tagline: String?
    public var description: String?
    public var features: [AppFeature]?
    public var accent: String?
    public var released: String?
    public var bytes: Int64?
    /// Shown only on a Mac that already has it (Update Studio KH, the control window).
    public var mainMacOnly: Bool?
    public var words: AppWords { AppWords(tagline: tagline, description: description, features: features, accent: accent) }
    public init(id: String, name: String, version: String, bundleID: String, bundleName: String? = nil, file: String? = nil,
                sha256: String? = nil, updatesItself: Bool = false, setup: String? = nil, icon: String? = nil, notes: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.bundleID = bundleID; self.bundleName = bundleName
        self.file = file; self.sha256 = sha256; self.updatesItself = updatesItself; self.setup = setup; self.icon = icon; self.notes = notes
    }
}

/// One mounted SSD that carries an `apps.json`.
public struct SSDSource: Sendable, Equatable {
    public var volume: String
    public var root: URL
    public var index: SSDIndex
    public init(volume: String, root: URL, index: SSDIndex) { self.volume = volume; self.root = root; self.index = index }

    /// Every mounted volume with a readable `apps.json`. Read only when someone opens the window
    /// or a volume mounts; an unreadable one is skipped, not fatal.
    public static func scan(_ volumes: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KHU_VOLUMES"] ?? "/Volumes")) -> [SSDSource] {
        // KHU_VOLUMES points the scan elsewhere, for tests and screenshots; nobody sets it in real use.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volumes.path)) ?? []
        return names.sorted().compactMap { name in
            let root = volumes.appendingPathComponent(name)
            guard let index = try? AtomicFile.readJSON(SSDIndex.self, from: root.appendingPathComponent(SSDIndex.fileName)) else { return nil }
            return SSDSource(volume: name, root: root, index: index)
        }
    }
}

/// One app as the Launcher lists it: from the feed, from an SSD, or both.
public struct CatalogEntry: Sendable, Equatable {
    public var id: String
    public var name: String
    public var bundleID: String?
    public var bundleName: String?
    public var updatesItself: Bool
    public var feedVersion: String?
    /// The SSD copy, when it is the one to install (newer than the feed's, or the same version
    /// and the same bytes as the feed's).
    public var ssd: Local?
    /// The newest usable copy on an SSD, kept even when the server offers a newer one: an
    /// explicit first install for a Mac that has no copy yet, before the server's newer version.
    public var initialSSD: Local?
    /// Why the copy on the SSD was not the offer, in plain words.
    public var ssdNote: String?
    public var setupFolder: String?
    public var icon: String?
    public var notes: String?
    /// For an app that updates itself: the newest version an SSD carries (it is never installed by
    /// KH Updater on its own; only the person at the Mac may install it).
    public var selfVersion: String?
    public var words = AppWords()
    public var released: String?
    public var bytes: Int64?
    public var mainMacOnly = false

    public struct Local: Sendable, Equatable {
        public var volume: String
        public var file: String
        public var sha256: String
        public var version: String
        /// The size of the copy on the drive, when it is known.
        public var bytes: Int64? = nil
        public init(volume: String, file: String, sha256: String, version: String, bytes: Int64? = nil) {
            self.volume = volume; self.file = file; self.sha256 = sha256; self.version = version; self.bytes = bytes
        }
    }

    /// The newest version on offer and where it comes from.
    public var available: String? { ssd?.version ?? feedVersion ?? selfVersion }
    public var source: String? { ssd.map(\.volume) ?? (feedVersion == nil ? nil : "Feed") }
}

public enum Catalog {
    /// Feed plus SSDs, matched by bundle ID (or app id). The SSD copy is chosen when it is at least
    /// as new as the feed's: the same version installs faster with no download.
    /// What one SSD's copy of an app may be used for.
    public enum SSDCopy {
        /// The copy may be installed now.
        case offer(CatalogEntry.Local)
        /// The copy is older than the server's: an explicit first install only, never the offer.
        case initialOnly(CatalogEntry.Local)
        /// The copy may not be used, and this says why in plain words.
        case refused(String)
    }

    /// One SSD's copy of an app, checked against the drive it sits on and against what the server
    /// signs for the same app. The bytes themselves are checked where they are installed, not here.
    public static func ssdCopy(_ app: SSDApp, file: String, sha: String, source: SSDSource, server: FeedApp?) -> SSDCopy {
        guard VersionCompare.isValid(app.version) else { return .refused("The copy on \(source.volume) names a version that cannot be compared.") }
        guard BundleInfo.isBundleID(app.bundleID) else { return .refused("The copy on \(source.volume) names no bundle that can be recognised.") }
        if let id = server?.bundleID, id != app.bundleID { return .refused("The copy on \(source.volume) is not the app the server names.") }
        let checksum = sha.lowercased()
        guard checksum.count == 64, checksum.allSatisfy({ $0.isHexDigit }) else {
            return .refused("The copy on \(source.volume) does not name its checksum the way a checksum is named.")
        }
        guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else {
            return .refused("The copy on \(source.volume) points outside the drive.")
        }
        let url = source.root.appendingPathComponent(file)
        let path = url.path
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            return .refused("The installer on \(source.volume) is missing or is not a regular file.")
        }
        do {
            let root = RealPath.of(source.root.path)
            guard RealPath.of(path).hasPrefix(root + "/") else { return .refused("The copy on \(source.volume) is a link out of the drive.") }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { return .refused("The copy on \(source.volume) is a link, not a file on the drive.") }
            if let declared = app.bytes {
                let actual = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                guard declared > 0, actual.map({ $0.int64Value == declared }) ?? false else {
                    return .refused("The copy on \(source.volume) is not the size the index names.")
                }
            }
        }
        let local = CatalogEntry.Local(volume: source.volume, file: path, sha256: checksum, version: app.version, bytes: app.bytes)
        guard let server else { return .offer(local) }   // the drive is the only source
        guard let order = VersionCompare.compare(app.version, server.version) else {
            return .refused("The copy on \(source.volume) cannot be compared with the server's version.")
        }
        switch order {
        case 1: return .offer(local)                     // newer than the server's
        case 0:
            // The same version: only the bytes the server signed count as that version.
            guard server.sha256.lowercased() == checksum else {
                return .refused("The copy on \(source.volume) is not the bytes the server signed for \(app.version).")
            }
            return .offer(local)
        default: return .initialOnly(local)              // older: an explicit first install only
        }
    }

    public static func build(feed: Feed?, ssd: [SSDSource], seen: [SSDApp] = [], icons: URL? = nil) -> [CatalogEntry] {
        var entries: [String: CatalogEntry] = [:]
        // What an SSD said before it was unplugged: names, "updates itself" and icons (cached
        // under `icons`), never anything to install.
        for app in seen where app.id != "updater" {
            var entry = CatalogEntry(id: app.id, name: app.name, bundleID: app.bundleID, bundleName: app.bundleName, updatesItself: app.updatesItself)
            if let icons, FileManager.default.fileExists(atPath: icons.appendingPathComponent("\(app.bundleID).png").path) {
                entry.icon = icons.appendingPathComponent("\(app.bundleID).png").path
            }
            entry.words = app.words
            entry.mainMacOnly = app.mainMacOnly ?? false
            entries[app.id] = entry
        }
        for (id, app) in feed?.apps ?? [:] where app.kind != "updater" {
            let key = entries.first { $0.value.bundleID != nil && $0.value.bundleID == app.bundleID }?.key ?? id
            let before = entries.removeValue(forKey: key)
            entries[id] = CatalogEntry(id: id, name: app.name ?? before?.name ?? AppNames.display(id), bundleID: app.bundleID ?? before?.bundleID,
                                       bundleName: app.bundleName ?? before?.bundleName,
                                       updatesItself: (before?.updatesItself ?? false) || Agent.statusOnly.contains(app.kind),
                                       feedVersion: app.version, icon: before?.icon, notes: app.notes)
            let w = AppWords(tagline: app.tagline, description: app.description, features: app.features, accent: app.accent)
            entries[id]?.words = w.isEmpty ? (before?.words ?? w) : w
            entries[id]?.released = app.released; entries[id]?.bytes = app.bytes
            entries[id]?.mainMacOnly = (app.mainMacOnly ?? false) || (before?.mainMacOnly ?? false)
        }
        for source in ssd {
            // The helper itself is not an app on offer: it is already here.
            for app in source.index.apps where app.id != "updater" {
                let key = entries.first { $0.value.bundleID == app.bundleID }?.key ?? app.id
                var entry = entries[key] ?? CatalogEntry(id: app.id, name: app.name, bundleID: app.bundleID, bundleName: app.bundleName,
                                                         updatesItself: app.updatesItself)
                entry.bundleID = entry.bundleID ?? app.bundleID
                entry.bundleName = entry.bundleName ?? app.bundleName
                entry.updatesItself = entry.updatesItself || app.updatesItself
                if entry.notes == nil { entry.notes = app.notes }
                if entry.words.isEmpty { entry.words = app.words }
                if app.mainMacOnly == true { entry.mainMacOnly = true }
                if let setup = app.setup { entry.setupFolder = source.root.appendingPathComponent(setup).path }
                if let icon = app.icon, entry.icon == nil { entry.icon = source.root.appendingPathComponent(icon).path }
                if let file = app.file, let sha = app.sha256 {
                    // The server's own copy of this app, when the feed names one.
                    let server = feed?.apps.values.first { $0.bundleID != nil && $0.bundleID == app.bundleID } ?? feed?.apps[app.id]
                    switch Catalog.ssdCopy(app, file: file, sha: sha, source: source, server: server) {
                    case .offer(let local):
                        // The offer: this copy is newer than the server's, or it is the same version
                        // and the same bytes the server signed.
                        if entry.ssd == nil || VersionCompare.isNewer(local.version, than: entry.ssd!.version) {
                            entry.ssd = local
                            entry.released = app.released ?? entry.released; entry.bytes = app.bytes ?? entry.bytes
                            // What's New belongs to the version on offer: the SSD's own notes when it is not the feed's version.
                            if app.version != entry.feedVersion { entry.notes = app.notes }
                        }
                        // The newest sound copy on any drive, kept even when the server has a newer
                        // one: an explicit first install for a Mac that has no copy yet.
                        if entry.initialSSD == nil || VersionCompare.isNewer(local.version, than: entry.initialSSD!.version) { entry.initialSSD = local }
                    case .initialOnly(let local):
                        if entry.initialSSD == nil || VersionCompare.isNewer(local.version, than: entry.initialSSD!.version) { entry.initialSSD = local }
                    case .refused(let why):
                        if entry.ssdNote == nil { entry.ssdNote = why }
                    }
                }
                if app.updatesItself, entry.selfVersion.map({ VersionCompare.isNewer(app.version, than: $0) }) ?? true {
                    entry.selfVersion = app.version
                }
                entries[key] = entry
            }
        }
        return entries.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundle ID → (app id, updates itself), from the feed and every SSD index this Mac has seen.
    public static func knownBundles(feed: Feed?, ssd: [SSDApp]) -> [String: (id: String, updatesItself: Bool)] {
        var known: [String: (String, Bool)] = [:]
        for app in ssd { known[app.bundleID] = (app.id, app.updatesItself) }
        for (id, app) in feed?.apps ?? [:] {
            if let b = app.bundleID { known[b] = (id, (known[b]?.1 ?? false) || Agent.statusOnly.contains(app.kind)) }
        }
        return known
    }

    /// Apps installed by hand that this Mac's config does not list yet, found by bundle ID in the
    /// usual Applications folders. An app that updates itself is reported only; any other is
    /// managed with Automatic on, the default for a new install.
    public static func discover(config: AgentConfig, known: [String: (id: String, updatesItself: Bool)],
                                folders: [URL]) -> [String: AppConfig] {
        let taken = Set(config.apps.values.map { LiveControl.realPath($0.bundlePath) })
        var found: [String: AppConfig] = [:]
        for folder in folders {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where name.hasSuffix(".app") {
                let path = folder.appendingPathComponent(name).path
                guard let info = try? BundleInfo.read(path), let hit = known[info.identifier],
                      config.apps[hit.id] == nil, found[hit.id] == nil, !taken.contains(LiveControl.realPath(path)) else { continue }
                // An app that keeps its own updater is never managed here: it is reported, and only
                // the person at this Mac may install or update it.
                let itself = hit.updatesItself || Agent.updatesItself(app: hit.id)
                found[hit.id] = AppConfig(bundlePath: path, recipe: itself ? "status" : "app-dmg",
                                          automatic: !itself, bundleID: info.identifier)
            }
        }
        return found
    }

    public static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// What this Mac can recognise when it finds an app installed: the SSD apps and feed apps seen
    /// on earlier runs (an SSD may be unplugged since), plus the SSDs mounted now. A feed app is
    /// first recognised on the run after the feed named it.
    public static func known(in stateDir: URL, ssd: [SSDSource]) -> [String: (id: String, updatesItself: Bool)] {
        knownBundles(feed: nil, ssd: seen(in: stateDir) + ssd.flatMap(\.index.apps))
    }

    /// The SSD apps this Mac has seen, kept so a hand-installed app is still recognised after the
    /// SSD is unplugged.
    public static func seenFile(in stateDir: URL) -> URL { stateDir.appendingPathComponent("ssd-apps.json") }
    public static func remember(_ ssd: [SSDSource], feed: Feed?, in stateDir: URL) {
        var seen = (try? AtomicFile.readJSON([String: SSDApp].self, from: seenFile(in: stateDir))) ?? [:]
        let before = seen
        for (id, app) in feed?.apps ?? [:] where app.kind != "updater" {
            if let b = app.bundleID {
                if seen[b] == nil { seen[b] = SSDApp(id: id, name: app.name ?? id, version: app.version, bundleID: b) }
            }
        }
        let icons = stateDir.appendingPathComponent("icons")
        for source in ssd {
            for app in source.index.apps {
                seen[app.bundleID] = app
                guard let icon = app.icon else { continue }
                try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
                let cached = icons.appendingPathComponent("\(app.bundleID).png")
                if let data = try? Data(contentsOf: source.root.appendingPathComponent(icon)), (try? Data(contentsOf: cached)) != data {
                    try? data.write(to: cached, options: .atomic)
                }
            }
        }
        for (_, app) in feed?.apps ?? [:] where Agent.statusOnly.contains(app.kind) {
            if let b = app.bundleID { seen[b]?.updatesItself = true }
        }
        guard seen != before else { return }
        try? AtomicFile.writeJSON(seen, to: seenFile(in: stateDir))
    }
    public static func seen(in stateDir: URL) -> [SSDApp] {
        Array(((try? AtomicFile.readJSON([String: SSDApp].self, from: seenFile(in: stateDir))) ?? [:]).values)
    }
}

/// Writes an SSD's `apps.json` from what is really in "1 Install Apps/": every DMG its folder's
/// SHA256.txt lists, plus any app bundle sitting in the folder. The newest version of each bundle
/// ID wins. Hand edits in the previous `apps.json` (id, name, updatesItself, setup, notes) are kept.
public enum SSDIndexer {
    public static let appsFolder = "1 Install Apps"
    public static let iconsFolder = ".apps-icons"

    public static func index(volume root: URL, feed: Feed? = nil, changelogs: [String: URL] = [:], shell: Shell = SystemShell()) throws -> SSDIndex {
        let fm = FileManager.default
        let previous = (try? AtomicFile.readJSON(SSDIndex.self, from: root.appendingPathComponent(SSDIndex.fileName)))?.apps ?? []
        let appsDir = root.appendingPathComponent(appsFolder)
        var best: [String: SSDApp] = [:]
        try fm.createDirectory(at: root.appendingPathComponent(iconsFolder), withIntermediateDirectories: true)
        for folder in try fm.contentsOfDirectory(atPath: appsDir.path).sorted() where !folder.hasPrefix(".") && !folder.hasPrefix("_") {
            let dir = appsDir.appendingPathComponent(folder)
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let hasScript = names.contains { $0.hasSuffix(".command") }
            var found: [(AppMeta, String?, String?)] = []
            let sums = (try? String(contentsOf: dir.appendingPathComponent("SHA256.txt"), encoding: .utf8)) ?? ""
            for line in sums.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].count == 64 else { continue }
                let rel = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
                guard rel.hasSuffix(".dmg"), let meta = try? AppMeta.read(dmg: dir.appendingPathComponent(rel).path, shell: shell) else { continue }
                found.append((meta, "\(appsFolder)/\(folder)/\(rel)", parts[0]))
            }
            for name in names where name.hasSuffix(".app") {
                if let meta = try? AppMeta.read(app: dir.appendingPathComponent(name).path) { found.append((meta, nil, nil)) }
            }
            for (meta, file, sha) in found {
                if let have = best[meta.bundleID], !VersionCompare.isNewer(meta.version, than: have.version) { continue }
                let old = previous.first { $0.bundleID == meta.bundleID }
                let slug = folder.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
                var icon: String?
                if let png = meta.iconPNG {
                    icon = "\(iconsFolder)/\(meta.bundleID).png"
                    try png.write(to: root.appendingPathComponent(icon!), options: .atomic)
                }
                let selfUpdating = old?.updatesItself ?? hasScript
                var app = SSDApp(id: old?.id ?? String(slug), name: old?.name ?? meta.name, version: meta.version,
                                             bundleID: meta.bundleID, bundleName: meta.bundleName, file: file, sha256: sha,
                                             updatesItself: selfUpdating,
                                             setup: old?.setup ?? (selfUpdating ? "\(appsFolder)/\(folder)" : nil), icon: icon, notes: old?.notes)
                // Hand-written words survive; the date and size are the installer's own.
                app.tagline = old?.tagline; app.description = old?.description; app.features = old?.features; app.accent = old?.accent
                app.mainMacOnly = old?.mainMacOnly
                // The feed's notes for this exact version, else this version's changelog entry, so
                // both places read the same; an app with neither keeps its folder README's list.
                let feedApp = feed?.apps[app.id]
                app.notes = (feedApp?.version == meta.version ? feedApp?.notes : nil)
                    ?? changelogs[app.id].flatMap { try? ReleaseNotes.entries(of: $0).first { $0.version == meta.version }?.notes }.flatMap { $0.isEmpty ? nil : $0 }
                    ?? whatsNew(in: dir.appendingPathComponent("README.md"), version: meta.version)
                    ?? old.flatMap { $0.version == meta.version ? $0.notes : nil }
                let path = file.map { root.appendingPathComponent($0).path } ?? dir.path
                let attrs = try? fm.attributesOfItem(atPath: path)
                app.released = (attrs?[.modificationDate] as? Date).map(ISO.string)
                app.bytes = file == nil ? nil : (attrs?[.size] as? NSNumber)?.int64Value
                best[meta.bundleID] = app
            }
        }
        let index = SSDIndex(apps: best.values.sorted { $0.name < $1.name })
        try AtomicFile.writeJSON(index, to: root.appendingPathComponent(SSDIndex.fileName))
        return index
    }

    /// The "- " lines under a "## What's new in <version>" heading, or nil.
    static func whatsNew(in readme: URL, version: String) -> String? {
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\n## ")
        guard let section = parts.first(where: { $0.lowercased().hasPrefix("what's new in \(version)") || $0.lowercased().hasPrefix("what’s new in \(version)") }) else { return nil }
        let lines = section.split(separator: "\n").dropFirst().filter { $0.hasPrefix("- ") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
