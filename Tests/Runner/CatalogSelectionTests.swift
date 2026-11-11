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
}
