import Foundation

/// One feed publisher at a time (issue `20261125-5`).
///
/// Preflight → upload → readback is not atomic, and the publisher's own `publish.lock` serialises its
/// writes, not two operators: on 2026-11-25 two sessions started a `khu feed --publish` inside the
/// same minute, each holding the signing key, and only messages kept them apart. This is the lock
/// that makes "one publisher" a property of the tool rather than a habit of the people running it.
///
/// `flock` on a file the kernel releases when the holder dies, so a killed pass never leaves a
/// publish wedged. The holder writes its pid and start time, and a refusal repeats them: a lock
/// nobody can attribute is the message an operator learns to ignore.
public enum FeedPublishLock {
    /// `<home>/Library/KHUpdater/feed-publish.lock`; `KH_FEED_PUBLISH_LOCK` points a test elsewhere.
    public static func path() -> URL {
        if let given = ProcessInfo.processInfo.environment["KH_FEED_PUBLISH_LOCK"], !given.isEmpty {
            return URL(fileURLWithPath: given)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/KHUpdater/feed-publish.lock")
    }

    /// The line a refusal repeats, and exactly what a held lock file says.
    public static func holderLine(pid: Int32 = getpid(), at date: Date = Date()) -> String {
        "pid \(pid), started \(ISO.string(date))"
    }

    /// Runs `body` while no other pass holds the lock. Throws — naming the holder — rather than waits:
    /// a pass that quietly queued behind another publisher is how two publishes look like one.
    public static func withLock<T>(_ body: () throws -> T) throws -> T {
        let url = path()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw khuFail("cannot open the publish lock \(url.path) (errno \(errno))") }
        defer { close(fd) }
        var result: Int32
        repeat { result = flock(fd, LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
        // Captured before reading the file: the read can set errno and hide why the lock failed.
        let failure = errno
        guard result == 0 else {
            if failure == EWOULDBLOCK {
                let held = (try? String(contentsOf: url, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw khuFail("refused: another feed publish is running"
                              + (held.isEmpty ? "" : " (\(held))")
                              + "; nothing was generated. One publisher at a time — wait for it to finish or stop it")
            }
            throw khuFail("cannot lock \(url.path) (errno \(failure))")
        }
        defer { flock(fd, LOCK_UN) }
        // ftruncate then write: the previous holder's line must not sit beside this one.
        _ = ftruncate(fd, 0)
        let line = holderLine()
        _ = line.withCString { write(fd, $0, strlen($0)) }
        return try body()
    }
}
