import AppKit
import CoreGraphics

/// The agent's icon: a Dock icon as well as the menu-bar one, so a closed window is never gone
/// with no way back. It lives in the agent's own process, so it arrives with the updater's
/// self-update. The agent loop runs on its own thread; this owns the main thread.
final class HelperMenu: NSObject, NSMenuDelegate, NSApplicationDelegate, @unchecked Sendable {
    let lock = NSLock()
    var apps: [HelperApp] = []
    var lastError: String?
    var installingApp: String?
    var requested: Set<String> = []
    /// The apps this run was asked for and has not started yet: their rows say "Receiving update…"
    /// from the click until `installing` names them, so a queued click is never drawn as nothing.
    var active: Set<String> = []
    let pacing = RunPacing()
    /// The Launcher's own update hold (Sparkle's shim posts here before any check). Kept alive for
    /// the life of the app; nil when its port could not be opened.
    var holdServer: LauncherHold?
    /// Kept alive for the process's life: the signal source that writes the agent's stop line.
    var stopSource: DispatchSourceSignal?
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
    var feedAppIDs: Set<String>?
    var feedPublishedAt: String?
    var checkedFeedSource: String?
    var lastDriveScan: Date?
    var window: LauncherWindow?
    var fleetWindow: FleetWindow?
    var ssdSources: [SSDSource] { lock.lock(); defer { lock.unlock() }; return ssd }
    var hasPendingWork: Bool { lock.lock(); defer { lock.unlock() }; return installingApp != nil || !active.isEmpty || !requested.isEmpty }
    var ssd: [SSDSource] = []

    init(config: AgentConfig, version: String?) {
        self.config = config
        stateDir = URL(fileURLWithPath: config.stateDir); machine = config.machine; self.version = version
    }

    /// Only in a logged-in session: without one there is no menu bar, and the agent runs as before.
    static var available: Bool { CGSessionCopyCurrentDictionary() != nil && ProcessInfo.processInfo.environment["KHU_NO_MENU"] == nil }

