import Foundation

/// Feature 5: a hand-installed copy is offered at its own path; managed and declined apps stay out.
func adoptionTests() {
    let root = tmpDir("adoption")
    let apps = root.appendingPathComponent("Applications")
    try! fm.createDirectory(at: apps, withIntermediateDirectories: true)

    // The fleet's bundle IDs come from the signed feed through Catalog, never from a list here.
    let storyID = "com.fixture.adoption.story", hubID = "com.fixture.adoption.hub"
    var feed = Feed(published_at: "2026-11-19T00:00:00Z")
    for (id, bundle) in [("story", storyID), ("hub", hubID)] {
        var app = FeedApp(version: "1.0.0", file: "\(id).dmg", sha256: String(repeating: "0", count: 64),
                          bytes: 10, kind: "app-dmg")
        app.bundleID = bundle
        feed.apps[id] = app
    }
    let known = Catalog.knownBundles(feed: feed, ssd: [])

    let handInstalled = makeApp(apps.appendingPathComponent("Story Studio KH.app"), version: "1.2.3", id: storyID)
    let managedCopy = makeApp(apps.appendingPathComponent("Hub Studio KH.app"), version: "2.0.0", id: hubID)
    let otherVendor = makeApp(apps.appendingPathComponent("Other Vendor.app"), version: "3.0.0", id: "com.other.vendor")
    let before = (try? fm.contentsOfDirectory(atPath: apps.path)) ?? []

    let offers = Adoption.offers(known: known, managed: [:], folders: [apps])
    expect(offers.count == 2, "AD1 only this fleet's unmanaged bundles are offered")
    let offered = offers.first { $0.appID == "story" }
    expect(offered?.bundleID == storyID && offered?.version == "1.2.3"
           && offered?.existingPath == handInstalled.path,
           "AD2 the hand-installed app is offered at the path where it already lives")
    expect(!offers.contains { $0.existingPath == otherVendor.path }, "AD3 another vendor's bundle id is ignored")

    let withManaged = Adoption.offers(known: known,
                                      managed: ["hub": AppConfig(bundlePath: managedCopy.path, bundleID: hubID)],
                                      folders: [apps])
    expect(!withManaged.contains { $0.appID == "hub" } && withManaged.contains { $0.appID == "story" },
           "AD4 an app already in the config is not offered again")

    let declined = Adoption.offers(known: known, managed: [:], dismissed: ["story"], folders: [apps])
    expect(!declined.contains { $0.appID == "story" } && declined.contains { $0.appID == "hub" },
           "AD5 a declined app stays declined for that app only")

    expect(((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []) == before
           && !fm.fileExists(atPath: apps.appendingPathComponent("Story Studio KH 2.app").path),
           "AD6 scanning and adopting never stage or move a second copy")
}
