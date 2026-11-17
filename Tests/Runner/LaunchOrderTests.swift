import Foundation

/// Remote launch: an owner's order starts an installed app on a Mac, hidden, and proves it is up.
func launchOrderTests() {
    func config(_ tag: String, bundle: String?, wait: Int? = nil) -> AgentConfig {
        var cfg = AgentConfig(feedURL: "http://127.0.0.1:8790/release.json", publicKey: "unused", stateDir: tmpDir(tag).path,
                              machine: "mac1", token: "t")
        if let bundle { cfg.apps["foo"] = AppConfig(bundlePath: bundle) }
        cfg.launchWaitSeconds = wait
        return cfg
    }

    // L1: an app with no configured path, or nothing at that path, is refused before anything opens.
    do {
        let shell = LaunchShell()
        let absent = tmpDir("launch-absent").appendingPathComponent("Foo.app").path
        let noEntry = Agent.launchOrdered(app: "foo", config: config("launch-noentry", bundle: nil), shell: shell)
        expect(noEntry.status == "failed" && (noEntry.reason ?? "").contains("no installed app path"),
               "L1 an app this Mac has no path for fails plainly (\(noEntry.reason ?? "nil"))")
        let missing = Agent.launchOrdered(app: "foo", config: config("launch-missing", bundle: absent), shell: shell)
        expect(missing.status == "failed" && (missing.reason ?? "").contains("not installed"),
               "L1 a missing bundle fails as not installed (\(missing.reason ?? "nil"))")
        expect(shell.opens == 0, "L1 nothing was opened for a path that is not there")
    }

    // L2: a bundle that does not verify is not opened.
    do {
        let dir = tmpDir("launch-unsigned")
        makeApp(dir.appendingPathComponent("Foo.app"), version: "2.0.0")
        let shell = LaunchShell(); shell.codesignExit = 1
        let res = Agent.launchOrdered(app: "foo", config: config("launch-unsigned-cfg", bundle: dir.appendingPathComponent("Foo.app").path), shell: shell)
        expect(res.status == "failed" && (res.reason ?? "").contains("signature"),
               "L2 an unverifiable bundle is refused with the reason (\(res.reason ?? "nil"))")
        expect(shell.opens == 0, "L2 an unverifiable bundle is never opened")
    }

    // L3: a bundle that verifies is opened hidden and detached, and the pid proves it started.
    do {
        let dir = tmpDir("launch-ok")
        let app = dir.appendingPathComponent("Foo.app")
        makeApp(app, version: "2.0.0")
        let shell = LaunchShell()
        var polls = 0
        let res = Agent.launchOrdered(app: "foo", config: config("launch-ok-cfg", bundle: app.path), shell: shell,
                                      processes: { _ in polls += 1; return polls >= 3 ? [4242] : [] },
                                      clock: { Mono.now() }, wait: 20)
        expect(res.status == "launched" && (res.reason ?? "").contains("pid 4242"),
               "L3 a launch that appears is reported launched with its pid (\(res.reason ?? "nil"))")
        expect(shell.calls.contains { $0 == "/usr/bin/open -g -j \(app.path)" },
               "L3 the app is opened with -g -j (hidden, never brought forward): \(shell.calls.filter { $0.contains("open") })")
        expect(!shell.calls.contains { $0.contains("/usr/bin/open -a") || $0.contains("activate") },
               "L3 nothing activates the app")
    }

    // L4: an app already running is reported with its pid and not opened a second time.
    do {
        let dir = tmpDir("launch-running")
        let app = dir.appendingPathComponent("Foo.app")
        makeApp(app, version: "2.0.0")
        let shell = LaunchShell()
        let res = Agent.launchOrdered(app: "foo", config: config("launch-running-cfg", bundle: app.path), shell: shell,
                                      processes: { _ in [77] })
        expect(res.status == "launched" && (res.reason ?? "").contains("already running (pid 77)"),
               "L4 an already-running app is reported with its pid (\(res.reason ?? "nil"))")
        expect(shell.opens == 0, "L4 no second open for an app that is already running")
    }

    // L5: a process that never appears ends failed, in words naming the ceiling and what open said.
    do {
        let dir = tmpDir("launch-never")
        let app = dir.appendingPathComponent("Foo.app")
        makeApp(app, version: "2.0.0")
        let shell = LaunchShell()
        var now: TimeInterval = 0
        let res = Agent.launchOrdered(app: "foo", config: config("launch-never-cfg", bundle: app.path), shell: shell,
                                      processes: { _ in [] }, clock: { now += 5; return now }, wait: 10)
        expect(res.status == "failed" && (res.reason ?? "").contains("did not start within 10 s"),
               "L5 an app that never appears ends failed with its own ceiling (\(res.reason ?? "nil"))")
        expect((res.reason ?? "").contains("open exited 0"),
               "L5 the failure says what open answered instead of guessing (\(res.reason ?? "nil"))")
    }

    // L6: the route queues a launch order through the same queue as an update — one fresh order,
    // a stale one replaced — and names it in the Mac's pending list.
    do {
        let r = R6Rig("launch-route")
        let body = JSON.encode(["machine": "mac1", "app": "foo"])
        let headers = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        func post() -> HTTPResponse {
            r.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-launch", headers: headers, body: body), remote: "127.0.0.1")
        }
        func pending() -> [ServerCommand] { (try? StateStore.load(from: r.rig.state))?.machines["mac1"]?.pending ?? [] }
        expect(post().status == 200, "L6 the owner can queue a launch")
        let first = pending()
        expect(first.count == 1 && first.first?.action == ServerCommand.launch,
               "L6 the queued order is a launch (\(first.map(\.action) ?? []))")
        _ = post()
        expect(pending().count == 1 && pending().first?.id == first.first?.id,
               "L6 a fresh duplicate is skipped, not queued twice")
        var stale = try! StateStore.load(from: r.rig.state)
        stale.machines["mac1"]?.pending = [ServerCommand(id: first[0].id, machine: "mac1", app: "foo",
                                                         createdAt: ISO.string(Date().addingTimeInterval(-40 * 60)),
                                                         action: ServerCommand.launch)]
        try! StateStore.save(stale, to: r.rig.state)
        _ = post()
        let replaced = pending()
        expect(replaced.count == 1 && replaced.first?.id != first[0].id,
               "L6 an order older than 30 minutes is replaced by the new one")
        // The route is same-site only, like every other owner order.
        let crossSite = r.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-launch",
                                                               headers: headers.merging(["origin": "http://evil.test"]) { _, b in b },
                                                               body: body), remote: "127.0.0.1")
        expect(crossSite.status == 403, "L6 a cross-site launch request is refused")
    }

    // L7: a launch is withheld from an agent that has not said it understands one.
    do {
        let r = R6Rig("launch-gating")
        let body = JSON.encode(["machine": "mac1", "app": "foo"])
        _ = r.rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/request-launch",
            headers: ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"],
            body: body), remote: "127.0.0.1")
        func orders(_ query: String) -> CommandsReply? {
            let response = r.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/commands?machine=mac1\(query)",
                headers: ["authorization": "Bearer \(r.config.token)"]), remote: "100.64.0.9")
            let signed = try? JSON.decode(SignedReply.self, from: response.data)
            guard let data = signed?.replyData, let sig = signed?.signatureData,
                  Signing.verify(data, signature: sig, publicKey: r.rig.pair.privateKey.publicKey) else { return nil }
            return try? JSON.decode(CommandsReply.self, from: data)
        }
        expect(orders("")?.commands.isEmpty == true,
               "L7 a launch order is not delivered to an agent that does not advertise launch-v1")
        expect(orders("&capabilities=owner-rollback-v1,launch-v1")?.commands.first?.action == "launch",
               "L7 a launch order is delivered to an agent that advertises it")
        // The page offers Launch for an app this Mac has reported installed, and not while a launch
        // is already queued: an app it has never reported is "not checked", not launchable.
        var state = try! StateStore.load(from: r.rig.state)
        state.machines["mac1"]?.installed = ["foo": "2.0.0"]
        state.machines["mac1"]?.pending = []
        // A Mac that has never reported shows only its orders: the page lists what it reported.
        state.machines["mac1"]?.lastSeen = ISO.string(Date())
        try! StateStore.save(state, to: r.rig.state)
        let page = r.rig.server.handleRequest(HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1:8790"]), remote: "127.0.0.1")
        let html = String(data: page.data, encoding: .utf8) ?? ""
        expect(html.contains("action=/api/request-launch") && html.contains("Launch"),
               "L7 the page offers one Launch button for the Mac and app")
    }

    // L8: an owner's launch order reaches the Mac's own launch path and its outcome is reported.
    do {
        let r = R6Rig("launch-run")
        r.order(ServerCommand.launch)
        let shell = LaunchShell()
        let result = try? Agent.runOnce(config: { var c = r.config; c.launchWaitSeconds = 1; return c }(),
                                        http: r.client, shell: shell, control: { _, _ in r.control })
        let status = try? StateStore.load(from: r.rig.state)
        let done = status?.machines["mac1"]?.lastResults?["foo"]?.status
        expect(shell.opens == 1, "L8 the Mac opened the app once for the owner's launch order (opens \(shell.opens))")
        expect(done == "failed" || done == "launched",
               "L8 the launch order's outcome is reported back (got \(done ?? "nil"), run notes \(result?.notes ?? []))")
        expect((try? StateStore.load(from: r.rig.state))?.machines["mac1"]?.pending.isEmpty == true,
               "L8 the order does not stay pending after its result")
    }

    // L9: the wait ceiling is the default unless the setting is a positive number; a typo is not
    // a 1 s window that would report a slow start as a failure.
    do {
        expect(Agent.launchWait(config("launch-wait-unset", bundle: nil)) == Agent.launchWaitSeconds,
               "L9 no setting uses the 30 s default")
        expect(Agent.launchWait(config("launch-wait-negative", bundle: nil, wait: -30)) == Agent.launchWaitSeconds,
               "L9 a negative setting is read as unset, not as 1 s")
        expect(Agent.launchWait(config("launch-wait-set", bundle: nil, wait: 7)) == 7,
               "L9 a positive setting is used as given")
    }
}
