// KH Updater.app: a window onto the publisher's own status page. Nothing else.
import AppKit
import WebKit

final class Delegate: NSObject, NSApplicationDelegate, WKUIDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit KH Updater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu

        let web = WKWebView()
        web.uiDelegate = self
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:8790/")!))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KH Updater"
        window.contentView = web
        window.minSize = NSSize(width: 420, height: 400)
        window.center()
        window.setFrameAutosaveName("KHUpdaterMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The page asks before Remove Mac, Update N Macs and Roll back; a web view shows no confirm box unless the app does.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        // The button says what the page is asking for: Remove, Update or Roll back.
        alert.addButton(withTitle: ["Remove", "Update", "Roll back"].first { message.hasPrefix($0) } ?? "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
