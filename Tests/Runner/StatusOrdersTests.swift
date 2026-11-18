import Foundation

/// A publisher that records any separate orders request and refuses it, so a test can prove the
/// 0.1.61 Mac never makes it.
final class NoSeparateOrdersClient: HTTPClient, @unchecked Sendable {
    private let inner: InProcessClient
    private let lock = NSLock()
    private var asks = 0
    var commandsAsked: Int { lock.lock(); defer { lock.unlock() }; return asks }
    init(_ inner: InProcessClient) { self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        if url.path == "/commands" {
            lock.lock(); asks += 1; lock.unlock()
            return (Data(), 500)
        }
        return try inner.get(url, headers: headers)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        try inner.download(url, headers: headers, to: file, limit: limit)
    }
}

/// 0.1.61: the orders ride in the status reply, so an idle run is two transfers — the feed and the
/// status report — instead of three. The old `/commands` route still answers an older agent.
func statusOrdersTests() {
    let caps = AgentCapability.all.joined(separator: ",")

    // SO1: the status reply carries the Mac's order(s), signed by the publisher's key.
    do {
        let rig = Rig("status-orders")
        try rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        try StateStore.update(in: rig.state) { state in
            state.machines["mac1"]?.pending.append(ServerCommand(machine: "mac1", app: "demo", action: ServerCommand.update))
        }
        let response = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","capabilities":"\#(caps)"}"#.utf8)), remote: "100.64.0.9")
        expect(response.status == 200, "SO1 status answers 200")
        let envelope = try? JSON.decode(SignedReply.self, from: response.data)
        let verified = envelope.flatMap { signed in
            signed.replyData.flatMap { body in
                Signing.verify(body, signature: signed.signatureData ?? Data(), publicKey: rig.pair.privateKey.publicKey)
                    ? try? JSON.decode(CommandsReply.self, from: body) : nil
            }
        }
        expect(verified?.machine == "mac1" && verified?.commands.map(\.app) == ["demo"],
               "SO1 the status reply carries this Mac's signed order")
        let still = try? StateStore.read(in: rig.state).machines["mac1"]
        expect(still?.pending.count == 1, "SO1 the order stays pending until its result is reported")
    } catch { expect(false, "SO1 status orders: \(error)") }

    // SO2: a client that never asks for orders separately still updates, and asks no /commands.
    do {
        let rig = Rig("status-skips-orders")
        try rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        try StateStore.update(in: rig.state) { state in
            state.machines["mac1"]?.pending.append(ServerCommand(machine: "mac1", app: "demo", action: ServerCommand.update))
        }
        let appPath = makeApp(rig.root.appendingPathComponent("OQApp.app"), version: "1.0")
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: appPath.path, recipe: "fake-for-tests")])
        let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
        let client = NoSeparateOrdersClient(InProcessClient(server: rig.server))
        var run: AgentRunResult?
        var threw: String?
        do {
            run = try Agent.runOnce(config: cfg, http: client, shell: RecordingShell(mount: rig.root),
                                    control: { _, _ in quiet }, appFolders: [])
        } catch {
            threw = "\(error)"
        }
        expect(run?.updates == 1 && client.commandsAsked == 0,
               "SO2 the status reply's order updates the app with no separate orders request (updates \(run?.updates ?? -1), asked \(client.commandsAsked); threw: \(threw ?? "nothing"); notes \(run?.notes ?? []))")
        let after = try? StateStore.read(in: rig.state).machines["mac1"]
        expect(after?.pending.isEmpty == true, "SO2 the order is cleared after the agent reports it")
    } catch { expect(false, "SO2 skips the orders call: \(error)") }

    // SO3: an older agent's own orders request still answers, signed and with its order.
    do {
        let rig = Rig("status-legacy-orders")
        try rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        try StateStore.update(in: rig.state) { state in
            state.machines["mac1"]?.pending.append(ServerCommand(machine: "mac1", app: "demo", action: ServerCommand.update))
        }
        var request = HTTPRequest(method: "GET", path: "/commands", headers: ["authorization": "Bearer \(token)"])
        request.query = ["machine": "mac1"]
        let response = rig.server.handleRequest(request, remote: "100.64.0.9")
        let envelope = try? JSON.decode(SignedReply.self, from: response.data)
        let verified = envelope.flatMap { signed in
            signed.replyData.flatMap { body in
                Signing.verify(body, signature: signed.signatureData ?? Data(), publicKey: rig.pair.privateKey.publicKey)
                    ? try? JSON.decode(CommandsReply.self, from: body) : nil
            }
        }
        expect(response.status == 200 && verified?.commands.map(\.app) == ["demo"],
               "SO3 an old-style orders request still answers with the order")
    } catch { expect(false, "SO3 legacy orders: \(error)") }

    // SO4: an older publisher's plain `{}` status answer is not mistaken for orders; the Mac asks
    // /commands as it always did, and that answer still runs its order.
    do {
        let rig = Rig("status-old-publisher")
        try rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        try StateStore.update(in: rig.state) { state in
            state.machines["mac1"]?.pending.append(ServerCommand(machine: "mac1", app: "demo", action: ServerCommand.update))
        }
        let appPath = makeApp(rig.root.appendingPathComponent("Old.app"), version: "1.0")
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: appPath.path, recipe: "fake-for-tests")])
        let quiet = AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
        // The status route answers `{}`; everything else is the real server.
        final class PlainStatusClient: HTTPClient, @unchecked Sendable {
            let inner: InProcessClient
            private let lock = NSLock()
            private var commands = 0
            var commandsAsked: Int { lock.lock(); defer { lock.unlock() }; return commands }
            init(_ inner: InProcessClient) { self.inner = inner }
            func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
                if url.path == "/commands" { lock.lock(); commands += 1; lock.unlock() }
                return try inner.get(url, headers: headers)
            }
            func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
                if url.path == "/status" { return (Data("{}".utf8), 200) }
                return try inner.post(url, headers: headers, body: body)
            }
            func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
                try inner.download(url, headers: headers, to: file, limit: limit)
            }
        }
        let client = PlainStatusClient(InProcessClient(server: rig.server))
        let run = try? Agent.runOnce(config: cfg, http: client, shell: RecordingShell(mount: rig.root),
                                     control: { _, _ in quiet }, appFolders: [])
        expect(run?.updates == 1 && client.commandsAsked == 1,
               "SO4 a plain status answer falls back to the orders request and still updates (updates \(run?.updates ?? -1), asked \(client.commandsAsked))")
    } catch { expect(false, "SO4 old publisher: \(error)") }
}
