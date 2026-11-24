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
}
