import AppKit

extension HelperMenu {
    func showWindow() {
        rescanSSDs()
        if window == nil { window = LauncherWindow(helper: self) }
        window?.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.window.makeKeyAndOrderFront(nil)
        setMenuIcon(visible: true)
        DistributedNotificationCenter.default().postNotificationName(LauncherBundle.shownNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Volumes are read only when the window opens or a volume mounts or unmounts.
    func rescanSSDs() {
        let found = SSDSource.scan()
        lock.lock(); ssd = found; lock.unlock()
        window?.reload()
        wake.signal()
    }
}

/// The packaged Launcher forwards to the running helper. Raw helper updates must keep that
/// app's signature and kit intact; only a verified packaged app update replaces the bundle.
enum LauncherBundle {
    static let openNotification = Notification.Name("com.khupdater.launcher.open")
    static let shownNotification = Notification.Name("com.khupdater.launcher.shown")
    static let bundleID = "com.khupdater.launcher"
    static let name = "Studio Launcher KH.app"

    static func ensure(version: String?) {
        guard ProcessInfo.processInfo.environment["KHU_NO_BUNDLE"] == nil,
              !Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let fm = FileManager.default
        let locations = [URL(fileURLWithPath: "/Applications").appendingPathComponent(name),
                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").appendingPathComponent(name)]
        if locations.contains(where: { Connect.packagedLauncherVerifies($0) }) { return }
        FileHandle.standardError.write(Data("Install the signed Studio Launcher KH package from the install SSD. The helper keeps running; it cannot rebuild a signed app on this Mac.\n".utf8))
    }

    /// Also used by packaging (`khu launcher-bundle`), which adds the setup kit to Resources.
    static func write(bundle: URL, executable: URL, version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: executable, to: bundle.appendingPathComponent("Contents/MacOS/Studio Launcher KH"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": "Studio Launcher KH", "CFBundleDisplayName": "Studio Launcher KH",
            "CFBundleExecutable": "Studio Launcher KH", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
            "CFBundleVersion": version, "CFBundleIconFile": "AppIcon", "LSUIElement": true, "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": true,
            // macOS 14+ applies ATS to numeric IPs, and neither an IP literal nor a CIDR range is
            // matched in NSExceptionDomains, so plain HTTP is allowed for this bundle. The feed is
            // held to the tailnet or loopback where its URL is checked (FeedNetwork.feedURL).
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try icns().write(to: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns"))
    }

    /// A squircle in the house green with four app tiles: the Launcher's own icon.
    static func icns() throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "com.apple.icns" as CFString, 6, nil) else { throw khuFail("no icns writer") }
        for px in [16, 32, 128, 256, 512, 1024] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let s = Double(px) / 1024
            let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let squircle = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
            NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.56, blue: 0.43, alpha: 1),
                       ending: NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.27, alpha: 1))!.draw(in: squircle, angle: -90)
            NSColor.white.setFill()
            for (x, y) in [(270.0, 530.0), (530.0, 530.0), (270.0, 270.0), (530.0, 270.0)] {
                NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: 224 * s, height: 224 * s), xRadius: 52 * s, yRadius: 52 * s).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(dest, rep.cgImage!, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw khuFail("the icon could not be written") }
        return out as Data
    }
}

