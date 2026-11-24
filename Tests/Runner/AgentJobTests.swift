import Foundation

/// The agent's launchd job: a Mac whose job vanished must say so and repair itself from the kit the
/// app ships (measured 2026-11-23: the job was gone, nothing noticed, and a dead feed looked the same).
func agentJobTests() {
    let uid: uid_t = 501
    let printKey = "/bin/launchctl print gui/501/com.khupdater.agent"

    // AJ1 a loaded job needs nothing.
    do {
        let shell = FakeShell(responses: [printKey: ShellResult(exitCode: 0, stdout: "loaded", stderr: "")])
        let message = AgentJob.ensure(kit: tmpDir("job-kit-1"), home: tmpDir("job-home-1"), shell: shell, uid: uid)
        expect(message == nil, "AJ1 a loaded agent job needs no repair")
    }

    // AJ2 a missing job is reinstalled from the app's kit and started.
    do {
        let kit = tmpDir("job-kit-2"), home = tmpDir("job-home-2")
        try? "__HOME__/Library/KHUpdater/bin/khu-stub --base __HOME__/Library/KHUpdater/base"
            .write(to: kit.appendingPathComponent("com.khupdater.agent.plist"), atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: kit.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try? "#!/bin/sh\n".write(to: kit.appendingPathComponent("bin/khu-stub"), atomically: true, encoding: .utf8)
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.khupdater.agent.plist")
        let shell = FakeShell(responses: [
            printKey: ShellResult(exitCode: 113, stdout: "", stderr: "Could not find service"),
            "/bin/launchctl bootstrap gui/501 \(plist.path)": ShellResult(exitCode: 0, stdout: "", stderr: ""),
        ])
        let message = AgentJob.ensure(kit: kit, home: home, shell: shell, uid: uid)
        let written = (try? String(contentsOf: plist, encoding: .utf8)) ?? ""
        expect(message?.contains("reinstalled from the app's kit and started") == true,
               "AJ2 a missing job is reinstalled and started (\(message ?? "nil"))")
        expect(written.contains(home.path) && !written.contains("__HOME__"),
               "AJ2 the plist is written with this Mac's home")
        let copied = home.appendingPathComponent("Library/KHUpdater/bin/khu-stub")
        let mode = (try? fm.attributesOfItem(atPath: copied.path))?[.posixPermissions] as? NSNumber
        expect(mode?.intValue == 0o755, "AJ2 the kit's binary is copied back executable")
    }

    // AJ3 a repair that cannot start says why and never stops the app.
    do {
        let kit = tmpDir("job-kit-3"), home = tmpDir("job-home-3")
        try? "x".write(to: kit.appendingPathComponent("com.khupdater.agent.plist"), atomically: true, encoding: .utf8)
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.khupdater.agent.plist")
        let shell = FakeShell(responses: [
            printKey: ShellResult(exitCode: 113, stdout: "", stderr: ""),
            "/bin/launchctl bootstrap gui/501 \(plist.path)": ShellResult(exitCode: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error"),
        ])
        let message = AgentJob.ensure(kit: kit, home: home, shell: shell, uid: uid)
        expect(message?.contains("did not start") == true && message?.contains("Input/output error") == true,
               "AJ3 a refused bootstrap is named (\(message ?? "nil"))")
    }

    // AJ4 a kit with no plist is a stated limit, not a crash.
    do {
        let shell = FakeShell(responses: [printKey: ShellResult(exitCode: 113, stdout: "", stderr: "")])
        let message = AgentJob.ensure(kit: tmpDir("job-kit-4"), home: tmpDir("job-home-4"), shell: shell, uid: uid)
        expect(message?.contains("no com.khupdater.agent.plist") == true,
               "AJ4 a kit with no plist says so (\(message ?? "nil"))")
    }
}
