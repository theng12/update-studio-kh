import AppKit

/// The connection window in its two forms: **Connect to Update Studio** for first run (the kit
/// supplies the address and pins the key; the person can edit the address and types this Mac's
/// name and pairing code), and **Pair
/// again** for explicit local recovery (the saved settings vouch for the address, the name and
/// key are fixed, only the code is typed). Either way the attempt runs on a background queue so
/// the window keeps painting — connecting, the publisher's own refusal, and success — with the
/// Cancel behaviour its state allows. One attempt at a time, never two.
final class ConnectionWindow: NSObject, NSWindowDelegate {
    enum Outcome { case connected, cancelled }

    private enum Mode {
        case firstRun(kit: URL, home: URL)
        case repair(configFile: URL, plan: Connect.RepairPlan)
    }

    private enum State { case idle, working, refused, done }

    private static let width: CGFloat = 500
    private static let inset: CGFloat = 24
    private static let inner: CGFloat = ConnectionWindow.width - 2 * ConnectionWindow.inset
    private static let caption: CGFloat = 140

    private let mode: Mode
    private let window: NSWindow
    private let destinationField = NSTextField()
    private let nameField = NSTextField()
    private let codeField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var state: State = .idle
    private var stopping = false
    private var ended = false
    private var outcome: Outcome = .cancelled

    private var repairFile: URL? {
        if case .repair(let file, _) = mode { return file }
        return nil
    }

    private init(mode: Mode) {
        self.mode = mode
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()

        let repair: Bool
        switch mode {
        case .firstRun: repair = false
        case .repair: repair = true
        }
        window.title = repair ? "Pair again with Update Studio" : "Connect to Update Studio"
        connectButton.title = repair ? "Pair again" : "Connect"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let intro: NSTextField
        let destination = destinationField
        switch mode {
        case .firstRun(let kit, _):
            intro = Self.wrap("Studio Launcher KH sets up this Mac from the kit inside this app. "
                + "Type the pairing code shown in Update Studio KH on the Mac Studio, under Connect a Mac.")
            // An edited address changes the route, never the kit's pinned publisher key.
            destination.stringValue = (try? Connect.publisher(kit: kit))?.feedURL ?? "unknown"
            destination.setAccessibilityLabel("Update Studio address")
            nameField.stringValue = Connect.proposedName()
        case .repair(_, let plan):
            intro = Self.wrap("Your current sign-in file will be preserved in ~/Library/KHUpdater/_trash, and this Mac "
                + "keeps its name, its apps and its pinned key. Type the pairing code shown in Update Studio KH "
                + "on the Mac Studio, under Connect a Mac. Nothing is sent until you press Pair again.")
            destination.stringValue = plan.feedURL
            destination.isEditable = false
            destination.isBezeled = false
            destination.drawsBackground = false
            nameField.stringValue = plan.machine
            nameField.isEnabled = false
        }
        destination.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        destination.isSelectable = true

        nameField.setAccessibilityLabel("Name for this Mac")
        codeField.placeholderString = "123-456"
        codeField.setAccessibilityLabel("Pairing code")

        let nameHint = Self.wrap(repair
            ? "This Mac keeps the name it is already enrolled under; it cannot be changed here."
            : "This Mac appears in Update Studio under this name.")
        nameHint.textColor = .secondaryLabelColor

        statusLabel.isHidden = true
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = Self.inner - 24

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        spinner.setAccessibilityLabel("Connecting")

        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        connectButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"

        let rows = NSStackView(views: [
            Self.row("Update Studio", destination),
            Self.row("Name for this Mac", nameField),
            Self.row("Pairing code", codeField),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, connectButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true

        let stack = NSStackView(views: [title, intro, rows, nameHint, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.setHuggingPriority(.init(250), for: .vertical)

        let content = NSView()
        window.contentView = content
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = codeField
    }

    /// First run: the kit's window, to completion — connected (the setup finished) or cancelled
    /// (the person left; a connect attempt still in flight is allowed to finish first, never
    /// killed mid-run).
    static func run(kit: URL, home: URL) -> Outcome {
        present(ConnectionWindow(mode: .firstRun(kit: kit, home: home)))
    }

    /// Pair again: only after the plain confirmation — the old sign-in is preserved, a pairing
    /// code is required, and Cancel here sends nothing and writes nothing.
    static func runRepair(configFile: URL) -> Outcome {
        let confirm = NSAlert()
        confirm.messageText = "Pair again with Update Studio?"
        confirm.informativeText = "Your current sign-in file will be preserved in ~/Library/KHUpdater/_trash, and this Mac "
            + "keeps its name, its apps and its pinned key. A pairing code from Update Studio is required, and "
            + "nothing is sent unless you continue."
        confirm.addButton(withTitle: "Continue")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return .cancelled }
        let plan: Connect.RepairPlan
        do { plan = try Connect.repairPlan(configFile: configFile) }
        catch {
            let a = NSAlert()
            a.messageText = "There is nothing to pair again"
            a.informativeText = "\(error)"
            a.runModal()
            return .cancelled
        }
        return present(ConnectionWindow(mode: .repair(configFile: configFile, plan: plan)))
    }

    private static func present(_ controller: ConnectionWindow) -> Outcome {
        NSApp.activate(ignoringOtherApps: true)
        controller.window.level = .normal
        if let screen = controller.window.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            controller.window.setFrameOrigin(NSPoint(x: frame.midX - controller.window.frame.width / 2,
                                                     y: frame.midY - controller.window.frame.height / 2))
        }
        controller.window.makeKeyAndOrderFront(nil)
        controller.window.initialFirstResponder = controller.codeField
        // Keep all windows usable while the existing synchronous caller waits for this result.
        while !controller.ended {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.1),
                                          inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
        controller.window.orderOut(nil)
        return controller.outcome
    }

    // MARK: states

    private func show(_ text: String, color: NSColor?, spinning: Bool) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        statusLabel.textColor = color ?? .secondaryLabelColor
        if spinning { spinner.startAnimation(nil); spinner.isHidden = false }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    @objc private func connectPressed() {
        if state == .done { finish(.connected); return }
        guard state != .working else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { show("Type the pairing code from Update Studio.", color: .systemRed, spinning: false); return }
        let machine: String
        switch mode {
        case .firstRun:
            machine = nameField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            guard !machine.isEmpty else { show("Type the name for this Mac.", color: .systemRed, spinning: false); return }
        case .repair(_, let plan):
            machine = plan.machine
        }
        let destination = destinationField.stringValue
        if case .firstRun = mode {
            do { _ = try Connect.destination(destination) }
            catch { show("\(error)", color: .systemRed, spinning: false); return }
        }
        state = .working
        stopping = false
        destinationField.isEnabled = false
        nameField.isEnabled = false
        codeField.isEnabled = false
        connectButton.isEnabled = false
        cancelButton.isEnabled = true
        cancelButton.title = "Cancel"
        show("Connecting to Update Studio…", color: nil, spinning: true)
        let mode = self.mode
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                switch mode {
                case .firstRun(let kit, let home):
                    _ = try Connect.run(kit: kit, home: home, machine: machine, code: code, destination: destination)
                case .repair(let file, _):
                    // Confirmed only here because Pair again's confirmation was already accepted
                    // before this window could open (runRepair); Cancel sends nothing at all.
                    _ = try Connect.repair(configFile: file, code: code, confirmed: true)
                }
            }
            catch { failure = "\(error)" }
            DispatchQueue.main.async { self.finished(success: failure == nil, failure: failure) }
        }
    }

