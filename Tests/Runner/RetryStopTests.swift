import Foundation

/// An attempt the owner switched off must end — once, with one line — instead of being retried
/// every few seconds on a production Mac. Measured 2026-11-20 on macmini-angkor: Automatic was
/// turned off for storage-studio in Update Studio and the Mac kept failing every 7 s
/// (issue 20261120-151).
func retryStopTests() {
    // The page posts its switch as a form; same headers the owner's own browser sends.
    let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790",
                 "content-type": "application/x-www-form-urlencoded"]
    func fixture(_ tag: String) -> (Rig, String, URL) {
        let rig = Rig(tag)
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
        let app = makeApp(rig.root.appendingPathComponent("Demo.app"), version: "1.0.0")
        return (rig, token, app)
    }
    func run(_ rig: Rig, token: String, app: URL) -> AgentRunResult? {
        let config = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests")])
        let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
        var out: AgentRunResult?
        do {
            out = try Agent.runOnce(config: config, http: InProcessClient(server: rig.server),
                                    shell: RecordingShell(mount: rig.root),
                                    control: { _, _ in quiet }, appFolders: [])
        } catch { out = nil }
        return out
    }

    // RS1 — an order placed BEFORE the page's switch. It ends without installing, says why in one
    // line, is answered so it does not stay pending, and is not attempted again on the next run.
    do {
        let (rig, token, app) = fixture("retry-stop-before")
        let older = ServerCommand(machine: "mac1", app: "demo",
                                  createdAt: ISO.string(Date().addingTimeInterval(-600)), action: ServerCommand.update)
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]?.pending.append(older) }
        let off = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/automatic", headers: owner,
                                                       body: Data("machine=mac1&app=demo&on=false".utf8)),
                                           remote: "127.0.0.1")
        expect(off.status == 200 || off.status == 303, "RS1 Update Studio turns Automatic off for the app (HTTP \(off.status))")
        let first = run(rig, token: token, app: app)
        expect(first?.updates ?? -1 == 0 && first?.notes.contains { $0.contains("automatic updates are off") } == true,
               "RS1 the order placed before the switch ends without installing, with one line saying why (updates \(first?.updates ?? -1); notes \(first?.notes ?? []))")
        expect(try! StateStore.read(in: rig.state).machines["mac1"]!.pending.isEmpty,
               "RS1 the order is answered, so it is not re-delivered for ever")
        let second = run(rig, token: token, app: app)
        expect(second?.commandsRun ?? 1 == 0,
               "RS1 the next run does not attempt it again (\(second?.commandsRun ?? -1) commands)")
    }

    // RS2 — an order placed AFTER the switch is a fresh request from the owner and still runs.
    // The switch stops what was already in motion; it does not silence a request made since.
    do {
        let (rig, token, app) = fixture("retry-stop-after")
        try! StateStore.update(in: rig.state) { ms in
            ms.machines["mac1"]?.automatic = ["demo": false]
            ms.machines["mac1"]?.automaticSet = ["demo": AutomaticChange(at: ISO.string(Date().addingTimeInterval(-600)), byMac: false)]
            ms.machines["mac1"]?.pending.append(ServerCommand(machine: "mac1", app: "demo",
                                                              createdAt: ISO.string(Date()), action: ServerCommand.update))
        }
        let result = run(rig, token: token, app: app)
        expect(result?.updates == 1,
               "RS2 an order placed after the switch still installs (updates \(result?.updates ?? -1); notes \(result?.notes ?? []))")
    }

    // RS3 — the switch the agent actually obeys is the Mac's own (`helper.json`), which wins over
    // the page unless the page's value is provably later. An attempt it was switched off before
    // ends with one line naming the app, and the next run does not try again (issue 20261120-151:
    // the store, not the cache).
    do {
        let (rig, token, app) = fixture("retry-stop-mac-switch")
        let config = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests")])
        let stateDir = URL(fileURLWithPath: config.stateDir)
        try! fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try! HelperSettings(automatic: ["demo": .init(on: false, at: ISO.string(Date().addingTimeInterval(-600)))])
            .save(to: stateDir)
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]?.pending.append(ServerCommand(
            machine: "mac1", app: "demo", createdAt: ISO.string(Date().addingTimeInterval(-900)),
            action: ServerCommand.update)) }
        let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
        func go() -> AgentRunResult? {
            try? Agent.runOnce(config: config, http: InProcessClient(server: rig.server),
                               shell: RecordingShell(mount: rig.root), control: { _, _ in quiet }, appFolders: [])
        }
        let first = go()
        expect(first?.updates ?? -1 == 0
               && first?.notes.contains { $0.contains("automatic updates are off for demo") && $0.contains("set on this Mac") } == true,
               "RS3 an attempt the Mac's own switch is off ends without installing, naming the app and where the switch is (notes \(first?.notes ?? []))")
        let second = go()
        expect(second?.commandsRun ?? 1 == 0, "RS3 no second attempt (\(second?.commandsRun ?? -1) commands)")
    }

    // RS4–RS7 — the selection rules around 0.1.71's defect: a hold refusal is NOT an artifact
    // rejection (issue 20261120-209). It backs off and retries; a rejection expires; a legacy
    // rejection caused by a hold failure is healed once on load.
    do {
        let (rig, token, app) = fixture("retry-stop-hold-state")
        let config = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests", automatic: true)])
        let stateDir = URL(fileURLWithPath: config.stateDir)
        try! fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let memoryFile = stateDir.appendingPathComponent("agent-memory.json")
        // RS4 needs the app running (the backoff only holds a running app); RS5–RS7 need it closed,
        // so the retried artifact actually installs. A closed app with a refusal is RS8's case.
        var appRunning = true
        let quiet = AppControl(isRunning: { appRunning }, quit: { true }, launch: {}, healthy: { _ in true })
        func go() -> AgentRunResult? {
            try? Agent.runOnce(config: config, http: InProcessClient(server: rig.server),
                               shell: RecordingShell(mount: rig.root), control: { _, _ in quiet }, appFolders: [])
        }
        let sha = FeedPublisher.loadFeed(from: rig.feed)!.apps["demo"]!.sha256
        func memory() -> AgentMemory { (try? AtomicFile.readJSON(AgentMemory.self, from: memoryFile)) ?? AgentMemory() }

        // RS4: a fresh hold refusal backs off — no attempt, one line with its time, and the artifact
        // is NOT remembered as rejected.
        var m = AgentMemory()
        m.holdRefusals = ["demo": .init(version: "2.0.0", sha256: sha, reason: "the app did not pause", at: ISO.string(Date()), attempts: 1)]
        try! AtomicFile.writeJSON(m, to: memoryFile)
        let held = go()
        expect(held?.updates ?? -1 == 0 && memory().rejected["demo"] == nil
               && held?.notes.contains { $0.contains("update hold was refused") && $0.contains("trying again after 15 min") } == true,
               "RS4 a refused hold backs off with one line and is never an artifact rejection (notes \(held?.notes ?? []))")
        expect(memory().holdRefusals?["demo"]?.at == m.holdRefusals?["demo"]?.at,
               "RS4 a run that does not attempt it does not refresh its clock")

        // RS5: past the backoff the same artifact is attempted again.
        appRunning = false
        m.holdRefusals?["demo"]?.at = ISO.string(Date().addingTimeInterval(-(Agent.holdBackoff + 60)))
        try! AtomicFile.writeJSON(m, to: memoryFile)
        expect(go()?.updates ?? -1 == 1, "RS5 the same artifact is tried again after the backoff")

        // RS6: an artifact rejection expires, so no transient fault strands a Mac for ever.
        var expired = AgentMemory()
        expired.rejected = ["demo": sha]
        expired.rejectedAt = ["demo": ISO.string(Date().addingTimeInterval(-(Agent.artifactRejectionWindow + 60)))]
        try! AtomicFile.writeJSON(expired, to: memoryFile)
        expect(go()?.updates ?? -1 == 1, "RS6 a rejection older than the window is history, not a life sentence")

        // RS7: the 0.1.71 defect heals on load — a rejection with no clock whose newest result was a
        // hold refusal was never about the bytes.
        var legacy = AgentMemory()
        legacy.rejected = ["demo": sha]
        legacy.done["auto-demo-old"] = .init(app: "demo", status: "install_failed",
                                              reason: "demo's update hold is no longer safe", at: ISO.string(Date().addingTimeInterval(-3600)), sent: true)
        try! AtomicFile.writeJSON(legacy, to: memoryFile)
        let healed = go()
        expect(healed?.updates ?? -1 == 1 && healed?.notes.contains { $0.contains("recorded as a bad artifact by an earlier build") } == true,
               "RS7 a legacy hold-caused rejection is cleared once and the version is tried again (notes \(healed?.notes ?? []))")
    }

    // RS8–RS9 — spent hold refusals: actionable while running, cleared the moment the app closes,
    // and identical repeated failures keep `at` fixed while pacing the next backoff.
    do {
        let (rig, token, app) = fixture("retry-stop-spent-and-repeat")
        let config = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests", automatic: true)])
        let stateDir = URL(fileURLWithPath: config.stateDir)
        try! fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let memoryFile = stateDir.appendingPathComponent("agent-memory.json")
        let sha = FeedPublisher.loadFeed(from: rig.feed)!.apps["demo"]!.sha256
        func memory() -> AgentMemory { (try? AtomicFile.readJSON(AgentMemory.self, from: memoryFile)) ?? AgentMemory() }
        var running = true
        let ctl = AppControl(isRunning: { running }, quit: { true }, launch: {}, healthy: { _ in true })
        func go(at now: Date) -> AgentRunResult? {
            try? Agent.runOnce(config: config, http: InProcessClient(server: rig.server),
                               shell: RecordingShell(mount: rig.root), control: { _, _ in ctl }, now: now, appFolders: [])
        }

        // RS8: spent hold refusal skips while running with the action, and installs immediately on close
        // even inside the backoff window.
        let t0 = Date()
        var spent = AgentMemory()
        spent.holdRefusals = ["demo": .init(version: "2.0.0", sha256: sha, reason: "the app did not pause",
                                            at: ISO.string(t0.addingTimeInterval(-3600)), lastAttemptAt: ISO.string(t0),
                                            attempts: Agent.holdNeedsPerson)]
        try! AtomicFile.writeJSON(spent, to: memoryFile)
        let skipped = go(at: t0.addingTimeInterval(60))
        expect(skipped?.updates ?? -1 == 0 && skipped?.commandsRun ?? -1 == 0
               && skipped?.notes.contains { $0.contains("quit or restart demo once") } == true,
               "RS8 spent hold refusal skips while running and names the action (notes \(skipped?.notes ?? []))")
        running = false
        let closed = go(at: t0.addingTimeInterval(120))
        expect(closed?.updates ?? -1 == 1 && memory().holdRefusals?["demo"] == nil,
               "RS8 closing the app clears the spent refusal and installs on the next cycle without waiting")

        // RS9: repeated identical hold refusals keep `at` unrefreshed while pacing the backoff.
        let (rig9, token9, app9) = fixture("retry-stop-repeat-clock")
        // fake-for-tests, like RS4–RS7: app-dmg throws on a fixture zip instead of reporting the
        // refusal, so the repeat the test is about never happens.
        let cfg9 = agentConfig(rig9, token: token9, apps: ["demo": AppConfig(bundlePath: app9.path, recipe: "fake-for-tests", automatic: true)])
        let memFile9 = URL(fileURLWithPath: cfg9.stateDir).appendingPathComponent("agent-memory.json")
        var run9 = true
        let ctl9 = AppControl(isRunning: { run9 }, quit: { true }, launch: {}, healthy: { _ in true })
        func go9() -> AgentRunResult? {
            do {
                return try Agent.runOnce(config: cfg9, http: InProcessClient(server: rig9.server),
                                         shell: RecordingShell(mount: rig9.root), control: { _, _ in ctl9 },
                                         appFolders: [])
            } catch {
                print("RS9 run threw: \(error)")
                return nil
            }
        }
        func mem9() -> AgentMemory { (try? AtomicFile.readJSON(AgentMemory.self, from: memFile9)) ?? AgentMemory() }
        // Age the refusal, not the clock: moving the agent's clock forward makes the server's signed
        // order genuinely stale, and the run is refused as a replay before any of this is reached.
        func age(_ seconds: TimeInterval) {
            var m = mem9()
            m.holdRefusals?["demo"]?.lastAttemptAt = ISO.string(Date().addingTimeInterval(-seconds))
            try! AtomicFile.writeJSON(m, to: memFile9)
        }
        let r1 = go9()
        let firstAt = mem9().holdRefusals?["demo"]?.at
        expect(r1?.commandsRun == 1 && mem9().holdRefusals?["demo"]?.attempts == 1 && mem9().rejected["demo"] == nil,
               "RS9 first hold refusal records attempt 1 without rejecting the artifact")
        age(Agent.holdBackoff + 60)
        let r2 = go9()
        expect(r2?.commandsRun == 1 && mem9().holdRefusals?["demo"]?.attempts == 2
               && mem9().holdRefusals?["demo"]?.at == firstAt,
               "RS9 identical repeat increments attempts without refreshing the original timestamp (commands \(r2?.commandsRun ?? -1), attempts \(mem9().holdRefusals?["demo"]?.attempts ?? -1), at \(mem9().holdRefusals?["demo"]?.at ?? "none"), first \(firstAt ?? "none"), notes \(r2?.notes ?? []))")
        let r2Wait = go9()
        expect(r2Wait?.commandsRun == 0 && mem9().holdRefusals?["demo"]?.attempts == 2,
               "RS9 backoff holds after the second attempt too (commands \(r2Wait?.commandsRun ?? -1), attempts \(mem9().holdRefusals?["demo"]?.attempts ?? -1))")
        age(Agent.holdBackoff + 60)
        let r3 = go9()
        expect(r3?.commandsRun == 1 && mem9().holdRefusals?["demo"]?.attempts == 3
               && r3?.notes.contains { $0.contains("Quit or restart demo once") } == true,
               "RS9 third attempt surfaces the actionable instruction (commands \(r3?.commandsRun ?? -1), attempts \(mem9().holdRefusals?["demo"]?.attempts ?? -1), notes \(r3?.notes ?? []))")
        _ = run9; run9 = true
    }

    // RS10 — the page is one source of truth with this Mac's switch, and the sentence names the
    // switch that actually decided. Row 20261120-217: a Mac with no Hub had its page switch set on
    // (200, state.json written) and its next pass still ended the order "set on this Mac", because
    // section 5b read the Mac's switch raw instead of asking Helper.automaticDecision.
    do {
        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790",
                     "content-type": "application/x-www-form-urlencoded"]
        func go(_ tag: String, macOffAt: TimeInterval, pageOn: Bool) -> (result: AgentRunResult?, memory: AgentMemory) {
            let (rig, token, app) = fixture(tag)
            let config = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests")])
            let stateDir = URL(fileURLWithPath: config.stateDir)
            try! fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
            try! HelperSettings(automatic: ["demo": .init(on: false, at: ISO.string(Date().addingTimeInterval(macOffAt)))])
                .save(to: stateDir)
            try! StateStore.update(in: rig.state) { $0.machines["mac1"]?.pending.append(ServerCommand(
                machine: "mac1", app: "demo", createdAt: ISO.string(Date().addingTimeInterval(-900)),
                action: ServerCommand.update)) }
            _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/automatic", headers: owner,
                body: Data("machine=mac1&app=demo&on=\(pageOn)".utf8)), remote: "127.0.0.1")
            let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
            let result = try? Agent.runOnce(config: config, http: InProcessClient(server: rig.server),
                                            shell: RecordingShell(mount: rig.root), control: { _, _ in quiet },
                                            appFolders: [])
            let memory = (try? AtomicFile.readJSON(AgentMemory.self, from: stateDir.appendingPathComponent("agent-memory.json"))) ?? AgentMemory()
            return (result, memory)
        }

        // The switch set in the page three days after this Mac's own off-switch is the one that
        // decides: the queued order runs. This fails before the fix.
        // The order is older than this Mac's off-switch, so the "placed after the switch" exemption
        // cannot rescue it: only the page's later value can. That is the live case on 1301.
        let rescued = go("retry-stop-page-rescues", macOffAt: -600, pageOn: true).result
        expect(rescued?.updates == 1 && rescued?.notes.contains { $0.contains("automatic updates are off") } == false,
               "RS10 a page switch later than this Mac's off-switch lets the queued order run (updates \(rescued?.updates ?? -1); notes \(rescued?.notes ?? []))")

        // The same page value, but earlier than this Mac's own switch: the Mac's switch still wins,
        // and the sentence says so. Nothing about the 0.1.71 behaviour is loosened.
        let macWins = go("retry-stop-mac-still-wins", macOffAt: 60, pageOn: true).result
        expect(macWins?.updates == 0 && macWins?.notes.contains { $0.contains("automatic updates are off for demo") && $0.contains("set on this Mac") } == true,
               "RS10 a Mac switch later than the page's still ends the order, naming this Mac (notes \(macWins?.notes ?? []))")
    }
}
