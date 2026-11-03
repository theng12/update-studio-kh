import Foundation

func vendorPublisherTests() {
    let rig = Rig("vendor-publisher")
    _ = try! Enrolment.enrol(stateDir: rig.state, machine: "mac-a")
    _ = try! Enrolment.enrol(stateDir: rig.state, machine: "mac-b")
    func post(_ route: String, _ fields: [String: String], form: Bool = false) -> HTTPResponse {
        var headers = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790"]
        let body: Data
        if form {
            headers["content-type"] = "application/x-www-form-urlencoded"
            var parts = URLComponents()
            parts.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            body = Data(parts.percentEncodedQuery!.utf8)
        } else { body = JSON.encode(fields, pretty: false) }
        return rig.server.handleRequest(HTTPRequest(method: "POST", path: route, headers: headers, body: body), remote: "127.0.0.1")
    }
    let bulk = ["app": "chrome", "mac-mac-a": "on", "mac-mac-b": "on", "on": "true"]
    expect(post("/api/vendor-assign", bulk).status == 400, "VP1 bulk requires explicit confirmation")
    expect(try! StateStore.read(in: rig.state).machines.values.allSatisfy { $0.pending.isEmpty && $0.vendorAssignments == nil }, "VP2 refused bulk leaves all Macs untouched")
    var confirmed = bulk; confirmed["confirmed"] = "true"
    let assigned = post("/api/vendor-assign", confirmed, form: true)
    expect(assigned.status == 303 && assigned.headers["Location"] == "/#apps", "VP3 real form bulk queues and redirects to apps")
    let before = try! StateStore.read(in: rig.state)
    let oldOrder = before.machines["mac-a"]!.pending[0]
    expect(before.machines.values.allSatisfy { $0.vendorAssignments?["chrome"] == true && $0.pending.count == 1 }, "VP4 confirmed bulk assigns each selected Mac once")
    expect(rig.server.statusHTML().contains("name=\"mac-mac-a\" checked"), "VP5 assignments are shown as checked")
    var edited = ["app": "chrome", "source": "https://dl.google.com/new-chrome.dmg", "sourceKind": "direct",
        "sourceMatch": "", "hosts": "dl.google.com", "team": "NEWTEAM123", "bundle": "com.google.Chrome",
        "evidence": "fixture vendor evidence", "byteCap": "2000000"]
    expect(post("/api/vendor-edit", edited).status == 200, "VP6 source and identity edit succeeds")
    let after = try! StateStore.read(in: rig.state)
    expect(after.machines.values.allSatisfy { mac in
        let order = mac.pending.first!
        return order.vendor?.entry.teamID == "NEWTEAM123" && order.vendor?.entry.sourceURL == edited["source"]
            && order.vendor?.byteCap == 2_000_000 && order.vendor?.entry.enabled == true
            && order.id != oldOrder.id && mac.tokenHash == before.machines[mac.machine]?.tokenHash
    }, "VP7 waiting orders use edited identity/source/limit and keep enrolment")
    edited["sourceKind"] = "pageLink"
    expect(post("/api/vendor-edit", edited).status == 400, "VP8 page source needs a link match")
    edited["sourceMatch"] = ".dmg"
    expect(post("/api/vendor-edit", edited).status == 200, "VP9 editor can switch to a vendor page source")
    expect(try! VendorCatalog.load(from: VendorCatalog.url(in: rig.state.path)).entries.first { $0.id == "chrome" }?.sourceKind == .pageLink, "VP10 source type is persisted")
    expect(post("/api/vendor-retire", ["app": "chrome"]).status == 200, "VP11 retirement succeeds")
    let retired = try! StateStore.read(in: rig.state)
    expect(retired.machines.values.allSatisfy { $0.pending.isEmpty && $0.vendorAssignments?["chrome"] == false }, "VP12 retirement cancels waiting installs and turns assignments off")
    expect(post("/api/vendor-assign", confirmed).status == 409, "VP13 retired app cannot be assigned")
    expect(post("/api/vendor-restore", ["app": "chrome"]).status == 200, "VP14 retired app can be restored")
    expect(try! StateStore.read(in: rig.state).machines.values.allSatisfy { $0.pending.isEmpty && $0.vendorAssignments?["chrome"] == false }, "VP15 restore does not reactivate assignments")
    let restored = try! VendorCatalog.load(from: VendorCatalog.url(in: rig.state.path)).entries.first { $0.id == "chrome" }!
    expect(restored.teamID == "NEWTEAM123" && restored.sourceURL == edited["source"], "VP16 retirement preserves edited catalog")
    var unpinned = try! VendorCatalog.load(from: VendorCatalog.url(in: rig.state.path))
    unpinned.entries[0].teamID = nil
    try! unpinned.save(to: VendorCatalog.url(in: rig.state.path))
    expect(post("/api/vendor-assign", ["app": unpinned.entries[0].id, "mac-mac-a": "on", "on": "true"]).status == 400, "VP17 invalid catalog assignment reports an owner input error")
    expect(rig.server.statusHTML().contains("Download limit in bytes (for all other apps)"), "VP18 shared limit scope is shown")
    expect(rig.server.statusHTML().contains("<details class=notes><summary>Choose Macs</summary>"), "VP19 open assignment editor uses the existing timed-refresh pause so selections survive")
}

