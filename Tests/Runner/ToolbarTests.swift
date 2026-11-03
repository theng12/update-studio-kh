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
    let payload = lines.first.map { Data($0.dropFirst("order-provenance ".count).utf8) } ?? Data()
    let audit = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    expect(first.status == 200 && repeated.status == 200 && lines.count == 1 && audit?["created"] as? Int == 1
           && audit?["path"] as? String == "/api/request-update" && audit?["source"] as? String == "owner-page"
           && !String(decoding: payload, as: UTF8.self).contains(auditToken),
           "T9 owner-created order audit records committed scope once without credentials")
}
