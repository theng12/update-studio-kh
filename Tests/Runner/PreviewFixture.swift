import Foundation
import Darwin

// Exercise the real pairing handler over loopback, with a synthetic tailnet publisher identity.
// No real tailnet listener, owner state, launchd job or signing material is used.
func serveNativePreview(record: String) {
    let fields = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: record))) as! [String: String]
    let root = URL(fileURLWithPath: fields["root"]!).resolvingSymlinksInPath()
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    precondition(root.lastPathComponent.hasPrefix("khu-test-toolbar-preview-") && root.path.hasPrefix(temporary.path + "/"))
    for field in ["feed", "state", "testKey"] {
        precondition(URL(fileURLWithPath: fields[field]!).resolvingSymlinksInPath().path.hasPrefix(root.path + "/"))
    }
    let feed = URL(fileURLWithPath: fields["feed"]!), state = URL(fileURLWithPath: fields["state"]!)
    let key = try! Signing.loadPrivateKey(from: URL(fileURLWithPath: fields["testKey"]!))
    let recovery = ProcessInfo.processInfo.environment["KHU_NATIVE_RECOVERY_FIXTURE"] == "1"
    let port = recovery ? 8809 : 8808
    let router = FeedServer(feedDir: feed, stateDir: state, bind: "100.64.0.9", port: port, commandKey: key)
    let listener = FeedServer(feedDir: feed, stateDir: state, bind: "127.0.0.1", port: port)
    let socket = try! listener.listen()
    print("Isolated native pairing fixture listening on loopback:\(port)")
    while true {
        let client = accept(socket, nil, nil)
        guard client >= 0 else { continue }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        if let bytes = HTTP.readRequest(from: client), let request = HTTP.parse(bytes) {
            var response = router.handleRequest(request, remote: "127.0.0.1")
            if recovery, request.path == "/enrol", response.status == 200 {
                // Test transport only: keep recovery traffic on loopback, signed by this temporary fixture's key.
                let signed = try! JSON.decode(SignedReply.self, from: response.data)
                var reply = try! JSON.decode(EnrolReply.self, from: signed.replyData!)
                reply.feedURL = "http://127.0.0.1:\(port)/release.json"
                let body = JSON.encode(reply)
                response = HTTPResponse(200, "application/json", data: JSON.encode(SignedReply(reply: body, signature: try! Signing.sign(body, with: key))))
            }
            HTTP.send(client, response)
        }
        close(client)
    }
}

// Isolated publisher data for actual UI checks; no owner's state or key is read.
func makePreviewFixture(record: String) {
    let rig = Rig("toolbar-preview")
    try! rig.publish("demo", "2.0", rig.artifact("demo.zip", "isolated preview; not an installer"))
    for index in 1...8 {
        let machine = "preview-mac-\(index)"
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: machine)
        let body: [String: Any] = ["machine": machine, "display_name": "TEST Mac \(index)",
                                    "installed": ["demo": index < 4 ? "1.0" : "2.0"], "automatic_default": ["demo": false]]
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status", headers: ["authorization": "Bearer \(token)"],
                                                 body: try! JSONSerialization.data(withJSONObject: body)), remote: "100.64.0.9")
    }
    try! StateStore.update(in: rig.state) { state in
        state.machines["preview-mac-1"]?.pending.append(ServerCommand(machine: "preview-mac-1", app: "demo", action: ServerCommand.update))
        state.machines["preview-mac-8"]?.lastSeen = ISO.string(Date().addingTimeInterval(-3600))
    }
    try! Enrolment.ensurePairingCode(stateDir: rig.state)
    let fields = ["root": rig.root.path, "feed": rig.feed.path, "state": rig.state.path, "testKey": rig.key.path]
    try! JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: record), options: .atomic)
    print("Isolated UI fixture prepared")
}
