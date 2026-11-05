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
        loaded = true; reload()
        runConnectionCheck()
        // KHU_PAGE_SCRIPT runs once on the page, for screenshots; nobody sets it in real use.
        if let script = ProcessInfo.processInfo.environment["KHU_PAGE_SCRIPT"], !script.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { webView.evaluateJavaScript(script) }
        }
    }

    /// Sends the page the current state. Cheap: the page redraws from it.
    func reload() {
        guard loaded else { return }
        helper.lock.lock()
        let apps = helper.apps, busy = helper.installingApp, ssd = helper.ssd, error = helper.lastError, last = helper.lastRun
        helper.lock.unlock()
        let settings = HelperSettings.load(from: helper.stateDir)
        let cleanup = try? HelperRetirementSettings.load(from: helper.stateDir)
        let hidden = Set(settings.hidden ?? [])
        var rows: [[String: Any]] = []
        for app in apps {
            var row: [String: Any] = [
                "id": app.app, "name": app.name.isEmpty ? AppNames.display(app.app) : app.name, "status": busy == app.app ? HelperApp.updating : app.status,
                "managed": app.managed, "statusOnly": app.statusOnly, "automatic": app.automatic, "hidden": hidden.contains(app.app),
                "open": app.bundlePath != nil, "setup": app.setupFolder != nil, "canRollBack": app.canRollBack, "helper": app.app == "updater",
            ]
            row["installed"] = app.installed; row["available"] = app.available; row["reason"] = app.reason
            row["source"] = app.source; row["fromSSD"] = app.fromSSD; row["released"] = app.released; row["installedAt"] = app.installedAt
            row["bytes"] = app.bytes.map { NSNumber(value: $0) }
            row["tagline"] = app.words.tagline; row["description"] = app.words.description; row["accent"] = app.words.accent
            row["features"] = app.words.features?.map { ["title": $0.title, "text": $0.text ?? ""] }
            row["notes"] = (app.notes ?? "").split(separator: "\n").map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }.filter { !$0.isEmpty }
            row["icon"] = icon(for: app)
            if busy == app.app { row["progress"] = progress(app) }
            rows.append(row)
        }
        let state: [String: Any] = [
            "apps": rows, "sources": ssd.map(\.volume), "error": error as Any, "lastRun": last.map(ISO.string) as Any,
            "version": helper.version ?? "", "whatsNew": helper.version.map(WhatsNew.lines(for:)) ?? [],
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
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("render(\(json))")
        // While something installs, the progress line follows the download file as it grows.
        if busy != nil, progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
        } else if busy == nil {
            progressTimer?.invalidate(); progressTimer = nil
        }
    }

    /// Bytes so far of the download in progress, read from its `.part` file, or nil when the
    /// install copies from an SSD or is past the download.
    private func progress(_ app: HelperApp) -> [String: Any] {
        let dir = helper.stateDir.appendingPathComponent("downloads").appendingPathComponent(app.app)
        let part = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).first { $0.hasSuffix(".part") }
        let done = part.flatMap { (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.size] as? NSNumber }
        var p: [String: Any] = ["paused": DownloadControl.paused]
        if let done { p["done"] = done; p["total"] = app.bytes.map { NSNumber(value: $0) } ?? NSNumber(value: 0) }
        if done == nil, let ssd = app.fromSSD { p["copying"] = ssd }
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
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); helper.wake.signal() }
            catch { helper.alert("\(app?.name ?? id) was not moved to the Trash", "\(error)") }
        case "hide", "unhide":
            var s = HelperSettings.load(from: helper.stateDir)
            var h = Set(s.hidden ?? []); if action == "hide" { h.insert(id) } else { h.remove(id) }
            s.hidden = h.sorted(); try? s.save(to: helper.stateDir)
        case "automatic": helper.setAutomatic(id, body["on"] as? Bool ?? false)
        case "check": helper.rescanSSDs()
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
                } catch { helper.alert("Helper cleanup could not be changed", "\(error)") }
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
            case "appearance": s.appearance = v as? String; helper.applyAppearance(s.appearance)
            default: break
            }
            try? s.save(to: helper.stateDir)
        default: break
        }
        reload()
    }

    private func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) { helper.windowClosed() }
}

/// WKUserContentController keeps its handler strongly; this keeps the window free to go.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
