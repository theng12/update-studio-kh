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

/// Studio Launcher KH.app in /Applications (or ~/Applications when that is not writable): the
/// same helper binary in a bundle, so Spotlight finds it and opening it shows the window. The
/// helper refreshes it whenever its own binary changes; the old copy goes to _trash.
enum LauncherBundle {
    static let openNotification = Notification.Name("com.khupdater.launcher.open")
    static let shownNotification = Notification.Name("com.khupdater.launcher.shown")
    static let bundleID = "com.khupdater.launcher"
    static let name = "Studio Launcher KH.app"

    static func ensure(version: String?) {
        guard ProcessInfo.processInfo.environment["KHU_NO_BUNDLE"] == nil, !Bundle.main.bundlePath.hasSuffix(".app"),
              let exe = Bundle.main.executablePath.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) else { return }
        let fm = FileManager.default
        let parent = fm.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications")
            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let target = parent.appendingPathComponent(name)
        let inside = target.appendingPathComponent("Contents/MacOS/Studio Launcher KH")
        if let a = try? Signing.sha256Hex(fileAt: exe).hex, let b = try? Signing.sha256Hex(fileAt: inside).hex, a == b { return }
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".\(name).khu-tmp-\(UUID().uuidString)")
            try write(bundle: staging, executable: exe, version: version ?? "0")
            if fm.fileExists(atPath: target.path) {
                try Trash.move(target, into: Trash.root(in: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/KHUpdater/state")))
            }
            try fm.moveItem(at: staging, to: target)
        } catch {
            FileHandle.standardError.write(Data("Studio Launcher KH.app not written: \(error)\n".utf8))
        }
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
/// its window. Without one, it is the front door: it asks for the pairing code once, sets the
/// helper up from the kit inside the app, then shows the window.
enum FrontDoor {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        if Connect.isSetUp(home: home) { askHelper(seconds: 2); exit(0) }
        NSApp.activate(ignoringOtherApps: true)
        guard let kit = Bundle.main.resourceURL?.appendingPathComponent("khu-agent"),
              FileManager.default.fileExists(atPath: kit.appendingPathComponent("MANIFEST.json").path) else {
            say("Studio Launcher KH is not set up on this Mac",
                "This copy has no setup kit. Open Studio Launcher KH from the SSD's “1 Install Apps/0 - Start here - Studio Launcher KH” folder.")
            exit(1)
        }
        var problem = ""
        let name = NSTextField(string: Connect.proposedName())
        let code = NSTextField(string: "")
        code.placeholderString = "123-456"
        while true {
            let alert = NSAlert()
            alert.messageText = "Set up Studio Launcher KH"
            alert.informativeText = (problem.isEmpty ? "" : problem + "\n\n")
                + "Type the pairing code shown in Update Studio KH on the Mac Studio, under Connect a Mac."
            let form = NSGridView(views: [[NSTextField(labelWithString: "Name for this Mac"), name],
                                          [NSTextField(labelWithString: "Pairing code"), code]])
            form.frame = NSRect(x: 0, y: 0, width: 360, height: 56)
            name.widthAnchor.constraint(equalToConstant: 220).isActive = true
            alert.accessoryView = form
            alert.addButton(withTitle: "Set Up")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = code
            guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }
            do {
                _ = try Connect.run(kit: kit, home: home, machine: name.stringValue.trimmingCharacters(in: .whitespaces).lowercased(),
                                    code: code.stringValue.trimmingCharacters(in: .whitespaces))
                break
            } catch {
                problem = "Not set up: \(error)"
            }
        }
        // The helper is starting under launchd; ask until it shows the list.
        askHelper(seconds: 30)
        exit(0)
    }

    /// Asks every second until the helper says its window is showing.
    static func askHelper(seconds: Int) {
        var shown = false
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: LauncherBundle.shownNotification, object: nil, queue: nil) { _ in shown = true }
        defer { center.removeObserver(token) }
        for _ in 0..<seconds where !shown {
            center.postNotificationName(LauncherBundle.openNotification, object: nil, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if !shown {
            say("Studio Launcher KH did not answer", "Its helper is not running yet. Try again in a minute; if it still does not open, restart this Mac.")
        }
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
