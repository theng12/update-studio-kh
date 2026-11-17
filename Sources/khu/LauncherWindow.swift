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
    private var connectionBusy = false

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

    /// Sends the page the current state. Cheap: the page redraws from it.
    func reload() {
        guard loaded else { return }
        helper.lock.lock()
        let apps = helper.apps, busy = helper.installingApp, pending = helper.active.union(helper.requested), ssd = helper.ssd, error = helper.lastError, last = helper.lastRun, attempt = helper.lastAttempt, serverKnown = helper.serverKnown
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
        let state: [String: Any] = [
            "apps": rows, "sources": ssd.map(\.volume), "error": error as Any, "lastRun": last.map(ISO.string) as Any,
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
                         "helperHealthySeconds": cleanup?.healthySeconds ?? 0],
            "connection": ["destination": helper.config.feedURL, "machine": helper.config.machine, "checking": connectionBusy,
                           "checkedAt": connectionUI.checkedAt as Any, "ok": connectionUI.ok as Any, "note": connectionUI.note as Any,
                           "serverNote": connectionUI.serverNote as Any, "serverOk": connectionUI.serverOk as Any,
                           "pairAvailable": connectionUI.pairAvailable],
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
            for a in all where a.managed && !a.statusOnly && a.status == HelperApp.updateAvailable { helper.request(a.app) }
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
        // The page's one outside link: a free, optional donation, opened in the browser.
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
                        self.connectionUI.serverNote = "Saved. The next update check uses this address."
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
        case "setting":
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
