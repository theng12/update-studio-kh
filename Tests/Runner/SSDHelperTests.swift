import Foundation

func ssdHelperTests() {
    let home = tmpDir("ssd-helper")
    defer { try? fm.removeItem(at: home) }
    let launcher = home.appendingPathComponent("Applications/Studio Launcher KH.app")
    expect((try? SSDHelper.refresh(launcher: launcher, home: home))?.status == "needs_connection",
           "SSD installs Launcher without inventing a connection for a new Mac")
    let base = home.appendingPathComponent("Library/KHUpdater/base")
    let state = home.appendingPathComponent("Library/KHUpdater/state")
    try! fm.createDirectory(at: base, withIntermediateDirectories: true)
    try! fm.createDirectory(at: state, withIntermediateDirectories: true)
    var cfg = AgentConfig(feedURL: "http://127.0.0.1/release.json", publicKey: "test-pin", stateDir: state.path,
                          machine: "ssd-fixture", token: "fixture-token-unused", apps: [:])
    cfg.stubBase = base.path
    let file = base.appendingPathComponent("config.json")
    try! AtomicFile.writeJSON(cfg, to: file)
    let original = try! Data(contentsOf: file)
    var settings = HelperSettings()
    settings.pausedUntil = ISO.string(Date().addingTimeInterval(3600))
    try! settings.save(to: state)
    let savedPause = try! Data(contentsOf: HelperSettings.file(in: state))
    expect((try? SSDHelper.refresh(launcher: launcher, home: home))?.status == "paused",
           "SSD helper refresh respects an existing pause before inspecting kit bytes")
    expect((try? Data(contentsOf: file)) == original && (try? Data(contentsOf: HelperSettings.file(in: state))) == savedPause,
           "SSD helper refresh preserves saved identity and pause bytes")
    settings.pausedUntil = nil
    try! settings.save(to: state)
    let kit = launcher.appendingPathComponent("Contents/Resources/khu-agent")
    try! fm.createDirectory(at: kit.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try! Data("0.1.11\n".utf8).write(to: kit.appendingPathComponent("VERSION"))
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: kit.appendingPathComponent("bin/khu"))
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: kit.appendingPathComponent("install-agent.sh"))
    try! JSONSerialization.data(withJSONObject: ["feedURL": cfg.feedURL, "enrolURL": "http://127.0.0.1/enrol", "publicKey": cfg.publicKey])
        .write(to: kit.appendingPathComponent("publisher.json"))
    var pins: [String: [String: Any]] = [:]
    for name in ["VERSION", "bin/khu", "publisher.json", "install-agent.sh"] {
        let data = try! Data(contentsOf: kit.appendingPathComponent(name))
        pins[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
    }
    try! JSONSerialization.data(withJSONObject: ["files": pins]).write(to: kit.appendingPathComponent("MANIFEST.json"))
    let layout = StubLayout(base: base)
    let old = try! layout.binary(for: "0.1.10")
    try! fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: old)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
    try! StubSwitcher(layout: layout).install(version: "0.1.10")
    let result = try? SSDHelper.refresh(launcher: launcher, home: home)
    expect(result?.status == "switched" && layout.currentBinary().map(StubLayout.version) == "0.1.11"
           && layout.previousBinary().map(StubLayout.version) == "0.1.10" && (try? Data(contentsOf: file)) == original,
           "SSD helper promotion keeps the old fallback and exact saved connection bytes")
    try! Data("changed".utf8).write(to: kit.appendingPathComponent("bin/khu"))
    expectThrows("SSD helper refuses a changed kit before promotion", contains: "changed") {
        _ = try SSDHelper.refresh(launcher: launcher, home: home)
    }
    cfg.stateDir = home.appendingPathComponent("other-state").path
    try! AtomicFile.writeJSON(cfg, to: file)
    expectThrows("SSD helper refuses a different runtime layout", contains: "different helper layout") {
        _ = try SSDHelper.refresh(launcher: launcher, home: home)
    }
}
