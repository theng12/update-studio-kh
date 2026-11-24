import Foundation

/// One feed publisher at a time (issue `20261125-5`), measured on the real lock file.
///
/// Two sessions started a `khu feed --publish` inside the same minute on 2026-11-25 and only
/// messages kept them apart. The lock is a property of the tool now: a second pass refuses, and the
/// refusal names the holder so an operator can act on it.
func publishLockTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("khu-publish-lock-\(UUID().uuidString)")
    let lockFile = dir.appendingPathComponent("feed-publish.lock")
    setenv("KH_FEED_PUBLISH_LOCK", lockFile.path, 1)
    defer { unsetenv("KH_FEED_PUBLISH_LOCK"); _ = try? FileManager.default.removeItem(at: dir) }

    // A whole publish is not needed to prove the lock: the lock is taken before anything is read.
    let first = (try? FeedPublishLock.withLock { () -> String in
        var refusal = ""
        do {
            _ = try FeedPublishLock.withLock { "second pass should not run" }
            refusal = "none"
        } catch {
            refusal = "\(error)"
        }
        return refusal
    }) ?? "the first pass itself refused"

    expect(first != "none" && first != "the first pass itself refused",
           "PK1 a second publish refuses while one holds the lock (\(first))")
    expect(first.contains("pid ") && first.contains("started "),
           "PK1 the refusal names the holder's pid and start time (\(first))")
    expect(first.contains("One publisher at a time"),
           "PK1 ... and says the rule, so it is not read as a transient error (\(first))")

    // Released: the next pass takes it, and the file names that pass rather than the last one.
    let second = (try? FeedPublishLock.withLock { () -> String in
        (try? String(contentsOf: lockFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }) ?? ""
    expect(second.contains("pid \(getpid())"),
           "PK2 after the holder releases, the next pass takes the lock and rewrites the holder line (\(second))")

    // A file left behind by a killed pass is not a lock: the kernel dropped it with the process.
    try? "pid 999999, started 2026-01-01T00:00:00Z".write(to: lockFile, atomically: true, encoding: .utf8)
    let stale = (try? FeedPublishLock.withLock { true }) ?? false
    expect(stale, "PK3 a holder line with no live holder does not wedge the next publish")

    // Clean-tree registry guard: 0.1.82's pass served Launcher hold fields staged for 0.1.83 because
    // the generator read a dirty working-tree feed-registry.json. Test against a real git repo.
    let shell = SystemShell()
    let repo = dir.appendingPathComponent("repo")
    try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    let reg = repo.appendingPathComponent("feed-registry.json")
    let committedJSON = """
    {
      "apps": {
        "hub": { "name": "Hub Studio KH", "tagline": "Runs AI models." },
        "launcher": { "name": "Studio Launcher KH", "tagline": "Every KH Studio app." }
      }
    }
    """
    try? committedJSON.write(to: reg, atomically: true, encoding: .utf8)
    _ = try? shell.run("/usr/bin/git", arguments: ["-C", repo.path, "init", "-q"], timeout: 15)
    _ = try? shell.run("/usr/bin/git", arguments: ["-C", repo.path, "config", "user.email", "test@example.invalid"], timeout: 15)
    _ = try? shell.run("/usr/bin/git", arguments: ["-C", repo.path, "config", "user.name", "Test"], timeout: 15)
    _ = try? shell.run("/usr/bin/git", arguments: ["-C", repo.path, "add", "feed-registry.json"], timeout: 15)
    _ = try? shell.run("/usr/bin/git", arguments: ["-C", repo.path, "commit", "-q", "-m", "initial registry"], timeout: 15)

    var cleanError: String?
    do { try FeedRegistryGuard.requireCommitted(at: reg) } catch { cleanError = "\(error)" }
    expect(cleanError == nil, "PK4 a committed feed-registry.json passes the clean-tree guard (\(cleanError ?? "ok"))")

    // Stage an uncommitted change to launcher's hold fields — the exact 0.1.82/0.1.83 leak.
    let dirtyJSON = """
    {
      "apps": {
        "hub": { "name": "Hub Studio KH", "tagline": "Runs AI models." },
        "launcher": {
          "name": "Studio Launcher KH",
          "tagline": "Every KH Studio app.",
          "hold_url": "http://127.0.0.1:8792/api/maintenance/hold",
          "hold_since": "0.1.83"
        }
      }
    }
    """
    try? dirtyJSON.write(to: reg, atomically: true, encoding: .utf8)
    var dirtyRefusal = ""
    do {
        try FeedRegistryGuard.requireCommitted(at: reg)
    } catch {
        dirtyRefusal = "\(error)"
    }
    expect(dirtyRefusal.contains("uncommitted changes")
           && dirtyRefusal.contains("launcher.hold_since")
           && dirtyRefusal.contains("launcher.hold_url")
           && !dirtyRefusal.contains("hub"),
           "PK5 an uncommitted registry edit refuses naming only the changed keys (\(dirtyRefusal))")
    expect(dirtyRefusal.contains("Commit the registry before publishing"),
           "PK5 ... and tells the operator to commit before publishing (\(dirtyRefusal))")

    // The two publish-path guards must be distinguishable sentences so an operator knows which bit.
    expect(first != dirtyRefusal
           && !first.contains("uncommitted")
           && !dirtyRefusal.contains("One publisher at a time")
           && !dirtyRefusal.contains("pid "),
           "PK6 lock refusal and dirty-registry refusal are distinct sentences")

    // An untracked file in the repo has no HEAD copy and refuses.
    let untracked = repo.appendingPathComponent("draft-registry.json")
    try? committedJSON.write(to: untracked, atomically: true, encoding: .utf8)
    var untrackedRefusal = ""
    do { try FeedRegistryGuard.requireCommitted(at: untracked) } catch { untrackedRefusal = "\(error)" }
    expect(untrackedRefusal.contains("is not committed"),
           "PK7 an untracked registry refuses as not committed (\(untrackedRefusal))")

    // A registry outside any git repo refuses rather than silently trusting unversioned bytes.
    let outside = dir.appendingPathComponent("outside-registry.json")
    try? committedJSON.write(to: outside, atomically: true, encoding: .utf8)
    var outsideRefusal = ""
    do { try FeedRegistryGuard.requireCommitted(at: outside) } catch { outsideRefusal = "\(error)" }
    expect(outsideRefusal.contains("not inside a git repository"),
           "PK8 a registry outside git refuses (\(outsideRefusal))")
}
