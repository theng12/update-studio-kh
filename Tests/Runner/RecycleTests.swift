import Foundation

/// RC1: the helper starts itself again in place before the HTTP stack's per-transfer cost matters.
///
/// Measured 2026-11-17: about one Mach port and 30–50 KB per completed transfer, never returned, and
/// not a dangling session (a bare URLSession shows the same). The agent therefore bounds its own
/// lifetime; these are the bounds and the reasons it gives.
func recycleTests() {
    expect(AgentRecycle.due(transfers: 0, age: 0) == nil, "RC1 a fresh helper does not restart")
    expect(AgentRecycle.due(transfers: AgentRecycle.afterTransfers - 1, age: 60) == nil,
           "RC1 one transfer short of the cap keeps running")
    let byTransfers = AgentRecycle.due(transfers: AgentRecycle.afterTransfers, age: 60) ?? ""
    expect(byTransfers.contains("transfer"),
           "RC1 reaching the transfer cap gives its reason (\(byTransfers))")
    let byAge = AgentRecycle.due(transfers: 3, age: AgentRecycle.afterSeconds) ?? ""
    expect(byAge.contains("running"),
           "RC1 reaching the age cap gives its reason (\(byAge))")
    // The numbers are the arithmetic, not a taste: the feed, the status report and the orders check
    // are three transfers per five-minute cycle, 864 a day — so 500 recycles about every 14 hours
    // and holds the process near 500 ports and ~20 MB instead of ~864 a day.
    expect(AgentRecycle.afterTransfers == 500 && AgentRecycle.afterSeconds == 86_400,
           "RC1 the caps hold the process near 500 transfers and one day")

    // RC2–RC4, the 1301 loop of 2026-11-22: every run failed at its first status POST, the cap
    // fired anyway, and the helper restarted 1,605 times. A failed run has nothing to preserve.
    let cap = AgentRecycle.afterTransfers
    expect(AgentRecycle.due(transfers: cap, age: 0, successfulRun: false) == nil,
           "RC2 a failed run at the transfer cap does not restart the helper")
    expect(AgentRecycle.due(transfers: cap, age: 0, successfulRun: true) != nil,
           "RC3 a successful run at the transfer cap does restart it")
    expect(AgentRecycle.due(transfers: cap, age: 0, successfulRun: true, recycledSinceSuccess: true) == nil,
           "RC4 two restarts cannot happen with no successful run between them")

    // The ban outlives the exec that swaps the process image, which is the whole point: an
    // in-memory flag would be reset by the restart it is meant to bound.
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("khu-rc-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: state) }
    expect(!AgentRecycle.recycledSinceSuccess(stateDir: state.path), "RC4a a fresh state dir has no restart on record")
    AgentRecycle.recordRecycle(stateDir: state.path, transfers: cap)
    expect(AgentRecycle.recycledSinceSuccess(stateDir: state.path), "RC4b a restart is on record after it happens")
    AgentRecycle.recordSuccess(stateDir: state.path)
    expect(!AgentRecycle.recycledSinceSuccess(stateDir: state.path),
           "RC4c one successful run lifts the ban on the next restart")

    // RC8, the counter a quiet fleet needs: a helper with nothing to install makes no transfers, so
    // the transfer cap never fires while memory still grows a little per run. Measured 2026-11-24 at
    // about 0.5 MB a run, and 1300's 7.63 GB helper was a few hundred quiet runs. The count lives on
    // disk because the restart it triggers is an `exec`, which would reset it to zero.
    expect(AgentRecycle.due(transfers: 0, age: 0, runs: AgentRecycle.afterRuns - 1) == nil,
           "RC8 one run short of the cap keeps running")
    let byRuns = AgentRecycle.due(transfers: 0, age: 0, runs: AgentRecycle.afterRuns) ?? ""
    expect(byRuns.contains("runs") && !byRuns.contains("transfer"),
           "RC8 a quiet helper at the run cap restarts and its reason names runs, not transfers (\(byRuns))")
    expect(AgentRecycle.runs(stateDir: state.path) == 0, "RC8a a fresh state dir has no runs on record")
    AgentRecycle.recordRun(stateDir: state.path)
    AgentRecycle.recordRun(stateDir: state.path)
    expect(AgentRecycle.runs(stateDir: state.path) == 2, "RC8b runs are counted on disk, so an exec does not reset them")
    AgentRecycle.recordRecycle(stateDir: state.path, transfers: 0)
    expect(AgentRecycle.runs(stateDir: state.path) == 0, "RC8c a restart starts its own count")

    // RC9, the bound a public-feed Mac lost (2026-11-26): a public feed is never posted to, so
    // `statusPosted` stays false by design and the guard below never let the helper restart. Measured
    // on the live 0.1.87 helper: 255 runs this process, 367 on the counter, 21 h, zero recycle lines.
    do {
        let perRun = AgentRecycle.successfulRun(statusPosted: false, publicFeed: true, feedError: nil)
        expect(perRun, "RC9 a public-feed run that read its feed counts as successful")
        expect(AgentRecycle.due(transfers: 0, age: 0, successfulRun: perRun, runs: AgentRecycle.afterRuns) != nil,
               "RC9 it lets the run bound fire, so a public-feed helper still recycles")
        // The failures the churn guard exists for must not become "successful" by way of a public feed.
        expect(!AgentRecycle.successfulRun(statusPosted: false, publicFeed: true, feedError: "the feed did not answer"),
               "RC9 a public-feed run whose feed could not be read is still a failure")
        expect(!AgentRecycle.successfulRun(statusPosted: false, publicFeed: false, feedError: nil),
               "RC9 a run that never reached the publisher is still a failure")
        expect(!AgentRecycle.successfulRun(statusPosted: false, publicFeed: false, feedError: "offline"),
               "RC9 the offline SSD path stays a failure, so it never lifts the guard")
        expect(AgentRecycle.successfulRun(statusPosted: true, publicFeed: false, feedError: nil),
               "RC9 a posted run is successful exactly as before")
        expect(AgentRecycle.due(transfers: 0, age: 0,
                                successfulRun: AgentRecycle.successfulRun(statusPosted: false, publicFeed: false, feedError: nil),
                                runs: AgentRecycle.afterRuns) == nil,
               "RC9 the 1301 churn case is still guarded: a failed run at the cap does not restart")
    }

    // RC5: the 0.1.63 Dock icon stays. 0.1.79 bounds the loop that made it appear 1,605 times, and a
    // later change that quietly takes the owner's reopen route away has to break this test first.
    let spec = StubRunner.agentHelperSpec(version: "0.1.79", icon: nil)
    expect(spec.dockIcon, "RC5 the agent helper still carries the 0.1.63 Dock icon")
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("khu-rcb-\(UUID().uuidString.prefix(8))")
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("khu-rcsrc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: source) }
    try? Data("#!/bin/sh\n".utf8).write(to: source)
    if let bundle = try? HelperBundle.ensure(spec, source: source, out: out.appendingPathComponent("H.app")),
       let plist = try? String(contentsOf: bundle.deletingLastPathComponent().deletingLastPathComponent()
                                 .appendingPathComponent("Info.plist"), encoding: .utf8) {
        expect(!plist.contains("LSUIElement"),
               "RC5 the agent's bundle keeps out of the accessory list, so the Dock icon shows")
    } else {
        expect(false, "RC5 the agent's helper bundle could be made from the spec")
    }

    // RC6, parts 5 and 6 of the same fix: with the publisher unreachable the run ends inside its own
    // ceiling, writes one line naming the target and the reason, and is not recycled afterwards —
    // all three in this one test, because any of them alone is a calm-looking agent that cannot
    // reach its publisher and never says so.
    do {
        struct DeadPublisher: HTTPClient {
            func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { throw URLError(.timedOut) }
            func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw URLError(.timedOut) }
            func post(_ url: URL, headers: [String: String], body: Data, timeout: TimeInterval) throws -> (Data, Int) { throw URLError(.timedOut) }
            func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { throw URLError(.timedOut) }
        }
        let rig = Rig("rc6-dead-publisher")
        let cfg = agentConfig(rig, token: "", apps: [:])
        let started = Date()
        let run = try? Agent.runOnce(config: cfg, http: DeadPublisher(), shell: CaptureShell(), appFolders: [],
                                     startupWaitSeconds: 0.2)
        let took = Date().timeIntervalSince(started)
        let notes = run?.notes ?? []
        expect(took < 10, "RC6 the run ends inside its ceiling, not parked in the status report (\(took) s)")
        expect(notes.contains { $0.contains("/status") && $0.contains("no answer within") },
               "RC6 one line names the status target and the reason (\(notes))")
        expect(run?.statusPosted == false, "RC6 a dead publisher reports nothing as posted")
        expect(AgentRecycle.due(transfers: AgentRecycle.afterTransfers, age: 0,
                                successfulRun: run?.statusPosted ?? false) == nil,
               "RC6 a failed run at the transfer cap is not recycled")
    }

    // RC7, part 6: the startup wait for the publisher's name is bounded, says one line when it runs
    // out, and says nothing when the name answers.
    do {
        StartupWait.resetForTests()
        let started = Date()
        let note = StartupWait.waitOnce(for: "no-such-host.invalid", maximum: 1)
        let took = Date().timeIntervalSince(started)
        expect(note?.contains("network not up") == true, "RC7 a name that never resolves reports the wait (\(note ?? "no note"))")
        expect(took < 5, "RC7 the startup wait is bounded by its own ceiling (\(took) s)")
        StartupWait.resetForTests()
        expect(StartupWait.waitOnce(for: "127.0.0.1", maximum: 2) == nil,
               "RC7 a name that answers logs nothing and posts normally")
    }
}
