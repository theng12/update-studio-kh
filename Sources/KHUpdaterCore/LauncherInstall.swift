import Foundation

extension Agent {
    /// An older registration wrote `status` for an app the sources then called self-updating. Once
    /// the signed feed offers that app as an installer, the recipe is upgraded to `app-dmg` — in
    /// memory and in `launcher-apps.json` — so Update really runs. The person's Automatic choice is
    /// kept as it was; nothing else about the registration changes.
    static func upgradeObservedOnlyRecipes(config: inout AgentConfig, catalog: [CatalogEntry], feed: Feed, stateDir: URL) {
        func installableNow(_ app: String) -> Bool {
            feed.apps[app] != nil && catalog.first(where: { $0.id == app }).map { !$0.updatesItself } == true
        }
        let file = stateDir.appendingPathComponent("launcher-apps.json")
        var saved = (try? AtomicFile.readJSON([String: AppConfig].self, from: file)) ?? [:]
        var changed = false
        for (app, cfg) in config.apps where cfg.recipe == "status" && installableNow(app) {
            var upgraded = cfg
            upgraded.recipe = "app-dmg"
            config.apps[app] = upgraded
            if saved[app] != nil { saved[app] = upgraded; changed = true }
        }
        // The saved registration is repaired too: discovery may already run this app as managed
        // (so the in-memory recipe is right while the file still says `status`), and an app that is
        // moved or replaced later must not fall back to a recipe the feed no longer supports.
        for (app, cfg) in saved where cfg.recipe == "status" && installableNow(app) {
            saved[app]?.recipe = "app-dmg"
            changed = true
        }
        // A known recipe replacing another known recipe cannot make the config invalid; the run's
        // own validation still runs after this.
        guard changed else { return }
        try? AtomicFile.writeJSON(saved, to: file)
    }

