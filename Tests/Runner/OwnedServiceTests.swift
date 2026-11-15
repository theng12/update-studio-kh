import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Answers `launchctl list` from what the fixture reports, and records every call. Nothing here
/// reaches the real gui domain.
private final class LaunchdShell: Shell, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    var list: () -> String = { "" }
    var bootoutExit: Int32 = 0
    var bootstrapExit: Int32 = 0
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
            onKickstart?()
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
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

/// A bundle with a copied, signed helper executable and a LaunchAgent that names it.
private struct ServiceRig {
    let root = tmpDir("owned-service")
    let app: URL
    let helper: URL
    let agents: URL
    let label = "com.example.foo.helper"
    var process: Process?

    init(policy: [String: Any], programOutside: Bool = false) {
        app = makeApp(root.appendingPathComponent("Foo.app"), version: "1.0.0", id: "com.example.foo")
        helper = app.appendingPathComponent("Contents/Resources/Helper")
        _ = try? fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! fm.copyItem(atPath: "/bin/sleep", toPath: helper.path)
        _ = try? SystemShell().run("/usr/bin/codesign", arguments: ["-f", "-s", "-", helper.path], timeout: 10)
        agents = root.appendingPathComponent("LaunchAgents")
        try! fm.createDirectory(at: agents, withIntermediateDirectories: true)
        var job: [String: Any] = ["Label": label, "RunAtLoad": true,
                                  "ProgramArguments": [programOutside ? "/bin/sleep" : helper.path]]
        for (key, value) in policy { job[key] = value }
        try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("\(label).plist"))
    }

    /// A real process whose executable is inside the bundle, so the kernel agrees with the plist.
    mutating func startHelper() {
        let p = Process(); p.executableURL = helper; p.arguments = ["30"]
        try! p.run()
        process = p
        Thread.sleep(forTimeInterval: 0.2)
    }
    var pid: pid_t { process?.processIdentifier ?? 0 }
    func stopHelper() {
        if let p = process, p.isRunning { p.terminate() }
        process?.waitUntilExit()
    }
    /// `launchctl list` while the helper lives, for a loaded-but-stopped job, or — when the install
    /// unloaded it — nothing at all.
    func list(_ unloaded: Bool) -> String {
        if unloaded { return "" }
        if let p = process, p.isRunning { return "\(p.processIdentifier) 0 \(label)" }
        return "- 0 \(label)"
    }
}

