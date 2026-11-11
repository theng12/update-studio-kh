// Update Studio KH.app: a window onto the publisher's own status page. Nothing else.
import AppKit
import WebKit
import CryptoKit
import UniformTypeIdentifiers

final class Delegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "What's New…", action: #selector(showWhatsNew), keyEquivalent: "").target = self
        let versionItem = NSMenuItem(title: "Update Studio KH \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        appMenu.addItem(versionItem)
        appMenu.addItem(withTitle: "Quit Update Studio KH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "saveLauncher")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        // The page shows its own version (footer pill), so the running app names it.
        var page = URLComponents(string: "http://127.0.0.1:8790/")!
        page.queryItems = [URLQueryItem(name: "app", value: version)]
        web.load(URLRequest(url: page.url ?? URL(string: "http://127.0.0.1:8790/")!))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Update Studio KH"
        window.contentView = web
        window.minSize = NSSize(width: 420, height: 400)
        window.center()
        window.setFrameAutosaveName("KHUpdaterMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "lastWhatsNewVersion")
        defaults.set(version, forKey: "lastWhatsNewVersion")
        if let previous, previous.compare(version, options: .numeric) == .orderedAscending {
            DispatchQueue.main.async { self.showWhatsNew() }
        }
    }

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Not checked" }

    @objc func showWhatsNew() {
        let alert = NSAlert()
        alert.messageText = "What's New · Update Studio KH \(version) (current)"
        do {
            guard let url = Bundle.main.url(forResource: "whats-new", withExtension: "json") else {
                throw copyError("The packaged release notes are missing. Install the complete signed Update Studio package.")
            }
            struct Entry: Decodable { var version: String; var items: [String] }
            let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
            guard let entry = entries.first(where: { $0.version == version }) else {
                throw copyError("The packaged release notes do not match this app's version.")
            }
            alert.informativeText = entry.items.map { "• " + $0 }.joined(separator: "\n")
        } catch { alert.informativeText = "Release notes could not be read: \(error.localizedDescription)" }
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window)
    }

    // The page asks before Remove Mac, Update N Macs, Roll back and New code; a web view shows no confirm box unless the app does.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        // The button says what the page is asking for.
        alert.addButton(withTitle: ["Remove", "Update", "Roll back", "New code"].first { message.hasPrefix($0) } ?? "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    var savingLauncher = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == "saveLauncher", message.frameInfo.isMainFrame,
              origin.protocol == "http", origin.host == "127.0.0.1", origin.port == 8790, !savingLauncher else { return }
        savingLauncher = true
        do {
            let source = try launcherForSharing()
            let panel = NSSavePanel()
            panel.title = "Save Studio Launcher KH for another Mac"
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "Studio Launcher KH.zip"
            panel.beginSheetModal(for: window) { answer in
                guard answer == .OK, let target = panel.url else { self.savingLauncher = false; return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let fm = FileManager.default
                    let stage = target.deletingLastPathComponent().appendingPathComponent(".launcher-\(UUID().uuidString).zip")
                    do {
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, stage.path]
                        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
                        try task.run(); task.waitUntilExit()
                        guard task.terminationStatus == 0 else { throw self.copyError("The Launcher copy could not be saved. Check the destination has enough free space and try again.") }
                        if fm.fileExists(atPath: target.path) {
                            let kept = target.deletingLastPathComponent().appendingPathComponent("_trash", isDirectory: true)
                            try fm.createDirectory(at: kept, withIntermediateDirectories: true)
                            try fm.moveItem(at: target, to: kept.appendingPathComponent("\(UUID().uuidString)-\(target.lastPathComponent)"))
                        }
                        try fm.moveItem(at: stage, to: target)
                        DispatchQueue.main.async {
                            self.savingLauncher = false
                            let alert = NSAlert(); alert.messageText = "Launcher copy saved"
                            alert.informativeText = "Transfer the ZIP to the new Mac, open it, move Studio Launcher KH into Applications, then open the app and choose Connect to Update Studio. The copy contains the publisher’s public connection settings, not a Mac’s token."
                            alert.beginSheetModal(for: self.window)
                        }
                    } catch {
                        DispatchQueue.main.async { self.savingLauncher = false; self.showCopyError(error) }
                    }
                }
            }
        } catch { savingLauncher = false; showCopyError(error) }
    }

    func copyError(_ text: String) -> NSError { NSError(domain: "LauncherCopy", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    func showCopyError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Launcher copy was not saved"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    func launcherForSharing() throws -> URL {
        let fm = FileManager.default
        let locations = [URL(fileURLWithPath: "/Applications/Studio Launcher KH.app"),
                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Studio Launcher KH.app")]
        for app in locations {
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.khupdater.launcher" else { continue }
            let kit = app.appendingPathComponent("Contents/Resources/khu-agent")
            guard let data = try? Data(contentsOf: kit.appendingPathComponent("MANIFEST.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = manifest["files"] as? [String: [String: Any]] else { continue }
            let expected: Set<String> = ["VERSION", "agent-config.example.json", "bin/khu", "bin/khu-stub", "com.khupdater.agent.plist", "install-agent.sh", "publisher.json"]
            guard Set(files.keys) == expected || Set(files.keys) == expected.union(["AppIcon.icns"]) else { continue }
            var valid = true
            for (name, pin) in files {
                let file = kit.appendingPathComponent(name).resolvingSymlinksInPath()
                guard file.path.hasPrefix(kit.resolvingSymlinksInPath().path + "/"),
                      let bytes = try? Data(contentsOf: file), bytes.count == pin["bytes"] as? Int,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == pin["sha256"] as? String else { valid = false; break }
            }
            guard valid else { continue }
            let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--deep", "--strict", app.path]
            verify.standardOutput = FileHandle.nullDevice; verify.standardError = FileHandle.nullDevice
            try verify.run(); verify.waitUntilExit()
            if verify.terminationStatus == 0 { return app }
        }
        throw copyError("Install the signed Studio Launcher KH package with its connection kit first, then try again. You can also use the Launcher installer on an install SSD. The helper-only copy on this Mac cannot connect a new Mac.")
    }

    // The page is this Mac's publisher; a donation link opens in the browser and nothing else may
    // navigate the window away. The address is the one this app loaded.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "http", url.host == "127.0.0.1", url.port == 8790 { return decisionHandler(.allow) }
        if url.scheme == "https", url.host == "nowpayments.io" || url.host == "www.nowpayments.io" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
