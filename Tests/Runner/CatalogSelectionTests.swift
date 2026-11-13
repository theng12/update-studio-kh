import Foundation

func catalogSelectionTests() {
    let root = tmpDir("catalog-selection")
    let installer = root.appendingPathComponent("Fixture.dmg")
    let data = Data("fixture installer bytes".utf8)
    try! data.write(to: installer)
    let sha = Signing.sha256Hex(data)
    var server = FeedApp(version: "2.0", file: "server.dmg", sha256: sha, bytes: Int64(data.count), kind: "app-dmg")
    server.bundleID = "com.fixture.catalog"; server.bundleName = "Fixture.app"
    let feed = Feed(published_at: ISO.string(Date()), apps: ["fixture": server])
    func app(_ version: String) -> SSDApp {
        var app = SSDApp(id: "fixture", name: "Fixture", version: version, bundleID: "com.fixture.catalog", bundleName: "Fixture.app", file: installer.lastPathComponent, sha256: sha)
        app.bytes = Int64(data.count)
        return app
    }
    func row(_ app: SSDApp, offline: Bool = false) -> CatalogEntry? {
        Catalog.build(feed: offline ? nil : feed, ssd: [SSDSource(volume: "Fixture SSD", root: root, index: SSDIndex(apps: [app]))]).first
    }
    let old = row(app("1.0")), same = row(app("2.0")), newer = row(app("3.0"))
    expect(old?.ssd == nil && old?.initialSSD?.version == "1.0" && old?.available == "2.0", "CS1 older SSD stays an explicit first-install choice")
    expect(same?.ssd?.version == "2.0" && same?.initialSSD?.bytes == Int64(data.count), "CS2 identical signed SSD bytes win with the declared size")
    expect(newer?.available == "3.0" && newer?.source == "Fixture SSD", "CS3 newer SSD wins")
    expect(row(app("2.0"), offline: true)?.ssd != nil, "CS4 usable SSD works without a server answer")
    var bad = app("2.0"); bad.sha256 = String(repeating: "0", count: 64)
    expect(row(bad)?.ssd == nil && row(bad)?.initialSSD == nil && row(bad)?.ssdNote != nil, "CS5 same-version different bytes never impersonate the signed version")
    bad = app("bad")
    expect(row(bad)?.ssd == nil && row(bad)?.initialSSD == nil, "CS6 invalid versions are not eligible")
    bad = app("2.0"); bad.bytes = 1
    expect(row(bad)?.ssd == nil, "CS7 wrong declared size is refused")
    bad = app("2.0"); bad.bundleID = "com.fixture.other"
    expect(row(bad)?.ssd == nil, "CS8 a reused app id cannot replace another bundle identity")
    bad = app("2.0"); bad.file = "../Fixture.dmg"
    expect(row(bad)?.ssd == nil, "CS9 paths outside the drive are refused")
    bad = app("2.0"); bad.file = "missing.dmg"
    expect(row(bad)?.ssd == nil && row(bad)?.initialSSD == nil, "CS10 missing installers are not advertised as eligible")
    let link = root.appendingPathComponent("link.dmg")
    try! fm.createSymbolicLink(at: link, withDestinationURL: installer)
    bad = app("2.0"); bad.file = link.lastPathComponent
    expect(row(bad)?.ssd == nil, "CS11 symbolic installer links are refused")
    expect(Catalog.build(feed: feed, ssd: []).first?.available == "2.0", "CS12 a new feed-only app needs no registry change")
    // An app that updates itself still carries its installer: the person at the Mac may choose it.
    var itself = app("2.0"); itself.updatesItself = true
    expect(row(itself)?.ssd?.version == "2.0" && row(itself)?.initialSSD?.version == "2.0",
           "CS13 an app that updates itself still offers the copy on the SSD, for an explicit install")
    itself = app("1.0"); itself.updatesItself = true
    expect(row(itself)?.ssd == nil && row(itself)?.initialSSD?.version == "1.0",
           "CS14 an older SSD copy of an app that updates itself stays an explicit first-install choice")
    // The signed feed's own kind is the policy: no hard-coded app-id registry, no SSD needed.
    // `status` is the one kind that keeps an app out of the installer; Story and Hub publish as
    // `app-dmg` and install like every other app now.
    do {
        var own = server
        own.kind = "status"; own.bundleID = "com.fixture.status"; own.bundleName = "status.app"
        let ownFeed = Feed(published_at: feed.published_at, apps: ["status": own])
        let catalog = Catalog.build(feed: ownFeed, ssd: [])
        expect(catalog.first?.updatesItself == true && catalog.first?.setupFolder == nil,
               "CS15 the feed's status kind preserves a status-only policy without an SSD or invented setup")
        let known = Catalog.knownBundles(feed: ownFeed, ssd: [])
        let folder = root.appendingPathComponent("status")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = makeApp(folder.appendingPathComponent(own.bundleName!), version: "1.0", id: own.bundleID!)
        let discovered = Catalog.discover(config: AgentConfig(feedURL: "http://127.0.0.1/release.json", publicKey: "fixture",
                                                             stateDir: folder.path, machine: "fixture", token: "fixture", apps: [:]),
                                          known: known, folders: [folder])
        expect(discovered["status"]?.recipe == "status" && discovered["status"]?.automatic == false,
               "CS16 hand-installed status app remains observed, not automatically replaced")
        var config = AgentConfig(feedURL: "http://127.0.0.1/release.json", publicKey: "fixture", stateDir: folder.path,
                                 machine: "fixture", token: "fixture", apps: [:])
        let state = folder.appendingPathComponent("state")
        let failures = try! Agent.registerLauncherApps(["status"], catalog: catalog, config: &config, stateDir: state, folders: [folder])
        expect(failures.isEmpty && config.apps["status"]?.recipe == "status" && config.apps["status"]?.automatic == false,
               "CS17 a first-install request registers a status app under its own status recipe, never as an app it manages alone")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        Catalog.remember([], feed: ownFeed, in: state)
        expect(Catalog.seen(in: state).first?.updatesItself == true,
               "CS18 a status app's policy survives an offline or unplugged-source run")
    }
    // A drive or a remembered entry cannot keep Story or Hub self-updating once the signed feed
    // offers them as installers: the live source wins, with no app id special-cased anywhere.
    for id in ["story", "hub"] {
        var live = server
        live.kind = "app-dmg"
        live.bundleID = "com.fixture.\(id)"; live.bundleName = "\(id).app"
        let liveFeed = Feed(published_at: feed.published_at, apps: [id: live])
        let driveCopy = SSDApp(id: id, name: id, version: "2.0", bundleID: live.bundleID!, bundleName: live.bundleName,
                               file: nil, sha256: nil, updatesItself: true)
        let drive = SSDSource(volume: "Fixture SSD", root: root, index: SSDIndex(apps: [driveCopy]))
        let catalog = Catalog.build(feed: liveFeed, ssd: [drive], seen: [driveCopy])
        expect(catalog.first?.updatesItself == false,
               "CS19 \(id) is installable as soon as the signed feed offers it, though a remembered drive said otherwise")
        expect(Catalog.knownBundles(feed: liveFeed, ssd: [driveCopy])[live.bundleID!]?.updatesItself == false,
               "CS19 a hand-installed \(id) is discovered as managed, not as an app that updates itself")
        // The stale flag in the remembered cache is cleared by the next run, with no hand edit.
        let state = root.appendingPathComponent("policy-\(id)")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        try! AtomicFile.writeJSON([driveCopy.bundleID: driveCopy], to: Catalog.seenFile(in: state))
        Catalog.remember([drive], feed: liveFeed, in: state)
        expect(Catalog.seen(in: state).first { $0.bundleID == live.bundleID }?.updatesItself == false,
               "CS19 the signed feed clears a stale self-updating flag in the remembered cache")
    }
}
