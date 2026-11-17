// The fleet window: the publisher's own page for this Mac's Update Studio, inside Studio Launcher KH.
//
// It is the view Update Studio KH.app used to be — an SSH tunnel onto the publisher's loopback page,
// so a person at this Mac can see and act on the whole fleet. It lives in this app now (owner,
// 2026-11-17: one GUI app), and the background helper stays the separate headless `khu` agent.
// Nothing here is live until the tunnel answers: a failure says what was tried and why.
import AppKit
import WebKit
import CryptoKit
import UniformTypeIdentifiers

final class FleetWindow: NSObject, WKUIDelegate, WKScriptMessageHandler,
                         WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private var tunnel: Process?
    private var retryTimer: Timer?
    /// Seconds before the next automatic try: 30 s, doubling to at most 10 minutes; reset on success.
    private var retryDelay: TimeInterval = 30
    /// The fleet the window shows, named in the title bar so it is never mistaken for a local copy.
    private var fleetHost: String?
    private let localPort: UInt16 = 8790
    /// The version of this app, shown on the window's own page.
    var version: String = ""

    func show() {
        if window == nil {
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "saveLauncher")
            config.userContentController.add(self, name: "retry")
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
            web.uiDelegate = self
            web.navigationDelegate = self
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Fleet"
            window.contentView = web
            window.minSize = NSSize(width: 420, height: 400)
            window.delegate = self
            window.setFrameAutosaveName("KHFleetWindow")
            window.center()
            // Quitting never leaves the ssh child behind: the tunnel dies with the app.
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.tunnel?.terminate()
            }
        }
        window.makeKeyAndOrderFront(nil)
        connect()
    }

    // MARK: Reaching the publisher

    struct Publisher { var feedHost: String; var ssh: String; var key: String?; var knownHosts: String }

    /// Where the fleet lives, read from this Mac's Launcher config; each part can be overridden with
    /// `defaults write com.khupdater.launcher fleetSSHHost|fleetSSHUser|fleetSSHKey <value>`.
    private func publisher() throws -> Publisher {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent("Library/KHUpdater/base/config.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = object["feedURL"] as? String, let host = URL(string: feed)?.host else {
            throw copyError("This Mac has no Launcher connection, so the publisher's address is unknown (\(config.path) has no feed address).")
        }
        let defaults = UserDefaults.standard
        // The full host name, exactly as the feed names it: `known_hosts` is written with that name
        // by every other tool, and a short name is a different entry that strict checking refuses.
        let sshHost = defaults.string(forKey: "fleetSSHHost") ?? host
        let user = defaults.string(forKey: "fleetSSHUser") ?? NSUserName()
        let standardKey = home.appendingPathComponent(".ssh/id_ed25519_gateway1301").path
        let key = defaults.string(forKey: "fleetSSHKey") ?? (FileManager.default.fileExists(atPath: standardKey) ? standardKey : nil)
        let knownHosts = defaults.string(forKey: "fleetSSHKnownHosts") ?? home.appendingPathComponent(".ssh/known_hosts").path
        return Publisher(feedHost: host, ssh: "\(user)@\(sshHost)", key: key, knownHosts: knownHosts)
    }

    private static func portAnswers(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Opens the tunnel, then loads the page once its port answers. Every failure ends on a page that
    /// names what was tried and why it failed, and tries again after a growing wait.
    func connect() {
        retryTimer?.invalidate()
        let old = tunnel; tunnel = nil; old?.terminate()
        let target: Publisher
        do { target = try publisher() } catch { return offline("The publisher's address is unknown", error.localizedDescription) }
        window.title = "Fleet · connecting"
        showStatus(title: "Connecting to the publisher", detail: "Reaching \(target.feedHost) through \(target.ssh)…", retry: false)
        let port = localPort
        DispatchQueue.global(qos: .userInitiated).async {
            old?.waitUntilExit()
            if Self.portAnswers(port) {
                return DispatchQueue.main.async {
                    self.offline("Port \(port) on this Mac is already in use",
                                 "Another program on this Mac answers on 127.0.0.1:\(port), so this window cannot tell it apart from the publisher on \(target.feedHost). Stop it, then choose Try again.")
                }
            }
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                                 "-o", "UserKnownHostsFile=\(target.knownHosts)", "-o", "ConnectTimeout=10",
                                 "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                                 "-L", "127.0.0.1:\(port):127.0.0.1:8790"] + (target.key.map { ["-i", $0] } ?? []) + [target.ssh, "cat >/dev/null"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { ended in
                let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? "the connection closed (exit \(ended.terminationStatus))"
                DispatchQueue.main.async {
                    guard self.tunnel === ended else { return }
                    self.tunnel = nil
                    if said.contains("host key") || said.contains("known_hosts") {
                        self.offline("This Mac has not been told to trust \(target.ssh)",
                                     "ssh refused the connection because no key for \(target.ssh) is on file: \(said). Trust it once by running ssh \(target.ssh) in Terminal and answering yes, then choose Try again. Strict checking stays on; an unknown key is never accepted quietly.")
                    } else {
                        self.offline("The publisher on \(target.feedHost) is not reachable",
                                     "The connection through \(target.ssh) ended: \(said). No fleet data is shown until it works again.")
                    }
                }
            }
            DispatchQueue.main.sync { self.tunnel = process }
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
                        self.window.title = "Fleet · \(target.feedHost)"
                        var page = URLComponents(string: "http://127.0.0.1:\(port)/")!
                        page.queryItems = [URLQueryItem(name: "app", value: self.version)]
                        self.web.load(URLRequest(url: page.url!))
                    }
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if process.isRunning { process.terminate() }
        }
    }

    private func offline(_ title: String, _ detail: String) {
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 600)
        window.title = "Fleet · not connected"
        showStatus(title: title, detail: detail + " Trying again in \(wait >= 60 ? "\(Int(wait / 60)) minute\(wait >= 120 ? "s" : "")" : "\(Int(wait)) seconds").", retry: true)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in self?.connect() }
    }

    /// The window's own page, in the publisher page's colours.
    private func showStatus(title: String, detail: String, retry: Bool) {
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let html = """
        <!doctype html><html><head><meta charset=utf-8><meta name=color-scheme content="light dark"><style>
        :root{--bg:#f5f6f5;--panel:#fff;--line:#e2e5e3;--text:#16201c;--sub:#5b6762;--accent:#1d6b51;--accent-ink:#fff}
        @media(prefers-color-scheme:dark){:root{--bg:#101513;--panel:#171e1b;--line:#29332f;--text:#e6ece9;--sub:#a9b5af;--accent:#3fa37f;--accent-ink:#06120d}}
        body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,system-ui,sans-serif}
        main{max-width:640px;margin:12vh auto 0;padding:32px;background:var(--panel);border:1px solid var(--line);border-radius:14px}
        h1{font-size:22px;margin:0 0 10px}p.detail{color:var(--sub);margin:0 0 20px;overflow-wrap:anywhere}
        button{font:inherit;padding:8px 14px;border-radius:7px;border:1px solid var(--line);background:var(--panel);color:var(--text);cursor:pointer}
        button.primary{background:var(--accent);color:var(--accent-ink);border-color:var(--accent)}
        button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
        </style></head><body><main><h1>\(h(title))</h1>\(detail.isEmpty ? "" : "<p class=detail>\(h(detail))</p>")
        <div>\(retry ? "<button class=primary id=retry>Try again</button>" : "")</div></main>
        <script>var r=document.getElementById('retry');if(r)r.onclick=function(){r.disabled=true;r.textContent='Trying…';webkit.messageHandlers.retry.postMessage(1)};</script></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

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

    private func pageFailed(_ error: Error) {
        let ns = error as NSError
        // A load the window replaced itself, or one its own response check already stopped, is not a failure.
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled), !(ns.domain == "WebKitErrorDomain" && ns.code == 102) else { return }
        let host = (try? publisher().feedHost) ?? "the publisher"
        offline("The publisher on \(host) did not answer", "The connection is up, but its status page did not load: \(ns.localizedDescription)")
    }

    func windowWillClose(_ notification: Notification) {
        retryTimer?.invalidate()
        tunnel?.terminate(); tunnel = nil
    }

    /// The page asks before Remove Mac, Update N Macs, Roll back and New code; a web view shows no
    /// confirm box of its own, and `window.confirm` is a silent no-op in a packaged webview.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "This acts on the live fleet on \(fleetHost ?? "the publisher"), not on a copy."
        alert.addButton(withTitle: ["Remove", "Update", "Roll back", "New code"].first { message.hasPrefix($0) } ?? "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    private var savingLauncher = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "retry" { if message.frameInfo.isMainFrame { connect() }; return }
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

    private func copyError(_ text: String) -> NSError { NSError(domain: "LauncherCopy", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    private func showCopyError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Launcher copy was not saved"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    private func launcherForSharing() throws -> URL {
        let fm = FileManager.default
        let locations = [URL(fileURLWithPath: "/Applications/Studio Launcher KH.app"),
                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Studio Launcher KH.app")]
        for app in locations {
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == LauncherBundle.bundleID else { continue }
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
        throw copyError("Install the signed Studio Launcher KH package with its connection kit first, then try again.")
    }

    // The page is this Mac's publisher; a donation link opens in the browser and nothing else may
    // navigate the window away.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "http", url.host == "127.0.0.1", url.port == 8790 { return decisionHandler(.allow) }
        if url.absoluteString == "about:blank" { return decisionHandler(.allow) }
        if url.scheme == "https", url.host == "nowpayments.io" || url.host == "www.nowpayments.io" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