    private func finished(success: Bool, failure: String?) {
        guard state == .working else { return }
        if stopping { finish(.cancelled); return }
        destinationField.isEnabled = true
        if case .firstRun = mode { nameField.isEnabled = true }
        codeField.isEnabled = true
        connectButton.isEnabled = true
        cancelButton.isEnabled = true
        if success {
            state = .done
            connectButton.title = "Continue"
            if case .repair = mode {
                show("Paired. This Mac's sign-in is renewed — the next update check uses it.",
                     color: .systemGreen, spinning: false)
            } else {
                show("Connected. Studio Launcher KH is set up on this Mac.", color: .systemGreen, spinning: false)
            }
        } else {
            state = .refused
            codeField.stringValue = ""
            if case .repair = mode {
                connectButton.title = "Pair again"
                show("Not paired: \(failure ?? "the pairing was refused")", color: .systemRed, spinning: false)
            } else {
                connectButton.title = "Connect"
                show("Not connected: \(failure ?? "the connection was refused")", color: .systemRed, spinning: false)
            }
            window.initialFirstResponder = codeField
        }
    }

    @objc private func cancelPressed() {
        if state == .working {
            // The attempt in flight is left to finish — stopping it mid-enrolment could strand a
            // claim at the publisher — and the window closes the moment it does, either way.
            stopping = true
            cancelButton.isEnabled = false
            show("Stopping when this attempt finishes…", color: nil, spinning: true)
            return
        }
        if state == .done { finish(.connected); return }
        finish(.cancelled)
    }

    private func finish(_ result: Outcome) {
        guard !ended else { return }
        ended = true
        outcome = result
        window.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if state == .working {
            stopping = true
            return   // ends the run when the attempt finishes (finish is called there)
        }
        finish(state == .done ? .connected : .cancelled)
    }

    // MARK: layout helpers

    private static func wrap(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = inner
        label.widthAnchor.constraint(equalToConstant: inner).isActive = true
        return label
    }

    private static func row(_ caption: String, _ field: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: caption)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: Self.caption).isActive = true
        field.widthAnchor.constraint(equalToConstant: Self.inner - Self.caption - 12).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }
}
