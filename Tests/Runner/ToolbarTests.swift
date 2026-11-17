import Foundation
import Darwin

func toolbarTests() {
    let rig = Rig("toolbar")
    try! rig.publish("demo", "2.0", rig.artifact("demo.zip", "demo"))
    let token = try! Enrolment.enrol(stateDir: rig.state, machine: "fixture-mac")
    _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"],
        body: Data(#"{"machine":"fixture-mac","installed":{"demo":"1.0"},"automatic_default":{"demo":false}}"#.utf8)), remote: "100.64.0.9")
    try! StateStore.update(in: rig.state) { state in
        state.machines["fixture-mac"]?.pending.append(ServerCommand(machine: "fixture-mac", app: "demo", action: ServerCommand.update))
    }
    let before = try! Data(contentsOf: rig.state.appendingPathComponent("state.json"))
    let server = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 8790,
                            commandKey: rig.pair.privateKey, publisherBind: "100.64.0.9")
    let response = server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1:8790"]), remote: "127.0.0.1")
    let page = String(decoding: response.data, as: UTF8.self)
    expect(page.contains("Awaiting update result") && page.contains("Update requested") && !page.contains(">Updating</span>"),
           "T1 pending orders say requested, never claim an install is running")
    expect(page.contains("<span class=\"n warn\">1</span><span>Needs update") && page.contains("1 Mac awaiting results"),
           "T2 requests awaiting results are included in Needs update instead of disappearing from counts")
    expect(page.contains("data-f=update aria-pressed=false>Needs update <span class=num>1</span>"),
           "T3 Needs update filter includes pending requests")
    expect(page.contains("id=refresh>Refresh</button>") && page.contains("aria-live=polite"), "T4 Refresh has a visible control and status feedback")
    expect(!page.contains("~/Desktop") && page.contains("Studio Launcher KH → Connect to Update Studio") && page.contains("100.64.0.9:8790"),
           "T5 Connect names the actual app and publisher without exposing a local Desktop path")
    expect(try! Data(contentsOf: rig.state.appendingPathComponent("state.json")) == before, "T6 fetching the latest page preserves all fleet state")
    expect(page.contains("Connection ID</dt><dd><code>fixture-mac</code>") && page.contains("Name last reported by this Mac") && page.contains("does not report its source separately") && !page.contains("The macOS computer name is not reported separately."),
           "T8 Mac details distinguish fixed connection identity from reported name and missing independent probes")
    try! StateStore.update(in: rig.state) { state in state.machines["fixture-mac"]?.installed["demo"] = "2.0" }
    expect(server.statusHTML().contains("2.0"), "T7 fresh reads reflect the latest saved app reports")

    // Publisher redesign keeps connection settings informational and preserves every owner route.
    try! Enrolment.ensurePairingCode(stateDir: rig.state)
    let redesignPage = server.statusHTML(nonce: "redesign-test")
    expect(redesignPage.contains("id=pairing-code") && redesignPage.contains(">Copy code</button>")
           && redesignPage.contains(">Copy address</button>") && redesignPage.contains("id=copy-status"),
           "T10 pairing and address have separate copy controls with accessible feedback")
    expect(redesignPage.contains("data-view=settings") && redesignPage.contains("data-tab=settings")
           && redesignPage.contains("Pairing protection") && redesignPage.contains("Every Mac keeps its own choices."),
           "T11 settings exposes actual connection protection and existing automatic choices without resetting them")
    expect(redesignPage.contains("label=b.textContent") && redesignPage.contains("b.textContent=label")
           && redesignPage.contains("Copy was unavailable. Select the text and copy it manually."),
           "T12 shared copy handler restores each action label and reports copy refusal honestly")
    expect(redesignPage.contains("grid-template-columns:minmax(0,1.15fr) minmax(340px,.85fr)")
           && redesignPage.contains("[hidden]{display:none!important}") && redesignPage.contains("prefers-reduced-motion"),
           "T13 responsive publisher layout preserves hidden views and reduced-motion preference")

    expect(redesignPage.contains("id=page-size") && redesignPage.contains("id=site-filter") && redesignPage.contains("id=tag-filter")
           && redesignPage.contains("<dialog id=mac-dialog") && redesignPage.contains("dialog.showModal()"),
           "T14 fleet keeps search with pagination, site/tag controls and modal details")
    let metadataBody = JSON.encode(["machine": "fixture-mac", "site": "Office <West>", "tags": "Staff, Editing, Staff"], pretty: false)
    let metadataRequest = HTTPRequest(method: "POST", path: "/api/mac-metadata",
        headers: ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790"], body: metadataBody)
    let previousMac = try! StateStore.read(in: rig.state).machines["fixture-mac"]!
    expect(server.handleRequest(metadataRequest, remote: "100.64.0.5").status == 403,
           "T15 remote peers cannot change owner site and tags")
    expect(server.handleRequest(metadataRequest, remote: "127.0.0.1").status == 200,
           "T16 owner can save a site and deduplicated tags")
    let tagged = try! StateStore.read(in: rig.state).machines["fixture-mac"]!
    expect(tagged.site == "Office <West>" && tagged.tags == ["Editing", "Staff"]
           && tagged.tokenHash == previousMac.tokenHash && tagged.pending.map(\.id) == previousMac.pending.map(\.id)
           && tagged.automatic == previousMac.automatic,
           "T17 metadata edits preserve connection, waiting orders and automatic choices")
    expect(server.statusHTML().contains("Office &lt;West&gt;"), "T18 metadata is escaped before rendering")
    let beforeBadMetadata = try! Data(contentsOf: rig.state.appendingPathComponent("state.json"))
    let badMetadata = HTTPRequest(method: "POST", path: "/api/mac-metadata",
        headers: ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790"],
        body: JSON.encode(["machine": "fixture-mac", "site": String(repeating: "x", count: 129)], pretty: false))
    expect(server.handleRequest(badMetadata, remote: "127.0.0.1").status == 400
           && (try! Data(contentsOf: rig.state.appendingPathComponent("state.json"))) == beforeBadMetadata,
           "T19 overlong metadata is refused without changing state")
    expect(PublisherFleet.icon(nil) == PublisherFleet.icon("unknown")
           && PublisherFleet.icon("Macmini9,1") != PublisherFleet.icon("MacBookPro18,1"),
           "T20 device icons use reported identifiers with an honest generic fallback")

    let inventoryReport: [String: Any] = ["machine": "fixture-mac", "site": "Untrusted site",
        "tags": ["untrusted"], "inventory": ["model_id": "Mac14,13", "model_name": "Mac Studio",
        "apps": [["id": "com.example.editor", "name": "Editor <One>", "maker": "Maker <Two>", "path": "/Applications/Editor.app"]]]]
    let reportResponse = server.handleRequest(HTTPRequest(method: "POST", path: "/status",
        headers: ["authorization": "Bearer \(token)"], body: try! JSONSerialization.data(withJSONObject: inventoryReport)), remote: "100.64.0.9")
    let reportedMac = try! StateStore.read(in: rig.state).machines["fixture-mac"]!
    expect(reportResponse.status == 200 && reportedMac.inventory?.model_id == "Mac14,13"
           && reportedMac.site == "Office <West>" && reportedMac.tags == ["Editing", "Staff"],
           "T21 inventory reports cannot overwrite owner site and tags")
    let inventoryPage = server.statusHTML()
    expect(inventoryPage.contains("Editor &lt;One&gt;") && inventoryPage.contains("Maker &lt;Two&gt;")
           && inventoryPage.contains("Copy last reachable report"),
           "T22 reported inventory is escaped and connection facts offer copy actions")
    _ = server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"],
        body: Data(#"{"machine":"fixture-mac","installed":{"demo":"2.0"}}"#.utf8)), remote: "100.64.0.9")
    expect((try! StateStore.read(in: rig.state)).machines["fixture-mac"]?.inventory == reportedMac.inventory,
           "T23 an older status report preserves the last inventory instead of clearing it")

    // Capture the actual owner-route audit, including a duplicate request that creates nothing.
    let auditRig = Rig("order-audit")
    try! auditRig.publish("demo", "2.0", auditRig.artifact("demo.zip", "demo"))
    let auditToken = try! Enrolment.enrol(stateDir: auditRig.state, machine: "audit-mac")
    _ = auditRig.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(auditToken)"],
        body: Data(#"{"machine":"audit-mac","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
    let pipe = Pipe(), savedError = dup(STDERR_FILENO)
    precondition(savedError >= 0 && dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0)
    let request = HTTPRequest(method: "POST", path: "/api/request-update", headers: ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790"],
                              body: Data("machine=audit-mac&app=demo".utf8))
    let first = auditRig.server.handleRequest(request, remote: "127.0.0.1")
    let repeated = auditRig.server.handleRequest(request, remote: "127.0.0.1")
    precondition(dup2(savedError, STDERR_FILENO) >= 0)
    close(savedError)
    try! pipe.fileHandleForWriting.close()
    let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
    func audit(_ line: Substring?) -> [String: Any]? {
        line.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.dropFirst("order-provenance ".count).utf8))) as? [String: Any] }
    }
    let created = audit(lines.first)
    let swallowed = audit(lines.dropFirst().first)
    expect(first.status == 200 && repeated.status == 200,
           "T9 both owner requests answer 200 (first \(first.status), repeated \(repeated.status))")
    expect(created?["created"] as? Int == 1 && created?["skipped"] as? Int == 0 && created?["why"] == nil,
           "T9a the first order is logged as created once, with nothing skipped (\(created ?? [:]))")
    // The duplicate creates nothing, and it is now recorded instead of vanishing: that line is how a
    // swallowed order stops being invisible (2026-11-16, 39 Macs sat on one for an hour).
    expect(swallowed?["created"] as? Int == 0 && swallowed?["skipped"] as? Int == 1
           && swallowed?["why"] as? String == "fresh-duplicate",
           "T9b a swallowed duplicate is logged with its reason (\(swallowed ?? [:]))")
    expect(lines.count == 2,
           "T9c one line per owner request, never more (\(lines.count))")
    expect(created?["path"] as? String == "/api/request-update" && created?["source"] as? String == "owner-page"
           && !lines.contains(where: { $0.contains(auditToken) }),
           "T9d the audit names its route and source and carries no credential")
}
