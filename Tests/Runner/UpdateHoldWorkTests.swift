import Foundation

/// Live work the stand-in "app" really dispatches, so the hold is proven against an active queue
/// rather than a scripted count: two jobs run, four wait, and every job must finish after resume.
private final class WorkQueue: @unchecked Sendable {
    private let lane = DispatchQueue(label: "hold-work", attributes: .concurrent)
    private let lock = NSLock()
    private var waiting = 0, running = 0, done = 0
    private var paused = false, stopped = false
    func add(_ jobs: Int) {
        lock.lock(); waiting += jobs; lock.unlock(); pump()
    }
    private func pump() {
        lock.lock()
        while !paused, !stopped, waiting > 0, running < 2 {
            waiting -= 1; running += 1; lock.unlock()
            lane.async { [self] in
                Thread.sleep(forTimeInterval: 3)
                lock.lock(); running -= 1; done += 1; lock.unlock()
                pump()
            }
            lock.lock()
        }
        lock.unlock()
    }
    /// Stop dispatching and wait for what is already running, up to `deadline` seconds.
    func pauseAndSettle(deadline: TimeInterval) -> (running: Int, waiting: Int) {
        lock.lock(); paused = true; let queued = waiting; lock.unlock()
        let until = Date().addingTimeInterval(deadline)
        while Date() < until {
            lock.lock(); let busy = running; lock.unlock()
            if busy == 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock(); let busy = running; let stillQueued = waiting; lock.unlock()
        return (busy, stillQueued)
    }
    func resume() { lock.lock(); paused = false; lock.unlock(); pump() }
    func stop() { lock.lock(); stopped = true; paused = false; lock.unlock(); pump() }
    var counts: (done: Int, running: Int, waiting: Int) {
        lock.lock(); defer { lock.unlock() }; return (done, running, waiting)
    }
}

private final class ProofLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, Date)] = []
    func add(_ name: String) { lock.lock(); entries.append((name, Date())); lock.unlock() }
    func time(_ name: String) -> Date? { lock.lock(); defer { lock.unlock() }; return entries.first { $0.0 == name }?.1 }
    func reset() { lock.lock(); entries.removeAll(); lock.unlock() }
    var all: [(String, Date)] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// HOLD_WORK_ONLY=1: the real caller against a real feed server and a stand-in app that is really
