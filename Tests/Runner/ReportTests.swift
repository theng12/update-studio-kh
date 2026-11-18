import Foundation

/// RS: a switch is judged by reports, not by the process — and a failed check is never silence.
///
/// 15 Macs stayed quiet for 9.5 h after a 0.1.56 switch with a live, beating helper: the heartbeat
/// proved the process ran, and nothing proved it reached the publisher. These are the two halves of
/// that gap: the report the helper leaves, and the rollback the stub may key on it.
func reportTests() {
    let now = Date()
    func supervisor(_ policy: StubPolicy) -> StubSupervisor {
        var s = StubSupervisor(policy: policy)
        s.recordSwitch(at: now, target: "0.1.56")
        s.recordHeartbeat(at: now.addingTimeInterval(1), now: now.addingTimeInterval(2))
        return s
    }
    let policy = StubPolicy(reportGrace: 900, reportedRecently: 3600)
    func reason(_ decision: StubDecision) -> String? {
        if case .switchBack(let why) = decision { return why }
        return nil
    }

    // RS1 this Mac reported until the switch, then nothing: the new version is rolled back, by name.
    do {
        let report = AgentReport(kind: "unreachable", reason: "no answer from the publisher",
                                 at: ISO.string(now.addingTimeInterval(890)),
                                 lastOkAt: ISO.string(now.addingTimeInterval(-300)))
        let why = reason(supervisor(policy).decide(at: now.addingTimeInterval(901), report: report))
        expect(why != nil && why!.contains("no check was accepted"),
               "RS1 a silently failing switch is rolled back with its reason (\(why ?? "kept running"))")
    }
    // RS2 inside the grace it is left alone: a check every five minutes needs time to arrive.
    do {
        let report = AgentReport(kind: "unreachable", at: ISO.string(now.addingTimeInterval(600)),
                                 lastOkAt: ISO.string(now.addingTimeInterval(-300)))
        expect(reason(supervisor(policy).decide(at: now.addingTimeInterval(601), report: report)) == nil,
               "RS2 a switch is not rolled back before its report window")
    }
    // RS3 a Mac that was already silent before the switch is never rolled back for staying silent:
    // it is offline, and ping-ponging versions would not bring the publisher back.
    do {
        let report = AgentReport(kind: "unreachable", at: ISO.string(now.addingTimeInterval(890)),
                                 lastOkAt: ISO.string(now.addingTimeInterval(-7200)))
        expect(reason(supervisor(policy).decide(at: now.addingTimeInterval(901), report: report)) == nil,
               "RS3 a Mac that was already silent keeps the new version")
    }
    // RS4 one accepted check after the switch settles the question for good.
    do {
        let report = AgentReport(kind: "unreachable", at: ISO.string(now.addingTimeInterval(890)),
                                 lastOkAt: ISO.string(now.addingTimeInterval(120)))
        expect(reason(supervisor(policy).decide(at: now.addingTimeInterval(901), report: report)) == nil,
               "RS4 a version that has reported since the switch keeps its place")
    }
    // RS5 never silence: a failure keeps the last accepted time and records why it stopped.
    do {
        let state = tmpDir("report-store")
        AgentReport.record(kind: "ok", reason: nil, stateDir: state, now: now.addingTimeInterval(-300))
        let ok = AgentReport.read(stateDir: state)
        expect(ok?.kind == "ok" && ok?.lastOkAt != nil, "RS5 an accepted check records when it was accepted")
        AgentReport.record(kind: "error", reason: "the feed address did not answer", stateDir: state, now: now)
        let failed = AgentReport.read(stateDir: state)
        expect(failed?.kind == "error" && failed?.reason?.contains("did not answer") == true,
               "RS5 a failed check records its reason (\(failed?.reason ?? "none"))")
        expect(failed?.lastOkAt == ok?.lastOkAt,
               "RS5 a failed check keeps the last accepted time, so the Mac reads as 'last checked' not vanished")
    }
    // RS6 the same Mac recovers by itself when the address answers again: the next accepted check
    // replaces the failure, with no hand step (the 1409 Mac needed one today).
    do {
        let state = tmpDir("report-recover")
        AgentReport.record(kind: "error", reason: "unreachable", stateDir: state, now: now.addingTimeInterval(-600))
        AgentReport.record(kind: "ok", reason: nil, stateDir: state, now: now)
        let after = AgentReport.read(stateDir: state)
        expect(after?.kind == "ok" && after?.reason == nil && after?.lastOkAt == ISO.string(now),
               "RS6 a check that answers again clears the failure by itself")
    }
}