func vendorExecutionTests() {
    func run(_ tag: String, obstructReceipt: Bool) {
        let rig = VendorRig(tag)
        var entry = rig.entry(id: "chrome")
        entry.enabled = true
        let command = ServerCommand(machine: "fixture", app: "vendor-chrome", action: ServerCommand.vendorInstall,
            vendor: VendorOrder(entry: entry, kind: .dmg, byteCap: 1 << 20))
        var config = AgentConfig(feedURL: "http://publisher.test/release.json", publicKey: "fixture", stateDir: rig.state.path,
            machine: "fixture", token: "fixture")
        config.apps[command.app] = AppConfig(bundlePath: rig.installed.path, bundleID: entry.bundleID)
        if obstructReceipt { try! Data("fixture obstruction".utf8).write(to: rig.state.appendingPathComponent("vendor-receipts")) }
        let outcome = try! Agent.installVendor(command, config: config, stateDir: rig.state, http: VendorHTTP(), shell: rig.shell,
                                              control: { _, _ in rig.control })
        expect(outcome.status == "installed" && marker(rig.installed) == "1.2.3", "VE1 actual install outcome survives receipt state")
        if obstructReceipt {
            expect(outcome.reason?.contains("receipt could not be saved") == true, "VE2 receipt-save failure is loud without claiming install failure")
        } else {
            let rows = Agent.vendorRows(stateDir: rig.state)
            expect(rows.count == 1 && rows[0].installed == "1.2.3" && rows[0].app == "vendor-chrome", "VE3 native receipt row reads the actual matching bundle")
        }
    }
    run("vendor-execution-receipt", obstructReceipt: false)
    run("vendor-execution-receipt-failed", obstructReceipt: true)
    do {
        let rig = VendorRig("vendor-interrupted-recovery")
        let entry = rig.entry(id: "chrome")
        let command = ServerCommand(machine: "fixture", app: "vendor-chrome", action: ServerCommand.vendorInstall,
            vendor: VendorOrder(entry: entry, kind: .dmg, byteCap: 1 << 20))
        var config = AgentConfig(feedURL: "http://publisher.test/release.json", publicKey: "fixture", stateDir: rig.state.path,
            machine: "fixture", token: "fixture")
        config.apps[command.app] = AppConfig(bundlePath: rig.installed.path, bundleID: entry.bundleID)
        _ = try! Agent.installVendor(command, config: config, stateDir: rig.state, http: VendorHTTP(), shell: rig.shell,
                                     control: { _, _ in rig.control })
        let registered = try? AtomicFile.readJSON([String: AppConfig].self, from: rig.state.appendingPathComponent("vendor-apps.json"))
        expect(registered?[command.app]?.bundlePath == rig.installed.path, "VE4 vendor recovery destination is durable before a swap")
        let staged = rig.apps.appendingPathComponent(".Foo.app.khu-staging")
        try! fm.moveItem(at: rig.installed, to: staged)
        let rollback = rig.state.appendingPathComponent("rollback-vendor-chrome/Foo.app")
        if !fm.fileExists(atPath: rollback.path) { makeApp(rollback, version: "1.0.0") }
        let journal = InstallJournal(phase: "promoting", installed: rig.installed.path, staged: staged.path,
            rollback: rollback.path, previousVersion: "1.0.0", wasRunning: true, version: "1.2.3")
        try! AtomicFile.writeJSON(journal, to: Recipe.journalURL(stateDir: rig.state.path, app: command.app))
        config.apps = [:]
        let publisher = Rig("vendor-recovery-publisher")
        try! publisher.publish("demo", "1.0", publisher.artifact("demo.zip", "fixture"))
        config.publicKey = publisher.pair.publicKeyBase64
        config.token = try! Enrolment.enrol(stateDir: publisher.state, machine: config.machine)
        let recovered = try! Agent.runOnce(config: config, http: InProcessClient(server: publisher.server), shell: rig.shell,
                                           control: { _, _ in rig.control })
        expect(marker(rig.installed) == "1.0.0" && !Recipe.isUnresolved(stateDir: rig.state.path, app: command.app),
               "VE5 next agent run restores an interrupted vendor swap without any fresh order or config entry")
        let row = recovered.apps.first { $0.app == command.app }
        expect(row?.source == "Official vendor" && row?.setupFolder != nil && row?.installed == "1.0.0",
               "VE6 recovered vendor registration preserves the native receipt and setup-folder handoff")
    }
}
