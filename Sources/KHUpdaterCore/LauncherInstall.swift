import Foundation

extension Agent {
    /// Register before staging so recovery can find even an interrupted first installation.
    static func registerLauncherApps(_ requested: Set<String>, catalog: [CatalogEntry], config: inout AgentConfig,
                                     stateDir: URL, folders: [URL]) throws -> [String: String] {
        let file = stateDir.appendingPathComponent("launcher-apps.json")
        var saved = try AtomicFile.readJSON([String: AppConfig].self, from: file) ?? [:]
        var failures: [String: String] = [:]
        for app in requested.sorted() where config.apps[app] == nil {
            guard let entry = catalog.first(where: { $0.id == app }), !entry.mainMacOnly else { continue }
            do {
                guard let bundle = entry.bundleName, let identity = entry.bundleID else {
                    throw khuFail("The installer for \(entry.name) does not name its app bundle. Update Studio needs to publish its app details before a first install.")
                }
                _ = try SafeName.component(app, what: "app id")
                _ = try SafeName.component(bundle, what: "app bundle")
                guard bundle.hasSuffix(".app"), !identity.isEmpty else { throw khuFail("The installer does not name a usable app bundle.") }
                let matches = folders.map { $0.appendingPathComponent(bundle) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                guard matches.count <= 1 else { throw khuFail("More than one copy of \(entry.name) exists. Choose the intended installed copy first.") }
                let path: URL
                if let existing = matches.first {
                    guard let info = try? BundleInfo.read(existing.path), info.identifier == identity else {
                        throw khuFail("The existing \(entry.name) has unreadable or different identity. Nothing was replaced.")
                    }
                    path = existing
                } else {
                    guard let folder = folders.first(where: { FileManager.default.isWritableFile(atPath: $0.path) }) else {
                        throw khuFail("No Applications folder is writable by this user. Nothing was installed.")
                    }
                    path = folder.appendingPathComponent(bundle)
                }
                // An app that updates itself keeps its own policy: it is registered so a first
                // install can be recovered, but it is never managed by KH Updater on its own.
                let itself = Agent.updatesItself(app: app, entry: entry)
                let cfg = AppConfig(bundlePath: path.path, recipe: itself ? "status" : "app-dmg", automatic: !itself, bundleID: identity)
                var candidate = config
                candidate.apps[app] = cfg
                try validate(candidate)
                var registration = saved
                registration[app] = cfg
                try AtomicFile.writeJSON(registration, to: file)
                saved = registration
                config = candidate
            } catch { failures[app] = String(describing: error) }
        }
        return failures
    }

    /// Offline is explicit local work only; no cached feed is presented as a fresh server answer.
    static func offlineSSD(config original: AgentConfig, requested: Set<String>, installed: [String: String],
                           memory: inout AgentMemory, stateDir: URL, ssd: [SSDSource], http: HTTPClient,
                           shell: Shell, control: (String, AppConfig) -> AppControl, executable: String?,
                           serverBase: URL, now: Date, installing: (String?) -> Void, appFolders: [URL],
                           reinstall: Set<String> = [], rollbacks: Set<String> = [], initialSSD: Set<String> = [], previousResult: AgentRunResult = AgentRunResult()) throws -> AgentRunResult {
        var config = original
        Catalog.remember(ssd, feed: nil, in: stateDir)
        let catalog = Catalog.build(feed: nil, ssd: ssd, seen: Catalog.seen(in: stateDir), icons: stateDir.appendingPathComponent("icons"))
        let failures = try registerLauncherApps(requested, catalog: catalog, config: &config, stateDir: stateDir, folders: appFolders)
        var result = previousResult
        result.feedError = FeedUnavailable().description
        let helper = HelperSettings.load(from: stateDir)
        for app in requested.union(rollbacks).sorted() {
            let outcome: RecipeResult
            let id = "auto-\(app)-local-\(UUID().uuidString)"
            if let failure = failures[app] {
                outcome = RecipeResult(status: "refused", reason: failure)
            } else if let cfg = config.apps[app], !Agent.updatesItself(app: app, recipe: cfg.recipe) || requested.contains(app) {
                DownloadControl.reset()
                installing(app)
                defer { installing(nil) }
                let current = installed[app] ?? (try? BundleInfo.read(cfg.bundlePath).version)
                do {
                    if initialSSD.contains(app), current != nil {
                        outcome = RecipeResult(status: "refused", reason: "The older SSD choice is for a first install only. The installed app was kept.")
                    } else if rollbacks.contains(app) {
                        outcome = try orderedRollback(app: app, order: id, installed: current, config: config, stateDir: stateDir, shell: shell, control: control)
                        if outcome.status == "rolled_back_by_owner", let displaced = outcome.version {
                            memory.offlineRollbacks = (memory.offlineRollbacks ?? [:]).merging([app: displaced]) { _, new in new }
                        }
                    } else if let refusal = Agent.refusesWhileRunning(app: app, cfg: cfg, control: control) {
                        outcome = RecipeResult(status: "refused", reason: refusal)
                    } else if let local = catalog.first(where: { $0.id == app })?.ssd {
                        outcome = try installLocal(local, app: app, installed: current, cfg: cfg,
                                                   stateDir: stateDir, shell: shell, control: control, force: reinstall.contains(app))
                    } else {
                        outcome = RecipeResult(status: "refused", reason: "Update Studio is unreachable and no eligible SSD installer is available. Nothing was installed.")
                    }
                } catch { outcome = RecipeResult(status: "install_failed", reason: "\(error)") }
            } else {
                outcome = RecipeResult(status: "refused", reason: "No eligible local action is available for this app. Nothing was changed.")
            }
            memory.done[id] = .init(app: app, status: outcome.status, reason: outcome.reason ?? "", at: ISO.string(now), sent: false)
            try AtomicFile.writeJSON(memory, to: stateDir.appendingPathComponent("agent-memory.json"))
            result.commandsRun += 1
            if outcome.status == "updated" { result.updates += 1 }
        }
        result.apps = snapshot(config: config, feed: Feed(published_at: ISO.string(now)), catalog: catalog,
                               orders: CommandsReply(machine: config.machine, commands: [], automatic: [:]), helper: helper,
                               memory: memory, executable: executable, http: http, serverBase: serverBase, stateDir: stateDir)
        return result
    }
}
