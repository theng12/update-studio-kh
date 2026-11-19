import Foundation

func orderQueueTests() {
    // OQ1: first order queues exactly one pending entry; audit shows created 1.
    let rig = Rig("order-queue")
    try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
    let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
    _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"],
        body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
    let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
    let body1 = Data(#"{"machine":"mac1","app":"demo"}"#.utf8)
    let r1 = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-update", headers: owner, body: body1), remote: "127.0.0.1")
    expect(r1.status == 200, "OQ1 first request-update returns 200")
    var ms1 = try! StateStore.read(in: rig.state).machines["mac1"]!
    let firstPending = ms1.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
    expect(firstPending.count == 1, "OQ1 exactly one pending entry after first order")
    let firstId = firstPending.first!.id

    // OQ2: same request 60 s later is a fresh duplicate — same id, skipped 1.
    // Driven via queueOrder directly because the in-process server always uses Date() and we
    // cannot inject `now` through the HTTP route without touching files we are not allowed to.
    var ms2 = ms1
    let young = FeedServer.queueOrder(&ms2, machine: "mac1", app: "demo", action: ServerCommand.update,
                                      now: Date().addingTimeInterval(60))
    expect(young == .skippedFreshDuplicate, "OQ2 60 s later is skippedFreshDuplicate")
    let youngPending = ms2.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
    expect(youngPending.count == 1 && youngPending.first!.id == firstId, "OQ2 same id preserved on fresh duplicate")

    // OQ3: same request 31 min later replaces the stale entry with a new id.
    var ms3 = ms1
    let stale = FeedServer.queueOrder(&ms3, machine: "mac1", app: "demo", action: ServerCommand.update,
                                      now: Date().addingTimeInterval(31 * 60))
    expect(stale == .replacedStale, "OQ3 31 min later is replacedStale")
    let stalePending = ms3.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
    expect(stalePending.count == 1 && stalePending.first!.id != firstId, "OQ3 new id after stale replacement")
    expect(!ms3.pending.contains(where: { $0.id == firstId }), "OQ3 old id is gone after stale replacement")

    // OQ4: Agent.runOnce dispatches exactly one order and clears pending on acknowledgement.
    let client = InProcessClient(server: rig.server)
    let appPath = rig.root.appendingPathComponent("OQApp.app")
    try! fm.createDirectory(at: appPath, withIntermediateDirectories: true)
    let infoPlist = appPath.appendingPathComponent("Contents/Info.plist")
    try! fm.createDirectory(at: infoPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "com.test.oq", "CFBundleVersion": "1.0",
                                "CFBundleShortVersionString": "1.0", "CFBundleExecutable": "OQApp"]
    try! (try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        .write(to: infoPlist)
    let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: appPath.path, recipe: "fake-for-tests")])
    // A scripted control: this must never look at the real machine's processes.
    let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
    // Same shape the hold tests use: no real app folders are scanned, and the throw is kept so a
    // red line names its cause instead of "updates -1".
    var run: AgentRunResult?
    var threw: String?
    do {
        run = try Agent.runOnce(config: cfg, http: client, shell: RecordingShell(mount: rig.root),
                                control: { _, _ in quiet }, appFolders: [])
    } catch {
        threw = "\(error)"
    }
    expect(run?.updates == 1, "OQ4 agent ran exactly one update (updates \(run?.updates ?? -1); threw: \(threw ?? "nothing"); notes \(run?.notes ?? []))")
    let afterRun = try! StateStore.read(in: rig.state).machines["mac1"]!
    expect(afterRun.pending.isEmpty, "OQ4 pending is empty after agent acknowledgement (still \(afterRun.pending.map(\.app)))")

    // OQ5: the fleet route and a machine that already holds an order for that app.
    // This used to assert the opposite — that a stale order was left exactly as it was, and the
    // fleet route could neither clear nor re-drive it. That was the defect, written down as a
    // passing test: a Mac holding a dead order could never be sent another one, because this route
    // is the only place orders come from (2026-11-20). OQ5 now asserts the fix: past
    // `orderRetryWindow` the dead order is replaced, and a machine with nothing pending is still
    // queued once. BU1 in BulkUpdateTests covers the same behaviour through the same route.
    let rig5 = Rig("order-queue-fleet")
    try! rig5.publish("demo", "2.0.0", rig5.artifact("demo.zip", "bytes"))
    let token5 = try! Enrolment.enrol(stateDir: rig5.state, machine: "fleet-mac")
    _ = rig5.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token5)"],
        body: Data(#"{"machine":"fleet-mac","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
    let token6 = try! Enrolment.enrol(stateDir: rig5.state, machine: "fleet-free")
    _ = rig5.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token6)"],
        body: Data(#"{"machine":"fleet-free","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
    let staleCmd = ServerCommand(machine: "fleet-mac", app: "demo",
                                 createdAt: ISO.string(Date().addingTimeInterval(-(FeedServer.orderRetryWindow + 60))),
                                 action: ServerCommand.update)
    try! StateStore.update(in: rig5.state) { state in
        state.machines["fleet-mac"]?.pending.append(staleCmd)
    }
    let fr = rig5.server.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all",
                                                  headers: owner, body: Data(#"{"app":"demo"}"#.utf8)), remote: "127.0.0.1")
    expect(fr.status == 200, "OQ5 fleet update-all returns 200")
    let held = try! StateStore.read(in: rig5.state).machines["fleet-mac"]!
    expect(held.pending.count == 1 && held.pending.first!.id != staleCmd.id,
           "OQ5 a machine holding a stale order gets a new one, and the dead order is gone (pending \(held.pending.count))")
    let free = try! StateStore.read(in: rig5.state).machines["fleet-free"]!
    let freePending = free.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
    expect(freePending.count == 1, "OQ5 a machine with nothing pending is queued once (pending \(freePending.count))")
}
