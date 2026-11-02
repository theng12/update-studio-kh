import AppKit
import CoreGraphics

/// The agent's menu-bar icon: no Dock icon and no app to manage. It lives in the agent's own
/// process, so it arrives with the updater's self-update. The agent loop runs on its own thread;
/// this owns the main thread.
final class HelperMenu: NSObject, NSMenuDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [HelperApp] = []
    private var lastError: String?
    private var installingApp: String?
    private var requested: Set<String> = []
    private let wake = DispatchSemaphore(value: 0)
    private let stateDir: URL
    private let machine: String
    private let version: String?
    private var item: NSStatusItem!

    init(config: AgentConfig, version: String?) {
        stateDir = URL(fileURLWithPath: config.stateDir); machine = config.machine; self.version = version
    }

    /// Only in a logged-in session: without one there is no menu bar, and the agent runs as before.
    static var available: Bool { CGSessionCopyCurrentDictionary() != nil && ProcessInfo.processInfo.environment["KHU_NO_MENU"] == nil }

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
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
    func installing(_ app: String?) {
        lock.lock(); installingApp = app; lock.unlock()
        DispatchQueue.main.async { self.refreshIcon() }
    }
    func finished(_ result: AgentRunResult?, error: String?) {
        lock.lock()
        if let result { apps = result.apps }
        lastError = error
        installingApp = nil
        lock.unlock()
        DispatchQueue.main.async {
            self.refreshIcon()
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
        func note(_ text: String) { let i = NSMenuItem(title: text, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
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
        for app in list {
            let status = busy == app.app ? HelperApp.updating : app.status
            let row = NSMenuItem(title: "\(AppNames.display(app.app))   \(app.installed ?? "—") · \(status)", action: nil, keyEquivalent: "")
            menu.addItem(row)
            // Story and Hub update themselves: a status line, no switch.
            guard !app.statusOnly else { row.isEnabled = false; continue }
            let sub = NSMenu()
            sub.autoenablesItems = false
            if let reason = app.reason {
                let r = NSMenuItem(title: Self.short(reason), action: nil, keyEquivalent: ""); r.isEnabled = false; sub.addItem(r)
            }
            if let available = app.available, [HelperApp.updateAvailable, HelperApp.failed, HelperApp.notInstalled].contains(app.status) {
                action("Update now to \(available)", #selector(updateNow(_:)), app.app, to: sub).isEnabled = busy == nil
            }
            action("Automatic updates", #selector(toggleAutomatic(_:)), app.app, to: sub).state = app.automatic ? .on : .off
            row.submenu = sub
        }
        menu.addItem(.separator())
        _ = action("Check for Updates Now", #selector(checkNow))
        _ = action(settings.paused(at: Date()) ? "Resume Automatic Updates" : "Pause Automatic Updates for 24 Hours", #selector(togglePause))
        menu.addItem(.separator())
        note("Studio Launcher KH \(version ?? "")")
        _ = action("What's New…", #selector(whatsNew))
    }

    @objc private func checkNow() { wake.signal() }

    @objc private func updateNow(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        lock.lock(); requested.insert(app); lock.unlock()
        installing(app)
        wake.signal()
    }

    @objc private func toggleAutomatic(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        var settings = HelperSettings.load(from: stateDir)
        let on = sender.state != .on
        settings.automatic[app] = .init(on: on, at: ISO.string(Date()))
        lock.lock(); if let i = apps.firstIndex(where: { $0.app == app }) { apps[i].automatic = on }; lock.unlock()
        save(settings)
    }

    @objc private func togglePause() {
        var settings = HelperSettings.load(from: stateDir)
        settings.pausedUntil = settings.paused(at: Date()) ? nil : ISO.string(Date().addingTimeInterval(24 * 3600))
        save(settings)
    }

    /// A change is saved, then the agent runs at once so the page hears of it in one report.
    private func save(_ settings: HelperSettings) {
        do { try settings.save(to: stateDir); wake.signal() }
        catch { alert("That change could not be saved", "\(error)") }
    }

    @objc private func whatsNew() {
        let lines = version.map(WhatsNew.lines(for:)) ?? []
        alert("What's new in Studio Launcher KH \(version ?? "")",
              lines.isEmpty ? "No notes for this version." : lines.map { "• " + $0 }.joined(separator: "\n"))
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    static func clock(_ iso: String) -> String {
        guard let d = ISO.date(iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }
    static func short(_ text: String) -> String { text.count > 90 ? String(text.prefix(89)) + "…" : text }
}
