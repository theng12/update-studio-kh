import Foundation

/// RA1–RA3 (owner via S001, 2026-11-25). On this Mac Relay was drawn twice — `relay` 0.3.39 under
/// "Installed on this Mac" and `Relay Studio KH · Not installed · 0.3.40` under Not installed —
/// because the kit's config still keys it `relay` while the feed publishes `relay-studio`. Identity
/// is the bundle id (studio-gate rule 3), so the fold has to happen before anything is counted.
func renamedAppTests() {
    func feedRow(_ id: String, bundle: String?, version: String) -> (String, FeedApp) {
        var app = FeedApp(version: version, file: "\(id).dmg", sha256: String(repeating: "0", count: 64),
                          bytes: 10, kind: "app-dmg")
        app.bundleID = bundle
        return (id, app)
    }
    var feed = Feed(published_at: "2026-11-25T00:00:00Z")
    for (id, app) in [feedRow("relay-studio", bundle: "kh.relay.desktop", version: "0.3.40"),
                      feedRow("hub", bundle: "local.studiohub.standalone", version: "0.6.260")] { feed.apps[id] = app }

    let relayPath = "/Applications/Relay Studio KH.app"
    let strangerPath = "/Applications/Some Stranger.app"
    let configs = [
        "relay": AppConfig(bundlePath: relayPath, recipe: "app-dmg", automatic: true, bundleID: nil),
        "stranger": AppConfig(bundlePath: strangerPath, recipe: "app-dmg", automatic: true, bundleID: nil),
        "hub": AppConfig(bundlePath: "/Applications/Hub Studio KH.app", recipe: "app-dmg", automatic: true, bundleID: nil),
    ]
    let bundles = [relayPath: "kh.relay.desktop", strangerPath: "com.example.stranger",
                   "/Applications/Hub Studio KH.app": "local.studiohub.standalone"]
    let folded = Agent.foldRenamed(configs, feed: feed) { bundles[$0.bundlePath] }

    // RA1 the kit's old id becomes the feed's id: one row, and it is the one the feed publishes.
    expect(folded["relay"] == nil, "RA1 the kit id `relay` is gone once its bundle is found on the feed")
    expect(folded["relay-studio"]?.bundlePath == relayPath,
           "RA1 `relay-studio` now carries the local config, so the row reads installed with an update")
    // RA2 an app the feed truly does not know keeps its own id — the stranger list must still work.
    expect(folded["stranger"]?.bundlePath == strangerPath,
           "RA2 an app whose bundle no feed row publishes stays under its own id")
    // RA3 nothing else moves: an id the feed already uses is left exactly as it was.
    expect(folded["hub"]?.bundlePath == "/Applications/Hub Studio KH.app",
           "RA3 a config whose id already matches the feed is untouched")
    expect(folded.count == 3, "RA3 the fold neither adds nor loses a row (got \(folded.count))")

    // RA4–RA5 (owner 2026-11-27, 1301): the fold the work loop itself runs, from the ids this Mac
    // remembers from the feed. A kit still keyed `relay` sat beside a registration under
    // `relay-studio`, and `validate` refused the whole run as "one app per bundle" — so the app
    // could never update. The fold now happens before validation, and a second entry for the same
    // bundle does not make the run fatal.
    let rig = Rig("fold-work")
    let relayApp = makeApp(rig.root.appendingPathComponent("Relay Studio KH.app"), version: "0.3.41", id: "kh.relay.desktop")
    try! AtomicFile.writeJSON(["kh.relay.desktop": SSDApp(id: "relay-studio", name: "Relay Studio KH",
                                                          version: "0.3.41", bundleID: "kh.relay.desktop",
                                                          updatesItself: false)],
                              to: Catalog.seenFile(in: rig.state))
    var cfg = agentConfig(rig, token: "unused", apps: ["relay": AppConfig(bundlePath: relayApp.path, recipe: "app-dmg", automatic: true)])
    cfg.stateDir = rig.state.path
    let notes = Agent.foldConfig(&cfg, stateDir: rig.state, ssd: [])
    expect(cfg.apps["relay-studio"]?.bundlePath == relayApp.path && cfg.apps["relay"] == nil
           && !notes.isEmpty && notes[0].contains("folded"),
           "RA4 the work-site fold moves a kit's old id onto the feed's id for its bundle (\(notes))")
    var both = agentConfig(rig, token: "unused", apps: [
        "relay": AppConfig(bundlePath: relayApp.path, recipe: "app-dmg", automatic: true),
        "relay-studio": AppConfig(bundlePath: relayApp.path, recipe: "app-dmg", automatic: true),
    ])
    both.stateDir = rig.state.path
    _ = Agent.foldConfig(&both, stateDir: rig.state, ssd: [])
    expect(both.apps.count == 1 && both.apps["relay-studio"] != nil && (try? Agent.validate(both)) != nil,
           "RA5 with both ids the old one is dropped and the config still validates")

    // RA6 the fold is written back, so the saved config no longer carries the old id and the next run
    // does not fold again; every other key and the file's own mode are left as they were.
    let file = rig.root.appendingPathComponent("config.json")
    let saved: [String: Any] = ["machine": "mac1", "feedURL": "https://example.test/release.json",
                                "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": true],
                                         "relay": ["bundlePath": relayApp.path, "recipe": "app-dmg", "automatic": true]]]
    try! JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted]).write(to: file)
    try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var persisted = agentConfig(rig, token: "unused", apps: ["relay": AppConfig(bundlePath: relayApp.path, recipe: "app-dmg", automatic: true)])
    persisted.stateDir = rig.state.path
    _ = Agent.foldConfig(&persisted, stateDir: rig.state, ssd: [], file: file)
    let written = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
    let writtenApps = written?["apps"] as? [String: [String: Any]]
    let writtenMode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
    expect(writtenApps?["relay"] == nil && writtenApps?["relay-studio"]?["bundlePath"] as? String == relayApp.path
           && writtenApps?["updater"] != nil && written?["machine"] as? String == "mac1" && writtenMode?.intValue == 0o600,
           "RA6 the fold is saved: the old id is gone, the feed's id carries the entry, and the rest is untouched")
    expect(Agent.foldConfig(&persisted, stateDir: rig.state, ssd: []).isEmpty,
           "RA6 a second run finds nothing to fold")
}