/// dispatching work, with queued work behind it. No window, no app, temp data only.
func updateHoldWorkTests() {
    setenv("KHU_HOLD_TOKEN_FILE", tmpDir("hold-token-live").appendingPathComponent("hold-token").path, 1)
    let rig = Rig("hold-work")
    let installed = makeApp(rig.root.appendingPathComponent("Demo.app"), version: "1.0.0", id: "com.example.demo")
    let queue = WorkQueue()
    let log = ProofLog()
    guard let hold = LoopbackHTTPServer() else { expect(false, "HW1 the hold fixture could not listen"); return }
    hold.handler = { method, target in
        if method == "POST" {
            log.add("hold")
            let timeout = target.split(separator: "&").first(where: { $0.hasPrefix("timeout_s=") })
                .flatMap { Int($0.dropFirst("timeout_s=".count)) } ?? 20
            let settled = queue.pauseAndSettle(deadline: TimeInterval(min(30, timeout)))
            log.add("held")
            let names = settled.running == 0 ? "[]" : "[\"a job that would not settle\"]"
            return Data(#"{"safe":\#(settled.running == 0),"unsettled":\#(names),"dispatch_paused_s":120,"in_flight":\#(settled.running)}"#.utf8)
        }
        log.add("resume")
        queue.resume()
        return Data("{}".utf8)
    }
    let holdURL = "http://127.0.0.1:\(hold.port)/api/maintenance/hold"
    Thread { hold.serve() }.start()

    // A Printer-like native app with no hold endpoint, and the app the run updates.
    try! rig.publish("demo", "1.0.0", rig.artifact("demo-old.dmg", "old bytes"), kind: "fake-for-tests", hold: holdURL)
    try! rig.publish("native", "2.0.0", rig.artifact("native.dmg", "native bytes"), kind: "fake-for-tests")

    let server = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0, commandKey: rig.pair.privateKey)
    let fd: Int32
    do { fd = try server.listen() } catch { expect(false, "HW1 the feed server could not listen: \(error)"); return }
    let feedPort = FeedServer.boundPort(fd)
    Thread { try? server.serve(on: fd) }.start()
    defer { close(fd); hold.stop(); queue.stop() }

    let token = (try? Enrolment.enrol(stateDir: rig.state, machine: "mac1")) ?? ""
    let stateDir = rig.root.appendingPathComponent("agent")
    try! fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    var cfg = AgentConfig(feedURL: "http://127.0.0.1:\(feedPort)/release.json", publicKey: rig.pair.publicKeyBase64,
                          stateDir: stateDir.path, machine: "mac1", token: token,
                          apps: ["demo": AppConfig(bundlePath: installed.path, recipe: "fake-for-tests", automatic: true)], once: true)
    cfg.stubBase = rig.root.appendingPathComponent("stub").path
    let app = FakeApp(installed: installed, running: true, healthy: ["2.0.0"])
    let empty = rig.root.appendingPathComponent("empty")

    // A fresh enrolment gets an adoption order for the app it already has. The warm runs report the
    // inventory and let the order settle; then the feed offers 2.0.0 and the measured run updates
    // the app through that order under the hold, with work still queued.
    var warm = cfg
    warm.apps["demo"]?.automatic = false
    _ = try? Agent.runOnce(config: warm, http: URLSessionHTTPClient(), shell: RecordingShell(mount: empty),
                           control: { _, _ in app.control })
    _ = try? Agent.runOnce(config: warm, http: URLSessionHTTPClient(), shell: RecordingShell(mount: empty),
                           control: { _, _ in app.control })
    try! rig.publish("demo", "2.0.0", rig.artifact("demo.dmg", "dmg bytes"), kind: "fake-for-tests", hold: holdURL)
    log.reset()

    // Two jobs are already running and four are queued when the update starts.
    queue.add(6)
    Thread.sleep(forTimeInterval: 0.2)
    let before = queue.counts
    expect(before.running > 0 && before.waiting > 0 && before.done == 0,
           "HW1 the app really has active and queued work before the update (\(before))")

    // The real feed must be reachable over the socket before the run; a silent failure here would
    // look exactly like a skipped app.
    do {
        let (feedData, feedCode) = try URLSessionHTTPClient().get(URL(string: "http://127.0.0.1:\(feedPort)/release.json")!, headers: [:])
        expect(feedCode == 200 && !feedData.isEmpty, "HW1 the real feed is served over the socket (\(feedCode))")
    } catch { expect(false, "HW1 the real feed could not be read: \(error)") }
    var demoFailure = ""
    let result: AgentRunResult?
    do { result = try Agent.runOnce(config: cfg, http: URLSessionHTTPClient(), shell: RecordingShell(mount: empty),
                                    control: { _, _ in app.control }) }
    catch { result = nil; demoFailure = "\(error)" }
    let artifact = stateDir.appendingPathComponent("downloads/demo")
    var downloadDone: Date?
    if let file = (try? fm.contentsOfDirectory(atPath: artifact.path))?.first(where: { $0.hasSuffix(".dmg") }) {
        downloadDone = (try? fm.attributesOfItem(atPath: artifact.appendingPathComponent(file).path))?[.modificationDate] as? Date
    }
    let store = try? StateStore.load(from: rig.state)
    let row = store?.machines["mac1"]?.lastResults?["demo"]

    expect(result?.updates == 1, "HW2 the real caller updates the app (\(result?.updates ?? -1)) \(demoFailure)")
    expect(row?.reason?.contains("held") == true, "HW2 the result says the work was held (\(row?.reason ?? "nil"))")
    expect(log.time("hold") != nil && log.time("held") != nil && log.time("resume") != nil,
           "HW3 the hold was taken and resumed (\(log.all.map(\.0)))")
    if let held = log.time("held"), let resumed = log.time("resume") {
        expect(resumed > held, "HW3 the resume follows the hold's settle")
    }
    if let held = log.time("held"), let downloadDone {
        expect(downloadDone > held, "HW4 no byte was downloaded before the app settled")
    }
    let deadline = Date().addingTimeInterval(15)
    while queue.counts.done < 6, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    let after = queue.counts
    expect(after.done == 6 && after.running == 0 && after.waiting == 0,
           "HW5 every job finished after resume, none was cancelled or lost (\(after))")
    let resumedAt = log.time("resume")
    expect(resumedAt != nil && after.done == 6, "HW5 queued work started only after the resume")

    // The Printer case: a running native app with no hold endpoint is refused before any byte, and
    // nothing about it is quit or touched.
    var nativeCfg = cfg
    nativeCfg.apps = ["native": AppConfig(bundlePath: installed.path, recipe: "fake-for-tests", automatic: true)]
    nativeCfg.once = true
    let nativeApp = FakeApp(installed: installed, running: true, healthy: ["2.0.0"])
    let nativeResult = try? Agent.runOnce(config: nativeCfg, http: URLSessionHTTPClient(), shell: RecordingShell(mount: empty),
                                          control: { _, _ in nativeApp.control })
    let nativeRow = (try? StateStore.load(from: rig.state))?.machines["mac1"]?.lastResults?["native"]
    let nativeDownload = stateDir.appendingPathComponent("downloads/native")
    expect(nativeResult?.updates == 0 && nativeRow?.status == "refused"
           && (nativeRow?.reason ?? "").contains("does not name an update-hold endpoint"),
           "HW6 a running app with no endpoint is refused (\(nativeRow?.status ?? "nil"))")
    expect(!fm.fileExists(atPath: nativeDownload.path) && nativeApp.events.isEmpty,
           "HW6 nothing was downloaded and the app was never quit (\(nativeApp.events))")
    expect(log.all.filter { $0.0 == "hold" }.count == 1, "HW6 no hold call was made for the unsupported app")
}
