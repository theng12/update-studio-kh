import Foundation

func downloadDeadlineTests() {
    // DDL1: the old flat ceiling is now the floor. A 1.48 GB artifact at the fleet's ~1 MB/s gets
    // about 1,500 s — well past 600 s — so repeated partial pulls stop being cut off at ten minutes.
    let large = URLSessionHTTPClient.transferDeadline(bytes: 1_480_000_000, rate: 1_000_000)
    expect(large > 600, "DDL1 1.48 GB deadline (\(Int(large)) s) exceeds the old 600 s ceiling")
    expect(large == 1_480, "DDL1 1.48 GB at 1 MB/s is its own duration, not clamped (\(Int(large)) s)")

    // DDL2: nothing is given less time than before. A small artifact keeps the old 600 s — the
    // 60 s inactivity timeout, not this number, is what ends a dead link.
    let small = URLSessionHTTPClient.transferDeadline(bytes: 2_000_000, rate: 1_000_000)
    expect(small == URLSessionHTTPClient.transferFloor,
           "DDL2 a 2 MB artifact is floored at the old ceiling (\(Int(small)) s, floor \(Int(URLSessionHTTPClient.transferFloor)) s)")
    let tiny = URLSessionHTTPClient.transferDeadline(bytes: 0, rate: 1_000_000)
    expect(tiny == URLSessionHTTPClient.transferFloor, "DDL2 zero bytes still gets the floor, never less (\(Int(tiny)) s)")

    // DDL3: a huge artifact is clamped to the cap, never above it.
    let huge = URLSessionHTTPClient.transferDeadline(bytes: 10_000_000_000_000, rate: 1_000_000)
    expect(huge <= URLSessionHTTPClient.transferCap,
           "DDL3 huge artifact deadline (\(Int(huge)) s) is clamped to the cap (\(Int(URLSessionHTTPClient.transferCap)) s)")

    // DDL4: transferDeadline is monotonic in bytes — doubling the bytes never shortens the deadline.
    let base = URLSessionHTTPClient.transferDeadline(bytes: 1_000_000_000, rate: 1_000_000)
    let doubled = URLSessionHTTPClient.transferDeadline(bytes: 2_000_000_000, rate: 1_000_000)
    expect(doubled >= base, "DDL4 doubling bytes does not shorten the deadline (\(Int(base)) → \(Int(doubled)) s)")

    // DDL6: the rate is a constant, so a collapsed rate can never hand back an unbounded deadline.
    // Zero, negative and NaN all answer a finite number no greater than the cap.
    let zero = URLSessionHTTPClient.transferDeadline(bytes: 1_480_000_000, rate: 0)
    let negative = URLSessionHTTPClient.transferDeadline(bytes: 1_480_000_000, rate: -1)
    let nan = URLSessionHTTPClient.transferDeadline(bytes: 1_480_000_000, rate: .nan)
    expect(zero.isFinite && negative.isFinite && nan.isFinite
           && zero <= URLSessionHTTPClient.transferCap && negative <= URLSessionHTTPClient.transferCap
           && nan <= URLSessionHTTPClient.transferCap,
           "DDL6 a rate of zero, below zero or not-a-number still answers a finite deadline (\(Int(zero)) / \(Int(negative)) / \(Int(nan)) s)")

    // DDL5: the shorten-only path for non-download requests is unchanged — min semantics hold,
    // and a large download deadline does not leak into the hold's window.
    let noOverride = URLSessionHTTPClient.requestTimeout(total: 600, override: nil)
    expect(noOverride == 600, "DDL5a requestTimeout with no override returns totalTimeout (got \(noOverride))")
    let shortened = URLSessionHTTPClient.requestTimeout(total: 600, override: 30)
    expect(shortened == 30, "DDL5b requestTimeout with a 30 s override returns 30 (got \(shortened))")
    let extended = URLSessionHTTPClient.requestTimeout(total: 600, override: 1200)
    expect(extended == 600, "DDL5c requestTimeout with a bigger override still caps at totalTimeout (got \(extended))")
}
