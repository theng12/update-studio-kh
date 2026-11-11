import AppKit
import CoreGraphics

/// The agent's menu-bar icon: no Dock icon and no app to manage. It lives in the agent's own
/// process, so it arrives with the updater's self-update. The agent loop runs on its own thread;
/// this owns the main thread.
final class HelperMenu: NSObject, NSMenuDelegate, @unchecked Sendable {
    let lock = NSLock()
    var apps: [HelperApp] = []
    var lastError: String?
    var installingApp: String?
    var requested: Set<String> = []
    let wake = DispatchSemaphore(value: 0)
    let stateDir: URL
    let machine: String
    let version: String?
    /// This Mac's own updater settings, read once when the helper starts. Settings keeps it
    /// current: saving a new Update Studio address updates `feedURL` here so the connection check
    /// talks to what the page just saved. The token inside is never shown or sent anywhere.
    var config: AgentConfig
    private var item: NSStatusItem!
    var itemIfReady: NSStatusItem? { item }
    var lastRun: Date?
    var lastAttempt: Date?
    var settingsNote: String?
    var serverKnown = false
    var window: LauncherWindow?
    var ssdSources: [SSDSource] { lock.lock(); defer { lock.unlock() }; return ssd }
    var ssd: [SSDSource] = []

    init(config: AgentConfig, version: String?) {
        self.config = config
        stateDir = URL(fileURLWithPath: config.stateDir); machine = config.machine; self.version = version
    }

