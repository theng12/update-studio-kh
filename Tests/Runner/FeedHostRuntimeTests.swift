import Foundation

/// Scripts launchctl so no test can reach the real gui domain: every call is recorded and
/// `print` answers from `loaded`, `bootstrap`/`bootout` from their scripted results.
private final class FeedHostShell: Shell, @unchecked Sendable {
    var calls: [String] = []
    var loaded = false
    var statusOutput = "state = running\n pid = 123\n"
    var bootstrap = ShellResult(exitCode: 0, stdout: "", stderr: "")
    var bootout = ShellResult(exitCode: 0, stdout: "", stderr: "")
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        calls.append(([executable] + arguments).joined(separator: " "))
        switch arguments.first {
        case "print":
            return ShellResult(exitCode: loaded ? 0 : 1, stdout: statusOutput,
                               stderr: loaded ? "" : "Could not find service \"\(arguments.last ?? "")\"")
        case "bootstrap":
            if bootstrap.exitCode == 0 { loaded = true }
            return bootstrap
        case "bootout":
            if bootout.exitCode == 0 { loaded = false }
            return bootout
        default: throw khuFail("feed-host fixture refused unexpected command: \(executable) \(arguments.joined(separator: " "))")
        }
    }
    func count(_ verb: String) -> Int { calls.filter { $0.contains(" \(verb) ") || $0.hasSuffix(" \(verb)") }.count }
    func call(_ verb: String) -> String? { calls.first { $0.contains(" \(verb) ") || $0.hasSuffix(" \(verb)") } }
}

private struct FeedHostFixture {
    let home: URL, state: URL, feed: URL, plist: URL, publisher: URL
    init(_ tag: String, mirror: Bool) {
        let root = tmpDir(tag)
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        feed = FeedHostRole.feedDirectory(in: state)
        if mirror {
            try! fm.createDirectory(at: feed, withIntermediateDirectories: true)
            try! "{\"schema\":1}".write(to: feed.appendingPathComponent("release.json"),
                                        atomically: true, encoding: .utf8)
        }
        plist = home.appendingPathComponent("Library/LaunchAgents/com.khupdater.feed-host.plist")
        publisher = home.appendingPathComponent("Library/LaunchAgents/com.khupdater.publisher.plist")
    }
}

