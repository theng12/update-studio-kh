import Foundation

/// RC1: the helper starts itself again in place before the HTTP stack's per-transfer cost matters.
///
/// Measured 2026-11-17: about one Mach port and 30–50 KB per completed transfer, never returned, and
/// not a dangling session (a bare URLSession shows the same). The agent therefore bounds its own
/// lifetime; these are the bounds and the reasons it gives.
func recycleTests() {
    expect(AgentRecycle.due(transfers: 0, age: 0) == nil, "RC1 a fresh helper does not restart")
    expect(AgentRecycle.due(transfers: AgentRecycle.afterTransfers - 1, age: 60) == nil,
           "RC1 one transfer short of the cap keeps running")
    let byTransfers = AgentRecycle.due(transfers: AgentRecycle.afterTransfers, age: 60) ?? ""
    expect(byTransfers.contains("transfer"),
           "RC1 reaching the transfer cap gives its reason (\(byTransfers))")
    let byAge = AgentRecycle.due(transfers: 3, age: AgentRecycle.afterSeconds) ?? ""
    expect(byAge.contains("running"),
           "RC1 reaching the age cap gives its reason (\(byAge))")
    // The numbers are the arithmetic, not a taste: the feed, the status report and the orders check
    // are three transfers per five-minute cycle, 864 a day — so 500 recycles about every 14 hours
    // and holds the process near 500 ports and ~20 MB instead of ~864 a day.
    expect(AgentRecycle.afterTransfers == 500 && AgentRecycle.afterSeconds == 86_400,
           "RC1 the caps hold the process near 500 transfers and one day")
}