    /// Only in a logged-in session: without one there is no menu bar, and the agent runs as before.
    static var available: Bool { CGSessionCopyCurrentDictionary() != nil && ProcessInfo.processInfo.environment["KHU_NO_MENU"] == nil }

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        LauncherMenus.install()
        // KHU_MENU_SHOW=light|dark opens the menu after the first run, for screenshots; nobody sets it in real use.
        if let look = ProcessInfo.processInfo.environment["KHU_MENU_SHOW"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
        applyAppearance(HelperSettings.load(from: stateDir).appearance)
        LauncherBundle.ensure(version: version)
        // Opening Studio Launcher KH.app asks this process to show its window; an SSD that mounts refreshes the list.
        DistributedNotificationCenter.default().addObserver(forName: LauncherBundle.openNotification, object: nil, queue: .main) { _ in self.showWindow() }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in self.rescanSSDs() }
        }
        if let version {
            let defaults = UserDefaults.standard
            let key = "com.khupdater.lastWhatsNewVersion"
            let previous = defaults.string(forKey: key)
            defaults.set(version, forKey: key)
            if let previous, VersionCompare.isNewer(version, than: previous) {
                DispatchQueue.main.async { self.whatsNew() }
            }
        }
        NSApp.run()
    }

    // MARK: the agent loop's side

    /// Waits out the interval, or less when someone asks from the menu. Returns the apps to update now.
    func waitForNextRun(seconds: Double) -> Set<String> {
        _ = wake.wait(timeout: .now() + seconds)
        lock.lock(); defer { lock.unlock() }
        let asked = requested; requested = []
        return asked
    }
    /// Says which app the agent is working on right now. The Launcher's "Updating…" row is driven
    /// by this flag, so the flag changing has to move the window too: pushing state only at the end
    /// of a run left a stopped attempt still drawn as Installing.
    func installing(_ app: String?) {
        lock.lock(); installingApp = app; lock.unlock()
        DispatchQueue.main.async {
            self.refreshIcon()
            self.window?.reload()
        }
    }
    func finished(_ result: AgentRunResult?, error: String?) {
        lock.lock()
        if let result { apps = result.apps }
        lastError = error ?? result?.feedError
        serverKnown = result != nil && result?.feedError == nil && error == nil
        lastAttempt = Date()
        if serverKnown { lastRun = lastAttempt }
        let ready = apps.filter { $0.managed && !$0.statusOnly && $0.status == HelperApp.updateAvailable }
        installingApp = nil
        lock.unlock()
        Notifier.announce(ready, stateDir: stateDir)
        DispatchQueue.main.async {
            self.refreshIcon()
            self.window?.reload()
            // KHU_WINDOW_SHOW=light|dark opens the window after the first run, for screenshots; nobody sets it in real use.
            if let look = ProcessInfo.processInfo.environment["KHU_WINDOW_SHOW"], !look.isEmpty {
                setenv("KHU_WINDOW_SHOW", "", 1)
                NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
                self.showWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    FileHandle.standardError.write(Data("launcher window \(self.window?.window.windowNumber ?? 0)\n".utf8))
                }
            }
            if let look = ProcessInfo.processInfo.environment["KHU_MENU_SHOW"], !look.isEmpty {
                setenv("KHU_MENU_SHOW", "", 1)
                // At a fixed spot, so the shot does not depend on room left in the menu bar.
                guard let menu = self.item.menu, let screen = NSScreen.main else { return }
                self.menuNeedsUpdate(menu)
                menu.appearance = NSApp.appearance
                FileHandle.standardError.write(Data("menu at 200,60 size \(Int(menu.size.width))x\(Int(menu.size.height))\n".utf8))
                // The menu's own window number, so the shot is that window alone.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    let all = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                    for w in all where (w[kCGWindowOwnerPID as String] as? Int32) == getpid() {
                        FileHandle.standardError.write(Data("menu window \(w[kCGWindowNumber as String] ?? 0) layer \(w[kCGWindowLayer as String] ?? 0)\n".utf8))
                    }
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 200, y: screen.frame.maxY - 60), in: nil)
            }
        }
    }

    // MARK: the menu

    private func refreshIcon() {
        lock.lock(); let list = apps, busy = installingApp != nil, error = lastError; lock.unlock()
        let symbol = list.contains { $0.status == HelperApp.failed } || error != nil ? "exclamationmark.arrow.circlepath"
            : busy ? "arrow.triangle.2.circlepath"
            : list.contains { $0.status == HelperApp.updateAvailable } ? "arrow.down.circle.fill" : "arrow.down.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Studio Launcher KH")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        lock.lock(); let list = apps, error = lastError, busy = installingApp; lock.unlock()
        let settings = HelperSettings.load(from: stateDir)
        menu.removeAllItems()
        func note(_ text: String, to target: NSMenu? = nil) { let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false; (target ?? menu).addItem(i) }
        func action(_ title: String, _ selector: Selector, _ app: String? = nil, to target: NSMenu? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            i.target = self; i.representedObject = app
            (target ?? menu).addItem(i)
            return i
        }

        note("Studio Launcher KH · \(machine)")
        if let until = settings.pausedUntil, settings.paused(at: Date()) {
            note("Automatic updates paused until \(Self.clock(until))")
        }
        if let error { note("Last check failed: \(Self.short(error))") }
        if list.isEmpty && error == nil { note("Checking…") }
        menu.addItem(.separator())
        for app in list where app.managed {
            let status = busy == app.app ? HelperApp.updating : app.status
            let row = NSMenuItem(title: "\(app.name.isEmpty ? AppNames.display(app.app) : app.name)   \(app.installed ?? "—") · \(status)", action: nil, keyEquivalent: "")
            menu.addItem(row)
            // Story and Hub update themselves: a status line, no switch.
            guard !app.statusOnly else { row.isEnabled = false; continue }
            let sub = NSMenu()
            sub.autoenablesItems = false
            if let reason = app.reason { note(Self.short(reason), to: sub) }
            if let available = app.available, [HelperApp.updateAvailable, HelperApp.failed, HelperApp.notInstalled].contains(app.status) {
                action("Update now to \(available)", #selector(updateNow(_:)), app.app, to: sub).isEnabled = busy == nil
            }
            action("Automatic updates", #selector(toggleAutomatic(_:)), app.app, to: sub).state = app.automatic ? .on : .off
            // Whichever of the three settings this value follows, in the same words the Launcher
            // page uses; the rule itself lives in `HelperSettings.automaticDecision`.
            if let from = app.automaticOrigin { note(from, to: sub) }
            row.submenu = sub
        }
        menu.addItem(.separator())
        _ = action("Open Studio Launcher…", #selector(openWindow))
        _ = action("Check for Updates Now", #selector(checkNow))
        _ = action(settings.paused(at: Date()) ? "Resume Automatic Updates" : "Pause Automatic Updates for 24 Hours", #selector(togglePause))
        menu.addItem(.separator())
        note("Studio Launcher KH \(version ?? "")")
        _ = action("What's New…", #selector(whatsNew))
    }

    @objc private func checkNow() { wake.signal() }
    @objc private func openWindow() { showWindow() }

    @objc private func updateNow(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        request(app)
    }
    func request(_ app: String) {
        // Only the agent's item-start callback owns live progress; a click just queues work.
        lock.lock(); requested.insert(app); lock.unlock()
        wake.signal()
    }

    @objc private func toggleAutomatic(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        setAutomatic(app, sender.state != .on)
    }
    func setAutomatic(_ app: String, _ on: Bool) {
        var settings = HelperSettings.load(from: stateDir)
        settings.automatic[app] = .init(on: on, at: ISO.string(Date()))
        guard save(settings) else { return }
        lock.lock(); if let i = apps.firstIndex(where: { $0.app == app }) { apps[i].automatic = on }; lock.unlock()
    }

    @objc private func togglePause() {
        var settings = HelperSettings.load(from: stateDir)
        settings.pausedUntil = settings.paused(at: Date()) ? nil : ISO.string(Date().addingTimeInterval(24 * 3600))
        save(settings)
    }

    /// A change is saved, then the agent runs at once so the page hears of it in one report.
    @discardableResult func save(_ settings: HelperSettings) -> Bool {
        do {
            try settings.save(to: stateDir)
            settingsNote = "Saved."
            wake.signal()
            return true
        } catch {
            settingsNote = "Could not save that change. Your previous settings are kept."
            alert("That change could not be saved", "\(error)")
            return false
        }
    }

    @objc func whatsNew() {
        showWindow()
        guard let host = window?.window, host.attachedSheet == nil else { return }
        let lines = version.map(WhatsNew.lines(for:)) ?? []
        let notes = NSAlert()
        notes.messageText = "What's New · Studio Launcher KH \(version ?? "") (current)"
        notes.informativeText = lines.isEmpty ? "No notes for this version." : lines.map { "• " + $0 }.joined(separator: "\n")
        // Keep the helper's normal event loop available to acknowledge Launcher opens.
        notes.beginSheetModal(for: host)
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    static func clock(_ iso: String) -> String {
        guard let d = ISO.date(iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }
    static func short(_ text: String) -> String { text.count > 90 ? String(text.prefix(89)) + "…" : text }
}

extension HelperMenu {
    /// "system" (or nil), "dark" or "light", for the window and its sheets.
    func applyAppearance(_ choice: String?) {
        NSApp.appearance = choice == "dark" ? NSAppearance(named: .darkAqua) : choice == "light" ? NSAppearance(named: .aqua) : nil
    }

    /// With "keep the icon in the menu bar" off, the icon shows only while the window is open.
    /// The helper itself keeps running either way: it is what updates this Mac.
    func windowClosed() { setMenuIcon(visible: HelperSettings.load(from: stateDir).menuBarWhenClosed ?? true) }
    func setMenuIcon(visible: Bool) { statusItem?.isVisible = visible }
    var statusItem: NSStatusItem? { itemIfReady }
}
