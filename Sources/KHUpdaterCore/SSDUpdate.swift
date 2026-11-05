import Foundation

public struct SSDUpdateRow: Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: String
    public var reason: String?
    public init(id: String, name: String, status: String, reason: String? = nil) {
        self.id = id; self.name = name; self.status = status; self.reason = reason
    }
}

/// The explicit local SSD action; it never changes Automatic, trust, or pause settings.
public enum SSDUpdate {
    public static func index(at root: URL, sha256: String? = nil) throws -> SSDIndex {
        let data = try Data(contentsOf: root.appendingPathComponent(SSDIndex.fileName))
        if let sha256, Signing.sha256Hex(data) != sha256 {
            throw khuFail("The SSD apps list changed after Launcher was checked. Nothing was installed; start the SSD action again.")
        }
        return try JSON.decode(SSDIndex.self, from: data)
    }

    public static func run(source: SSDSource, stateDir: URL, folders: [URL] = Catalog.applicationFolders,
                           apps: [String: AppConfig] = [:], shell: Shell = SystemShell(),
                           control: ((SSDApp, String) -> AppControl)? = nil,
                           install: ((SSDApp, String, String, AppControl) throws -> RecipeResult)? = nil,
                           now: Date = Date(), progress: ((SSDUpdateRow) -> Void)? = nil) throws -> [SSDUpdateRow] {
        guard source.index.format == "kh.apps.v1", !source.index.apps.isEmpty else { throw khuFail("This SSD has no supported apps list.") }
        var ids = Set<String>(), bundles = Set<String>()
        for app in source.index.apps {
            _ = try SafeName.component(app.id, what: "SSD app id")
            guard ids.insert(app.id).inserted, BundleInfo.isBundleID(app.bundleID),
                  bundles.insert(app.bundleID).inserted, VersionCompare.isValid(app.version) else {
                throw khuFail("The SSD apps list has duplicate identities or invalid versions. Nothing was installed.")
            }
            if let name = app.bundleName {
                _ = try SafeName.component(name, what: "app bundle name")
                guard name.hasSuffix(".app") else { throw khuFail("The SSD app bundle name is invalid.") }
            }
        }
        return try FileLock.withExclusive(stateDir.appendingPathComponent("agent.lock"), wait: false) {
            let fm = FileManager.default
            let paused = HelperSettings.load(from: stateDir).paused(at: now)
            let root = RealPath.of(source.root.path)
            var rows: [SSDUpdateRow] = []
            var destinations = Set<String>()
            for app in source.index.apps {
                func row(_ status: String, _ reason: String? = nil) -> SSDUpdateRow {
                    SSDUpdateRow(id: app.id, name: app.name, status: status, reason: reason)
                }
                let result: SSDUpdateRow
                do {
                    var matches: [String] = []
                    for folder in folders {
                        if !fm.fileExists(atPath: folder.path) { continue }
                        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "app" {
                            if (try? BundleInfo.read(file.path).identifier) == app.bundleID { matches.append(file.path) }
                        }
                    }
                    if let saved = apps[app.id], saved.bundlePath.hasSuffix(".app"), fm.fileExists(atPath: saved.bundlePath) {
                        if let identity = try? BundleInfo.read(saved.bundlePath).identifier, identity != app.bundleID {
                            throw khuFail("The saved app path belongs to a different app. Nothing was replaced.")
                        }
                        guard saved.bundleID == nil || saved.bundleID == app.bundleID else { throw khuFail("The SSD identity differs from this Mac’s saved app.") }
                        matches.append(saved.bundlePath)
                    }
                    matches = Dictionary(grouping: matches, by: { Agent.bundleKey($0) }).values.compactMap(\.first).sorted()
                    guard matches.count <= 1 else { throw khuFail("More than one installed copy was found. Keep the intended copy before trying again.") }
                    let path: String
                    if let installed = matches.first { path = installed }
                    else {
                        guard app.id == "updater", app.bundleID == "com.khupdater.launcher" else {
                            // A damaged named bundle is still installed; never silently call it absent.
                            if let name = app.bundleName, folders.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(name).path) }) {
                                throw khuFail("An app at the expected path has unreadable or different identity. Open its setup folder to repair it.")
                            }
                            result = row("not_installed", "Not on this Mac; skipped.")
                            rows.append(result); progress?(result); continue
                        }
                        guard let name = app.bundleName else { throw khuFail("The SSD does not name the Launcher app bundle.") }
                        let folder = folders.first(where: { fm.isWritableFile(atPath: $0.path) }) ?? folders.last
                        guard let folder else { throw khuFail("No Applications folder is available.") }
                        path = folder.appendingPathComponent(name).path
                        guard !fm.fileExists(atPath: path) else { throw khuFail("The Launcher path already contains an unrecognized app. Nothing was replaced.") }
                    }
                    guard destinations.insert(Agent.bundleKey(path)).inserted else { throw khuFail("Another SSD row already names this app path.") }
                    if paused {
                        result = row("paused", "Updates are paused on this Mac. Its pause was kept.")
                    } else if let info = try? BundleInfo.read(path), let order = VersionCompare.compare(app.version, info.version), order < 0 {
                        result = row("current", "A newer version (\(info.version)) is already installed; kept.")
                    } else {
                        guard path.hasPrefix("/"), path.hasSuffix(".app") else { throw khuFail("The installed app path is invalid.") }
                        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                        guard fm.isWritableFile(atPath: parent.path), !fm.fileExists(atPath: path) || fm.isWritableFile(atPath: path) else {
                            throw khuFail("This app cannot be replaced by the signed-in user. No forced install was attempted.")
                        }
                        guard let relative = app.file, !relative.hasPrefix("/"), let pin = app.sha256,
                              pin.count == 64, pin.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                            throw khuFail("The SSD installer has no valid file and checksum.")
                        }
                        let artifact = source.root.appendingPathComponent(relative)
                        guard RealPath.of(artifact.path).hasPrefix(root + "/"), artifact.pathExtension.lowercased() == "dmg" else {
                            throw khuFail("The installer must be a DMG inside this SSD.")
                        }
                        let digest = try Signing.sha256Hex(fileAt: artifact)
                        guard digest.hex == pin, app.bytes.map({ $0 == digest.bytes }) ?? true else {
                            throw khuFail("The SSD installer does not match its checksum. Nothing was installed.")
                        }
                        let ctl = control?(app, path) ?? ((app.id == "gateway" || apps[app.id]?.recipe == "gateway")
                            ? LiveControl.gateway(path, shell: shell) : LiveControl.appDmg(path, shell: shell))
                        if ["hub", "story", "gateway"].contains(app.id), ctl.isRunning() != false {
                            result = row("busy", "Quit this app when its work is finished, then run this SSD action again. No quiet point was proved.")
                        } else {
                            // Mount private verified bytes: the SSD can change after its first checksum.
                            let staging = stateDir.appendingPathComponent("ssd-staging/\(UUID().uuidString)")
                            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            defer { _ = try? Trash.move(staging, into: Trash.root(in: stateDir)) }
                            let local = staging.appendingPathComponent("installer.dmg")
                            try fm.copyItem(at: artifact, to: local)
                            guard try Signing.sha256Hex(fileAt: local).hex == pin else { throw khuFail("The SSD installer changed while copying. Nothing was installed.") }
                            let outcome: RecipeResult
                            if let install { outcome = try install(app, path, local.path, ctl) }
                            else {
                                outcome = try Recipe.appDmg(shell: shell, installedPath: path, artifactPath: local.path,
                                    feedVersion: app.version, expectedBundleID: app.bundleID, stateDir: stateDir.path,
                                    app: app.id, control: ctl, verifyStaged: { staged in
                                        let checked = try shell.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", staged], timeout: 60)
                                        // Released KH linker-signed apps may have no resource seal; the pinned DMG binds their bytes.
                                        let unsealed = checked.exitCode == 1 && checked.stdout.isEmpty && checked.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "\(staged): code has no resources but signature indicates they must be present"
                                        guard checked.exitCode == 0 || unsealed else { throw khuFail("The staged app signature could not be verified; nothing was replaced.") }
                                    })
                            }
                            result = row(outcome.status, outcome.reason)
                        }
                    }
                } catch { result = row("refused", "\(error)") }
                rows.append(result); progress?(result)
            }
            return rows
        }
    }
}
