import Foundation

func withPauseFixture(_ body: (Rig) throws -> Void) rethrows {
    let rig = Rig("pause")
    defer {
        do { try fm.removeItem(at: rig.root) }
        catch { expect(false, "pause fixture teardown: \(error)") }
    }
    try body(rig)
}

func pauseFixtureCleanupTests() {
    enum FixtureFailure: Error { case expected }
    var roots: [URL] = []
    func populate(_ rig: Rig) throws {
        roots.append(rig.root)
        try Data("partial download".utf8).write(to: rig.root.appendingPathComponent("out.part"))
    }
    do {
        try withPauseFixture { rig in try populate(rig) }
        do {
            try withPauseFixture { rig in
                try populate(rig)
                throw FixtureFailure.expected
            }
            expect(false, "pause fixture propagates the test failure")
        } catch FixtureFailure.expected {}
        expect(roots.count == 2 && roots.allSatisfy { !fm.fileExists(atPath: $0.path) },
               "pause fixture leaves no temp directory after success or test failure")
    } catch {
        expect(false, "pause fixture cleanup regression: \(error)")
    }
}
