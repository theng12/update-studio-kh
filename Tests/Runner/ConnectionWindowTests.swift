import AppKit
import Foundation

/// The first-run window's "Where updates come from" states, built headlessly — no window is shown
/// and nothing takes the desktop. A kit with an address keeps today's publisher route; one without
/// (a public download) starts on GitHub releases.
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

    // A publisher kit: three sources, the kit's own route selected and still prefilled with a code.
    let kit = firstRunKit("cw-kit", feed: "http://demo-host.ts.net:8790/release.json")
    let window = ConnectionWindow.testFirstRun(kit: kit, home: home)
    var state = window.testState
    expect(state.sources == ["GitHub releases", "Custom address", "This Mac's Update Studio"],
           "CW1 a publisher kit builds all three sources in order (\(state.sources))")
    expect(state.selected == 2, "CW1 a publisher kit starts on its own Update Studio route (\(state.selected))")
    expect(state.address == "http://demo-host.ts.net:8790/release.json" && state.editable,
           "CW1 the kit's address is prefilled and editable (\(state.address))")
    expect(state.codeVisible, "CW1 the pairing code is shown for the kit route")

    // GitHub releases: the public link, no editing, no code, and the sentence that says so.
    window.testSelect(0)
    state = window.testState
    expect(state.address == ConnectionWindow.publicFeedURL && !state.editable,
           "CW2 GitHub releases shows the public link and cannot be edited (\(state.address))")
    expect(!state.codeVisible, "CW2 GitHub releases asks for no pairing code")
    expect(state.note.lowercased().contains("reports nothing to anyone"),
           "CW2 GitHub releases says this Mac reports nothing to anyone")
    expect((try? ConnectionWindow.route(state.address))?.publicFeed == true,
           "CW2 the GitHub link routes to the public feed")
    expect((try? ConnectionWindow.route(state.address))?.needsCode == false,
           "CW2 the GitHub link needs no code")

    // Custom: blank and editable, with the code row back for a publisher's Tailscale name.
    window.testSelect(1)
    state = window.testState
    expect(state.address.isEmpty && state.editable, "CW3 a custom address starts blank and editable")
    expect(state.codeVisible, "CW3 a custom address keeps the pairing code row")

    // A public download's kit carries no address: two sources, GitHub by default.
    let publicKit = firstRunKit("cw-public", feed: nil)
    let publicWindow = ConnectionWindow.testFirstRun(kit: publicKit, home: home)
    let publicState = publicWindow.testState
    expect(publicState.sources == ["GitHub releases", "Custom address"],
           "CW4 a kit without an address offers two sources (\(publicState.sources))")
    expect(publicState.selected == 0 && publicState.address == ConnectionWindow.publicFeedURL,
           "CW4 a kit without an address starts on GitHub releases (\(publicState.selected))")

    // The publisher route keeps its rules: a name needs the code, a numeric IP is refused with the fix.
    expect((try? ConnectionWindow.route("demo-host.ts.net:8790"))?.needsCode == true,
           "CW5 a Tailscale name still needs the pairing code")
    do {
        _ = try ConnectionWindow.route("100.64.0.7:8790")
        expect(false, "CW5 a numeric IP is still refused")
    } catch {
        expect("\(error)".contains("App Transport Security") && "\(error)".contains("shown on the publisher's Update Studio window"),
               "CW5 a numeric IP is refused and says to use the publisher's name (\(error))")
    }
}
