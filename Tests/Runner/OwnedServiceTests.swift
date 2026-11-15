import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Answers `launchctl list` from the fixture's helper process, and records every call. Nothing here
/// reaches the real gui domain.
private final class LaunchdShell: Shell, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    var list: () -> String = { "" }
    var bootoutExit: Int32 = 0
    var bootstrapExit: Int32 = 0
    var kickstartExit: Int32 = 0
    var onBootout: (() -> Void)?
    var onBootstrap: (() -> Void)?
    var onKickstart: (() -> Void)?
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        lock.lock(); calls.append(([executable] + arguments).joined(separator: " ")); lock.unlock()
        switch (executable, arguments.first) {
        case ("/bin/launchctl", "list"):
            return ShellResult(exitCode: 0, stdout: list(), stderr: "")
        case ("/bin/launchctl", "bootout"):
            if bootoutExit == 0 { onBootout?() }
            return ShellResult(exitCode: bootoutExit, stdout: "", stderr: "")
        case ("/bin/launchctl", "bootstrap"):
            if bootstrapExit == 0 { onBootstrap?() }
            return ShellResult(exitCode: bootstrapExit, stdout: "", stderr: "")
        case ("/bin/launchctl", "kickstart"):
            if kickstartExit == 0 { onKickstart?() }
            return ShellResult(exitCode: kickstartExit, stdout: "", stderr: "")
        case ("/usr/bin/osascript", _):
            return ShellResult(exitCode: 1, stdout: "", stderr: "refused in tests")
        case ("/usr/bin/open", _):
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
    func count(_ needle: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.contains(needle) }.count
    }
}

/// A bundle with a copied, signed helper executable and a LaunchAgent that names it. Starting and
/// stopping the helper is what makes the fake `launchctl list` change, like launchd's own state.
private final class ServiceRig {
    let root = tmpDir("owned-service")
    let app: URL
    let helper: URL
    let agents: URL
    let label = "com.example.foo.helper"
    private var process: Process?

    init(policy: [String: Any], programOutside: Bool = false) {
        app = makeApp(root.appendingPathComponent("Foo.app"), version: "1.0.0", id: "com.example.foo")
        helper = app.appendingPathComponent("Contents/Resources/Helper")
        ServiceRig.installHelper(at: helper)
        agents = root.appendingPathComponent("LaunchAgents")
        try! fm.createDirectory(at: agents, withIntermediateDirectories: true)
        var job: [String: Any] = ["Label": label, "RunAtLoad": true,
                                  "ProgramArguments": [programOutside ? "/bin/sleep" : helper.path]]
        for (key, value) in policy { job[key] = value }
        try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("\(label).plist"))
    }

    /// Puts a signed copy of /bin/sleep inside a bundle at `path`.
    static func installHelper(at path: URL) {
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: path)
        try! fm.copyItem(atPath: "/bin/sleep", toPath: path.path)
        _ = try? SystemShell().run("/usr/bin/codesign", arguments: ["-f", "-s", "-", path.path], timeout: 10)
    }

    func startHelper() {
        if let process, process.isRunning { return }
        let p = Process(); p.executableURL = helper; p.arguments = ["30"]
        try! p.run()
        process = p
        Thread.sleep(forTimeInterval: 0.2)
    }
    func stopHelper() {
        if let process, process.isRunning { process.terminate() }
        process?.waitUntilExit()
    }
    /// `launchctl list` while the helper lives, for a loaded-but-stopped job, or — when the install
    /// unloaded it — nothing at all.
    func list(unloaded: Bool) -> String {
        if unloaded { return "" }
        if let process, process.isRunning { return "\(process.processIdentifier) 0 \(label)" }
        return "- 0 \(label)"
    }
}

