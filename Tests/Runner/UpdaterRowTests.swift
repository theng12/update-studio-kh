import Foundation

/// The helper is not a feed app (owner ruling 2026-11-23: the Launcher DMG embeds it). These checks
/// hold the three places that used to read `feed.apps["updater"]`, and the strand the fleet measured
/// the same day: ~21 of 31 silent Macs went quiet on a "switched updater" event and still reported
/// the old version.
func updaterRowTests() {
    func memory(_ cfg: AgentConfig) -> AgentMemory? {
        try? AtomicFile.readJSON(AgentMemory.self, from: URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("agent-memory.json"))
    }
    func record(_ rig: Rig) -> MachineState? { (try? StateStore.load(from: rig.state))?.machines["mac1"] }

    // UR1. No updater row, an updater recipe in this Mac's config, and an order to update it: the run
    // says the helper follows the Launcher. Never "the feed has no updater", never a silent skip.
    do {
        let rig = Rig("updater-row")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        var cfg = agentConfig(rig, token: token, apps: ["updater": AppConfig(bundlePath: "", recipe: "updater", automatic: true)])
        cfg.updaterVersion = "0.1.79"
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), requested: ["updater"])
        let done = memory(cfg)?.done.values.first { $0.app == "updater" }
        expect(done?.status == "not_offered" && done?.reason.contains("ships inside the Launcher") == true,
               "UR1 an order to update the helper states it follows the Launcher (\(done?.status ?? "nil"): \(done?.reason ?? "nil"))")
        expect(run?.updates == 0, "UR1 nothing was installed for it")
        let row = run?.apps.first { $0.app == "updater" }
        expect(row?.status == HelperApp.shipsWithLauncher && row?.reason?.contains("Ships inside the Launcher") == true,
               "UR1 the row says it ships with the Launcher, not 'Not in the feed' (\(row?.status ?? "nil"))")
        expect(row?.installed == "0.1.79", "UR1 the row still names the version running here")
    }

    // UR2. A version the stub rolled back, with no record of what it downloaded: the run says the sha
    // is unknown. It never throws, never prints a blank, and never asks the feed for the updater.
    do {
        let rig = Rig("updater-unknown-sha")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["updater": AppConfig(bundlePath: "", recipe: "updater")])
        let layout = StubLayout(base: URL(fileURLWithPath: cfg.stubBase!))
        var state = StubState(rollbacks: 1, rolledBack: "0.1.60")
        state.target = try! layout.binary(for: "0.1.60").path
        try! AtomicFile.writeJSON(state, to: layout.stateFile)
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server))
        expect(run != nil, "UR2 a rollback with no recorded download does not throw")
        expect(run?.notes.contains { $0.contains("0.1.60") && $0.contains("sha is unknown") } == true,
               "UR2 the run names the version and says its sha is unknown (\(run?.notes ?? []))")
        expect(memory(cfg)?.rejected["updater"] == nil, "UR2 nothing is marked rejected on a guess")
    }

    // UR3. The same rollback with the download recorded: those bytes are rejected by the recorded sha.
    do {
        let rig = Rig("updater-known-sha")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["updater": AppConfig(bundlePath: "", recipe: "updater")])
        let layout = StubLayout(base: URL(fileURLWithPath: cfg.stubBase!))
        try! AtomicFile.writeJSON(StubState(rollbacks: 1, rolledBack: "0.1.60"), to: layout.stateFile)
        let sha = String(repeating: "d", count: 64)
        var seeded = AgentMemory()
        seeded.observedStubRollbacks = 0
        seeded.updaterArtifacts = ["0.1.60": sha]
        let dir = URL(fileURLWithPath: cfg.stateDir)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! AtomicFile.writeJSON(seeded, to: dir.appendingPathComponent("agent-memory.json"))
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server))
        expect(run?.notes.contains { $0.contains("those bytes are rejected") } == true,
               "UR3 a rollback with a recorded download rejects those bytes (\(run?.notes ?? []))")
        expect(memory(cfg)?.rejected["updater"] == sha, "UR3 the rejection uses the journal's own sha")
    }

    // UR4. Across the switch: the updater installs, and the agent's next run still reports — and the
    // version the publisher records is the one actually running. This is the strand of 2026-11-23:
    // ~21 Macs went silent on "switched updater" and kept reporting the old version.
    do {
        let rig = Rig("updater-switch-report")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let artifact = rig.artifact("helper.bin", "new helper bytes")
        try! rig.publish("updater", "0.1.60", artifact)
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let feed = try! FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey)!
        var cfg = agentConfig(rig, token: token, apps: ["updater": AppConfig(bundlePath: "", recipe: "updater")])
        cfg.updaterVersion = "0.1.59"
        let switched = try? Agent.installUpdater(feed.apps["updater"]!, artifact: artifact, config: cfg)
        expect(switched?.status == "switched", "UR4 the updater switch happened (\(switched?.status ?? "nil"))")
        let running = try! StubLayout(base: URL(fileURLWithPath: cfg.stubBase!)).binary(for: "0.1.60").path
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), executable: running)
        expect(run?.statusPosted == true, "UR4 the agent keeps reporting across the switch")
        expect(record(rig)?.installed["updater"] == "0.1.60",
               "UR4 the publisher records the version actually running (\(record(rig)?.installed["updater"] ?? "nil"))")
    }

    // UR5. A helper installed from inside the Launcher is not under versions/<v>: its own bundle
    // names it, and a saved version that disagrees is corrected in the report instead of repeated.
    do {
        let rig = Rig("updater-bundle-version")
        try? rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "demo-bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        var cfg = agentConfig(rig, token: token, apps: ["updater": AppConfig(bundlePath: "", recipe: "updater")])
        cfg.updaterVersion = "0.1.79"
        let app = rig.root.appendingPathComponent("Studio Launcher KH.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try! fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "0.1.80", "CFBundleIdentifier": "com.khupdater.agent",
                                    "CFBundleExecutable": "khu"]
        try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = macos.appendingPathComponent("khu")
        try! "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server), executable: exe.path)
        expect(record(rig)?.installed["updater"] == "0.1.80",
               "UR5 a helper outside versions/ reports its own bundle's version (\(record(rig)?.installed["updater"] ?? "nil"))")
        expect(run?.notes.contains { $0.contains("0.1.79") && $0.contains("0.1.80") } == true,
               "UR5 the run says the saved version disagreed (\(run?.notes ?? []))")
    }
}
