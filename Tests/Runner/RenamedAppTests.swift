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
}
