import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A feed client that treats an existing partial file the way a Range-capable publisher does: it
/// appends the missing bytes and answers 206. Everything that is not an artifact goes to the
/// in-process publisher, so status, orders and the feed are the real routes.
private final class ResumeHTTP: HTTPClient, @unchecked Sendable {
    let inner: InProcessClient
    var artifacts: [String: Data] = [:]
    /// The offset each artifact transfer started from, in order.
    var starts: [Int64] = []
    /// Append this many missing bytes, then fail like a dropped connection (once).
    var dropAfter: Int64?
    var cancelNext = false
    init(_ inner: InProcessClient) { self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { try inner.get(url, headers: headers) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        guard url.path.hasPrefix("/artifacts/"), let data = artifacts[url.lastPathComponent] else {
            return try inner.download(url, headers: headers, to: file, limit: limit)
        }
        let have = ((try? Data(contentsOf: file)) ?? Data()).count
        starts.append(Int64(have))
        if cancelNext {
            cancelNext = false
            try data.prefix(min(data.count, have + 1_000)).write(to: file)
            DownloadControl.cancel()
            throw khuFail("cancelled on this Mac; nothing was changed")
        }
        if let dropAfter {
            self.dropAfter = nil
            try data.prefix(min(data.count, have + Int(dropAfter))).write(to: file)
            throw URLError(.networkConnectionLost)
        }
        try data.write(to: file)
        return have > 0 ? 206 : 200
    }
}

private func resumeFixture(_ tag: String, app: [String: AppConfig], artifact: Data)
    -> (rig: Rig, cfg: AgentConfig, client: ResumeHTTP, dir: URL, file: String)? {
    let rig = Rig(tag)
    let source = rig.root.appendingPathComponent("fixture-artifact.dmg")
    try? artifact.write(to: source)
    try? rig.publish("demo", "2.0.0", source)
    guard let feed = try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey),
          let entry = feed.apps["demo"] else { return nil }
    let token = (try? Enrolment.enrol(stateDir: rig.state, machine: "mac1")) ?? ""
    let client = ResumeHTTP(InProcessClient(server: rig.server))
    client.artifacts[entry.file] = artifact
    let cfg = agentConfig(rig, token: token, apps: app)
    let dir = URL(fileURLWithPath: cfg.stateDir).appendingPathComponent("downloads/demo")
    return (rig, cfg, client, dir, entry.file)
}

