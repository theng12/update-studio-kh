import Foundation

func helperRetirementTests() {
    let root = tmpDir("helper-retirement")
    defer { try? fm.removeItem(at: root) }
    let layout = StubLayout(base: root.appendingPathComponent("base"))
    let state = root.appendingPathComponent("state")
    let start = Date(timeIntervalSince1970: 1_900_000_000)
    do {
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        for version in ["0.1.8", "0.1.9", "0.1.10", "0.1.11", "0.1.12", "notes"] {
            let binary = try layout.binary(for: version)
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: layout.versionsDirectory.appendingPathComponent("0.1.7"), withDestinationURL: outside)
        try StubSwitcher(layout: layout).install(version: "0.1.10", at: start)
        try StubSwitcher(layout: layout).install(version: "0.1.11", at: start)
        let current = try layout.binary(for: "0.1.11")
        func observe(_ seconds: TimeInterval, nonce: String = "child-a", probation: Bool = false, stale: Bool = false, gap: TimeInterval = 400) throws -> [String] {
            let now = start.addingTimeInterval(seconds)
            try AtomicFile.writeJSON(StubState(switched_at: probation ? ISO.string(now) : nil, target: current.path), to: layout.stateFile)
            try writeHeartbeat(to: layout.heartbeatFile, at: now.addingTimeInterval(stale ? -100 : 0), version: "0.1.11", pid: 123, nonce: nonce)
            return try HelperRetirement.observe(layout: layout, stateDir: state, executable: current, now: now, maximumReportGap: gap, pid: 123)
        }
        expect(try HelperRetirementSettings.load(from: state).enabled, "helper retirement defaults on")
        expect(try observe(0).isEmpty && observe(299).isEmpty, "helper retirement waits for configured sustained health")
        let retired = try observe(300)
        expect(retired == ["0.1.8", "0.1.9"], "helper retirement moves only older unprotected versions")
        expect(try layout.currentBinary() == current && layout.previousBinary() == layout.binary(for: "0.1.10"), "helper retirement preserves current and previous fallback")
        expect(fm.fileExists(atPath: (try layout.binary(for: "0.1.12")).path) && fm.fileExists(atPath: outside.path), "helper retirement keeps future versions and symlink targets")
        let trash = FileManager.default.enumerator(at: layout.trash, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        expect(trash.contains { $0.path.hasSuffix("0.1.8/khu") } && trash.contains { $0.path.hasSuffix("0.1.9/khu") }, "retired helper binaries remain restorable in _trash")
        let old = try layout.binary(for: "0.1.6")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: old)
        var settings = try HelperRetirementSettings.load(from: state)
        settings.enabled = false
        try settings.save(to: state)
        expect(try observe(600).isEmpty && fm.fileExists(atPath: old.path), "disabled helper cleanup preserves older versions")
        settings.enabled = true
        try settings.save(to: state)
        _ = try observe(700)
        expect(try observe(1001, nonce: "new-child").isEmpty, "helper restart resets sustained health")
        expect(try observe(1402, nonce: "new-child", gap: 400).isEmpty, "missing reports reset sustained health")
        expect(try observe(1800, probation: true).isEmpty, "helper probation never retires fallback versions")
        _ = try observe(1900)
        expect(try observe(2200, stale: true).isEmpty && fm.fileExists(atPath: old.path), "stale heartbeat prevents helper retirement")
        settings.healthySeconds = 10
        try settings.save(to: state)
        _ = try observe(2300)
        expect(try observe(2310) == ["0.1.6"], "helper cleanup uses configured health duration")
        settings.healthySeconds = 0
        expectThrows("helper cleanup refuses invalid health duration") { try settings.save(to: state) }
    } catch { expect(false, "helper retirement regression: \(error)") }
}
