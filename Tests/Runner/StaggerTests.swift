import Foundation

/// Staggered rollouts, decided on the Mac (owner 2026-11-20: "yes, stagger the hub rollouts from
/// now on"). A large artifact is pulled at this Mac's own minute in the window, from
/// `hash(machine, app, version) mod window`, so 65 Macs never pull 1.48 GB at once — and 65 Macs
/// retrying together after a "busy" answer cannot re-form the stampede, because the slot does not
/// move. A security update never waits.
func staggerTests() {
    func config(_ machine: String, window: Int? = 60, mb: Int? = 0) -> AgentConfig {
        var c = AgentConfig(feedURL: "https://example.invalid/release.json", publicKey: "k",
                            stateDir: "/tmp/unused", machine: machine, token: "")
        c.staggerMinutes = window
        c.staggerMB = mb
        return c
    }
    func entry(_ version: String = "2.0.0", bytes: Int64 = 200_000_000, security: Bool? = nil) -> FeedApp {
        var e = FeedApp(version: version, file: "hub.dmg", sha256: String(repeating: "a", count: 64),
                        bytes: bytes, kind: "app-dmg")
        e.security = security
        return e
    }
    func offset(_ machine: String, _ app: String, _ version: String, window: Int) -> Int {
        (Int(Enrolment.sha256Hex("\(machine)|\(app)|\(version)").prefix(8), radix: 16) ?? 0) % (window * 60)
    }
    let now = Date()

    // SG1: the slot is this Mac's own, stable, and not the same for everyone.
    do {
        let a = offset("mac-a", "hub", "2.0.0", window: 60)
        let b = offset("mac-b", "hub", "2.0.0", window: 60)
        var memory = AgentMemory()
        _ = Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a"), installed: "1.0",
                              memory: &memory, at: now)
        let stored = memory.stagger?["hub"]?.offsetSeconds ?? -1
        var again = AgentMemory()
        _ = Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a"), installed: "1.0",
                              memory: &again, at: now)
        expect(stored == a && again.stagger?["hub"]?.offsetSeconds == a,
               "SG1 a Mac's slot comes from its own name and does not move between runs (\(stored), \(again.stagger?["hub"]?.offsetSeconds ?? -1), expected \(a))")
        expect(a != b, "SG1 two Macs get different slots (\(a) vs \(b))")
        expect(Set(["mac1", "mac2", "mac3", "mac4", "mac5"]
            .map { offset($0, "hub", "2.0.0", window: 60) }).count > 1,
               "SG1 five Macs do not share one slot")
    }

    // SG2: before its slot the pull waits, with one plain line; at its slot it goes.
    do {
        var memory = AgentMemory()
        let start = Date()
        let wait = Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a"), installed: "1.0",
                                     memory: &memory, at: start)
        let a = offset("mac-a", "hub", "2.0.0", window: 60)
        expect((wait == nil) == (a == 0),
               "SG2 a Mac whose slot is minute 0 pulls at once, every other waits (offset \(a / 60) min; line \(wait ?? "none"))")
        if let wait {
            expect(wait.contains("rollout window") && wait.contains("in ") && wait.contains("nothing else waits"),
                   "SG2 the wait is one plain line naming its minute and the window (\(wait))")
        }
        let after = Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a"), installed: "1.0",
                                      memory: &memory, at: start.addingTimeInterval(TimeInterval(a) + 1))
        expect(after == nil, "SG2 at its own slot the pull starts (offset \(a) s)")
        let later = Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a"), installed: "1.0",
                                      memory: &memory, at: start.addingTimeInterval(TimeInterval(a) + 3600))
        expect(later == nil, "SG2 once the slot has passed the pull is never held again")
    }

    // SG3: a security update never waits — that is the Mac that has been offline and is far behind.
    do {
        var memory = AgentMemory()
        let wait = Agent.staggerWait(app: "hub", entry: entry(security: true), config: config("mac-a"),
                                     installed: "1.0", memory: &memory, at: now)
        expect(wait == nil && memory.stagger?["hub"] == nil,
               "SG3 a security update pulls now, with no slot and no remembered wait (\(wait ?? "none"))")
    }

    // SG4: an app that is not installed yet never waits, and a small artifact is not staggered.
    do {
        var memory = AgentMemory()
        expect(Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a"), installed: nil,
                                 memory: &memory, at: now) == nil,
               "SG4 an app this Mac does not have installs at once")
        var small = AgentMemory()
        expect(Agent.staggerWait(app: "hub", entry: entry(bytes: 5_000_000), config: config("mac-a", mb: 100),
                                 installed: "1.0", memory: &small, at: now) == nil,
               "SG4 an artifact below the size setting is not staggered")
        var off = AgentMemory()
        expect(Agent.staggerWait(app: "hub", entry: entry(), config: config("mac-a", window: 0), installed: "1.0",
                                 memory: &off, at: now) == nil,
               "SG4 a window of 0 turns the stagger off")
    }

    // SG5: a new version is a new anchor — the wait starts again from when this Mac saw it.
    do {
        var memory = AgentMemory()
        let start = Date()
        _ = Agent.staggerWait(app: "hub", entry: entry("2.0.0"), config: config("mac-a"), installed: "1.0",
                              memory: &memory, at: start)
        let seenAt = memory.stagger?["hub"]?.since
        let after = Agent.staggerWait(app: "hub", entry: entry("2.1.0"), config: config("mac-a"), installed: "1.0",
                                      memory: &memory, at: start.addingTimeInterval(7200))
        expect(memory.stagger?["hub"]?.version == "2.1.0" && memory.stagger?["hub"]?.since != seenAt,
               "SG5 a newer version gets its own slot and its own start (\(memory.stagger?["hub"]?.since ?? "none"))")
        expect(after == nil || memory.stagger?["hub"]?.offsetSeconds != 0,
               "SG5 the new version is paced from when this Mac first saw it")
    }

    // SG6: the sweep holds an automatic large pull and says so, without touching anything else.
    do {
        let rig = Rig("stagger-sweep")
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.bin", String(repeating: "x", count: 4096)))
        // agentConfig names this Mac "mac1", and the token must prove that same machine.
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0.0"}}"#.utf8)), remote: "100.64.0.9")
        let app = makeApp(rig.root.appendingPathComponent("Demo.app"), version: "1.0.0")
        var cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: app.path, recipe: "fake-for-tests", automatic: true)])
        cfg.staggerMB = 0
        let a = offset("mac1", "demo", "2.0.0", window: 60)
        let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
        let started = Date()
        func go(_ at: Date) -> AgentRunResult? {
            do {
                return try Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server),
                                         shell: RecordingShell(mount: rig.root), control: { _, _ in quiet },
                                         now: at, appFolders: [])
            } catch {
                print("SG6 run threw: \(error)")
                return nil
            }
        }
        let result = go(started)
        if a == 0 {
            expect(result?.commandsRun == 1, "SG6 a Mac whose slot is now pulls at once (\(result?.commandsRun ?? -1))")
        } else {
            expect(result?.commandsRun == 0 && result?.updates == 0
                   && result?.notes.contains { $0.contains("rollout window") } == true,
                   "SG6 the sweep holds a staggered pull and says why (commands \(result?.commandsRun ?? -1); notes \(result?.notes ?? []))")
            // Let the slot pass by backdating the anchor, never by moving the clock: a run whose
            // `now` jumps past the order freshness window refuses this Mac's own orders as replays.
            let memFile = URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("agent-memory.json")
            if var m = try? AtomicFile.readJSON(AgentMemory.self, from: memFile), var mark = m.stagger?["demo"] {
                mark.since = ISO.string(Date().addingTimeInterval(-TimeInterval(a) - 60))
                m.stagger?["demo"] = mark
                try? AtomicFile.writeJSON(m, to: memFile)
            }
            let atSlot = go(Date())
            expect(atSlot?.commandsRun == 1, "SG6 at its slot the same sweep pulls it (\(atSlot?.commandsRun ?? -1))")
        }
    }

    // SG7: the publisher can mark a release as a security update, and a routine re-publish keeps it.
    do {
        let rig = Rig("stagger-publish")
        try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "hub", version: "2.0.0",
                                   artifact: rig.artifact("hub.dmg", "AAAA"), kind: "app-dmg",
                                   allowSame: false, meta: nil, security: true, url: "https://example.test/artifacts/")
        let marked = FeedPublisher.loadFeed(from: rig.feed)?.apps["hub"]?.security
        try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "hub", version: "2.1.0",
                                   artifact: rig.artifact("hub-2.1.dmg", "BBBB"), kind: "app-dmg",
                                   allowSame: false, meta: nil, url: "https://example.test/artifacts/")
        let kept = FeedPublisher.loadFeed(from: rig.feed)?.apps["hub"]?.security
        let plain = Rig("stagger-publish-plain")
        try! plain.publish("hub", "2.0.0", plain.artifact("hub.dmg", "CCCC"), kind: "app-dmg")
        let unmarked = FeedPublisher.loadFeed(from: plain.feed)?.apps["hub"]?.security
        expect(marked == true && kept == true && unmarked == nil,
               "SG7 --security marks the entry, a routine re-publish keeps it, and a normal release carries none (\(String(describing: marked)), \(String(describing: kept)), \(String(describing: unmarked)))")
    }
}
