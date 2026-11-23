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
        /// A saved setup whose helper files or start file are incomplete: no code, no enrolment.
        case setupRepair(kit: URL, home: URL, plan: Connect.RepairPlan, reason: String)
    }

    private enum State { case idle, working, refused, done }

    /// The public mirror: signed by this fleet's pinned key, no publisher on the other end.
    static let publicFeedURL = Connect.publicFeedURL

    private static let width: CGFloat = 500
    private static let inset: CGFloat = 24
    private static let inner: CGFloat = ConnectionWindow.width - 2 * ConnectionWindow.inset
    private static let caption: CGFloat = 140

    private let mode: Mode
    private let window: NSWindow
    private let destinationField = NSTextField()
    private let nameField = NSTextField()
    private let codeField = NSTextField()
    private var codeRow: NSStackView?
    /// The kit's own address, or "" for a copy built for public download.
    private let kitAddress: String
    /// The saved address is one macOS refuses (a bare IP over plain http): repair alone can never work.
    private let savedAddressRefused: Bool
    private var savedAddress: String {
        switch mode {
        case .repair(_, let plan): return plan.feedURL
        case .setupRepair(_, _, let plan, _): return plan.feedURL
        case .firstRun: return ""
        }
    }
    /// What the window says, kept so a headless test can read it.
    private var introText = ""
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

    /// Where typing starts: the code, or the one button a repair — and a first run — has. A first
    /// run has no address to type and asks for no code until a publisher's own refusal names one.
    private var initialField: NSView {
        if case .repair = mode { return codeField }
        return connectButton
    }

    private init(mode: Mode) {
        self.mode = mode
        kitAddress = {
            guard case .firstRun(let kit, _) = mode, let pub = try? Connect.publisher(kit: kit) else { return "" }
            return pub.feedURL ?? ""
        }()
        // A saved address macOS refuses on sight is why "Repair" could never succeed: the window
        // offers the one action that can end, instead of a dead button.
        switch mode {
        case .firstRun: savedAddressRefused = false
        case .repair(_, let plan): savedAddressRefused = FeedNetwork.isUnusable(plan.feedURL)
        case .setupRepair(_, _, let plan, _): savedAddressRefused = FeedNetwork.isUnusable(plan.feedURL)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()

        let repair: Bool
        let setupRepair: Bool
        switch mode {
        case .firstRun: repair = false; setupRepair = false
        case .repair: repair = true; setupRepair = false
        case .setupRepair: repair = false; setupRepair = true
        }
        window.title = setupRepair ? "Repair this Mac's setup" : repair ? "Pair again with Update Studio" : "Connect to Update Studio"
        connectButton.title = savedAddressRefused ? "Use the saved feed instead"
            : setupRepair ? "Repair" : repair ? "Pair again" : "Connect"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: window.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let intro: NSTextField
        let destination = destinationField
        switch mode {
        case .firstRun:
            // One source, and this copy already knows it: a copy shared from a Studio carries that
            // Studio's address, and a copy downloaded for anyone carries the public signed feed.
            // Nothing here asks a person to choose, type an address or find a code up front.
            intro = Self.wrap(kitAddress.isEmpty
                ? "This Mac installs updates from its signed release feed. Nothing here is reported anywhere and no address or code is needed. Press Connect to set this Mac up."
                : "This Mac takes its updates from the Studio at \(URL(string: kitAddress)?.host ?? kitAddress). Press Connect. If that Studio asks for a pairing code, this window asks for it after the first try.")
            destination.setAccessibilityLabel("Updates come from")
            destination.stringValue = kitAddress.isEmpty ? Self.publicFeedURL : kitAddress
            destination.isEditable = false
            destination.isBezeled = false
            destination.drawsBackground = false
            nameField.stringValue = Connect.proposedName()
        case .repair(_, let plan):
            intro = Self.wrap("Your current sign-in file will be preserved in ~/Library/KHUpdater/_trash, and this Mac "
                + "keeps its name, its apps and its pinned key. Type the pairing code shown in Update Studio KH "
                + "on the controller Mac, under Connect a Mac. This Mac is already enrolled, so an allow-a-Mac "
                + "window on that Mac does not apply to it: the code is what reclaims its name. "
                + "Nothing is sent until you press Pair again.")
            destination.stringValue = plan.feedURL
            destination.isEditable = false
            destination.isBezeled = false
            destination.drawsBackground = false
            nameField.stringValue = plan.machine
            nameField.isEnabled = false
        case .setupRepair(_, _, let plan, let reason):
            intro = Self.wrap("The saved connection is kept exactly as it is: this Mac's name, address, pinned key, apps, "
                + "settings and pauses. The incomplete helper files and start file are rebuilt from this app's verified "
                + "setup kit. This does not pair again or enrol this Mac.\n\nStartup said: \(reason)")
            destination.stringValue = plan.feedURL
            destination.isEditable = false
            destination.isBezeled = false
            destination.drawsBackground = false
            nameField.stringValue = plan.machine
            nameField.isEnabled = false
        }
        if savedAddressRefused {
            // The exact state the owner photographed: address locked, Repair alone can never work.
            // Name the cause, then give the one press that ends it.
            intro.stringValue += "\n\nThe saved address \(savedAddress) is a bare IP, which macOS refuses for an "
                + "unencrypted feed, so Repair cannot succeed. Use the saved feed instead moves this Mac to the "
                + "public feed and then repairs it from this app's own setup kit. Your apps, settings and pinned "
                + "key are kept; nothing is reported anywhere."
        }
        introText = intro.stringValue
        destination.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        destination.isSelectable = true

        nameField.setAccessibilityLabel("Name for this Mac")
        codeField.placeholderString = "123-456"
        codeField.setAccessibilityLabel("Pairing code")

        let nameHint = Self.wrap(setupRepair || repair
            ? "This Mac keeps the name it is already enrolled under; it cannot be changed here."
            : kitAddress.isEmpty ? "The name this Mac is known by." : "This Mac appears in the Studio under this name.")
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

        codeRow = setupRepair ? nil : Self.row("Pairing code", codeField)
        var rowViews: [NSView] = []
        rowViews.append(Self.row("Updates from", destination))
        rowViews.append(Self.row("Name for this Mac", nameField))
        if let codeRow { rowViews.append(codeRow) }
        // A first run asks for no code until a Studio refuses without one; the row is built now and
        // revealed in the refusal, so the window never opens with a question a person cannot answer.
        if case .firstRun = mode { codeRow?.isHidden = true }
        let rows = NSStackView(views: rowViews)
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

        var stackViews: [NSView] = [title, intro, rows]
        stackViews += [nameHint, statusRow, buttons]
        let stack = NSStackView(views: stackViews)
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
        if case .firstRun = mode { window.initialFirstResponder = connectButton }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.initialFirstResponder = initialField
    }

    // MARK: where updates come from

    /// The one rule a first run follows: a copy shared from a Studio carries that Studio's address;
    /// every other copy carries none and reads the public signed feed. The address is never typed, so
    /// there is no source to choose and nothing to route. `Connect.destination` still refuses an
    /// address macOS cannot reach.
    private var firstRunIsPublic: Bool { kitAddress.isEmpty }

    /// First run: the kit's window, to completion — connected (the setup finished) or cancelled
    /// (the person left; a connect attempt still in flight is allowed to finish first, never
    /// killed mid-run).
    static func run(kit: URL, home: URL) -> Outcome {
        present(ConnectionWindow(mode: .firstRun(kit: kit, home: home)))
    }

    /// Pair again: only after the plain confirmation — the old sign-in is preserved, a pairing
    /// code or the publisher's open allow-a-Mac window is required, and Cancel here sends nothing
    /// and writes nothing.
    static func runRepair(configFile: URL) -> Outcome {
        let confirm = NSAlert()
        confirm.messageText = "Pair again with Update Studio?"
        confirm.informativeText = "Your current sign-in file will be preserved in ~/Library/KHUpdater/_trash, and this Mac "
            + "keeps its name, its apps and its pinned key. A pairing code from Update Studio is required — an open "
            + "allow-a-Mac window only helps when the publisher does not already list this Mac — and nothing is sent "
            + "unless you continue."
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

    /// Repair this Mac's saved setup, without a code: only after the plain confirmation. The
    /// saved connection is never rewritten; a kit for another publisher is refused before the
    /// window opens, and Cancel repairs nothing.
    static func runSetupRepair(kit: URL, home: URL, reason: String) -> Outcome {
        NSApp.activate(ignoringOtherApps: true)
        let configFile = Connect.configFile(stateDir: home.appendingPathComponent("Library/KHUpdater/state"))
        let plan: Connect.RepairPlan
        do {
            plan = try Connect.repairPlan(configFile: configFile)
            guard try Connect.publisher(kit: kit).publicKey == plan.publicKey else {
                throw khuFail("This Launcher's setup kit belongs to a different Update Studio. "
                    + "Open the Studio Launcher KH copy this Mac was set up with; its saved trust was kept.")
            }
        } catch {
            let a = NSAlert()
            a.messageText = "This Mac's setup cannot be repaired from this copy"
            a.informativeText = "\(error)"
            a.runModal()
            return .cancelled
        }
        let confirm = NSAlert()
        confirm.messageText = "Repair this Mac's setup?"
        confirm.informativeText = "The saved connection is kept exactly as it is: this Mac's name, address, pinned key, "
            + "apps, settings and pauses. The incomplete helper files and start file are rebuilt from this app's "
            + "verified setup kit. This does not pair again or enrol this Mac.\n\nStartup said: \(reason)"
        confirm.addButton(withTitle: "Repair")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return .cancelled }
        return present(ConnectionWindow(mode: .setupRepair(kit: kit, home: home, plan: plan, reason: reason)))
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
        controller.window.initialFirstResponder = controller.initialField
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
        let destination = destinationField.stringValue
        var publicFeed = false
        if case .firstRun = mode { publicFeed = firstRunIsPublic }
        let machine: String
        var code = ""
        switch mode {
        case .setupRepair(_, _, let plan, _):
            machine = plan.machine
        case .firstRun:
            machine = nameField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            guard !machine.isEmpty else { show("Type the name for this Mac.", color: .systemRed, spinning: false); return }
            // A public feed asks for no pairing code: there is no publisher to enrol with. A Studio
            // copy sends an empty code first — its owner may have the enrolment window open — and a
            // refusal is what reveals the code row and asks for it.
            code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        case .repair(_, let plan):
            // Empty is allowed: it works only when the publisher no longer lists this Mac and its
            // allow-a-Mac window is open; an enrolled Mac is refused with the publisher's own
            // sentence, which names the pairing code.
            code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
            machine = plan.machine
        }
        state = .working
        stopping = false
        destinationField.isEnabled = false
        nameField.isEnabled = false
        codeField.isEnabled = false
        connectButton.isEnabled = false
        cancelButton.isEnabled = true
        cancelButton.title = "Cancel"
        if case .setupRepair = mode {
            show("Repairing this Mac's saved setup…", color: nil, spinning: true)
        } else {
            show(publicFeed ? "Reading the public feed…" : "Connecting to Update Studio…", color: nil, spinning: true)
        }
        let mode = self.mode
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                switch mode {
                case .firstRun(let kit, let home) where publicFeed:
                    _ = try Connect.usePublicFeed(kit: kit, home: home, machine: machine, address: destination)
                case .firstRun(let kit, let home):
                    _ = try Connect.run(kit: kit, home: home, machine: machine, code: code, destination: destination)
                case .repair(let file, _):
                    // A saved address macOS refuses can never pair: the one press that ends it moves
                    // this Mac to the public feed, and nothing is sent to any publisher.
                    if self.savedAddressRefused {
                        _ = try Connect.switchToPublicFeed(file: file)
                        break
                    }
                    // Confirmed only here because Pair again's confirmation was already accepted
                    // before this window could open (runRepair); Cancel sends nothing at all.
                    _ = try Connect.repair(configFile: file, code: code, confirmed: true)
                case .setupRepair(let kit, let home, _, _):
                    // The saved address is unusable, so the repair starts by moving to the public
                    // feed; the kit then rebuilds the helper files against it.
                    if self.savedAddressRefused {
                        let file = Connect.configFile(stateDir: home.appendingPathComponent("Library/KHUpdater/state"))
                        _ = try Connect.switchToPublicFeed(file: file)
                    }
                    // Paused, already newer or any other status is not a repair; its own reason is
                    // shown honestly rather than as a green success.
                    let repaired = try Connect.repairSetup(kit: kit, home: home)
                    guard repaired.status == "repaired" else {
                        throw khuFail(repaired.reason ?? "The helper was not repaired (\(repaired.status)). Your saved connection and settings are kept.")
                    }
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
            if savedAddressRefused {
                // The dead end the owner photographed now ends here, in one press.
                show("Repaired. This Mac now updates from the saved feed and reports to nobody; its apps, "
                    + "settings and pinned key were kept.", color: .systemGreen, spinning: false)
            } else if case .repair = mode {
                show("Paired. This Mac's sign-in is renewed — the next update check uses it.",
                     color: .systemGreen, spinning: false)
            } else if case .setupRepair = mode {
                show("Repaired. The saved connection was kept and its helper was rebuilt.", color: .systemGreen, spinning: false)
            } else {
                // First run: the press that set the Mac up is the only press. The window says what
                // happened, then closes itself into the app, so there is no second "Continue".
                show("Connected. Studio Launcher KH is set up on this Mac.", color: .systemGreen, spinning: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.state == .done else { return }
                    self.finish(.connected)
                }
            }
        } else {
            state = .refused
            codeField.stringValue = ""
            if savedAddressRefused {
                connectButton.title = "Use the saved feed instead"
                show("Not repaired: \(failure ?? "the public feed could not be read")", color: .systemRed, spinning: false)
            } else if case .repair = mode {
                connectButton.title = "Pair again"
                show("Not paired: \(failure ?? "the pairing was refused")", color: .systemRed, spinning: false)
            } else if case .setupRepair = mode {
                connectButton.title = "Repair"
                show("Not repaired: \(failure ?? "the saved setup could not be repaired")", color: .systemRed, spinning: false)
            } else if case .firstRun = mode {
                // One sentence naming what was attempted and what failed, then Retry. A Studio that
                // refuses without a code is the one case that needs a second field, and the publisher's
                // own sentence says so.
                connectButton.title = "Retry"
                if !firstRunIsPublic { codeRow?.isHidden = false; codeField.isHidden = false }
                show("Not connected: \(failure ?? "the connection was refused") Retry when the connection is back.",
                     color: .systemRed, spinning: false)
                window.setContentSize(window.contentView?.fittingSize ?? window.contentView?.frame.size ?? .zero)
            } else {
                connectButton.title = "Connect"
                show("Not connected: \(failure ?? "the connection was refused")", color: .systemRed, spinning: false)
            }
            window.makeFirstResponder(initialField)
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

    #if KHU_TESTS
    /// Test-only: build the first-run window without presenting it, so a headless test can read
    /// the three states the picker builds. Nothing here is compiled into a shipped app.
    static func testFirstRun(kit: URL, home: URL) -> ConnectionWindow {
        ConnectionWindow(mode: .firstRun(kit: kit, home: home))
    }
    /// Test-only: build the setup-repair window without presenting it, so a headless test can read
    /// the photographed dead end and the action that now ends it.
    static func testSetupRepair(kit: URL, home: URL, reason: String) throws -> ConnectionWindow {
        let plan = try Connect.repairPlan(configFile: Connect.configFile(stateDir: home.appendingPathComponent("Library/KHUpdater/state")))
        return ConnectionWindow(mode: .setupRepair(kit: kit, home: home, plan: plan, reason: reason))
    }
    var testPrimaryTitle: String { connectButton.title }
    var testIntro: String { introText }
    /// Test-only: take the failure branch the real attempt takes when it comes back refused — no
    /// network, no window, so a test proves what the window does next rather than what it hopes.
    func testFail(_ reason: String) { state = .working; stopping = false; finished(success: false, failure: reason) }
    var testState: (address: String, editable: Bool, codeVisible: Bool, name: String,
                    primary: String, intro: String, status: String) {
        (destinationField.stringValue, destinationField.isEditable, !(codeRow?.isHidden ?? true),
         nameField.stringValue, connectButton.title, introText, statusLabel.stringValue)
    }
    #endif

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
