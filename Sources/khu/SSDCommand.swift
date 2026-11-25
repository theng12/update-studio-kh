import Foundation

/// Runs from the verified SSD Launcher, including on Macs that have never connected.
enum SSDCommand {
    static func run(volume: URL, indexSHA256: String? = nil) -> Never {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        SSDUpdateWindow.run(volume: volume, version: version) { report in
            let root = volume.standardizedFileURL.resolvingSymlinksInPath()
            let index = try SSDUpdate.index(at: root, sha256: indexSHA256)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let state = home.appendingPathComponent("Library/KHUpdater/state")
            let configFile = home.appendingPathComponent("Library/KHUpdater/base/config.json")
            let config = try AtomicFile.readJSON(AgentConfig.self, from: configFile)
            if let config, URL(fileURLWithPath: config.stateDir).standardizedFileURL != state.standardizedFileURL {
                throw khuFail("This Mac uses a different helper layout. Its apps and saved settings were left unchanged.")
            }
            let source = SSDSource(volume: root.lastPathComponent, root: root, index: index)
            SparkleInstallMarker.set("ssd")
            defer { SparkleInstallMarker.set(nil) }
            let rows = try SSDUpdate.run(source: source, stateDir: state, apps: config?.apps ?? [:], progress: { row in
                report("\(row.name): \(row.status.replacingOccurrences(of: "_", with: " "))" + (row.reason.map { " — " + $0 } ?? ""))
            })
            let accepted: Set<String> = ["installed", "updated", "repaired", "current", "not_installed"]
            var incomplete = rows.contains { !accepted.contains($0.status) }
            if let launcher = rows.first(where: { $0.id == "updater" }), accepted.contains(launcher.status), launcher.status != "not_installed" {
                let configured = config?.apps["updater"].map { URL(fileURLWithPath: $0.bundlePath) }
                let candidates = configured.map { [$0] } ?? Catalog.applicationFolders.flatMap { folder in
                    ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                }
                let matches = candidates.filter { (try? BundleInfo.read($0.path).identifier) == "com.khupdater.launcher" }
                guard matches.count == 1, let installed = matches.first else {
                    throw khuFail("Launcher could not be identified uniquely for its helper update. Saved connections were kept.")
                }
                do {
                    let result = try SSDHelper.refresh(launcher: installed)
                    report("Launcher helper: \(result.status.replacingOccurrences(of: "_", with: " "))" + (result.reason.map { " — " + $0 } ?? ""))
                    if !["switched", "current", "needs_connection"].contains(result.status) { incomplete = true }
                } catch {
                    report("Launcher helper: could not finish — \(error)")
                    incomplete = true
                }
            }
            if incomplete { throw khuFail("Some apps were kept or could not be updated. Each app’s reason is shown above.") }
        }
    }
}
