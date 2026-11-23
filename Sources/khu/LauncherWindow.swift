import AppKit
import WebKit

/// The Studio Launcher KH window: a native window showing one page drawn from live data. The page
/// is plain HTML in the same house style as Update Studio KH; every button posts a message back
/// here, so the page itself never touches a file, the network or an app.
final class LauncherWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    unowned let helper: HelperMenu
    let window: NSWindow
    private let web: WKWebView
    private var loaded = false
    private var iconCache: [String: String] = [:]
    private var progressTimer: Timer?
    /// The exact state the page already holds, and whether a render is already queued. The page
    /// rebuilds whatever a render touches, so a second push of the same state is a flash for no
    /// news — and one click can ask for three pushes in the same turn.
    private var pushed = ""
    private var pushQueued = false
    /// A What's New asked for before the page finished loading; shown once it holds the state.
    private var whatsNewWanted = false
    /// What the connection section of Settings last learned, in memory only: a check that is not
    /// run reads as "Not checked yet", never as passed.
    private struct ConnectionUI {
        var checkedAt: String?
        var ok: Bool?
        var note: String?
        var serverNote: String?
        var serverOk: Bool?
        /// True only after a check the publisher refused with 401/403 — the one state in which
        /// Pair again is offered, never a guess from any other failure.
        var pairAvailable = false
    }
    private var connectionUI = ConnectionUI()
    private enum ExtensionDownloads {
        case idle, loading, unpublished, failed
        case available([ExtensionCatalog.Entry], note: String? = nil)

        var page: [String: Any] {
            switch self {
            case .idle: return ["status": "idle"]
            case .loading: return ["status": "loading"]
            case .unpublished: return ["status": "unpublished"]
            case .failed: return ["status": "failed"]
            case let .available(entries, note):
                return ["status": "available", "note": note as Any, "entries": entries.map {
                    ["id": $0.id, "name": $0.name, "version": $0.version, "summary": $0.summary,
                     "kind": $0.kind, "download": $0.downloadURL != nil]
                }]
            }
        }
    }
    private var extensionDownloads = ExtensionDownloads.idle

    /// Enrolled to a publisher: a saved publisher address and the token that signs this Mac in.
    /// A GitHub-only Mac has neither, so "Leave this fleet" is absent rather than disabled.
    private var canLeaveFleet: Bool {
        Connect.enrolled(feedURL: helper.config.feedURL, token: helper.config.token)
    }

    /// This Mac reads a public feed: no publisher, so no reports, no orders — and the page says what
    /// that means and keeps the route back to a Studio visible while this Mac is a Studio's own.
    private var publicFeed: Bool {
        guard !helper.config.feedURL.isEmpty, let url = URL(string: helper.config.feedURL) else { return false }
        return !FeedNetwork.authenticated(url)
    }

    /// A Studio function is this Mac's own: it runs the Studio (the publisher answers on loopback),
    /// or it has joined one. Every other Mac is a single-Mac screen with no Studio wording on it.
    /// One rule for the page and the menu bar, so the two can never disagree.
    nonisolated(unsafe) private static var lastPublisherProbe = (at: Date.distantPast, answers: false)
    static func studioHere(config: AgentConfig) -> Bool {
        if Connect.enrolled(feedURL: config.feedURL, token: config.token) { return true }
        if let forced = ProcessInfo.processInfo.environment["KHU_TEST_PUBLISHER"] { return forced == "1" }
        // Cached for a minute: reload() runs often, and this asks the same loopback port each time.
        if Date().timeIntervalSince(lastPublisherProbe.at) > 60 {
            lastPublisherProbe = (Date(), FleetWindow.portAnswers(8790))
        }
        return lastPublisherProbe.answers
    }
    private var isStudio: Bool { Self.studioHere(config: helper.config) }
    private var connectionBusy = false
    private static let roster = (try? JSONDecoder().decode([String: String].self, from: Data(Changelog.fleetRosterJSON.utf8))) ?? [:]

    init(helper: HelperMenu) {
        self.helper = helper
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720), configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "khu")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.title = "Studio Launcher KH"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 480)
        window.contentView = web
        window.setFrameAutosaveName("StudioLauncherKH")
        if window.frame.width < 720 { window.center() }
        web.loadHTMLString(LauncherPage.html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushed = ""; loaded = true; reload()
        if whatsNewWanted { whatsNewWanted = false; askWhatsNew() }
        runConnectionCheck()
        // KHU_PAGE_SCRIPT runs once on the page, for screenshots; nobody sets it in real use.
        if let script = ProcessInfo.processInfo.environment["KHU_PAGE_SCRIPT"], !script.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { webView.evaluateJavaScript(script) }
        }
    }

    /// The menu bar's What's New: the page's own pop-up, so both routes show one design.
    func showWhatsNew() {
        if loaded { askWhatsNew() } else { whatsNewWanted = true }
    }
    private func askWhatsNew() {
        // Queued behind the render a reload() just queued, so the page already holds this version's notes.
        DispatchQueue.main.async { [weak self] in self?.web.evaluateJavaScript("showWhatsNew()") }
    }

    /// The apps this Mac manages here: the saved config plus the Launcher's own registrations, the
    /// same merge the agent makes at its run (`Agent.mergeRegistrations`).
    private func managedApps() -> [String: AppConfig] {
        var managed = helper.config.apps
        let file = helper.stateDir.appendingPathComponent("launcher-apps.json")
        for (app, cfg) in (try? AtomicFile.readJSON([String: AppConfig].self, from: file)) ?? [:] where managed[app] == nil {
            managed[app] = cfg
        }
        return managed
    }

    /// Sends the page the current state. Cheap: the page redraws from it.
    func reload() {
        guard loaded else { return }
        helper.lock.lock()
        let apps = helper.apps, busy = helper.installingApp, pending = helper.active.union(helper.requested), ssd = helper.ssd, error = helper.lastError, last = helper.lastRun, attempt = helper.lastAttempt, serverKnown = helper.serverKnown
        let feedAppIDs = helper.feedAppIDs, lastDriveScan = helper.lastDriveScan
        let feedPublishedAt = helper.feedPublishedAt, checkedFeedSource = helper.checkedFeedSource
        helper.lock.unlock()
        let settings = HelperSettings.load(from: helper.stateDir)
        let cleanup = try? HelperRetirementSettings.load(from: helper.stateDir)
        let hidden = Set(settings.hidden ?? [])
        var rows: [[String: Any]] = []
        for app in apps {
            var row: [String: Any] = [
                "id": app.app, "name": app.name.isEmpty ? AppNames.display(app.app) : app.name,
                "status": busy == app.app ? HelperApp.updating : (pending.contains(app.app) ? HelperApp.receiving : app.status),
                "managed": app.managed, "statusOnly": app.statusOnly, "automatic": app.automatic, "hidden": hidden.contains(app.app),
                "manuallyInstallable": app.manuallyInstallable, "installable": app.installable,
                "open": app.bundlePath != nil, "setup": app.setupFolder != nil, "canRollBack": app.canRollBack, "helper": app.app == "updater",
            ]
            row["installed"] = app.installed; row["available"] = app.available; row["reason"] = app.reason
            row["type"] = serverKnown ? app.feedType : nil
            row["unrecognised"] = !Self.roster.isEmpty && feedAppIDs?.contains(app.app) == true && Self.roster[app.app] == nil
            row["source"] = app.source; row["fromSSD"] = app.fromSSD; row["released"] = app.released; row["installedAt"] = app.installedAt
            row["ssdNote"] = app.ssdNote; row["automaticOrigin"] = app.automaticOrigin
            row["serverVersion"] = serverKnown ? app.serverVersion : nil; row["ssdVersion"] = app.ssdVersion; row["initialSSD"] = app.initialSSD
            row["bytes"] = app.bytes.map { NSNumber(value: $0) }
            row["tagline"] = app.words.tagline; row["description"] = app.words.description; row["accent"] = app.words.accent
            row["features"] = app.words.features?.map { ["title": $0.title, "text": $0.text ?? ""] }
            row["notes"] = (app.notes ?? "").split(separator: "\n").map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }.filter { !$0.isEmpty }
            row["icon"] = icon(for: app)
            if busy == app.app {
                row["progress"] = progress(app)
                // A row being worked on right now: whatever failure it carries is from the attempt
                // before, so the page must not read it as this attempt already having failed.
                row["retrying"] = app.status == HelperApp.failed
            }
            rows.append(row)
        }
        let known = Catalog.known(in: helper.stateDir, ssd: ssd)
        // A drive or installed copy is not evidence about what the signed feed carries.
        let missingFromFeed = Self.roster.filter { feedAppIDs?.contains($0.key) == false }.values.sorted()
        let state: [String: Any] = [
            "apps": rows, "appTypes": FeedPublisher.appTypes.sorted(), "extensions": extensionDownloads.page,
            "sources": ssd.map(\.volume), "error": error as Any, "lastRun": last.map(ISO.string) as Any,
            "missingFromFeed": missingFromFeed, "lastDriveScan": lastDriveScan.map(ISO.string) as Any,
            "feedCount": feedAppIDs?.count as Any, "feedPublishedAt": feedPublishedAt as Any,
            "checkedFeedSource": checkedFeedSource as Any,
            "configuredFeedSource": Connect.sourceName(URL(string: helper.config.feedURL)),
            "lastAttempt": attempt.map(ISO.string) as Any, "serverKnown": serverKnown, "settingsNote": helper.settingsNote as Any,
            "version": helper.version ?? "", "whatsNew": helper.version.map(WhatsNew.lines(for:)) ?? [],
            // Where this Mac's own files live and the cap one reply may carry: the page says both
            // from what the updater really does, never from a number typed into the page.
            "stateDir": helper.stateDir.path, "replyLimitBytes": NSNumber(value: Int64(URLSessionHTTPClient().smallLimit)),
            "paused": settings.paused(at: Date()),
            "settings": ["checkManually": settings.checkManually ?? false, "autoInstall": settings.autoInstall ?? true,
                         "notify": settings.notify ?? false, "appearance": settings.appearance ?? "system",
                         "menuBarWhenClosed": settings.menuBarWhenClosed ?? true,
                         "retireHelpers": cleanup?.enabled ?? false, "helperCleanupAvailable": cleanup != nil,
                         "helperHealthySeconds": cleanup?.healthySeconds ?? 0,
                         "viewMode": settings.viewMode ?? "grid", "logVerbosity": settings.logVerbosity ?? "normal"],
            // A run's log, where it really is, so the path is visible instead of a rumour.
            "logPath": AgentLog.path(name: "agent", in: helper.stateDir),
            // One quiet notice per new version, never repeated once dismissed (a dismissal is the
            // same record the system notification uses).
            "notices": apps.filter { app in
                app.managed && !app.statusOnly && app.status == HelperApp.updateAvailable
                    && app.available.map { settings.notified?[app.app] != $0 } == true
            }.map { ["id": $0.app, "name": $0.name.isEmpty ? AppNames.display($0.app) : $0.name,
                     "version": $0.available ?? ""] },
            // Hand-installed copies of this fleet's apps, offered once each; a declined one stays
            // declined on this Mac. `path` is the only thing adoption ever records.
            "adoptions": Adoption.offers(known: known,
                                         managed: managedApps(),
                                         dismissed: Set(settings.adoptionDeclined ?? []),
                                         folders: Catalog.applicationFolders)
                .map { ["id": $0.appID, "bundleID": $0.bundleID, "version": $0.version,
                        "name": AppNames.display($0.appID), "path": $0.existingPath] },
            "connection": ["destination": helper.config.feedURL,
                           // A Mac with no saved address shows and uses this default; a saved one wins.
                           "defaultFeed": ConnectionWindow.publicFeedURL, "machine": helper.config.machine,
                           "displayName": MacName.current(expectedMachine: helper.config.machine) as Any,
                           "checking": connectionBusy,
                           "checkedAt": connectionUI.checkedAt as Any, "ok": connectionUI.ok as Any, "note": connectionUI.note as Any,
                           "serverNote": connectionUI.serverNote as Any, "serverOk": connectionUI.serverOk as Any,
                           "pairAvailable": connectionUI.pairAvailable,
                           // Offered only to a Mac enrolled to a publisher; absent on a public-feed Mac.
                           "canLeave": canLeaveFleet,
                           // The Studio section is this Mac's own function. A single-Mac screen never
                           // shows it, so no fleet or publisher wording reaches a plain install.
                           "studio": isStudio,
                           // On a public feed there is no publisher: the page says so and offers the way back.
                           "publicFeed": publicFeed],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return }
        publish(json, busy: busy)
    }

    /// A push means the page rebuilds whatever it touches, so it has to mean something changed:
    /// identical state is not sent at all, and several asks in one turn (one click refreshes three
    /// times) become one render. Without this the window redrew twice a second for no news — the
    /// flicker — and it did so under an open dialog, stealing focus and what had been typed.
    private func publish(_ json: String, busy: String?) {
        if json != pushed {
            pushed = json
            if !pushQueued {
                pushQueued = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loaded else { return }
                    self.pushQueued = false
                    self.web.evaluateJavaScript("render(\(self.pushed))")
                }
            }
        }
        // While something installs, keep its actual transfer counters and phase visible. In the
        // common modes: in the default mode alone the tick stops behind a popup, a menu or a drag,
        // and the window keeps showing the last frame it drew — "Installing…" included.
        if busy == nil {
            progressTimer?.invalidate(); progressTimer = nil
        } else if progressTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        }
    }

    /// Actual transfer bytes and phase; no guessed progress from a missing download file. A cancel
    /// pressed on this Mac is reported as stopped, so a row never keeps counting down work that the
    /// person already ended — the page reads it as "Stopping…" rather than an endless install.
    private func progress(_ app: HelperApp) -> [String: Any] {
        let current = DownloadControl.progress
        var p: [String: Any] = ["paused": DownloadControl.paused, "phase": current.phase, "cancelled": DownloadControl.cancelled]
        if let received = current.received { p["done"] = NSNumber(value: received) }
        if let total = current.total { p["total"] = NSNumber(value: total) }
        if current.phase == "copying", let ssd = app.fromSSD { p["copying"] = ssd }
        return p
    }

    private func icon(for app: HelperApp) -> String {
        let key = app.app == "updater" ? "updater" : (app.icon ?? "")
        if let hit = iconCache[key] { return hit }
        let png: Data?
        if app.app == "updater" { png = (try? LauncherBundle.icns()).flatMap { NSImage(data: $0) }.flatMap(Self.png) }
        else if let path = app.icon, path.hasSuffix(".app") { png = AppMeta.iconPNG(forFile: path) }
        else { png = app.icon.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } }
        let uri = png.map { "data:image/png;base64," + $0.base64EncodedString() } ?? ""
        iconCache[key] = uri
        return uri
    }

    static func png(_ image: NSImage) -> Data? {
        image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
    }

    /// One connection check at a time on this Mac's own credentials. Only a 401/403 refusal —
    /// its own error type, never message matching — offers Pair again, and a success clears it.
    private func runConnectionCheck() {
        guard !connectionBusy else { return }
        connectionBusy = true
        connectionUI.note = nil
        connectionUI.pairAvailable = false
        reload()
        let config = helper.config
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false, note: String?, refused = false
            do { try Connect.check(config: config); ok = true }
            catch {
                note = "\(error)"
                refused = error is Connect.SigninRefused
            }
            DispatchQueue.main.async {
                self.connectionBusy = false
                self.connectionUI.ok = ok
                self.connectionUI.note = note
                self.connectionUI.pairAvailable = refused
                if ok { self.connectionUI.checkedAt = ISO.string(Date()) }
                self.reload()
                if refused { self.web.evaluateJavaScript("settingsOpen=true;drawSettings()") }
            }
        }
    }

    private func checkExtensions() {
        if case .loading = extensionDownloads { return }
        extensionDownloads = .loading
        reload()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: ExtensionDownloads
            do {
                let entries = try ExtensionCatalog.load() ?? []
                result = entries.isEmpty ? .unpublished : .available(entries)
            } catch { result = .failed }
            DispatchQueue.main.async { [weak self] in
                self?.extensionDownloads = result
                self?.reload()
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let id = body["app"] as? String ?? ""
        helper.lock.lock(); let app = helper.apps.first { $0.app == id }, all = helper.apps; helper.lock.unlock()
        switch action {
        case "install", "update": helper.request(id)
        case "installSSD":
            // An app that updates itself may still be installed by hand: the person asked for it.
            guard app?.installed == nil, app?.initialSSD != nil,
                  app?.statusOnly == false || app?.manuallyInstallable == true else { break }
            helper.request("ssd:" + id)
        case "reinstall": helper.request("reinstall:" + id)
        case "rollback":
            if confirm("Roll back \(app?.name ?? id)?", "It goes back to the version this Mac kept before the last update.", "Roll Back") { helper.request("rollback:" + id) }
        case "updateAll":
            for a in all where HelperApp.updateAllEligible(a) { helper.request(a.app) }
        case "open": if let p = app?.bundlePath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case "finder": if let p = app?.bundlePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case "setup": if let f = app?.setupFolder { NSWorkspace.shared.open(URL(fileURLWithPath: f)) }
        case "uninstall":
            guard let p = app?.bundlePath, confirm("Move \(app?.name ?? id) to the Trash?",
                                                   "It stops running and is no longer updated here. You can put it back from the Trash.", "Move to Trash") else { break }
            do {
                var settings = HelperSettings.load(from: helper.stateDir)
                settings.automatic[id] = .init(on: false, at: ISO.string(Date()))
                try settings.save(to: helper.stateDir)
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                helper.wake.signal()
            }
            catch { helper.alert("\(app?.name ?? id) was not moved to the Trash", "\(error)") }
        case "hide", "unhide":
            var s = HelperSettings.load(from: helper.stateDir)
            var h = Set(s.hidden ?? []); if action == "hide" { h.insert(id) } else { h.remove(id) }
            s.hidden = h.sorted(); helper.save(s)
        case "automatic": helper.setAutomatic(id, body["on"] as? Bool ?? false)
        case "check": helper.rescanSSDs()
            case "fleet": helper.showFleet()
        case "checkExtensions": checkExtensions()
        case "downloadExtension":
            // Only a catalog entry and its published address are used; the page never supplies a
            // target. The file is kept only after its bytes and checksum match the index.
            guard case let .available(entries, _) = extensionDownloads,
                  let entry = entries.first(where: { $0.id == id }) else { break }
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let name = (try? SafeName.component("kh-\(entry.id)-\(entry.version).zip", what: "download name"))
                ?? "kh-\(entry.id)-\(entry.version).zip"
            let file = folder.appendingPathComponent(name)
            extensionDownloads = .available(entries, note: "Downloading \(entry.name)…")
            reload()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: String
                do {
                    try ExtensionCatalog.fetch(entry, to: file)
                    result = "Saved \(name) in Downloads. Unzip it, then use Load unpacked in Chrome."
                } catch {
                    result = "\(entry.name) was not kept: \(error). Nothing changed."
                }
                DispatchQueue.main.async {
                    self?.extensionDownloads = .available(entries, note: result)
                    self?.reload()
                }
            }
        case "support": if let url = URL(string: "https://nowpayments.io/donation/studiokh") { NSWorkspace.shared.open(url) }
        case "copyReport":
            guard let app else { break }
            let report = ["Studio Launcher KH error report", "Mac: \(helper.machine)", "App: \(app.name) (\(app.app))",
                          "Installed: \(app.installed ?? "not installed")", "Offered: \(app.available ?? "-") from \(app.source ?? "-")",
                          "Reason: \(app.reason ?? "-")", "Helper: \(helper.version ?? "-")", "At: \(ISO.string(Date()))"].joined(separator: "\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string)
        case "log": FileHandle.standardError.write(Data("launcher page: \(body["text"] ?? "")\n".utf8)); return
        case "pause": DownloadControl.pause(body["on"] as? Bool ?? !DownloadControl.paused)
        case "cancel": DownloadControl.cancel()
        case "connectionCheck":
            // One check at a time, on this Mac's own credentials: signed answer, pinned key, this
            // Mac's name — never an enrolment, never a second attempt over the first.
            runConnectionCheck()
        case "pairAgain":
            // Explicit local recovery only. The plain confirmation (old sign-in preserved,
            // pairing code required) and the code entry live in the native window; a cancelled
            // confirmation returns here without any network call or file write.
            guard !connectionBusy else { break }
            let file = Connect.configFile(stateDir: helper.stateDir)
            connectionBusy = true
            reload()
            let outcome = ConnectionWindow.runRepair(configFile: file)
            connectionBusy = false
            guard outcome == .connected else { break }
            // The renewed sign-in is on disk; this window reads it again and then proves it.
            if let data = try? Data(contentsOf: file), let fresh = try? JSONDecoder().decode(AgentConfig.self, from: data) {
                helper.config = fresh
                helper.wake.signal()
                runConnectionCheck()
            } else {
                connectionUI.ok = false
                connectionUI.pairAvailable = false
                connectionUI.note = "The renewed sign-in was saved but could not be read back here; quit and reopen Studio Launcher KH."
                reload()
            }
        case "changeServer":
            guard !connectionBusy, let typed = body["value"] as? String,
                  !typed.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            connectionBusy = true
            connectionUI.serverOk = nil
            connectionUI.serverNote = "Checking that address…"
            reload()
            let file = Connect.configFile(stateDir: helper.stateDir)
            DispatchQueue.global(qos: .userInitiated).async {
                var saved: String?, note: String?
                do { saved = try Connect.changeDestination(to: typed, file: file) }
                catch { note = "\(error)" }
                DispatchQueue.main.async {
                    self.connectionBusy = false
                    if let saved {
                        self.helper.config.feedURL = saved
                        self.helper.wake.signal()
                        self.connectionUI.serverOk = true
                        // A public feed changes what this Mac is: no publisher, no reports, no orders.
                        self.connectionUI.serverNote = saved.lowercased().hasPrefix("https://")
                            ? "Saved. This Mac now updates from that public feed: it installs only what that feed signs and no longer reports to or takes orders from Update Studio."
                            : "Saved. The next update check uses this address."
                        self.connectionUI.checkedAt = nil
                        self.connectionUI.ok = nil
                        self.connectionUI.note = nil
                    } else {
                        self.connectionUI.serverOk = false
                        self.connectionUI.serverNote = note
                    }
                    self.reload()
                }
            }
        case "joinFleet":
            // The way back from the public feed: point at a publisher, then pair with its code —
            // the same two steps a first run takes, with this Mac's apps, models and settings kept.
            guard !connectionBusy, let typed = body["value"] as? String, let code = body["code"] as? String,
                  !typed.trimmingCharacters(in: .whitespaces).isEmpty,
                  !code.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            connectionBusy = true
            connectionUI.serverOk = nil
            connectionUI.serverNote = "Joining Update Studio…"
            reload()
            let joinFile = Connect.configFile(stateDir: helper.stateDir)
            DispatchQueue.global(qos: .userInitiated).async {
                var note: String?, joined = false
                do {
                    _ = try Connect.changeDestination(to: typed, file: joinFile)
                    _ = try Connect.repair(configFile: joinFile, code: code, confirmed: true)
                    note = "Joined Update Studio. This Mac reports to it again and follows its Automatic switches."
                    joined = true
                } catch { note = "Not joined: \(error)" }
                DispatchQueue.main.async {
                    self.connectionBusy = false
                    self.connectionUI.serverOk = joined
                    self.connectionUI.serverNote = note
                    self.connectionUI.checkedAt = nil
                    self.connectionUI.ok = nil
                    self.connectionUI.note = nil
                    if let data = try? Data(contentsOf: joinFile),
                       let fresh = try? JSONDecoder().decode(AgentConfig.self, from: data) {
                        self.helper.config = fresh
                        self.helper.wake.signal()
                    }
                    self.reload()
                }
            }
        case "leaveFleet":
            // Off the controller's books from this Mac itself: nothing is written to the network,
            // so it works with Update Studio off or this Mac offline. Apps, models, settings and the
            // pinned key stay; the old settings are kept in _trash and the page says where.
            guard !connectionBusy, canLeaveFleet else { break }
            connectionBusy = true
            connectionUI.serverOk = nil
            connectionUI.serverNote = "Leaving this fleet…"
            reload()
            let file = Connect.configFile(stateDir: helper.stateDir)
            DispatchQueue.global(qos: .userInitiated).async {
                var note: String?, left = false
                do {
                    let result = try Connect.leaveFleet(file: file)
                    note = "Left the Studio. This Mac now updates from the saved feed, reports to no Studio and "
                        + "takes no orders from one; your pinned key still verifies every update it reads. "
                        + "Your previous settings are kept in \(result.backup.path)."
                    left = true
                } catch { note = "\(error)" }
                DispatchQueue.main.async {
                    self.connectionBusy = false
                    self.connectionUI.serverOk = left
                    self.connectionUI.serverNote = note
                    self.connectionUI.checkedAt = nil
                    self.connectionUI.ok = nil
                    self.connectionUI.note = nil
                    if left, let data = try? Data(contentsOf: file),
                       let fresh = try? JSONDecoder().decode(AgentConfig.self, from: data) {
                        self.helper.config = fresh
                        self.helper.wake.signal()
                    }
                    self.reload()
                }
            }
        case "dismissNotice":
            // Dismissing the quiet notice records the version in the same map the system
            // notification uses, so neither ever returns for this version on this Mac.
            guard let version = body["version"] as? String else { break }
            var s = HelperSettings.load(from: helper.stateDir)
            var n = s.notified ?? [:]
            n[id] = version
            s.notified = n
            helper.save(s)
            reload()
        case "adopt", "declineAdoption":
            if action == "declineAdoption" {
                var s = HelperSettings.load(from: helper.stateDir)
                var d = Set(s.adoptionDeclined ?? []); d.insert(id); s.adoptionDeclined = d.sorted(); helper.save(s)
                reload()
                break
            }
            var config = helper.config
            config.apps = managedApps()
            let offer = Adoption.offers(known: Catalog.known(in: helper.stateDir, ssd: helper.ssdSources),
                                        managed: config.apps,
                                        folders: Catalog.applicationFolders).first { $0.appID == id }
            guard let offer else { break }
            // The same discovery the agent runs, so the recipe (an app that updates itself stays
            // "status") and the recorded path match the copy the person approved.
            let found = Catalog.discover(config: config,
                                         known: Catalog.known(in: helper.stateDir, ssd: helper.ssdSources),
                                         folders: Catalog.applicationFolders)
            guard let registration = found[id] else { break }
            // Record the copy where it already is. This is the whole of adoption: no move, no
            // rename, no reinstall over it, and no second copy.
            let file = helper.stateDir.appendingPathComponent("launcher-apps.json")
            var registrations = (try? AtomicFile.readJSON([String: AppConfig].self, from: file)) ?? [:]
            registrations[offer.appID] = registration
            do { try AtomicFile.writeJSON(registrations, to: file) }
            catch {
                helper.alert("\(AppNames.display(offer.appID)) could not be managed", "\(error)")
                break
            }
            helper.wake.signal()
            reload()
        case "setting":
            // The updater's own switch is this Mac's, on any feed: on a public feed there is no
            // publisher to set it, so a GitHub Mac can turn its self-update on here.
            if body["key"] as? String == "updaterAutomatic" {
                helper.setAutomatic("updater", body["value"] as? Bool ?? false)
                reload()
                return
            }
            if body["key"] as? String == "retireHelpers" {
                do {
                    var cleanup = try HelperRetirementSettings.load(from: helper.stateDir)
                    guard let enabled = body["value"] as? Bool else { break }
                    cleanup.enabled = enabled
                    try cleanup.save(to: helper.stateDir)
                    helper.settingsNote = "Saved."
                } catch {
                    helper.settingsNote = "Could not save helper cleanup. Your previous settings are kept."
                    helper.alert("Helper cleanup could not be changed", "\(error)")
                }
                reload()
                return
            }
            var s = HelperSettings.load(from: helper.stateDir)
            let v = body["value"]
            switch body["key"] as? String {
            case "checkManually": s.checkManually = v as? Bool
            case "autoInstall": s.autoInstall = v as? Bool
            case "notify": s.notify = v as? Bool
            case "menuBarWhenClosed": s.menuBarWhenClosed = v as? Bool
            case "appearance": s.appearance = v as? String
            case "viewMode": s.viewMode = v as? String
            case "logVerbosity": s.logVerbosity = v as? String
            default: break
            }
            if helper.save(s), body["key"] as? String == "appearance" { helper.applyAppearance(s.appearance) }
        default: break
        }
        reload()
    }

    private func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// A closed window has nobody to refresh: the tick stops here and the next `reload()` starts it
    /// again if work is still running.
    func windowWillClose(_ notification: Notification) {
        progressTimer?.invalidate(); progressTimer = nil
        helper.windowClosed()
    }
}

/// WKUserContentController keeps its handler strongly; this keeps the window free to go.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
