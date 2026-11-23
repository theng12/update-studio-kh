import Foundation

/// The floor between agent runs. Measured 2026-11-23: clearing a journal mid-cycle took this Mac
/// from 7 runs a minute to 90, same pid — the loop's wait returned the moment any state changed.
/// These checks hold the floor to one interval, whatever woke the loop, and keep a person's own
/// press immediate.
func runPacingTests() {
    let interval = 0.4

    // RP1. A journal cleared mid-wait (a state change) must not start the next run before the
    // interval. This is the measured defect, reproduced.
    do {
        let pacing = RunPacing()
        let journal = tmpDir("pacing-journal").appendingPathComponent("install-journal.json")
        try? #"{"app":"demo","status":"waitHealthy"}"#.write(to: journal, atomically: true, encoding: .utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            try? fm.removeItem(at: journal)
            pacing.wakeByState()
        }
        let start = Date()
        let woke = pacing.wait(interval: interval)
        let took = Date().timeIntervalSince(start)
        expect(!fm.fileExists(atPath: journal.path), "RP1 fixture cleared the journal while the agent waited")
        expect(woke == .interval && took >= interval - 0.05,
               "RP1 a journal cleared mid-wait starts the next run no sooner than the interval (woke \(String(format: "%.2f", took)) s into \(interval) s)")
    }

    // RP2. A burst of state changes is still exactly one interval, never one run per change.
    do {
        let pacing = RunPacing()
        for i in 0..<20 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02 * Double(i)) { pacing.wakeByState() }
        }
        let start = Date()
        _ = pacing.wait(interval: interval)
        let took = Date().timeIntervalSince(start)
        expect(took >= interval - 0.05,
               "RP2 twenty state changes never shorten the wait (\(String(format: "%.2f", took)) s)")
    }

    // RP3. A person's own press still runs at once: the floor is for state, not for the operator.
    do {
        let pacing = RunPacing()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { pacing.wakeByPerson() }
        let start = Date()
        let woke = pacing.wait(interval: interval)
        let took = Date().timeIntervalSince(start)
        expect(woke == .person && took < 0.2,
               "RP3 a person's press runs at once (\(String(format: "%.2f", took)) s)")
    }

    // RP4. A state wake and a person's press at the same moment leave nothing armed for the next
    // wait: the run after a person's press still waits out its interval.
    do {
        let pacing = RunPacing()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            pacing.wakeByState()
            pacing.wakeByPerson()
        }
        _ = pacing.wait(interval: interval)
        let start = Date()
        let woke = pacing.wait(interval: interval)
        let took = Date().timeIntervalSince(start)
        expect(woke == .interval && took >= interval - 0.05,
               "RP4 an absorbed wake is not scheduled twice (\(String(format: "%.2f", took)) s)")
    }
}