func ownedServiceTests() {
    let keepAlways: [String: Any] = ["KeepAlive": true]

    // OS1: an unconditional job is booted out (never signalled), and bootstrapped back afterwards.
    do {
        let rig = ServiceRig(policy: keepAlways)
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        var unloaded = false
        shell.list = { rig.list(unloaded: unloaded) }
        shell.onBootout = { unloaded = true; rig.stopHelper() }
        shell.onBootstrap = { unloaded = false; rig.startHelper() }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 2)
        expect(control.isRunning() == true, "OS1 a helper that lives inside the bundle is running")
        expect(control.quit(), "OS1 the app's own service is not the app: quit returns without waiting on it")
        expect(shell.count("/usr/bin/osascript") == 0, "OS1 no app is asked to quit when only its service runs")
        expect(control.stopService(), "OS1 an unconditional job is stopped")
        expect(shell.count("bootout gui/") == 1, "OS1 an unconditional job is stopped by launchctl bootout")
        expect(rig.list(unloaded: false).hasPrefix("- 0") || rig.list(unloaded: false).isEmpty,
               "OS1 the booted-out job's process is gone")
        let resumed = control.resumeServices()
        expect(resumed.ok && shell.count("bootstrap gui/") == 1 && shell.count("kickstart") == 0,
               "OS1 the unloaded job is bootstrapped from its own plist and runs again (\(resumed.reason ?? "ok"))")
        expect(!rig.list(unloaded: false).hasPrefix("- 0"), "OS1 the service is really running again")
    }

    // OS2: a refused bootout leaves everything running and reports the refusal.
    do {
        let rig = ServiceRig(policy: keepAlways)
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        shell.list = { rig.list(unloaded: false) }
        shell.bootoutExit = 5
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 1)
        expect(control.stopService() == false && !rig.list(unloaded: false).hasPrefix("- 0"),
               "OS2 a refused bootout stops nothing and keeps the service running")
        expect(shell.count("bootstrap") == 0, "OS2 a refused bootout puts nothing back")
    }

    // OS3: policies the updater cannot own are refused, not guessed at.
    let ambiguous: [(String, [String: Any], Bool)] = [
        ("a keep-alive of false", ["KeepAlive": false], false),
        ("a SuccessfulExit=true rule", ["KeepAlive": ["SuccessfulExit": true]], false),
        ("two keep-alive rules", ["KeepAlive": ["SuccessfulExit": false, "Crashed": true]], false),
        ("a scheduled job", ["KeepAlive": true, "StartInterval": 60], false),
        ("a path-state job", ["KeepAlive": true, "PathState": ["/tmp": ["Exists": true]]], false),
        ("a program outside the bundle", keepAlways, true),
    ]
    for (what, policy, outside) in ambiguous {
        let rig = ServiceRig(policy: policy, programOutside: outside)
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        shell.list = { rig.list(unloaded: false) }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 0.2)
        expect(control.stopService() == false && shell.count("bootout") == 0,
               "OS3 \(what) is not an owned service: nothing is unloaded")
        expect(control.quit() == false && shell.count("bootout") == 0,
               "OS3 \(what) keeps counting as the app, so the install refuses instead of stopping it")
    }

    // OS4: the existing restart-on-failure job is still signalled, then kickstarted back.
    do {
        let rig = ServiceRig(policy: ["KeepAlive": ["SuccessfulExit": false]])
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        shell.list = { rig.list(unloaded: false) }
        shell.onKickstart = { rig.startHelper() }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 2)
        expect(control.stopService(), "OS4 a restart-on-failure job is stopped")
        expect(shell.count("bootout") == 0, "OS4 a restart-on-failure job is not unloaded")
        let resumed = control.resumeServices()
        expect(resumed.ok && shell.count("kickstart gui/") == 1 && !rig.list(unloaded: false).hasPrefix("- 0"),
               "OS4 a loaded, stopped job is kickstarted back and really runs (\(resumed.reason ?? "ok"))")
    }

    // OS5: the whole swap through the recipe: the helper that used to block the install no longer
    // does, and it is put back after the new bundle is in place.
    do {
        let rig = ServiceRig(policy: keepAlways)
        let mounted = rig.root.appendingPathComponent("mount")
        let next = makeApp(mounted.appendingPathComponent("Foo.app"), version: "2.0.0", id: "com.example.foo")
        ServiceRig.installHelper(at: next.appendingPathComponent("Contents/Resources/Helper"))
        let shell = SwapShell(launchd: LaunchdShell(), mount: mounted)
        var unloaded = false
        shell.launchd.onBootout = { unloaded = true; rig.stopHelper() }
        shell.launchd.onBootstrap = { unloaded = false; rig.startHelper() }
        rig.startHelper()
        shell.launchd.list = { rig.list(unloaded: unloaded) }
        defer { rig.stopHelper() }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 3)
        let result = try? Recipe.appDmg(shell: shell, installedPath: rig.app.path,
                                        artifactPath: rig.root.appendingPathComponent("fixture.dmg").path,
                                        feedVersion: "2.0.0", expectedBundleID: "com.example.foo",
                                        stateDir: rig.root.appendingPathComponent("state").path, app: "fixture",
                                        control: control, relaunchAfterInstall: false)
        let version = (try? BundleInfo.read(rig.app.path))?.version
        expect(result?.status == "updated" && version == "2.0.0",
               "OS5 an app whose helper keeps a KeepAlive job installs instead of refusing 'did not quit' (\(result?.reason ?? "nil"))")
        expect(shell.launchd.count("bootout gui/") == 1 && shell.launchd.count("bootstrap gui/") == 1,
               "OS5 the swap unloads the job before the bundle exchange and bootstraps it after")
        expect(!rig.list(unloaded: false).hasPrefix("- 0"), "OS5 the service runs again from the new bundle")
    }

    // OS6: a bootstrap launchd refuses is reported and the journal is kept; the next recovery puts
    // the service back and clears the journal.
    do {
        let rig = ServiceRig(policy: keepAlways)
        let mounted = rig.root.appendingPathComponent("mount")
        let next = makeApp(mounted.appendingPathComponent("Foo.app"), version: "2.0.0", id: "com.example.foo")
        ServiceRig.installHelper(at: next.appendingPathComponent("Contents/Resources/Helper"))
        let shell = SwapShell(launchd: LaunchdShell(), mount: mounted)
        var unloaded = false
        shell.launchd.onBootout = { unloaded = true; rig.stopHelper() }
        shell.launchd.onBootstrap = { unloaded = false; rig.startHelper() }
        rig.startHelper()
        shell.launchd.list = { rig.list(unloaded: unloaded) }
        shell.launchd.bootstrapExit = 5
        defer { rig.stopHelper() }
        let state = rig.root.appendingPathComponent("state").path
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 3)
        let result = try? Recipe.appDmg(shell: shell, installedPath: rig.app.path,
                                        artifactPath: rig.root.appendingPathComponent("fixture.dmg").path,
                                        feedVersion: "2.0.0", expectedBundleID: "com.example.foo",
                                        stateDir: state, app: "fixture", control: control, relaunchAfterInstall: false)
        let journal = Recipe.journalURL(stateDir: state, app: "fixture")
        expect(result?.status == "install_failed" && (result?.reason ?? "").contains("background service did not restart")
               && (result?.reason ?? "").contains("bootstrap"),
               "OS6 a refused bootstrap is reported in the install outcome, not swallowed (\(result?.reason ?? "nil"))")
        expect(fm.fileExists(atPath: journal.path), "OS6 the journal is kept so the next run can retry the service")
        expect((try? BundleInfo.read(rig.app.path))?.version == "2.0.0", "OS6 the app itself was installed")

        shell.launchd.bootstrapExit = 0
        let note = (try? Recipe.recover(installedPath: rig.app.path, stateDir: state, app: "fixture", control: control)) ?? ""
        expect(!note.isEmpty && !fm.fileExists(atPath: journal.path),
               "OS6 the next recovery puts the service back and clears the journal (\(note))")
        expect(shell.launchd.count("bootstrap gui/") == 2 && !rig.list(unloaded: false).hasPrefix("- 0"),
               "OS6 the service is really loaded and running again on the retry")
    }

    // OS7: a refused kickstart is reported too.
    do {
        let rig = ServiceRig(policy: ["KeepAlive": ["SuccessfulExit": false]])
        let shell = LaunchdShell()
        shell.list = { "- 0 \(rig.label)" }
        shell.kickstartExit = 5
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 1)
        control.restoreServices([rig.label])
        let resumed = control.resumeServices()
        expect(!resumed.ok && (resumed.reason ?? "").contains("kickstart"),
               "OS7 a refused kickstart is a reported failure (\(resumed.reason ?? "nil"))")
    }

    // OS8: a saved plist rewritten with a scheduled or unknown policy is never started back.
    do {
        let rig = ServiceRig(policy: keepAlways)
        let plist = rig.agents.appendingPathComponent("\(rig.label).plist")
        func rewrite(_ job: [String: Any]) {
            try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        }
        let shell = LaunchdShell()
        shell.list = { "" }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 1)
        control.restoreServices([rig.label])
        rewrite(["Label": rig.label, "RunAtLoad": true, "StartInterval": 60,
                 "ProgramArguments": [rig.helper.path], "KeepAlive": true])
        let scheduled = control.resumeServices()
        expect(!scheduled.ok && shell.count("bootstrap") == 0,
               "OS8 a scheduled saved job is reported, never bootstrapped back (\(scheduled.reason ?? "nil"))")
        rewrite(["Label": rig.label, "RunAtLoad": true,
                 "ProgramArguments": [rig.helper.path], "KeepAlive": ["SuccessfulExit": true]])
        let unknown = control.resumeServices()
        expect(!unknown.ok && shell.count("bootstrap") == 0,
               "OS8 an unsupported policy in a saved job is reported, never bootstrapped back (\(unknown.reason ?? "nil"))")
    }
}

/// Fakes the DMG mount and launchd; ditto and codesign really run.
private final class SwapShell: Shell, @unchecked Sendable {
    let launchd: LaunchdShell
    let mount: URL
    init(launchd: LaunchdShell, mount: URL) {
        self.launchd = launchd
        self.mount = mount
    }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/bin/launchctl" || executable == "/usr/bin/osascript" || executable == "/usr/bin/open" {
            return try launchd.run(executable, arguments: arguments, timeout: timeout)
        }
        if executable == "/usr/bin/hdiutil" {
            if arguments.first == "attach" {
                let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": mount.path]]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        return try SystemShell().run(executable, arguments: arguments, timeout: timeout)
    }
}