func downloadResumeTests() {
    // Pause/Cancel state belongs to the operation that set it; a suite starts from neither.
    DownloadControl.reset()
    // RDL1: the real client and the publisher's own route resume from the bytes already on disk.
    do {
        let rig = Rig("resume-range")
        let bytes = Data((0..<400_000).map { UInt8($0 % 251) })
        let source = rig.root.appendingPathComponent("artifact-2.0.0.dmg")
        try bytes.write(to: source)
        try rig.publish("demo", "2.0.0", source)
        guard let feed = try FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey),
              let entry = feed.apps["demo"] else { expect(false, "RDL1 fixture feed"); return }
        let server = FeedServer(feedDir: rig.feed, stateDir: rig.state, bind: "127.0.0.1", port: 0)
        let fd = try server.listen()
        Thread.detachNewThread { try? server.serve(on: fd) }
        defer { close(fd) }
        let url = URL(string: "http://127.0.0.1:\(FeedServer.boundPort(fd))/artifacts/\(entry.file)")!

        let part = rig.root.appendingPathComponent("resume.part")
        try bytes.prefix(150_000).write(to: part)
        let status = try URLSessionHTTPClient().download(url, headers: [:], to: part, limit: entry.bytes, phase: "downloading")
        expect(status == 206, "RDL1 a Range request against the publisher is answered 206 (got \(status))")
        expect((try? Data(contentsOf: part)) == bytes, "RDL1 the resumed file is the whole signed artifact")

        let whole = rig.root.appendingPathComponent("whole.part")
        let code = try URLSessionHTTPClient().download(url, headers: [:], to: whole, limit: entry.bytes, phase: "downloading")
        expect(code == 200 && (try? Data(contentsOf: whole)) == bytes,
               "RDL1 without a partial the whole artifact is served (got \(code))")

        let past = server.handleRequest(HTTPRequest(method: "GET", path: "/artifacts/\(entry.file)",
                                                    headers: ["range": "bytes=\(entry.bytes)-"]), remote: "127.0.0.1")
        expect(past.status == 416 && past.headers["Content-Range"] == "bytes */\(entry.bytes)",
               "RDL1 a range past the end is refused, never served as bytes")
    } catch { expect(false, "RDL1 resume: \(error)") }

    // RDL2: a dropped transfer keeps its partial; the retry asks only for the rest.
    do {
        let bytes = Data((0..<300_000).map { UInt8($0 % 233) })
        let installed = makeApp(tmpDir("resume-agent-app").appendingPathComponent("Demo.app"), version: "1.0.0")
        guard let f = resumeFixture("resume-agent", app: ["demo": AppConfig(bundlePath: installed.path, recipe: "fake-for-tests")],
                                    artifact: bytes) else { expect(false, "RDL2 fixture feed"); return }
        let part = f.dir.appendingPathComponent(f.file + ".part")
        try? fm.createDirectory(at: f.dir, withIntermediateDirectories: true)
        try? Data("old version".utf8).write(to: f.dir.appendingPathComponent("older.dmg.part"))
        f.client.dropAfter = 120_000
        let failed = try? Agent.runOnce(config: f.cfg, http: f.client, requested: ["demo"])
        let kept = (try? Data(contentsOf: part))?.count ?? 0
        expect(failed?.updates == 0 && kept == 120_000,
               "RDL2 a failed download keeps its partial file (\(kept) of \(bytes.count))")
        expect(!fm.fileExists(atPath: f.dir.appendingPathComponent(f.file).path),
               "RDL2 a failed download is never presented as a finished artifact")
        expect(!fm.fileExists(atPath: f.dir.appendingPathComponent("older.dmg.part").path),
               "RDL2 a partial for another artifact is retired, not resumed")
        let resumed = try? Agent.runOnce(config: f.cfg, http: f.client, requested: ["demo"])
        expect(f.client.starts == [0, 120_000],
               "RDL2 the retry resumes from where the transfer stopped (\(f.client.starts))")
        expect(resumed?.updates == 1 && (try? Data(contentsOf: f.dir.appendingPathComponent(f.file))) == bytes,
               "RDL2 the resumed download finishes and matches the signed bytes")
    }

    // RDL3: an install that fails (the app did not quit) is retried from the finished artifact.
    do {
        let rig = Rig("resume-install")
        let installed = makeApp(rig.root.appendingPathComponent("Kept.app"), version: "1.0.0")
        try rig.publish("kept", "2.0.0", rig.artifact("kept.dmg", "dmg bytes"), kind: "app-dmg",
                        hold: "http://127.0.0.1:8790/api/maintenance/hold")
        guard let feed = try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey),
              let entry = feed.apps["kept"] else { expect(false, "RDL3 fixture feed"); return }
        let token = (try? Enrolment.enrol(stateDir: rig.state, machine: "mac1")) ?? ""
        let mount = rig.root.appendingPathComponent("mount")
        makeApp(mount.appendingPathComponent("Kept.app"), version: "2.0.0")
        let shell = RecordingShell(mount: mount)
        let app = FakeApp(installed: installed, running: true, quits: [false], healthy: ["2.0.0"])
        let control: (String, AppConfig) -> AppControl = { _, _ in app.control }
        let client = ResumeHTTP(InProcessClient(server: rig.server))
        client.artifacts[entry.file] = try Data(contentsOf: rig.feed.appendingPathComponent("artifacts/\(entry.file)"))
        let cfg = agentConfig(rig, token: token, apps: ["kept": AppConfig(bundlePath: installed.path, recipe: "app-dmg", automatic: true)])
        let first = try? Agent.runOnce(config: cfg, http: client, shell: shell, control: control)
        expect(first?.updates == 0 && marker(installed) == "1.0.0" && client.starts.count == 1,
               "RDL3 an app that did not quit is kept and the failure is reported")
        app.quits = [true]
        let second = try? Agent.runOnce(config: cfg, http: client, shell: shell, control: control, requested: ["kept"])
        expect(second?.updates == 1 && marker(installed) == "2.0.0" && client.starts.count == 1,
               "RDL3 the retry installs from the finished artifact without downloading it again")
    } catch { expect(false, "RDL3 resume-install: \(error)") }

    // RDL4: Cancel is the one outcome that gives up the partial.
    do {
        let bytes = Data((0..<200_000).map { UInt8($0 % 217) })
        let installed = makeApp(tmpDir("resume-cancel-app").appendingPathComponent("Demo.app"), version: "1.0.0")
        guard let f = resumeFixture("resume-cancel", app: ["demo": AppConfig(bundlePath: installed.path, recipe: "fake-for-tests")],
                                    artifact: bytes) else { expect(false, "RDL4 fixture feed"); return }
        f.client.cancelNext = true
        _ = try? Agent.runOnce(config: f.cfg, http: f.client, requested: ["demo"])
        let parts = (try? fm.contentsOfDirectory(atPath: f.dir.path))?.filter { $0.hasSuffix(".part") } ?? []
        let trash = fm.enumerator(at: Trash.root(in: URL(fileURLWithPath: f.cfg.stateDir)), includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []
        expect(parts.isEmpty && trash.contains { $0.pathExtension == "part" },
               "RDL4 Cancel clears the partial file, and keeps it recoverable in _trash")
        DownloadControl.reset()
    }
}
