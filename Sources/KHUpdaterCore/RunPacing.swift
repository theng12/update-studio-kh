import Foundation

/// The floor between completed runs: one interval, whatever woke the loop.
///
/// Measured 2026-11-23: a state change mid-cycle (a stale journal cleared) drove this Mac from
/// 7 runs a minute to 90 — one full run every ~1.5 s, each re-fetching the feed and re-attempting
/// four 404s, same pid, so it was this pacing and not launchd. A state change may wake the loop,
/// but it never shortens the interval; only a person's own press runs at once. A wake that is
/// already pending is never scheduled twice.
public final class RunPacing: @unchecked Sendable {
    public enum Wake: Equatable {
        /// The interval elapsed.
        case interval
        /// A person pressed something (Check now, Update now). Runs at once.
        case person
    }

    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var person = false
    private var state = false

    public init() {}

    /// A person's own press: the only wake that may shorten the interval.
    public func wakeByPerson() { arm { person = true } }

    /// A state change (a saved setting, a journal edit, a settle): wakes the loop so it can note
    /// the change, but the wait still runs to the interval.
    public func wakeByState() { arm { state = true } }

    /// Arms one wake, and only one: a second signal while one is pending is dropped, so a burst of
    /// state changes can never become a burst of runs.
    private func arm(_ set: () -> Void) {
        lock.lock()
        let pending = person || state
        if !pending { set() }
        lock.unlock()
        if !pending { signal.signal() }
    }

    /// Blocks until the interval has passed or a person asked. A state wake never returns early.
    public func wait(interval: TimeInterval) -> Wake {
        let deadline = Date().addingTimeInterval(interval)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .interval }
            guard signal.wait(timeout: .now() + remaining) == .success else { return .interval }
            lock.lock()
            let byPerson = person
            person = false
            state = false
            lock.unlock()
            if byPerson { return .person }
            // A state wake: the loop already knows, so it keeps waiting out the interval floor.
        }
    }
}