func feedHostRuntimeTests() {
    let role = FeedHostRole(enabled: true, bind: "127.0.0.1", port: 8791)
    let executable = "/Users/tester/Library/KHUpdater/base/current"
    let domain = "gui/\(getuid())"

    do {
        let base = tmpDir("feedhost-executable")
        let layout = StubLayout(base: base)
        let binary = try layout.binary(for: "0.1.12")
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try StubSwitcher(layout: layout).install(version: "0.1.12")
        let path = FeedHostRuntime.executable(stubBase: base.path, fallback: "/unused")
        expect(path == binary.path && fm.isExecutableFile(atPath: path ?? ""),
               "FH0 host uses the executable current symlink, not current/khu")
        expect(!fm.isExecutableFile(atPath: layout.currentLink.appendingPathComponent("khu").path),
               "FH0 released current/khu path is not executable")
        expect(FeedHostRuntime.executable(stubBase: nil, fallback: binary.path) == binary.path,
               "FH0 non-supervised hosts keep their executable")
        expect(FeedHostRuntime.executable(stubBase: base.appendingPathComponent("missing").path, fallback: binary.path) == binary.path,
               "FH0 missing current falls back to the running executable")
        let directoryBase = tmpDir("feedhost-directory-current")
        try fm.createSymbolicLink(atPath: directoryBase.appendingPathComponent("current").path, withDestinationPath: binary.deletingLastPathComponent().path)
        expect(FeedHostRuntime.executable(stubBase: directoryBase.path, fallback: binary.path) == binary.path,
               "FH0 a directory current target falls back to the running executable")
        expect(FeedHostRuntime.executable(stubBase: nil, fallback: base.path) == nil,
               "FH0 directory executable is refused")
        expect(FeedHostRuntime.executable(stubBase: base.appendingPathComponent("missing").path, fallback: "/missing/khu") == nil,
               "FH0 no usable executable returns nil before installing a job")
    } catch { expect(false, "FH0 executable layout: \(error)") }

    // FH1: off is the default and must create, install and start nothing.
    do {
        let fx = FeedHostFixture("feedhost-off", mirror: false)
        let shell = FeedHostShell()
        _ = try FeedHostRuntime.reconcile(role: nil, stateDir: fx.state, executable: nil, shell: shell, home: fx.home)
        expect(shell.count("bootstrap") == 0 && shell.count("bootout") == 0,
               "FH1 a nil role neither bootstraps nor boots out anything")
        expect(!fm.fileExists(atPath: fx.plist.path), "FH1 a nil role writes no LaunchAgent")
        let off = FeedHostFixture("feedhost-disabled", mirror: false)
        let shell2 = FeedHostShell()
        _ = try FeedHostRuntime.reconcile(role: FeedHostRole(enabled: false, bind: "127.0.0.1", port: 8790),
                                          stateDir: off.state, executable: executable, shell: shell2, home: off.home)
        expect(shell2.count("bootstrap") == 0 && !fm.fileExists(atPath: off.plist.path),
               "FH1b a disabled role installs and starts nothing")
    } catch { expect(false, "FH1 reconcile threw: \(error)") }

    // FH2: enabled writes the exact feed-only arguments, no key, restrictive, and bootstraps once.
    do {
        let fx = FeedHostFixture("feedhost-on", mirror: true)
        let shell = FeedHostShell()
        _ = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                          shell: shell, home: fx.home)
        let data = try Data(contentsOf: fx.plist)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let args = plist["ProgramArguments"] as! [String]
        expect(args == [executable, "serve",
                        "--feed", fx.feed.path,
                        "--state", fx.state.appendingPathComponent("feed-host/server-state").path,
                        "--bind", "127.0.0.1", "--port", "8791", "--feed-only"],
               "FH2 the job runs serve --feed-only with the mirror, state, bind and port")
        let text = String(decoding: data, as: UTF8.self)
        expect(!args.contains("--key") && !text.contains("--key") && !text.contains("token")
               && !text.contains("private.key"),
               "FH2 the plist carries no key or token")
        expect(plist["Label"] as? String == "com.khupdater.feed-host"
               && plist["KeepAlive"] as? Bool == true && plist["RunAtLoad"] as? Bool == true,
               "FH2 the plist is the feed-host job with KeepAlive and RunAtLoad")
        let perms = (try fm.attributesOfItem(atPath: fx.plist.path)[.posixPermissions] as? NSNumber)?.intValue
        expect(perms == 0o600, "FH2 the plist is owner-only (0600)")
        expect(shell.call("bootstrap") == "/bin/launchctl bootstrap \(domain) \(fx.plist.path)",
               "FH2 bootstraps exactly once in this user's gui domain")
        expect(shell.count("bootout") == 0, "FH2 nothing is unloaded on a fresh install")
    } catch { expect(false, "FH2 reconcile threw: \(error)") }

    // FH2b: the local mirror must already hold release.json.
    do {
        let fx = FeedHostFixture("feedhost-nomirror", mirror: false)
        expectThrows("FH2b enabled without a local release.json is refused", contains: "release.json") {
            _ = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                              shell: FeedHostShell(), home: fx.home)
        }
        expect(!fm.fileExists(atPath: fx.plist.path), "FH2b nothing is installed when the mirror is empty")
    }

    // FH3: an already-correct job is left untouched — no rewrite, no reload.
    do {
        let fx = FeedHostFixture("feedhost-idem", mirror: true)
        let shell = FeedHostShell()
        _ = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                          shell: shell, home: fx.home)
        shell.loaded = true   // an earlier process already created the job
        let before = try Data(contentsOf: fx.plist)
        let bootstraps = shell.count("bootstrap")
        let bootouts = shell.count("bootout")
        let message = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                                    shell: shell, home: fx.home)
        expect(shell.count("bootstrap") == bootstraps && shell.count("bootout") == bootouts,
               "FH3 an unchanged loaded service is not bootstrapped or booted out again")
        let after = try Data(contentsOf: fx.plist)
        expect(after == before, "FH3 the plist is not rewritten")
        expect(message == "running (pid 123)", "FH3 reconcile reports the observed running process")
    } catch { expect(false, "FH3 reconcile threw: \(error)") }

    // FH4: off stops only this exact job and retires only its own plist.
    do {
        let fx = FeedHostFixture("feedhost-owned", mirror: false)
        try! fm.createDirectory(at: fx.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "<plist version=\"1.0\"></plist>".write(to: fx.plist, atomically: true, encoding: .utf8)
        try! "<plist version=\"1.0\"></plist>".write(to: fx.publisher, atomically: true, encoding: .utf8)
        let shell = FeedHostShell()
        shell.loaded = true
        _ = try FeedHostRuntime.reconcile(role: nil, stateDir: fx.state, executable: nil, shell: shell, home: fx.home)
        expect(shell.call("bootout") == "/bin/launchctl bootout \(domain)/com.khupdater.feed-host",
               "FH4 bootout names exactly the feed-host job")
        expect(!shell.calls.contains { $0.contains("com.khupdater.publisher") },
               "FH4 the publisher job is never probed or stopped")
        expect(shell.count("bootstrap") == 0, "FH4 stopping starts nothing")
        expect(!fm.fileExists(atPath: fx.plist.path), "FH4 the feed-host plist leaves LaunchAgents")
        expect(fm.fileExists(atPath: fx.publisher.path), "FH4 the publisher plist stays where it is")
    } catch { expect(false, "FH4 reconcile threw: \(error)") }

    // FH5: a refused bootstrap is reported once, loudly, with the install kept.
    do {
        let fx = FeedHostFixture("feedhost-refuse", mirror: true)
        let shell = FeedHostShell()
        shell.bootstrap = ShellResult(exitCode: 1, stdout: "",
                                      stderr: "Bootstrap failed: 130: Service cannot be loaded")
        expectThrows("FH5 a bootstrap refusal is thrown, not worked around", contains: "Service cannot be loaded") {
            _ = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                              shell: shell, home: fx.home)
        }
        expect(shell.count("bootstrap") == 1, "FH5 the refusal is not retried automatically")
        expect(fm.fileExists(atPath: fx.plist.path), "FH5 the written plist is kept for a manual retry")
    }

    // FH6: changed settings unload exactly the old job and reload it from the new plist.
    do {
        let fx = FeedHostFixture("feedhost-reload", mirror: true)
        let shell = FeedHostShell()
        _ = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                          shell: shell, home: fx.home)
        shell.loaded = true   // the job an earlier process created is still loaded
        let changed = FeedHostRole(enabled: true, bind: "127.0.0.1", port: 8799)
        _ = try FeedHostRuntime.reconcile(role: changed, stateDir: fx.state, executable: executable,
                                          shell: shell, home: fx.home)
        expect(shell.call("bootout") == "/bin/launchctl bootout \(domain)/com.khupdater.feed-host",
               "FH6 changed settings boot out exactly the feed-host job")
        expect(shell.count("bootstrap") == 2, "FH6 the job is bootstrapped again from the new plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: fx.plist), format: nil)
            as! [String: Any]
        expect((plist["ProgramArguments"] as! [String]).contains("8799"), "FH6 the new port reaches the plist")
    } catch { expect(false, "FH6 reconcile threw: \(error)") }

    do {
        let fx = FeedHostFixture("feedhost-exited", mirror: true)
        let shell = FeedHostShell()
        shell.statusOutput = "state = spawn scheduled\nlast exit code = 78\n"
        let first = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                                shell: shell, home: fx.home)
        expect(first == "not running (last exit 78)", "FH7 bootstrap acceptance does not claim a failed host is running")
        let again = try FeedHostRuntime.reconcile(role: role, stateDir: fx.state, executable: executable,
                                                shell: shell, home: fx.home)
        expect(again == first && shell.count("bootstrap") == 1, "FH7 loaded exited host stays failed without forced restart")
        shell.statusOutput = "state = waiting\n"
        expect(FeedHostRuntime.status(shell: shell) == "loaded; running not confirmed", "FH7 loaded job without a process stays unconfirmed")
        shell.statusOutput = "state = running\npid = 123\nlast exit code = 78\n"
        expect(FeedHostRuntime.status(shell: shell) == "running (pid 123)", "FH7 fresh running process supersedes historical exit")
        shell.loaded = false
        expect(FeedHostRuntime.status(shell: shell) == "unknown (launchd print exit 1)",
               "FH7 refused observation does not assert the job is absent")
        for status in [first, again, FeedHostRuntime.status(shell: shell)] {
            expect(FeedServer.reportRefusal(installed: nil, health: ["feed-host": status], defaults: nil) == nil,
                   "FH7 observed status fits the existing controller health bound")
        }
    } catch { expect(false, "FH7 observed status: \(error)") }
}