    func start() {
        // A Dock icon, so the window is reachable after the red button: without it the only way
        // back was the menu-bar icon, which is easy to miss (owner, 2026-11-18, 0.1.63). It stays:
        // the 1,605 appearances on 1301 were one recycle loop, and 0.1.79 bounds that loop instead
        // of taking the icon away — at most one appearance per genuine restart.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.delegate = self
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

    // MARK: the Dock icon

    /// A click on the Dock icon after Close: the window comes back, and is made again when it was
    /// released. True says this call handled the reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: the agent loop's side

    /// Waits out the interval, or less when a person asks from the menu. Returns the apps to update now.
    /// A saved setting or a state change never shortens the wait — measured 2026-11-23, one state
    /// change took this Mac from 7 runs a minute to 90.
    func waitForNextRun(seconds: Double) -> Set<String> {
        _ = pacing.wait(interval: seconds)
        lock.lock(); defer { lock.unlock() }
        let asked = requested; requested = []; active = asked
        return asked
    }
    /// Says which app the agent is working on right now. The Launcher's "Updating…" row is driven
    /// by this flag, so the flag changing has to move the window too: pushing state only at the end
    /// of a run left a stopped attempt still drawn as Installing.
    func installing(_ app: String?) {
        lock.lock(); installingApp = app; if let app { active.remove(app) }; lock.unlock()
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
        feedAppIDs = serverKnown ? result?.feedAppIDs : nil
        feedPublishedAt = serverKnown ? result?.feedPublishedAt : nil
        checkedFeedSource = serverKnown ? result?.checkedFeedSource : nil
        lastAttempt = Date()
        if serverKnown { lastRun = lastAttempt }
        let ready = apps.filter { $0.managed && !$0.statusOnly && $0.status == HelperApp.updateAvailable }
        installingApp = nil
        active = []
        lock.unlock()
        Notifier.announce(ready, stateDir: stateDir)
        DispatchQueue.main.async {
            if self.window != nil { self.reloadSavedConnection() }
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

    /// Which symbol the item shows, in one place so a test can prove each name resolves on this
    /// macOS rather than only that some image was assigned.
    static func iconSymbol(apps: [HelperApp], busy: Bool, error: String?) -> String {
        apps.contains { $0.status == HelperApp.failed } || error != nil ? "exclamationmark.arrow.circlepath"
            : busy ? "arrow.triangle.2.circlepath"
            : apps.contains { $0.status == HelperApp.updateAvailable } ? "arrow.down.circle.fill" : "arrow.down.circle"
    }

    private func refreshIcon() {
        lock.lock(); let list = apps, busy = installingApp != nil, error = lastError; lock.unlock()
        let image = NSImage(systemSymbolName: Self.iconSymbol(apps: list, busy: busy, error: error),
                            accessibilityDescription: "Studio Launcher KH")
        image?.isTemplate = true
        item.button?.image = image
    }

    /// Catches a first paint that ran before the status item's button existed (a blank square on an
    /// idle Mac, reported 2026-11-20): once the app has launched, paint again.
    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()   // opening the menu also repairs an item that started blank
        lock.lock(); let list = apps, error = lastError, busy = installingApp, pending = active.union(requested); lock.unlock()
        let settings = HelperSettings.load(from: stateDir)
        menu.removeAllItems()
        /// A disabled line. `detail` is the whole sentence, shown on hover, so a line that has to be
        /// short never hides what it is shortening.
        func note(_ text: String, to target: NSMenu? = nil, detail: String? = nil) {
            let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            i.isEnabled = false
            if let detail, detail != text { i.toolTip = detail }
            (target ?? menu).addItem(i)
        }
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
        if let error {
            let line = MenuText.item("Last check failed: \(error)")
            note(line.title, detail: line.tooltip)
        }
        if list.isEmpty && error == nil { note("Checking…") }
        menu.addItem(.separator())
        // A fleet of many apps must not turn this menu into a wall of rows: by default only the
        // apps that need action are listed. Small fleets still show everything, and the choice is
        // a saved switch, not a fixed rule.
        let showsAll = UserDefaults.standard.bool(forKey: "com.khupdater.menuShowsAllApps")
            || list.filter { $0.managed }.count <= 8
        let needingAction: (HelperApp) -> Bool = { app in
            [HelperApp.updateAvailable, HelperApp.downloaded, HelperApp.failed, HelperApp.needsAttention, HelperApp.notInstalled].contains(app.status)
        }
        for app in list where app.managed && (showsAll || needingAction(app)) {
            let status = busy == app.app ? HelperApp.updating : (pending.contains(app.app) ? HelperApp.receiving : app.status)
            let row = NSMenuItem(title: "\(app.name.isEmpty ? AppNames.display(app.app) : app.name)   \(app.installed ?? "—") · \(status)", action: nil, keyEquivalent: "")
            menu.addItem(row)
            // An observed-only app has no switch: a status line only.
            guard !app.statusOnly else { row.isEnabled = false; continue }
            let sub = NSMenu()
            sub.autoenablesItems = false
            if let reason = app.reason {
                let line = MenuText.item(reason)
                note(line.title, to: sub, detail: line.tooltip)
            }
            if app.installable, let available = app.available, [HelperApp.updateAvailable, HelperApp.downloaded, HelperApp.failed, HelperApp.notInstalled].contains(app.status) {
                action("Update now to \(available)", #selector(updateNow(_:)), app.app, to: sub).isEnabled = busy == nil
            }
            action("Automatic updates", #selector(toggleAutomatic(_:)), app.app, to: sub).state = app.automatic ? .on : .off
            // Whichever of the three settings this value follows, in the same words the Launcher
            // page uses; the rule itself lives in `HelperSettings.automaticDecision`.
            if let from = app.automaticOrigin { note(from, to: sub) }
            row.submenu = sub
        }
        if !showsAll {
            let rest = list.filter { $0.managed && !needingAction($0) }.count
            if rest > 0 { note("\(rest) more up to date — open the window for everything") }
        }
        menu.addItem(.separator())
        _ = action("Open Studio Launcher…", #selector(openWindow))
        // The fleet is a Studio function: a Mac that runs no Studio and has joined none has no
        // fleet to open, and its menu does not offer one (owner, 2026-11-24).
        if LauncherWindow.studioHere(config: config) { _ = action("Open Fleet…", #selector(openFleet)) }
        _ = action(showsAll ? "Show only apps needing attention" : "Show all apps in menu", #selector(toggleShowAll))
        _ = action("Check for Updates Now", #selector(checkNow))
        _ = action(settings.paused(at: Date()) ? "Resume Automatic Updates" : "Pause Automatic Updates for 24 Hours", #selector(togglePause))
        menu.addItem(.separator())
        note("Studio Launcher KH \(version ?? "")")
        _ = action("What's New…", #selector(whatsNew))
        _ = action("Support This App…", #selector(supportApp))
        menu.addItem(.separator())
        _ = action("Quit Studio Launcher KH", #selector(quitApp))
    }

    /// The agent has no window to close in place of stopping it, so this is the plainest way.
    @objc private func quitApp() { NSApp.terminate(nil) }

    /// The same free, optional donation the page offers, opened in the browser.
    @objc private func supportApp() {
        if let url = URL(string: "https://nowpayments.io/donation/studiokh") { NSWorkspace.shared.open(url) }
    }

    @objc private func checkNow() { pacing.wakeByPerson() }
    @objc private func openWindow() { showWindow() }
    @objc private func openFleet() { showFleet() }

    @objc private func updateNow(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        request(app)
    }
    func request(_ app: String) {
        // Only the agent's item-start callback owns live progress; a click just queues work.
        lock.lock(); requested.insert(app); lock.unlock()
        pacing.wakeByPerson()
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

    /// A saved switch, not a fixed rule: the menu lists only apps needing action unless the owner
    /// asks for the full list (large fleets would otherwise fill the menu).
    @objc private func toggleShowAll() {
        let key = "com.khupdater.menuShowsAllApps"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        if let item, let menu = item.menu { menuNeedsUpdate(menu) }
    }

    /// A change is saved, then the loop wakes so the page hears of it — at the next scheduled run,
    /// never sooner: saving a setting must not become a reason to run again.
    @discardableResult func save(_ settings: HelperSettings) -> Bool {
        do {
            try settings.save(to: stateDir)
            settingsNote = "Saved."
            pacing.wakeByState()
            return true
        } catch {
            settingsNote = "Could not save that change. Your previous settings are kept."
            alert("That change could not be saved", "\(error)")
            return false
        }
    }

    @objc func whatsNew() {
        showWindow()
        // One design for both routes: the menu asks the page for its own pop-up.
        window?.showWhatsNew()
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    static func clock(_ iso: String) -> String {
        guard let d = ISO.date(iso) else { return iso }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }
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