/// Studio Launcher KH.app opened by a person. With the helper set up, it asks the helper to show
/// its window. Without one, it is the front door: it opens the native "Connect to Update Studio"
/// window, which shows the address this app's own kit names, takes the pairing code and this
/// Mac's name, and connects on a background queue. KHU_CONNECT_HOME / KHU_CONNECT_KIT point the
/// front door at a throwaway home and kit for isolated window checks; nobody sets them in real use.
enum FrontDoor {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        LauncherMenus.install()
        let env = ProcessInfo.processInfo.environment
        let isolated = env["KHU_CONNECT_HOME"] != nil
        let home = env["KHU_CONNECT_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        // The running helper is the authority even when this SSD copy cannot find its config.
        if !isolated && askHelper(seconds: 2) { exit(0) }
        if Connect.isSetUp(home: home) {
            // An isolated home never starts this Mac's real helper.
            if !isolated {
                do { try Connect.startInstalledAgent(home: home) }
                catch {
                    var failure = "\(error)"
                    // Repair is offered only for the saved helper files or start file being
                    // missing (startup's print said the job is absent, and it is not disabled).
                    // A disabled, unreadable or refused startup is left exactly as macOS has it.
                    let incomplete = failure.contains("needs its start file repaired")
                        || failure.contains("needs its helper files repaired")
                    let kit = env["KHU_CONNECT_KIT"].map { URL(fileURLWithPath: $0) }
                        ?? Bundle.main.resourceURL?.appendingPathComponent("khu-agent")
                    if incomplete, let kit, FileManager.default.fileExists(atPath: kit.appendingPathComponent("MANIFEST.json").path),
                       (try? Connect.publisher(kit: kit)) != nil {
                        switch ConnectionWindow.runSetupRepair(kit: kit, home: home, reason: failure) {
                        case .connected:
                            if !askHelper(seconds: 30) {
                                say("Studio Launcher KH did not answer",
                                    "The saved setup was repaired, but its window did not answer. Close this window and open Studio Launcher again.")
                            }
                            exit(0)
                        case .cancelled:
                            exit(0)
                        }
                    }
                    if incomplete {
                        failure += "\n\nThis copy has no setup kit inside it, so it cannot repair the helper. Open Studio Launcher KH "
                            + "from the SSD's “1 Install Apps/0 - Start here - Studio Launcher KH” folder."
                    } else {
                        failure += "\n\nNothing was changed: this copy repairs only a saved helper whose files or start file are missing."
                    }
                    say("Studio Launcher could not start", failure)
                    exit(1)
                }
                if !askHelper(seconds: 30) {
                    let reason = "The helper is registered with macOS, but its window did not answer within 30 seconds. "
                        + "Your saved connection and settings are kept."
                    let kit = env["KHU_CONNECT_KIT"].map { URL(fileURLWithPath: $0) }
                        ?? Bundle.main.resourceURL?.appendingPathComponent("khu-agent")
                    // A registered stub can still have missing runtime files. The deliberate repair
                    // rechecks the agent lock, pause, version and disabled state before replacement.
                    if let kit, (try? Connect.publisher(kit: kit)) != nil {
                        switch ConnectionWindow.runSetupRepair(kit: kit, home: home, reason: reason) {
                        case .connected:
                            if !askHelper(seconds: 30) {
                                say("Studio Launcher KH did not answer", "The saved setup was repaired, but its window did not answer. Your saved connection and settings are kept.")
                            }
                        case .cancelled: break
                        }
                    } else {
                        say("Studio Launcher KH did not answer", reason + " Open the trusted Launcher copy with its setup kit to repair the helper.")
                    }
                }
            }
            exit(0)
        }
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        let kit = env["KHU_CONNECT_KIT"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("khu-agent")
        guard let kit, FileManager.default.fileExists(atPath: kit.appendingPathComponent("MANIFEST.json").path) else {
            say("Studio Launcher KH is not set up on this Mac",
                "This copy has no setup kit. Open Studio Launcher KH from the SSD's “1 Install Apps/0 - Start here - Studio Launcher KH” folder.")
            exit(1)
        }
        // The kit is what names (and vouches for) the Update Studio this window shows: a kit whose
        // manifest or publisher record does not verify is not one to connect with, said plainly.
        do { _ = try Connect.publisher(kit: kit) }
        catch {
            say("This copy's setup kit cannot be used", "\(error)\n\nGet a fresh copy of Studio Launcher KH from the install SSD.")
            exit(1)
        }
        switch ConnectionWindow.run(kit: kit, home: home) {
        case .connected:
            if !isolated && !askHelper(seconds: 30) {
                say("Studio Launcher KH did not answer", "Your connection is saved. Close this window and open Studio Launcher again.")
            }
            exit(0)
        case .cancelled:
            exit(0)
        }
    }

    /// Asks every second until the helper says its window is showing.
    static func askHelper(seconds: Int) -> Bool {
        var shown = false
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: LauncherBundle.shownNotification, object: nil, queue: nil) { _ in shown = true }
        defer { center.removeObserver(token) }
        for _ in 0..<seconds where !shown {
            center.postNotificationName(LauncherBundle.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return shown
    }

    static func say(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

import UserNotifications

/// "Notify me when an update is ready": each app's update is announced once, by Studio Launcher
/// KH.app so the notification carries its name and icon. Off by default.
enum Notifier {
    static func announce(_ ready: [HelperApp], stateDir: URL) {
        var settings = HelperSettings.load(from: stateDir)
        guard settings.notify == true else { return }
        var told = settings.notified ?? [:]
        let new = ready.filter { told[$0.app] != $0.available }
        guard !new.isEmpty else { return }
        for app in new { told[app.app] = app.available }
        settings.notified = told
        try? settings.save(to: stateDir)
        let names = new.map { $0.name.isEmpty ? $0.app : $0.name }
        let body = names.count == 1 ? "\(names[0]) \(new[0].available ?? "") is ready to install." : "\(names.joined(separator: ", ")) have updates ready."
        let bundle = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            .map { $0 + "/" + LauncherBundle.name }.first { FileManager.default.fileExists(atPath: $0) }
        guard let bundle else { return }
        _ = try? SystemShell().run("/usr/bin/open", arguments: ["-g", "-a", bundle, "--args", "notify", "Update ready", body], timeout: 15)
    }

    static func post(title: String, body: String) -> Never {
        let center = UNUserNotificationCenter.current()
        let done = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { done.signal(); return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in done.signal() }
        }
        _ = done.wait(timeout: .now() + 60)
        exit(0)
    }
}
