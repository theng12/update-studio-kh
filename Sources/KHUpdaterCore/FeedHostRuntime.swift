import Foundation

/// Reconciles this Mac's `com.khupdater.feed-host` LaunchAgent with the role the signed feed
/// asks for. Off is the default and creates, installs and starts nothing; on writes one
/// restrictive per-user plist for the executable the caller supplies and keeps exactly that one
/// job loaded. The publisher, the agent and every other job are never probed, stopped or
/// rewritten here, and no token or key can reach the plist — the host runs `--feed-only`.
public enum FeedHostRuntime {
    static let label = "com.khupdater.feed-host"

    /// `role` nil or disabled stops only this job (and retires its plist to `_trash`); enabled
    /// validates the role, requires the local mirror's `release.json`, then installs or reloads
    /// the job. launchctl refusals are reported as thrown errors with the command that retries
    /// them — never worked around, never forced.
    public static func reconcile(role: FeedHostRole?,
                                 stateDir: URL,
                                 executable: String?,
                                 shell: Shell = SystemShell(),
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let plist = agents.appendingPathComponent("\(label).plist")
        let domain = "gui/\(getuid())"
        let job = "\(domain)/\(label)"
        let loaded: Bool = {
            let probe = (try? shell.run("/bin/launchctl", arguments: ["print", job], timeout: 15))
            return probe?.exitCode == 0
        }()

        guard let role, role.enabled else {
            if loaded {
                let stopped = try shell.run("/bin/launchctl", arguments: ["bootout", job], timeout: 30)
                guard stopped.exitCode == 0 else { throw stopFailure(stopped, job: job) }
            }
            if FileManager.default.fileExists(atPath: plist.path) {
                _ = try Trash.move(plist, into: home.appendingPathComponent("Library/_trash"))
            }
            return loaded ? "feed host is off; its launchd job was stopped"
                          : "feed host is off; nothing was installed"
        }

        _ = try role.validated()
        guard let executable, !executable.isEmpty else {
            throw khuFail("feed hosting is on but no executable path was given; nothing was installed")
        }
        let feedDirectory = FeedHostRole.feedDirectory(in: stateDir)
        guard FileManager.default.fileExists(atPath: feedDirectory.appendingPathComponent("release.json").path) else {
            throw khuFail("this Mac's local mirror has no release.json at \(feedDirectory.path); publish to it before hosting")
        }

        let desired: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "serve",
                                 "--feed", feedDirectory.path,
                                 "--state", stateDir.appendingPathComponent("feed-host/server-state").path,
                                 "--bind", role.bind,
                                 "--port", String(role.port),
                                 "--feed-only"],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let existing: [String: Any]? = (try? Data(contentsOf: plist)).flatMap { data in
            guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
            return parsed as? [String: Any]
        }
        let unchanged = existing.map { ($0 as NSDictionary).isEqual(desired as NSDictionary) } ?? false

        var nowLoaded = loaded
        if !unchanged {
            if loaded {
                let stopped = try shell.run("/bin/launchctl", arguments: ["bootout", job], timeout: 30)
                guard stopped.exitCode == 0 else { throw stopFailure(stopped, job: job) }
                nowLoaded = false
            }
            try write(desired, to: plist)
        }
        if !nowLoaded {
            let started = try shell.run("/bin/launchctl", arguments: ["bootstrap", domain, plist.path], timeout: 30)
            guard started.exitCode == 0 else {
                let reason = started.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw khuFail("feed host could not be started: \(reason.isEmpty ? "launchctl exited \(started.exitCode)" : reason). "
                    + "Its plist is kept at \(plist.path); start it later with: launchctl bootstrap \(domain) \(plist.path)")
            }
        }
        if unchanged && loaded { return "feed host already runs these settings; left untouched" }
        if unchanged { return "feed host started (launchd job \(label))" }
        return loaded ? "feed host settings updated; its job was restarted"
                      : "feed host installed and started (launchd job \(label))"
    }

    private static func write(_ plist: [String: Any], to url: URL) throws {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try AtomicFile.write(data, to: url, permissions: 0o600)
        } catch {
            throw khuFail("feed host's LaunchAgent could not be written at \(url.path): \(error)")
        }
    }

    private static func stopFailure(_ result: ShellResult, job: String) -> KHUError {
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return khuFail("feed host could not be stopped: \(reason.isEmpty ? "launchctl exited \(result.exitCode)" : reason) "
            + "(job \(job)); nothing else was touched")
    }
}
