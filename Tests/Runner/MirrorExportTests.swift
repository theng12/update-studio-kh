import Foundation

/// `khu mirror`: the live signed feed restated for a release page that stores its own asset names.
func mirrorExportTests() {
    let root = tmpDir("mirror-export")
    let feedDir = root.appendingPathComponent("feed")
    try! fm.createDirectory(at: feedDir, withIntermediateDirectories: true)
    let pair = Signing.generateKeyPair()
    let keyFile = root.appendingPathComponent("private.key")
    try! Signing.savePrivateKey(pair.privateKey, to: keyFile)

    let launcherBytes = Data(repeating: 7, count: 4096)
    let updaterBytes = Data(repeating: 9, count: 128)
    let oldBytes = Data(repeating: 3, count: 2048)
    let iconBytes = Data(repeating: 5, count: 64)
    let launcherSHA = Signing.sha256Hex(launcherBytes)
    let updaterSHA = Signing.sha256Hex(updaterBytes)
    let oldSHA = Signing.sha256Hex(oldBytes)
    let iconSHA = Signing.sha256Hex(iconBytes)

    var launcher = FeedApp(version: "0.1.65", file: "abc-launcher.dmg", sha256: launcherSHA,
                           bytes: Int64(launcherBytes.count), kind: "app-dmg")
    launcher.icon = "abc-icon.png"; launcher.iconSha256 = iconSHA
    launcher.delta = ArtifactDelta(file: "abc-delta", sha256: Signing.sha256Hex(Data("patch".utf8)), bytes: 5,
                                   baseSHA256: oldSHA, baseBytes: Int64(oldBytes.count))
    var old = FeedApp(version: "0.1.64", file: "old-launcher.dmg", sha256: oldSHA,
                      bytes: Int64(oldBytes.count), kind: "app-dmg")
    old.icon = "old-icon.png"; old.iconSha256 = iconSHA
    var feed = Feed(published_at: ISO.string(Date()))
    feed.apps["launcher"] = launcher
    feed.apps["updater"] = FeedApp(version: "0.1.65", file: "def-khu", sha256: updaterSHA,
                                   bytes: Int64(updaterBytes.count), kind: "updater")
    feed.previous = ["launcher": old]
    feed.network = FeedNetwork(feedURLs: ["http://100.64.0.7:8790/release.json"])
    try! FeedPublisher.saveFeed(feed, to: feedDir, key: pair.privateKey)

    let names = root.appendingPathComponent("names.tsv")
    let rows = [
        "app\ttag\tfeed file\tstored asset\tsha256",
        "launcher\tlauncher-v0.1.65\tabc-launcher.dmg\tStudio Launcher KH 0.1.65.dmg\t\(launcherSHA)",
        "launcher\tlauncher-v0.1.65\tabc-icon.png\ticon-abc.png\t\(iconSHA)",
        "launcher\tlauncher-v0.1.64\told-launcher.dmg\tStudio Launcher KH 0.1.64.dmg\t\(oldSHA)",
        "launcher\tlauncher-v0.1.64\told-icon.png\ticon-old.png\t\(iconSHA)",
        "updater\thelper-v0.1.65\tdef-khu\tkhu\t\(updaterSHA)",
    ]
    try! Data((rows.joined(separator: "\n") + "\n").utf8).write(to: names)

    let base = "https://github.com/theng12/kh-releases/releases/download"
    let out = root.appendingPathComponent("mirror-release.json")
    let written = try! FeedMirror.export(feedDir: feedDir, keyFile: keyFile, out: out, base: base,
                                         names: names, apps: ["launcher", "updater"])
    expect(written.count == 2, "MX1 the readback names one address per chosen app")
    expect(written.contains { $0.app == "launcher"
        && $0.url == base + "/launcher-v0.1.65/Studio%20Launcher%20KH%200.1.65.dmg"
        && $0.bytes == Int64(launcherBytes.count) },
        "MX2 the launcher's address is the release page's own asset name with its signed size")

    guard let release = try? AtomicFile.readJSON(Release.self, from: out), let body = release.feedData,
          let signature = release.signatureData else {
        expect(false, "MX3 the mirrored feed was written")
        return
    }
    expect(Signing.verify(body, signature: signature, publicKey: pair.privateKey.publicKey),
           "MX3 the mirrored feed verifies with the publisher's own key")
    let back = try! JSON.decode(Feed.self, from: body)
    expect(back.network?.feedURLs == ["http://100.64.0.7:8790/release.json"] && back.network?.controller == nil,
           "MX4 the mirror keeps the public addresses and never the publisher's own controller")
    expect(back.apps["launcher"]?.sha256 == launcherSHA && back.apps["launcher"]?.bytes == Int64(launcherBytes.count),
           "MX5 sizes and checksums are untouched")
    expect(back.apps["launcher"]?.file == "Studio Launcher KH 0.1.65.dmg",
           "MX6 the entry names what the release page stores")
    expect(back.apps["launcher"]?.delta == nil, "MX7 the patch, which the page does not hold, is left out")
    expect(back.apps["launcher"]?.icon == "icon-abc.png" && back.apps["launcher"]?.iconSha256 == iconSHA,
           "MX8 the icon keeps its checksum and takes the stored name")
    expect(back.previous?["launcher"]?.file == "Studio Launcher KH 0.1.64.dmg"
           && back.previous?["launcher"]?.url == base + "/launcher-v0.1.64/Studio%20Launcher%20KH%200.1.64.dmg",
           "MX9 the previous version is restated for the same page")
    expect(back.artifactIdentity == feed.artifactIdentity, "MX10 the mirrored feed is the same release")
    expect(back.apps["updater"] != nil && back.previous?["updater"] == nil, "MX11 only the chosen apps are carried")

    // A release page holding different bytes than the feed signs is not this release.
    let wrong = root.appendingPathComponent("wrong.tsv")
    try! Data((rows.map { $0.replacingOccurrences(of: launcherSHA, with: updaterSHA) }.joined(separator: "\n") + "\n").utf8)
        .write(to: wrong)
    expectThrows("MX12 an asset whose checksum differs from the signed installer is refused",
                 contains: "not the signed installer") {
        _ = try FeedMirror.export(feedDir: feedDir, keyFile: keyFile, out: root.appendingPathComponent("wrong.json"),
                                  base: base, names: wrong, apps: ["launcher", "updater"])
    }
    let missing = root.appendingPathComponent("missing.tsv")
    try! Data((rows.filter { !$0.hasPrefix("updater") }.joined(separator: "\n") + "\n").utf8).write(to: missing)
    expectThrows("MX13 an app the names file has no row for is refused", contains: "has no row") {
        _ = try FeedMirror.export(feedDir: feedDir, keyFile: keyFile, out: root.appendingPathComponent("missing.json"),
                                  base: base, names: missing, apps: ["launcher", "updater"])
    }
    expectThrows("MX14 a plain-http release page is refused", contains: "https") {
        _ = try FeedMirror.export(feedDir: feedDir, keyFile: keyFile, out: root.appendingPathComponent("plain.json"),
                                  base: "http://github.com/theng12/kh-releases/releases/download",
                                  names: names, apps: ["launcher", "updater"])
    }
    expect(!fm.fileExists(atPath: root.appendingPathComponent("wrong.json").path)
           && !fm.fileExists(atPath: root.appendingPathComponent("missing.json").path)
           && !fm.fileExists(atPath: root.appendingPathComponent("plain.json").path),
           "MX15 a refused mirror writes nothing")

    // A public page needs no downgrade path, and the builds before a release are the ones a safety
    // fix retired. `--current-only` writes the same release with no previous at all, and says which
    // apps it left out, instead of demanding those older installers be uploaded.
    let currentOut = root.appendingPathComponent("current-only.json")
    var omitted: [String] = []
    let currentOnly = try! FeedMirror.export(feedDir: feedDir, keyFile: keyFile, out: currentOut, base: base,
                                             names: names, apps: ["launcher", "updater"], currentOnly: true,
                                             previousOmitted: { omitted.append($0) })
    expect(currentOnly.count == 2, "MX16 --current-only still names every chosen app's installer")
    expect(omitted == ["launcher"], "MX17 --current-only reports the app whose previous was left out")
    guard let currentRelease = try? AtomicFile.readJSON(Release.self, from: currentOut),
          let currentBody = currentRelease.feedData else {
        expect(false, "MX18 the current-only feed was written")
        return
    }
    let current = try! JSON.decode(Feed.self, from: currentBody)
    expect(current.previous == nil, "MX18 --current-only writes no previous entry at all")
    expect(current.apps["launcher"]?.version == "0.1.65" && current.apps["launcher"]?.sha256 == launcherSHA,
           "MX19 the current entry is unchanged")
    expect(current.published_at == feed.published_at,
           "MX20 it is the same release: same published_at, only the previous block differs")
    // The strict default is untouched: without the flag the same call still restates `previous`.
    var strictOmitted: [String] = []
    _ = try! FeedMirror.export(feedDir: feedDir, keyFile: keyFile, out: root.appendingPathComponent("strict.json"),
                               base: base, names: names, apps: ["launcher", "updater"],
                               previousOmitted: { strictOmitted.append($0) })
    expect(strictOmitted.isEmpty, "MX21 the default still carries every previous entry")
}
