import AppKit

/// Native responder actions work in both setup fields and the Launcher's web view.
enum LauncherMenus {
    static func install() {
        guard NSApp.mainMenu == nil else { return }
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "Studio Launcher KH")
        application.addItem(NSMenuItem(title: "Hide Studio Launcher KH", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Quit Studio Launcher KH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = application
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                       ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key.lowercased())
            item.keyEquivalentModifierMask = key == "Z" ? [.command, .shift] : [.command]
            edit.addItem(item)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
