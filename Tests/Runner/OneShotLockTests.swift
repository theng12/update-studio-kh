import Foundation

func oneShotLockTests() {
    // LK1: a one-shot local request waits for the run in progress instead of being refused by its
    // lock, while a second long-running agent still refuses rather than racing.
    do {
        let rig = Rig("one-shot-lock")
        let installed = makeApp(rig.root.appendingPathComponent("Demo.app"), version: "1.0.0")
        try rig.publish("demo", "1.0.0", rig.artifact("demo.dmg", "demo"))
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: installed.path, recipe: "fake-for-tests")])
        let state = URL(fileURLWithPath: cfg.stateDir)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let client = InProcessClient(server: rig.server)
        let held = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? FileLock.withExclusive(state.appendingPathComponent("agent.lock")) {
                held.signal()
                released.wait()
            }
        }
        held.wait()
        // Another long-running agent does not queue behind the lock: two loops would race.
        var looping = cfg
        looping.once = false
        expectThrows("LK1 a second long-running agent refuses instead of racing", contains: "agent.lock") {
            _ = try Agent.runOnce(config: looping, http: client)
        }
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 1.2); released.signal() }
        let started = Date()
        let result = try? Agent.runOnce(config: cfg, http: client, requested: ["demo"])
        let waited = Date().timeIntervalSince(started)
        expect(result != nil && waited >= 0.9,
               "LK1 a one-shot local request waits for the agent's run to finish (waited \(String(format: "%.1f", waited)) s)")
    } catch { expect(false, "LK one-shot: \(error)") }
}
