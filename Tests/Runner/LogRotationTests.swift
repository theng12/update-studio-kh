import Foundation

/// Rotating logs: three runs kept, a missing log safe, and verbosity changed without a rebuild.
func logRotationTests() {
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func logFile(_ folder: URL, _ generation: Int) -> URL {
        folder.appendingPathComponent(generation == 0 ? "agent.log" : "agent.\(generation).log")
    }

    // Three starts, one rotation each: this run and the two before it, oldest in .2.log.
    let runs = tmpDir("log-rotation-runs")
    for line in ["first run", "second run", "third run"] {
        AgentLog(name: "agent", in: runs, environment: [:]).record(line, at: .quiet)
    }
    expect(text(logFile(runs, 0)).contains("third run"), "LR1 this run is in agent.log")
    expect(text(logFile(runs, 1)).contains("second run"), "LR2 the previous run is in agent.1.log")
    expect(text(logFile(runs, 2)).contains("first run"), "LR3 the run before it is in agent.2.log")
    expect(!text(logFile(runs, 2)).contains("second run"), "LR4 the oldest file holds only that run")
    expect(!fm.fileExists(atPath: logFile(runs, 3).path), "LR5 no fourth generation sits beside the three")

    // A fourth start retires the oldest into _trash, never away.
    AgentLog(name: "agent", in: runs, environment: [:]).record("fourth run", at: .quiet)
    let trash = Trash.root(in: runs)
    let retired = ((try? fm.subpathsOfDirectory(atPath: trash.path)) ?? []).map { trash.appendingPathComponent($0) }
    expect(retired.contains { text($0).contains("first run") }, "LR6 the oldest run is restorable in _trash")
    expect(text(logFile(runs, 1)).contains("third run") && text(logFile(runs, 2)).contains("second run"),
           "LR7 the two previous runs survive the next start")

    // No file yet, and a missing older generation, are both safe.
    let missing = tmpDir("log-rotation-missing")
    _ = AgentLog(name: "agent", in: missing, environment: [:])
    expect(text(logFile(missing, 0)).isEmpty, "LR8 a missing log starts empty")
    expect(!fm.fileExists(atPath: logFile(missing, 1).path) && !fm.fileExists(atPath: logFile(missing, 2).path),
           "LR9 no older files are invented")
    try! "orphan run\n".write(to: logFile(missing, 0), atomically: true, encoding: .utf8)
    _ = AgentLog(name: "agent", in: missing, environment: [:])
    expect(text(logFile(missing, 1)).contains("orphan run"), "LR10 a present log rotates with no older file")
    expect(text(logFile(missing, 0)).isEmpty, "LR11 the new run starts with an empty log")

    // A fresh sink reading a changed environment records differently without a rebuild.
    let verbosity = tmpDir("log-rotation-verbosity")
    let quiet = AgentLog(name: "agent", in: verbosity, environment: ["KHU_LOG_VERBOSITY": "quiet"])
    quiet.record("qr-essential", at: .quiet)
    quiet.record("qr-usual", at: .normal)
    quiet.record("qr-detail", at: .verbose)
    let quietText = text(logFile(verbosity, 0))
    expect(quietText.contains("qr-essential") && !quietText.contains("qr-usual") && !quietText.contains("qr-detail"),
           "LR12 quiet records only essential lines")
    let verbose = AgentLog(name: "agent", in: verbosity, environment: ["KHU_LOG_VERBOSITY": "verbose"])
    verbose.record("vr-essential", at: .quiet)
    verbose.record("vr-usual", at: .normal)
    verbose.record("vr-detail", at: .verbose)
    let verboseText = text(logFile(verbosity, 0))
    expect(verboseText.contains("vr-essential") && verboseText.contains("vr-usual") && verboseText.contains("vr-detail"),
           "LR13 the next run records every level after the switch")
    expect(text(logFile(verbosity, 1)).contains("qr-essential") && !text(logFile(verbosity, 1)).contains("qr-detail"),
           "LR14 the earlier run keeps what its own verbosity wrote")

    // helper.json is the other source; the environment still wins when both name a value.
    let savedDir = tmpDir("log-rotation-settings")
    var settings = HelperSettings()
    settings.logVerbosity = "verbose"
    try! settings.save(to: savedDir)
    AgentLog(name: "agent", in: savedDir, environment: [:]).record("settings-detail", at: .verbose)
    expect(text(logFile(savedDir, 0)).contains("settings-detail"), "LR15 saved logVerbosity changes recording")
    AgentLog(name: "agent", in: savedDir, environment: ["KHU_LOG_VERBOSITY": "quiet"])
        .record("override-detail", at: .verbose)
    expect(!text(logFile(savedDir, 0)).contains("override-detail"), "LR16 the environment overrides saved settings")

    let defaultDir = tmpDir("log-rotation-default")
    let normal = AgentLog(name: "agent", in: defaultDir, environment: [:])
    normal.record("plain-usual", at: .normal)
    normal.record("plain-detail", at: .verbose)
    let defaultText = text(logFile(defaultDir, 0))
    expect(defaultText.contains("plain-usual") && !defaultText.contains("plain-detail"),
           "LR17 normal is the default")

    // A long operator sentence reaches the log whole. The 2026-11-19 sighting of a `…` at about 104
    // characters must never be the log's own doing: the file is where the instruction survives.
    let longDir = tmpDir("log-rotation-long")
    let sentence = "the saved address 100.82.91.102 is a bare IP, which macOS refuses for an unencrypted feed; use the publisher's host name instead"
    let long = sentence + String(repeating: " x", count: 40)
    AgentLog(name: "agent", in: longDir, environment: [:]).record(long, at: .quiet)
    let longText = text(logFile(longDir, 0))
    expect(long.count >= 200, "LR18 the fixture line is at least 200 characters (\(long.count))")
    expect(longText.contains(long), "LR19 a \(long.count)-character line is recorded whole")
    expect(!longText.contains("…"), "LR20 the log adds no ellipsis of its own")
}
