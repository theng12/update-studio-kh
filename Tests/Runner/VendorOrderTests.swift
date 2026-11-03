import Foundation

func vendorOrderTests() {
    let hosts = ["dl.google.com"]
    expect(URLSessionHTTPClient.officialURL(URL(string: "https://dl.google.com/file")!, hosts: hosts), "VO1 official HTTPS source accepted")
    for text in ["http://dl.google.com/file", "https://evil.example/file", "https://dl.google.com:444/file", "https://fixture-user@dl.google.com/file"] {
        expect(!URLSessionHTTPClient.officialURL(URL(string: text)!, hosts: hosts), "VO2 refuse unofficial URL \(text)")
    }
    var entry = VendorCatalog.builtIn.entries.first { $0.id == "chrome" }!
    entry.enabled = true
    let vendor = VendorOrder(entry: entry, kind: .dmg, byteCap: 1_000_000)
    expect((try? vendor.validate(app: "vendor-chrome")) != nil, "VO3 signed vendor payload is valid")
    expectThrows("VO4 payload must name the ordered app", contains: "vendor order") { try vendor.validate(app: "vendor-word") }
    var unpinned = vendor
    unpinned.entry.teamID = nil
    expectThrows("VO5 hash cannot replace required signature", contains: "vendor order") { try unpinned.validate(app: "vendor-chrome") }
    var disabled = vendor
    disabled.entry.enabled = false
    expectThrows("VO6 disabled vendor order refused", contains: "vendor order") { try disabled.validate(app: "vendor-chrome") }
    let rig = Rig("vendor-orders")
    let token = try! Enrolment.enrol(stateDir: rig.state, machine: "vendor-mac")
    let command = ServerCommand(machine: "vendor-mac", app: "vendor-chrome", action: ServerCommand.vendorInstall, vendor: vendor)
    var preferences = VendorPreferences()
    preferences.byteCap = vendor.byteCap
    try! AtomicFile.writeJSON(preferences, to: VendorPreferences.url(rig.state))
    try! StateStore.update(in: rig.state) { state in
        state.machines["vendor-mac"]?.vendorAssignments = ["chrome": true]
        state.machines["vendor-mac"]?.pending = [command,
            ServerCommand(machine: "vendor-mac", app: "demo", action: ServerCommand.rollback),
            ServerCommand(machine: "vendor-mac", app: "unknown", action: "future-action")]
    }
    func commands(_ caps: String?) -> CommandsReply {
        var query = ["machine": "vendor-mac"]
        if let caps { query["capabilities"] = caps }
        var request = HTTPRequest(method: "GET", path: "/commands", headers: ["authorization": "Bearer \(token)"])
        request.query = query
        let response = rig.server.handleRequest(request, remote: "100.64.0.9")
        let envelope = try! JSON.decode(SignedReply.self, from: response.data)
        expect(Signing.verify(envelope.replyData!, signature: envelope.signatureData!, publicKey: rig.pair.privateKey.publicKey), "VO7 vendor reply signature verifies")
        return try! JSON.decode(CommandsReply.self, from: envelope.replyData!)
    }
    expect(commands(nil).commands.isEmpty, "VO8 legacy client receives no vendor or rollback orders")
    expect(commands(AgentCapability.ownerRollback).commands.map(\.action) == [ServerCommand.rollback, "future-action"], "VO9 rollback-capable agents retain unknown-action refusal without receiving vendor installs")
    let capable = commands(AgentCapability.vendorInstall)
    expect(capable.commands == [command] && capable.commands.first?.vendor == vendor, "VO10 exact vendor pins and limit survive signed delivery")
    expect(try! StateStore.read(in: rig.state).machines["vendor-mac"]!.pending.count == 3, "VO11 withheld orders remain pending")
    var changedCatalog = VendorCatalog.builtIn
    changedCatalog.entries[changedCatalog.entries.firstIndex { $0.id == "chrome" }!].teamID = "NEWTEAM123"
    try! changedCatalog.save(to: VendorCatalog.url(in: rig.state.path))
    expect(commands(AgentCapability.vendorInstall).commands.isEmpty, "VO20 superseded vendor pins are withheld even if state refresh failed")
    try! VendorCatalog.builtIn.save(to: VendorCatalog.url(in: rig.state.path))
    func assign(_ fields: [String: String], remote: String = "127.0.0.1", origin: String = "http://127.0.0.1:8790") -> HTTPResponse {
        rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/vendor-assign",
            headers: ["host": "127.0.0.1:8790", "origin": origin], body: JSON.encode(fields, pretty: false)), remote: remote)
    }
    expect(assign(["app": "chrome", "mac-vendor-mac": "on", "on": "true"], remote: "100.64.0.9").status == 403, "VO12 remote assignment refused")
    expect(assign(["app": "chrome", "mac-vendor-mac": "on", "on": "true"], origin: "https://evil.example").status == 403, "VO13 cross-site assignment refused")
    expect(assign(["app": "chrome", "mac-vendor-mac": "on", "on": "true"]).status == 200, "VO14 explicit single Mac assignment succeeds")
    var saved = try! StateStore.read(in: rig.state).machines["vendor-mac"]!
    expect(saved.vendorAssignments?["chrome"] == true && saved.pending.filter { $0.action == ServerCommand.vendorInstall }.count == 1, "VO15 assignment queues one signed vendor order")
    expect(assign(["app": "chrome", "mac-vendor-mac": "on", "on": "false"]).status == 200, "VO16 turning off succeeds")
    saved = try! StateStore.read(in: rig.state).machines["vendor-mac"]!
    expect(saved.vendorAssignments?["chrome"] == false && !saved.pending.contains { $0.action == ServerCommand.vendorInstall }, "VO17 turning off cancels waiting installs")
    expect(saved.pending.contains { $0.action == ServerCommand.rollback }, "VO18 vendor choices preserve unrelated orders")
    expect(rig.server.statusHTML().contains("Other apps") && rig.server.statusHTML().contains("Download limit:"), "VO19 page displays optional apps and enforced limit")
}
