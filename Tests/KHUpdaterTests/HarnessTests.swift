import XCTest

/// The project's suite is `./build.sh test`: it compiles `Tests/Runner/*.swift` into
/// `build/khu-tests` with `-D KHU_TESTS` and runs it. That harness is not XCTest, so this target
/// exists only to make `swift test` honest — measured 2026-11-23, `swift test` died before running
/// anything ("target at …/Tests contains mixed language source files") because the declared target
/// had no path, and a person with no history concludes the tests are broken rather than the target.
final class HarnessTests: XCTestCase {
    func testProjectSuitePasses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KHUpdaterTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let binary = root.appendingPathComponent("build/khu-tests")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("build/khu-tests is missing: the suite is built and run by ./build.sh test. This target only re-runs that binary; it does not replace it.")
            return
        }
        let run = Process()
        run.executableURL = binary
        try run.run()
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, "the project suite (build/khu-tests) failed; read its output above")
    }
}
