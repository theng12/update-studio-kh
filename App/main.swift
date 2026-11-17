// Update Studio KH.app: a window onto the publisher's own status page. Nothing else.
//
// The fleet's publisher is the release host named in this Mac's Launcher config (1301). Its owner page
// answers only on that host's own loopback, so the window reaches it through an SSH tunnel onto this
// Mac's 127.0.0.1:8790, the address the page and its checks expect. 1301's access rule is unchanged.
// When the tunnel or the page is not there, the window says so instead of showing anything stale.
import AppKit
import WebKit
import CryptoKit
import UniformTypeIdentifiers

final class Delegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var tunnel: Process?
    var tunnelInput: Pipe?
    var retryTimer: Timer?
    /// Seconds before the next automatic try: 30 s, doubling to at most 10 minutes; reset on success.
    var retryDelay: TimeInterval = 30
    /// The fleet the window shows, named in the title bar so it is never mistaken for a local copy.
    var fleetHost: String?
    let localPort: UInt16 = 8790
    /// `--snapshot <dir>`: render the window off screen to PNGs and exit; never shown, never activated.
    let snapshotDir: String? = CommandLine.arguments.firstIndex(of: "--snapshot").flatMap {
        CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }

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
        configuration.userContentController.add(self, name: "retry")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Update Studio KH"
        window.contentView = web
        window.minSize = NSSize(width: 420, height: 400)
        connect()
        if snapshotDir != nil { return }
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
        web.evaluateJavaScript("(function(){var d=document.getElementById('whats-new');if(!d)return false;if(!d.open)d.showModal();return true})()") { shown, _ in
            // The publisher's page is still loading: show the window's own page with the notes open.
            if shown as? Bool != true { self.showStatus(title: "Update Studio KH", detail: "", retry: false, openNotes: true) }
        }
    }

    // MARK: Reaching the publisher

    struct Publisher { var feedHost: String; var ssh: String; var key: String? }

    /// Where the fleet lives, read from this Mac's Launcher config; each part can be overridden with
    /// `defaults write com.khupdater.app publisherSSHHost|publisherSSHUser|publisherSSHKey <value>`.
    func publisher() throws -> Publisher {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent("Library/KHUpdater/base/config.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = object["feedURL"] as? String, let host = URL(string: feed)?.host else {
            throw copyError("This Mac has no Launcher connection, so the publisher's address is unknown (\(config.path) has no feed address). Connect Studio Launcher KH to Update Studio first.")
        }
        let defaults = UserDefaults.standard
        // The SSH host key on file is under the Mac's short name; an unknown key is never accepted.
        let sshHost = defaults.string(forKey: "publisherSSHHost") ?? String(host.split(separator: ".").first ?? Substring(host))
        let user = defaults.string(forKey: "publisherSSHUser") ?? NSUserName()
        let standardKey = home.appendingPathComponent(".ssh/id_ed25519_gateway1301").path
        let key = defaults.string(forKey: "publisherSSHKey") ?? (FileManager.default.fileExists(atPath: standardKey) ? standardKey : nil)
        return Publisher(feedHost: host, ssh: "\(user)@\(sshHost)", key: key)
    }

    static func portAnswers(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Opens the tunnel, then loads the page once its port answers. Every failure ends on a page that
    /// names what was tried and why it failed, and tries again every 30 seconds.
    func connect() {
        retryTimer?.invalidate()
        let old = tunnel; tunnel = nil; tunnelInput = nil; old?.terminate()
        let target: Publisher
        do { target = try publisher() } catch { return offline("The publisher's address is unknown", error.localizedDescription) }
        window.subtitle = "Connecting · nothing shown is live yet"
        showStatus(title: "Connecting to the publisher", detail: "Reaching \(target.feedHost) through \(target.ssh)…", retry: false)
        let port = localPort
        DispatchQueue.global(qos: .userInitiated).async {
            old?.waitUntilExit()
            if Self.portAnswers(port) {
                return DispatchQueue.main.async {
                    self.offline("Port \(port) on this Mac is already in use",
                                 "Another program on this Mac answers on 127.0.0.1:\(port), so this window cannot tell it apart from the publisher on \(target.feedHost). An old local publisher may have been started again; stop it, then choose Try again.")
                }
            }
            let process = Process(), input = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // The remote `cat` reads this pipe: when the app exits for any reason, the tunnel ends too.
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                                 "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                                 "-L", "127.0.0.1:\(port):127.0.0.1:8790"] + (target.key.map { ["-i", $0] } ?? []) + [target.ssh, "cat >/dev/null"]
            process.standardInput = input; process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { ended in
                let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "the connection closed (exit \(ended.terminationStatus))"
                DispatchQueue.main.async {
                    guard self.tunnel === ended else { return }
                    self.tunnel = nil; self.tunnelInput = nil
                    self.offline("The publisher on \(target.feedHost) is not reachable",
                                 "The connection through \(target.ssh) ended: \(said). No fleet data is shown until it works again.")
                }
            }
            DispatchQueue.main.sync { self.tunnel = process; self.tunnelInput = input }
            do { try process.run() } catch {
                return DispatchQueue.main.async { self.tunnel = nil; self.offline("The connection could not start", "\(error.localizedDescription)") }
            }
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning, Date() < deadline {
                if Self.portAnswers(port) {
                    return DispatchQueue.main.async {
                        guard self.tunnel === process else { return }
                        self.retryDelay = 30
                        self.fleetHost = target.feedHost
                        self.window.subtitle = "Live fleet on \(target.feedHost) · actions here change those Macs"
                        // The page shows its own version (footer pill), so the running app names it.
                        var page = URLComponents(string: "http://127.0.0.1:\(port)/")!
                        page.queryItems = [URLQueryItem(name: "app", value: self.version)]
                        self.web.load(URLRequest(url: page.url!))
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if process.isRunning {
                process.terminate()  // the termination handler names it, as for any other ending
            }
        }
    }

    func offline(_ title: String, _ detail: String) {
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 600)
        window.subtitle = "Not connected · nothing shown is live"
        showStatus(title: title, detail: detail + " Trying again in \(wait >= 60 ? "\(Int(wait / 60)) minute\(wait >= 120 ? "s" : "")" : "\(Int(wait)) seconds").", retry: true)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.connect() }
        snapshotIfAsked()
    }

    /// The window's own page, in the publisher page's colours, with the same What's New dialog.
    func showStatus(title: String, detail: String, retry: Bool, openNotes: Bool = false) {
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let css = (Bundle.main.url(forResource: "whats-new-dialog", withExtension: "css")).flatMap { try? String(contentsOf: $0) } ?? ""
        let notes = whatsNewBody(escape: h)
        let html = """
        <!doctype html><html><head><meta charset=utf-8><meta name=color-scheme content="light dark"><style>
        :root{--bg:#f5f6f5;--panel:#fff;--line:#e2e5e3;--text:#16201c;--sub:#5b6762;--accent:#1d6b51;--accent-ink:#fff;--ok:#1a7448;--ok-bg:#e2f3e9;--bad:#b42318;--shadow:0 10px 30px rgba(15,30,25,.14)}
        @media(prefers-color-scheme:dark){:root{--bg:#101513;--panel:#171e1b;--line:#29332f;--text:#e6ece9;--sub:#a9b5af;--accent:#3fa37f;--accent-ink:#06120d;--ok:#62d19a;--ok-bg:#15301f;--bad:#ff8a7e;--shadow:0 12px 32px rgba(0,0,0,.5)}}
        body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,system-ui,sans-serif}
        main{max-width:640px;margin:12vh auto 0;padding:32px;background:var(--panel);border:1px solid var(--line);border-radius:14px}
        h1{font-size:22px;margin:0 0 10px}p.detail{color:var(--sub);margin:0 0 20px;overflow-wrap:anywhere}
        .row{display:flex;gap:10px;flex-wrap:wrap}button{font:inherit;padding:8px 14px;border-radius:7px;border:1px solid var(--line);background:var(--panel);color:var(--text);cursor:pointer}
        button.primary{background:var(--accent);color:var(--accent-ink);border-color:var(--accent)}button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
        dialog{padding:0;border:1px solid var(--line);border-radius:14px;background:var(--panel);color:var(--text);box-shadow:var(--shadow)}dialog::backdrop{background:rgba(0,0,0,.48)}
        .modalbar{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 24px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--panel);z-index:2}.modalbar h2{margin:0;font-size:20px}
        \(css)</style></head><body><main><h1>\(h(title))</h1>\(detail.isEmpty ? "" : "<p class=detail>\(h(detail))</p>")
        <div class=row>\(retry ? "<button class=primary id=retry>Try again</button>" : "")<button id=notes>What's New</button></div></main>
        <dialog id=whats-new aria-labelledby=whats-new-title><div class=modalbar><h2 id=whats-new-title>What's New</h2><button type=button id=whats-new-close aria-label="Close What's New">Close</button></div><div class=body>\(notes)</div></dialog>
        <script>var d=document.getElementById('whats-new');document.getElementById('notes').onclick=function(){d.showModal()};
        document.getElementById('whats-new-close').onclick=function(){d.close()};
        var r=document.getElementById('retry');if(r)r.onclick=function(){r.disabled=true;r.textContent='Trying…';webkit.messageHandlers.retry.postMessage(1)};
        \(openNotes ? "d.showModal();" : "")</script></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    /// Same markup as the publisher page's dialog (`WhatsNew.dialogBody` in KHUpdaterCore), from the
    /// release notes packaged with this app.
    func whatsNewBody(escape h: (String) -> String) -> String {
        struct Entry: Decodable { var version: String; var date: String?; var items: [String] }
        guard let url = Bundle.main.url(forResource: "whats-new", withExtension: "json"),
              let entries = try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)), !entries.isEmpty else {
            return "<p class=newssum>The packaged release notes are missing. Install the complete signed Update Studio package.</p>"
        }
        func list(_ items: [String]) -> String { "<ul class=newslist>" + items.map { "<li>\(h(plain($0)))</li>" }.joined() + "</ul>" }
        let index = entries.firstIndex { $0.version == version } ?? 0
        let entry = entries[index], count = entry.items.count
        let mismatch = entry.version == version ? "" : " This app runs v\(h(version)), which has no notes of its own; these are the newest."
        var out = "<p class=newshead><strong>Update Studio KH v\(h(entry.version))</strong>"
            + (entry.version == version ? "<span class=tag>This version</span>" : "")
            + (entry.date.map { "<span class=when>\(h($0))</span>" } ?? "") + "</p>"
            + "<p class=newssum>\(count) change\(count == 1 ? "" : "s") in this release.\(mismatch)</p>" + list(entry.items)
        for earlier in entries.dropFirst(index + 1).prefix(4) {
            out += "<section class=rel><h3>v\(h(earlier.version))" + (earlier.date.map { " <span class=when>\(h($0))</span>" } ?? "") + "</h3>\(list(earlier.items))</section>"
        }
        return out
    }

    /// The changelog's Markdown marks (`**`, backticks) are not shown as characters.
    func plain(_ item: String) -> String { item.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }

    // MARK: Page loads

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse, http.statusCode != 200 {
            decisionHandler(.cancel)
            let host = (try? publisher().feedHost) ?? "the publisher"
            return offline("The publisher on \(host) refused the page", "It answered HTTP \(http.statusCode) instead of its status page.")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageFailed(error) }

    func pageFailed(_ error: Error) {
        let ns = error as NSError
        // A load the window replaced itself, or one its own response check already stopped, is not a failure.
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled), !(ns.domain == "WebKitErrorDomain" && ns.code == 102) else { return }
        let host = (try? publisher().feedHost) ?? "the publisher"
        offline("The publisher on \(host) did not answer", "The connection is up, but its status page did not load: \(ns.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.port == Int(localPort) { snapshotIfAsked() }
    }

    var snapshotTaken = false
    func snapshotIfAsked() {
        guard let dir = snapshotDir, !snapshotTaken else { return }
        snapshotTaken = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let name = self.web.url?.scheme == "about" ? "status" : "publisher"
            print("window: \(self.window.title) — \(self.window.subtitle)")
            self.snap("\(dir)/\(name).png") {
                self.web.evaluateJavaScript("var d=document.getElementById('whats-new');if(d&&!d.open)d.showModal();!!d") { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self.snap("\(dir)/\(name)-whats-new.png") { exit(0) }
                    }
                }
            }
        }
    }

    func snap(_ path: String, then: @escaping () -> Void) {
        web.takeSnapshot(with: nil) { image, error in
            if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
            } else { print("snapshot failed: \(error?.localizedDescription ?? "no image")") }
            then()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { tunnel?.terminate() }

    // The page asks before Remove Mac, Update N Macs, Roll back and New code; a web view shows no confirm box unless the app does.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "This acts on the live fleet on \(fleetHost ?? "the publisher"), not on a copy."
        // The button says what the page is asking for.
        alert.addButton(withTitle: ["Remove", "Update", "Roll back", "New code"].first { message.hasPrefix($0) } ?? "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    var savingLauncher = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "retry" { if message.frameInfo.isMainFrame, web.url?.scheme == "about" { connect() }; return }
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
        // The window's own status page (loaded from a string) and nothing else from about:.
        if url.absoluteString == "about:blank" { return decisionHandler(.allow) }
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
// A snapshot run never shows a Dock icon or takes focus.
app.setActivationPolicy(CommandLine.arguments.contains("--snapshot") ? .prohibited : .regular)
app.run()
