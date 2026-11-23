import Foundation

/// The agent's launchd job, and its repair.
///
/// Measured 2026-11-23: this Mac's `com.khupdater.agent` job was gone — not paused, not disabled —
/// the app still shipped its plist, and every surface looked quiet. A launchd definition that is
/// merely present is not proof, so the Launcher checks the job itself at start and rebuilds it from
/// the kit it ships when it is missing. The agent writes a start line and this process writes a
/// stop line, so a Mac that stops taking updates is visible in its own record.
public enum AgentJob {
    public static let label = "com.khupdater.agent"

    public static func isLoaded(shell: Shell, uid: uid_t = getuid()) -> Bool {
        (try? shell.run("/bin/launchctl", arguments: ["print", "gui/\(uid)/\(label)"], timeout: 15))?.exitCode == 0
    }

    /// Puts the job back when it is missing. Returns one line to log, or nil when there was nothing
    /// to do. Never throws: a repair that cannot finish is a line naming why, not a stopped app.
    @discardableResult
    public static func ensure(kit: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                              shell: Shell, uid: uid_t = getuid()) -> String? {
        if isLoaded(shell: shell, uid: uid) { return nil }
        let fm = FileManager.default
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let target = agents.appendingPathComponent("\(label).plist")
        do {
            if !fm.fileExists(atPath: target.path) {
                let template = kit.appendingPathComponent("\(label).plist")
                guard let text = try? String(contentsOf: template, encoding: .utf8) else {
                    return "agent job: missing, and the app's kit carries no \(label).plist; this Mac takes no updates until it is installed"
                }
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)
                try text.replacingOccurrences(of: "__HOME__", with: home.path)
                    .write(to: target, atomically: true, encoding: .utf8)
            }
            // The job runs the kit's binaries from the app's own home; a missing one is copied back.
            let bin = home.appendingPathComponent("Library/KHUpdater/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["khu", "khu-stub"] {
                let dest = bin.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                let source = kit.appendingPathComponent("bin/\(name)")
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            let boot = try shell.run("/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", target.path], timeout: 30)
            guard boot.exitCode == 0 else {
                let said = (boot.stderr + boot.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                return "agent job: was missing; reinstalled but did not start (\(said.isEmpty ? "launchctl exit \(boot.exitCode)" : said))"
            }
            return "agent job: was missing; reinstalled from the app's kit and started"
        } catch {
            return "agent job: was missing and could not be repaired (\(error)); this Mac takes no updates until it is installed"
        }
    }
}
