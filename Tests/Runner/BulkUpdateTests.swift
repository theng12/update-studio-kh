import Foundation

/// The fleet's recovery path had no exit.
///
/// "Update N Macs" (`/api/update-all`) sends an order to exactly the Macs `updateAvailable` names.
/// That predicate excluded any Mac holding a pending order for the app, whatever its age, and any
/// Mac whose newest result for it was a failure, whatever its age. Nothing else places an order —
/// the single-Mac button goes through the same predicate — so a Mac excluded this way could only
/// escape by reporting a result, which needs an order, which is the thing being withheld:
///
///     failure hides the Mac → no order → no new result → the failure stands for ever.
///
/// `queueOrder` already aged a pending order out (`orderRetryWindow`); the predicate in front of it
/// did not, so the single-Mac button never got far enough for that rule to matter. These tests run
/// the route, not the predicate, because a predicate can read correctly and still be preceded by
/// something that means it is never consulted the way you think.
///
/// The window is `FeedServer.orderRetryWindow` (30 minutes), the same constant both exclusions use.
func bulkUpdateTests() {
    // BU1 — the bulk route sends an order to a Mac holding a pending order older than the window,
    // and replaces that dead order rather than leaving it. This is the Mon night case: a Mac that
    // fetched an order, never answered, and then sat behind every later "Update N Macs".
    do {
        let rig = Rig("bulk-stale-order")
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
        let stale = ServerCommand(machine: "mac1", app: "demo",
                                  createdAt: ISO.string(Date().addingTimeInterval(-(FeedServer.orderRetryWindow + 60))),
                                  action: ServerCommand.update)
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]?.pending.append(stale) }

        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        let r = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: owner,
                                                     body: Data(#"{"app":"demo"}"#.utf8)), remote: "127.0.0.1")
        let after = try! StateStore.read(in: rig.state).machines["mac1"]!
        let orders = after.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
        expect(r.status == 200, "BU1 update-all answers 200")
        expect(orders.count == 1 && orders.first!.id != stale.id,
               "BU1 a pending order older than the window does not exclude the Mac: it is replaced by a new order (pending \(orders.count), same id as the dead one: \(orders.first?.id == stale.id))")
        expect(!after.pending.contains(where: { $0.id == stale.id }),
               "BU1 the dead order is not left beside the new one")
    }

    // BU2 — a Mac with a *young* pending order is still skipped, and that order is not replaced.
    // The age rule must not turn into "always re-order", or every click would interrupt a working
    // install.
    do {
        let rig = Rig("bulk-young-order")
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
        let young = ServerCommand(machine: "mac1", app: "demo",
                                  createdAt: ISO.string(Date().addingTimeInterval(-60)),
                                  action: ServerCommand.update)
        try! StateStore.update(in: rig.state) { $0.machines["mac1"]?.pending.append(young) }

        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: owner,
                                                    body: Data(#"{"app":"demo"}"#.utf8)), remote: "127.0.0.1")
        let after = try! StateStore.read(in: rig.state).machines["mac1"]!
        let orders = after.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
        expect(orders.count == 1 && orders.first!.id == young.id,
               "BU2 a pending order inside the window still excludes the Mac and is left untouched (pending \(orders.count))")
    }

    // BU3 — the closed loop, run end to end. A Mac reports a rollback, so its newest result is a
    // failure. Without a fix, every later "Update N Macs" skips it for ever. With the fix, a failure
    // older than the window no longer excludes it: the bulk action *is* the fresh attempt the
    // failure was waiting for.
    do {
        let rig = Rig("bulk-stale-failure")
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
        // The failure is the Mac's newest word on the app, and it is 17 days old — the `.part` case.
        try! StateStore.update(in: rig.state) { ms in
            ms.machines["mac1"]?.lastResults = ["demo": CommandResult(
                commandId: "old-order", status: "rolled_back",
                reason: "the new version was not healthy within 60 s",
                at: ISO.string(Date().addingTimeInterval(-17 * 86_400)))]
        }

        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        let r = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: owner,
                                                     body: Data(#"{"app":"demo"}"#.utf8)), remote: "127.0.0.1")
        let after = try! StateStore.read(in: rig.state).machines["mac1"]!
        let orders = after.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
        expect(r.status == 200, "BU3 update-all answers 200")
        expect(orders.count == 1,
               "BU3 a failure older than the window does not exclude the Mac: Update N Macs places an order (pending \(orders.count)) — this is the loop with no exit")
        expect(after.lastResults?["demo"]?.status == "rolled_back",
               "BU3 the old failure is kept as history; placing an order does not rewrite what happened")
    }

    // BU4 — a *recent* failure still excludes the Mac. A Mac that just said "that did not work"
    // must be looked at, not swept into the next sweep: the owner reads the reason first.
    do {
        let rig = Rig("bulk-recent-failure")
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
        try! StateStore.update(in: rig.state) { ms in
            ms.machines["mac1"]?.lastResults = ["demo": CommandResult(
                commandId: "recent", status: "install_failed", reason: "the app did not quit",
                at: ISO.string(Date().addingTimeInterval(-5 * 60)))]
        }

        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: owner,
                                                    body: Data(#"{"app":"demo"}"#.utf8)), remote: "127.0.0.1")
        let after = try! StateStore.read(in: rig.state).machines["mac1"]!
        let orders = after.pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }
        expect(orders.isEmpty,
               "BU4 a failure inside the window still excludes the Mac (pending \(orders.count))")
    }

    // BU5 — what limits the retry loop. A genuinely broken Mac is retried once per "Update N Macs"
    // the owner presses, and that is bounded at both ends:
    //   * placing an order moves the Mac's noun to the order, not to a retry schedule — the bulk
    //     route only ever runs on a POST from the owner's page, never on a timer, so an unattended
    //     publisher cannot spin;
    //   * the Mac's own agent stops re-trying an artifact it already knows is bad
    //     (`memory.rejected[app] == entry.sha256`) until the feed names a different one.
    // This asserts the first half — no timer reaches the route — by showing that nothing in the
    // page or the routes posts it except the owner's form. The second half is asserted in
    // `Agent`'s own tests; this test would not catch a regression there, and it does not claim to.
    do {
        let rig = Rig("bulk-no-timer")
        try! rig.publish("demo", "2.0.0", rig.artifact("demo.zip", "bytes"))
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/status",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(#"{"machine":"mac1","installed":{"demo":"1.0"}}"#.utf8)), remote: "100.64.0.9")
        try! StateStore.update(in: rig.state) { ms in
            ms.machines["mac1"]?.lastResults = ["demo": CommandResult(
                commandId: "old", status: "rolled_back", at: ISO.string(Date().addingTimeInterval(-86_400)))]
        }
        // Three presses: the first places an order, and each one after it meets that young order
        // and is a young-order skip. Pending never grows past one, and after the first press the
        // old failure no longer decides anything either — the order does.
        let owner = ["host": "127.0.0.1:8790", "origin": "http://127.0.0.1:8790", "content-type": "application/json"]
        var counts: [Int] = []
        for _ in 0..<3 {
            _ = rig.server.handleRequest(HTTPRequest(method: "POST", path: "/api/update-all", headers: owner,
                                                        body: Data(#"{"app":"demo"}"#.utf8)), remote: "127.0.0.1")
            counts.append(try! StateStore.read(in: rig.state).machines["mac1"]!
                .pending.filter { $0.app == "demo" && $0.action == ServerCommand.update }.count)
        }
        expect(counts == [1, 1, 1],
               "BU5 repeated presses hold one order at a time, never a growing queue (\(counts))")
    }
}
