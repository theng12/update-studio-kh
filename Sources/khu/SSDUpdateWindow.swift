import AppKit

/// The SSD action stays usable before this Mac has a saved connection.
final class SSDUpdateWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let output = NSTextView()
    private let status = NSTextField(labelWithString: "Checking this Mac…")
    private let spinner = NSProgressIndicator()
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private var finished = false
    private var exitCode: Int32 = 1

    init(volume: URL, version: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Update installed apps — Studio Launcher KH \(version)"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        window.delegate = self
        let title = NSTextField(labelWithString: "Update installed apps")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let source = NSTextField(wrappingLabelWithString: "From \(volume.lastPathComponent). Checksums are checked before installation. Only apps already on this Mac and Studio Launcher are included.")
        source.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        output.isEditable = false
        output.isSelectable = true
        output.font = .systemFont(ofSize: 13)
        output.textContainerInset = NSSize(width: 12, height: 12)
        output.autoresizingMask = [.width]
        output.isHorizontallyResizable = false
        output.isVerticallyResizable = true
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        done.target = self
        done.action = #selector(close)
        done.keyEquivalent = "\r"
        done.isEnabled = false
        let bottom = NSStackView(views: [spinner, status, done])
        bottom.orientation = .horizontal
        bottom.spacing = 10
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, source, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.center()
    }

    func append(_ text: String) {
        let line = NSAttributedString(string: text + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        output.textStorage?.append(line)
        output.scrollToEndOfDocument(nil)
    }

    private func finish(error: Error?) {
        finished = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        done.isEnabled = true
        exitCode = error == nil ? 0 : 1
        if let error { append("Could not finish: \(error.localizedDescription)") }
        status.stringValue = error == nil ? "Finished — review each app’s result." : "Not finished — review the reason above."
    }

    @objc private func close() { if finished { exit(exitCode) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished { exit(exitCode) }
        status.stringValue = "An app is still being checked. Wait for its result."
        return false
    }

    static func run(volume: URL, version: String,
                    operation: @escaping (@escaping (String) -> Void) throws -> Void) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let view = SSDUpdateWindow(volume: volume, version: version)
        view.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try operation { line in DispatchQueue.main.async { view.append(line) } } }
            catch { failure = error }
            let result = failure
            DispatchQueue.main.async { view.finish(error: result) }
        }
        NSApp.run()
        exit(1)
    }
}
