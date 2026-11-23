import Foundation

/// Owner, 2026-11-24: automatic updates default ON for a fresh Mac, and the switch the person sees
/// is the value the helper really follows. Proven here from the state a Mac has before anything is
/// saved — no settings file, no apps listed, a copy found on disk for the first time — rather than
/// by reading the code that decides it.
func automaticFreshMacTests() {
    let stateDir = tmpDir("fresh-automatic")
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)

    // AF1 nothing saved: the helper installs automatically.
    expect(!fm.fileExists(atPath: HelperSettings.file(in: stateDir).path),
           "AF1 a fresh Mac has no helper settings file")
    let fresh = HelperSettings.load(from: stateDir)
    expect(fresh.checkManually != true && fresh.autoInstall != false,
           "AF1 a fresh Mac's own settings install updates automatically")
    expect(fresh.installsAutomatically, "AF1 and the helper's own rule agrees")

    // AF2 the first app found on this Mac is registered with Automatic on. An app that keeps its own
    // updater is the deliberate exception — it is reported, never installed by the helper.
    let folder = tmpDir("fresh-apps")
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    _ = makeApp(folder.appendingPathComponent("Demo.app"), version: "1.0", id: "com.example.demo")
    _ = makeApp(folder.appendingPathComponent("Own.app"), version: "1.0", id: "com.example.own")
    let known: [String: (id: String, updatesItself: Bool)] = [
        "demo": ("com.example.demo", false),
        "own": ("com.example.own", true),
    ]
    let empty = AgentConfig(feedURL: "https://example.test/release.json", publicKey: "k",
                            stateDir: stateDir.path, machine: "mac", token: "")
    let found = Catalog.discover(config: empty, known: known, folders: [folder])
    expect(found["demo"]?.automatic == true,
           "AF2 an app found for the first time is managed with Automatic on")
    expect(found["own"]?.automatic == false,
           "AF2 an app that updates itself is never installed automatically")

    // AF3 the row's own decision: nothing set on this Mac, nothing set on a page, so the configured
    // default rules — Automatic on, in the helper's own words.
    if let demo = found["demo"] {
        let decision = fresh.automaticDecision("demo", page: nil, pageAt: nil, config: demo.automatic)
        expect(decision.on && decision.origin == .config,
               "AF3 a fresh Mac follows its own default, which is Automatic on (\(decision.origin.words))")
    } else { expect(false, "AF3 the fixture found no demo app to decide") }

    // AF4 a stored off stays off: a fresh Mac is a Mac with nothing saved, never one whose choice a
    // new build overwrites. The same for one app's own switch.
    var chosen = HelperSettings(); chosen.autoInstall = false
    expect(!chosen.installsAutomatically, "AF4 a stored off is kept")
    var picked = HelperSettings(); picked.automatic["demo"] = .init(on: false, at: ISO.string(Date()))
    expect(!picked.automatic("demo", page: nil, pageAt: nil, config: true),
           "AF4 an app switched off on this Mac stays off")
}