    /// Every configured app must name a bundle that is really there. A path that is gone (a renamed
    /// app, a hand-written config) is repaired from the signed feed's bundle name, else from the
    /// app's own bundle ID in the usual Applications folders. The repair is said out loud once per
    /// run, in one line, instead of the app being skipped in silence.
    static func repairConfiguredPaths(config: inout AgentConfig, feed: Feed, folders: [URL], stateDir: URL,
                                      installed: inout [String: String], build: inout [String: String],
                                      health: inout [String: String]) -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        let file = stateDir.appendingPathComponent("launcher-apps.json")
        var saved = (try? AtomicFile.readJSON([String: AppConfig].self, from: file)) ?? [:]
        var savedChanged = false
        for (app, cfg) in config.apps.sorted(by: { $0.key < $1.key }) where cfg.recipe != "updater" {
            let want = cfg.bundleID ?? feed.apps[app]?.bundleID
            let existing = try? BundleInfo.read(cfg.bundlePath)
            if let existing, want == nil || existing.identifier == want { continue }
            // The candidate names: the feed's own bundle name first, then the configured one.
            var names: [String] = []
            if let name = feed.apps[app]?.bundleName { names.append(name) }
            let configuredName = URL(fileURLWithPath: cfg.bundlePath).lastPathComponent
            if !configuredName.isEmpty, !names.contains(configuredName) { names.append(configuredName) }
            var candidates: [URL] = names.map { $0 }.flatMap { name in
                folders.map { $0.appendingPathComponent(name) }.filter { fm.fileExists(atPath: $0.path) }
            }
            if candidates.isEmpty, let want {
                candidates = folders.flatMap { folder in
                    ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().compactMap { name in
                        guard name.hasSuffix(".app") else { return nil }
                        let path = folder.appendingPathComponent(name)
                        return (try? BundleInfo.read(path.path))?.identifier == want ? path : nil
                    }
                }
            }
            let matches = candidates.filter { candidate in
                guard let info = try? BundleInfo.read(candidate.path) else { return false }
                return want == nil || info.identifier == want
            }
            guard let found = matches.first else { continue }  // nothing installed: a first install uses the configured path
            var repaired = cfg
            repaired.bundlePath = found.path
            config.apps[app] = repaired
            if saved[app] != nil { saved[app] = repaired; savedChanged = true }
            let because = fm.fileExists(atPath: cfg.bundlePath) ? "holds another app" : "is missing"
            notes.append("\(app): configured bundle path \(cfg.bundlePath) \(because); using \(found.path)")
            if let info = try? BundleInfo.read(found.path) {
                installed[app] = info.version
                if let value = info.build { build[app] = value }
            }
            switch LiveControl.isRunning(found.path) {
            case true?: health[app] = "running"
            case false?: health[app] = "not running"
            case nil: health[app] = "unknown"
            }
        }
        if savedChanged { try? AtomicFile.writeJSON(saved, to: file) }
        return notes
    }

    /// A repaired path is written back into the live config file, so the next run starts from the
    /// app that is really here instead of repairing — and naming — the old path again. Only paths
    /// that changed are written; every other key and the file's own permissions stay as they were.
    static func persistRepairedPaths(loaded: [String: String], config: AgentConfig, file: URL?) {
        let fm = FileManager.default
        guard let file, fm.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var apps = root["apps"] as? [String: [String: Any]] else { return }
        var changed = false
        for (app, before) in loaded {
            guard let now = config.apps[app]?.bundlePath, now != before,
                  apps[app]?["bundlePath"] as? String != now else { continue }
            apps[app]?["bundlePath"] = now
            changed = true
        }
        guard changed else { return }
        root["apps"] = apps
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
        // The file holds this Mac's enrolment token: when its mode cannot be read it is written
        // 0600, never widened to the atomic writer's open default.
        try? AtomicFile.write(out, to: file, permissions: mode?.uint16Value ?? 0o600)
    }

    /// A saved address that can never be fetched is replaced by the one this check actually
    /// reached — and **only after a cycle has succeeded through it**, so a Mac is never pointed at
    /// an address that has not answered. Returns the old value when it wrote, nil when it did not.
    @discardableResult
    static func repairFeedAddress(used: String, config: AgentConfig, file: URL?) -> String? {
        let fm = FileManager.default
        guard let file, fm.fileExists(atPath: file.path),
              FeedNetwork.isUnusable(config.feedURL), used != config.feedURL, !FeedNetwork.isUnusable(used),
              let data = try? Data(contentsOf: file),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["feedURL"] as? String == config.feedURL else { return nil }
        root["feedURL"] = used
        // The same replacement inside a saved mirror list, when this Mac carries one: leaving a
        // dead literal there would keep it as a source for ever.
        if var network = root["network"] as? [String: Any], let list = network["feedURLs"] as? [String] {
            network["feedURLs"] = list.map { FeedNetwork.isUnusable($0) ? used : $0 }
            root["network"] = network
        }
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
        try? AtomicFile.write(out, to: file, permissions: mode?.uint16Value ?? 0o600)
        return config.feedURL
    }

    /// A Mac that was only just enrolled has nothing but the helper configured. Every app the signed
    /// feed names and this Mac already has is adopted by its bundle ID — never by a path, never with
    /// a hand edit — so a Hub-only mini updates through the Launcher on its first run.
    static func adoptInstalledApps(config: inout AgentConfig, feed: Feed, folders: [URL], sparseConfig: Bool,
                                   stateDir: URL) -> [String] {
        guard sparseConfig else { return [] }
        let discovered = Catalog.discover(config: config, known: Catalog.knownBundles(feed: feed, ssd: []), folders: folders)
        guard !discovered.isEmpty else { return [] }
        config.apps = Catalog.adopting(config.apps, discovered: discovered)
        persistAdoptions(Array(discovered.keys), config: config, stateDir: stateDir)
        return discovered.keys.sorted().map { "\($0): adopted this Mac's installed app from the signed feed" }
    }

    /// Saves the adopted apps beside the other Launcher registrations, so a Mac that has just been
    /// enrolled keeps what it found instead of rediscovering it (and reprinting the note) each run.
    static func persistAdoptions(_ ids: [String], config: AgentConfig, stateDir: URL) {
        let file = stateDir.appendingPathComponent("launcher-apps.json")
        var saved = (try? AtomicFile.readJSON([String: AppConfig].self, from: file)) ?? [:]
        var changed = false
        for id in ids where saved[id] == nil {
            guard let cfg = config.apps[id] else { continue }
            saved[id] = cfg
            changed = true
        }
        guard changed else { return }
        try? AtomicFile.writeJSON(saved, to: file)
    }

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
            // The live catalog, not just this Mac's recipe: an app its SSD marks as updating itself
            // stays a hand-only install even under an older config that still says `app-dmg`.
            let policy = catalog.first(where: { $0.id == app })
            if let failure = failures[app] {
                outcome = RecipeResult(status: "refused", reason: failure)
            } else if let cfg = config.apps[app], !Agent.updatesItself(app: app, recipe: cfg.recipe, entry: policy) || requested.contains(app) {
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
                    } else if let refusal = Agent.refusesWhileRunning(app: app, cfg: cfg, control: control, entry: policy) {
                        outcome = RecipeResult(status: "refused", reason: refusal)
                    } else if let local = policy?.ssd {
                        outcome = try installLocal(local, app: app, installed: current, cfg: cfg,
                                                   stateDir: stateDir, shell: shell, control: control, force: reinstall.contains(app),
                                                   manual: true, catalogEntry: policy)
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