func ownedServiceTests() {
    let keepAlways: [String: Any] = ["KeepAlive": true]

    // OS1: an unconditional job is booted out (never signalled), and bootstrapped back afterwards.
    do {
        var rig = ServiceRig(policy: keepAlways)
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        var unloaded = false
        shell.list = { rig.list(unloaded) }
        shell.onBootout = { unloaded = true; rig.stopHelper() }
        shell.onBootstrap = { unloaded = false }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 2)
        expect(control.isRunning() == true, "OS1 a helper that lives inside the bundle is running")
        expect(control.quit(), "OS1 the app's own service is not the app: quit returns without waiting on it")
        expect(shell.count("/usr/bin/osascript") == 0, "OS1 no app is asked to quit when only its service runs")
        expect(control.stopService(), "OS1 an unconditional job is stopped")
        expect(shell.count("bootout gui/") == 1, "OS1 an unconditional job is stopped by launchctl bootout")
        expect(rig.process?.isRunning == false, "OS1 the booted-out job's process is gone")
        control.resumeServices()
        expect(shell.count("bootstrap gui/") == 1 && shell.count("kickstart") == 0,
               "OS1 the unloaded job is bootstrapped from its own plist")
    }

    // OS2: a refused bootout leaves everything running and reports the refusal.
    do {
        var rig = ServiceRig(policy: keepAlways)
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        shell.list = { rig.list(false) }
        shell.bootoutExit = 5
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 1)
        expect(control.stopService() == false && rig.process?.isRunning == true,
               "OS2 a refused bootout stops nothing and keeps the service running")
        expect(shell.count("bootstrap") == 0, "OS2 a refused bootout puts nothing back")
    }

    // OS3: policies the updater cannot own are refused, not guessed at.
    let ambiguous: [(String, [String: Any], Bool)] = [
        ("a keep-alive of false", ["KeepAlive": false], false),
        ("a SuccessfulExit=true rule", ["KeepAlive": ["SuccessfulExit": true]], false),
        ("two keep-alive rules", ["KeepAlive": ["SuccessfulExit": false, "Crashed": true]], false),
        ("a scheduled job", ["KeepAlive": true, "StartInterval": 60], false),
        ("a program outside the bundle", keepAlways, true),
    ]
    for (what, policy, outside) in ambiguous {
        var rig = ServiceRig(policy: policy, programOutside: outside)
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        shell.list = { rig.list(false) }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 0.2)
        expect(control.stopService() == false && shell.count("bootout") == 0,
               "OS3 \(what) is not an owned service: nothing is unloaded")
        expect(control.quit() == false && shell.count("bootout") == 0,
               "OS3 \(what) keeps counting as the app, so the install refuses instead of stopping it")
    }

    // OS4: the existing restart-on-failure job is still signalled, then kickstarted back.
    do {
        var rig = ServiceRig(policy: ["KeepAlive": ["SuccessfulExit": false]])
        rig.startHelper()
        defer { rig.stopHelper() }
        let shell = LaunchdShell()
        shell.list = { rig.list(false) }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 2)
        expect(control.stopService(), "OS4 a restart-on-failure job is stopped")
        expect(shell.count("bootout") == 0, "OS4 a restart-on-failure job is not unloaded")
        control.resumeServices()
        expect(shell.count("kickstart gui/") == 1, "OS4 a loaded, stopped job is kickstarted back")
    }

    // OS5: the whole swap through the recipe: the helper that used to block the install no longer
    // does, and it is put back after the new bundle is in place.
    do {
        let rig = ServiceRig(policy: keepAlways)
        let mounted = rig.root.appendingPathComponent("mount")
        makeApp(mounted.appendingPathComponent("Foo.app"), version: "2.0.0", id: "com.example.foo")
        let shell = SwapShell(launchd: LaunchdShell(), mount: mounted)
        var unloaded = false
        let p = Process(); p.executableURL = rig.helper; p.arguments = ["30"]
        shell.launchd.onBootout = { unloaded = true; if p.isRunning { p.terminate() } }
        try! p.run()
        Thread.sleep(forTimeInterval: 0.2)
        shell.launchd.list = { unloaded ? "" : (p.isRunning ? "\(p.processIdentifier) 0 \(rig.label)" : "- 0 \(rig.label)") }
        shell.launchd.onBootstrap = { unloaded = false }
        defer { if p.isRunning { p.terminate() }; p.waitUntilExit() }
        let control = LiveControl.appDmg(rig.app.path, shell: shell, agentsDirectory: rig.agents, quitWait: 3)
        let result = try? Recipe.appDmg(shell: shell, installedPath: rig.app.path,
                                        artifactPath: rig.root.appendingPathComponent("fixture.dmg").path,
                                        feedVersion: "2.0.0", expectedBundleID: "com.example.foo",
                                        stateDir: rig.root.appendingPathComponent("state").path, app: "fixture",
                                        control: control, relaunchAfterInstall: false)
        let version = (try? BundleInfo.read(rig.app.path))?.version
        expect(result?.status == "updated" && version == "2.0.0",
               "OS5 an app whose helper keeps a KeepAlive job installs instead of refusing 'did not quit'")
        expect(shell.launchd.count("bootout gui/") == 1 && shell.launchd.count("bootstrap gui/") == 1,
               "OS5 the swap unloads the job before the bundle exchange and bootstraps it after")
        expect(p.isRunning == false, "OS5 the old bundle's helper is not left running")
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
