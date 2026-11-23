import AppKit
import Foundation

/// The first-run window, built headlessly — no window is shown and nothing takes the desktop.
/// Owner, 2026-11-24: one first run, one source. A copy shared from a Studio carries that Studio's
/// address; every other copy carries none and reads the public signed feed. Nothing is chosen, typed
/// or asked for before the one press, and a failure names what was tried and offers Retry.
private func firstRunKit(_ tag: String, feed: String?) -> URL {
    let kit = tmpDir(tag).appendingPathComponent("kit")
    try! fm.createDirectory(at: kit, withIntermediateDirectories: true)
    var record: [String: Any] = ["publicKey": "test-pinned-key"]
    if let feed { record["feedURL"] = feed; record["enrolURL"] = feed.replacingOccurrences(of: "release.json", with: "enrol") }
    try! JSONSerialization.data(withJSONObject: record).write(to: kit.appendingPathComponent("publisher.json"))
    try! "#!/bin/bash\nexit 0\n".write(to: kit.appendingPathComponent("install-agent.sh"), atomically: true, encoding: .utf8)
    var files: [String: Any] = [:]
    for name in ["publisher.json", "install-agent.sh"] {
        let data = try! Data(contentsOf: kit.appendingPathComponent(name))
        files[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
    }
    try! JSONSerialization.data(withJSONObject: ["files": files]).write(to: kit.appendingPathComponent("MANIFEST.json"))
    return kit
}

func connectionWindowTests() {
    _ = NSApplication.shared   // AppKit is initialized headlessly; nothing is shown or activated.
    let home = tmpDir("cw-home")

    // CW1 a copy shared from a Studio: its address is already known, read-only, and no code is asked
    // for before the Studio has asked for one. The one press is the primary action.
    let kit = firstRunKit("cw-kit", feed: "http://demo-host.ts.net:8790/release.json")
    let window = ConnectionWindow.testFirstRun(kit: kit, home: home)
    var state = window.testState
    expect(state.address == "http://demo-host.ts.net:8790/release.json" && !state.editable,
           "CW1 a Studio copy shows its own address and cannot be retyped (\(state.address))")
    expect(!state.codeVisible, "CW1 no pairing code is requested before a Studio asks for one")
    expect(state.primary == "Connect", "CW1 the one press is Connect (\(state.primary))")
    expect(!state.name.isEmpty, "CW1 this Mac's name is already filled in (\(state.name))")
    expect(state.intro.contains("demo-host.ts.net") && !state.intro.lowercased().contains("choose"),
           "CW1 the window names the Studio it will use and asks no question (\(state.intro))")

    // CW2 a refusal names the failure and offers Retry; a Studio's refusal is what reveals the code.
    window.testFail("the Studio did not answer")
    state = window.testState
    expect(state.primary == "Retry", "CW2 a failed first run offers Retry (\(state.primary))")
    expect(state.status.contains("Not connected: the Studio did not answer"),
           "CW2 the failure names what was tried and what happened (\(state.status))")
    expect(state.codeVisible, "CW2 a Studio's refusal reveals the pairing code rather than stranding the Mac")

    // CW3 a copy downloaded for anyone: the public signed feed, no address typed, no code, no
    // service named. Its one press is still the only thing between the person and a set-up Mac.
    let publicKit = firstRunKit("cw-public", feed: nil)
    let publicWindow = ConnectionWindow.testFirstRun(kit: publicKit, home: home)
    let publicState = publicWindow.testState
    expect(publicState.address == ConnectionWindow.publicFeedURL && !publicState.editable,
           "CW3 a public copy shows the signed feed and cannot be retyped (\(publicState.address))")
    expect(!publicState.codeVisible, "CW3 a public copy asks for no pairing code")
    expect(!publicState.intro.contains("GitHub"), "CW3 the first run never names GitHub (\(publicState.intro))")
    expect(!publicState.intro.contains("Update Studio"), "CW3 and never names a Studio (\(publicState.intro))")
    expect(publicState.primary == "Connect", "CW3 one press sets this Mac up (\(publicState.primary))")

    // CW4 a public copy's failure is a named failure with Retry, and no field appears for it.
    publicWindow.testFail("the feed did not answer")
    state = publicWindow.testState
    expect(state.primary == "Retry" && state.status.contains("Not connected: the feed did not answer"),
           "CW4 a public copy fails in one plain sentence and offers Retry (\(state.status))")
    expect(!state.codeVisible, "CW4 a public copy never asks for a code it cannot use")
}