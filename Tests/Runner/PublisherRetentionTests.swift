import Foundation
import CryptoKit

/// `FeedPublisher.publish` retirement: once the signed release commits, installers and icons no
/// signed pin names any more — and never one the retention ledger still holds — move to the
/// injected Trash destination. Fixture destinations stand in for the native macOS Trash here;
/// the real Trash is never touched.
func publisherRetentionTests() {
    let root = tmpDir("publisher-retention")
    defer { try? fm.removeItem(at: root) }
    let key = Curve25519.Signing.PrivateKey()
    let keyFile = root.appendingPathComponent("fixture.key")
    try! Signing.savePrivateKey(key, to: keyFile)

    func feedDir(_ tag: String) -> URL {
        let dir = root.appendingPathComponent(tag)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Publishes from `root/src-<source>`, so two apps sharing bytes share a source name and
    /// therefore one content-addressed artifact, exactly as two real DMGs of identical bytes would.
    func publish(_ dir: URL, _ app: String, _ version: String, _ bytes: String,
                 source: String = "artifact.bin", kind: String = "fake-for-tests",
                 meta: ((String) throws -> AppMeta)? = nil,
                 retire: ((URL) throws -> Void)? = nil) throws {
        let src = root.appendingPathComponent("src-" + source)
        try Data(bytes.utf8).write(to: src)
        try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: app, version: version, artifact: src,
                                  kind: kind, allowSame: false, meta: meta, retireArtifact: retire)
    }
    func meta(_ version: String, icon: Data) -> ((String) throws -> AppMeta) {
        { _ in AppMeta(name: "Media Studio KH", bundleID: "com.t.media", bundleName: "Media Studio KH.app",
                       version: version, iconPNG: icon) }
    }
    func stored(_ dir: URL) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("artifacts").path)) ?? [])
    }
    /// File names the fixture Trash holds (recursively; the timestamp folders are skipped).
    func trashed(_ trash: URL) -> Set<String> {
        let all = fm.enumerator(at: trash, includingPropertiesForKeys: [.isDirectoryKey])?
            .allObjects.compactMap { $0 as? URL } ?? []
        return Set(all.filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) == false
        }.map { $0.lastPathComponent })
    }

    // 1. Three versions: the displaced oldest installer and its icon retire only after the signed
    // release is on disk; current and previous stay pinned and verifiable.
    do {
        let dir = feedDir("three-versions")
        let trash = root.appendingPathComponent("system-trash-three")
        var sawFeedVersion: [String] = []
        let retire: (URL) throws -> Void = { file in
            let live = try? FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)
            sawFeedVersion.append(live?.apps["media"]?.version ?? "unpublished")
            _ = try Trash.move(file, into: trash)
        }
        try publish(dir, "media", "1.0.0", "bytes-1", kind: "app-dmg",
                    meta: meta("1.0.0", icon: Data("icon 1".utf8)), retire: retire)
        try publish(dir, "media", "1.0.1", "bytes-2", kind: "app-dmg",
                    meta: meta("1.0.1", icon: Data("icon 2".utf8)), retire: retire)
        let second = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        let oldest = second.previous!["media"]!
        expect(oldest.version == "1.0.0" && stored(dir).contains(oldest.file)
               && stored(dir).contains(oldest.icon ?? ""),
               "RET the displaced installer and its icon are pinned on disk")
        try publish(dir, "media", "1.0.2", "bytes-3", kind: "app-dmg",
                    meta: meta("1.0.2", icon: Data("icon 3".utf8)), retire: retire)
        let feed = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        let current = feed.apps["media"]!, previous = feed.previous!["media"]!
        expect(current.version == "1.0.2" && previous.version == "1.0.1",
               "RET the signed feed names current 1.0.2 and previous 1.0.1")
        expect(stored(dir) == Set([current.file, previous.file, current.icon ?? "", previous.icon ?? ""]),
               "RET exactly the four pinned names remain in artifacts")
        expect(trashed(trash) == Set([oldest.file, oldest.icon ?? ""]),
               "RET the oldest installer and its icon moved to the injected Trash")
        expect(sawFeedVersion == ["1.0.2", "1.0.2"],
               "RET the signed release was already committed before every retired file moved")
        let retired = (fm.enumerator(at: trash, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL } ?? []).first { $0.lastPathComponent == oldest.file }
        expect(retired.flatMap { try? Signing.sha256Hex(fileAt: $0).hex } == oldest.sha256,
               "RET the retired bytes still hash as their signed entry (recoverable)")
        let pinnedFile = dir.appendingPathComponent("artifacts").appendingPathComponent(previous.file)
        let measured = try Signing.sha256Hex(fileAt: pinnedFile)
        expect(measured.hex == previous.sha256 && measured.bytes == previous.bytes,
               "RET the signed previous pin still verifies from disk")
    } catch { expect(false, "RET three versions: \(error)") }

    // 2. One artifact and one icon shared by two apps retire only once no current or previous of
    // either app names them any more.
    do {
        let dir = feedDir("shared-artifact")
        let trash = root.appendingPathComponent("system-trash-shared")
        var moved: [String] = []
        let retire: (URL) throws -> Void = { file in moved.append(file.lastPathComponent)
            _ = try Trash.move(file, into: trash) }
        let sharedIcon = Data("one shared icon".utf8)
        func sharedMeta(_ version: String) -> ((String) throws -> AppMeta) { meta(version, icon: sharedIcon) }
        try publish(dir, "one", "1.0.0", "same bytes", source: "shared.bin", kind: "app-dmg",
                    meta: sharedMeta("1.0.0"), retire: retire)
        try publish(dir, "two", "1.0.0", "same bytes", source: "shared.bin", kind: "app-dmg",
                    meta: sharedMeta("1.0.0"), retire: retire)
        let seed = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        expect(seed.apps["one"]!.file == seed.apps["two"]!.file,
               "RET both apps name the one stored artifact")
        let sharedName = seed.apps["one"]!.file, sharedIconName = seed.apps["one"]!.icon ?? ""
        try publish(dir, "one", "1.0.1", "one v2", kind: "app-dmg", meta: sharedMeta("1.0.1"), retire: retire)
        expect(stored(dir).contains(sharedName) && moved.isEmpty,
               "RET the shared artifact stays while it is one app's previous and the other's current")
        try publish(dir, "two", "1.0.1", "two v2", kind: "app-dmg", meta: sharedMeta("1.0.1"), retire: retire)
        expect(stored(dir).contains(sharedName) && moved.isEmpty,
               "RET it stays while it is both apps' previous")
        try publish(dir, "one", "1.0.2", "one v3", kind: "app-dmg", meta: sharedMeta("1.0.2"), retire: retire)
        expect(stored(dir).contains(sharedName) && moved.isEmpty,
               "RET it stays while the other app's previous still pins it")
        try publish(dir, "two", "1.0.2", "two v3", kind: "app-dmg", meta: sharedMeta("1.0.2"), retire: retire)
        expect(moved == [sharedName] && !stored(dir).contains(sharedName),
               "RET once no current or previous names it, the shared artifact retires")
        expect(stored(dir).contains(sharedIconName),
               "RET the shared icon stays while every entry still names it")
        expect(trashed(trash) == [sharedName] as Set<String>,
               "RET only the unreferenced shared artifact reached the Trash")
    } catch { expect(false, "RET shared artifact: \(error)") }

    // 3. Publishing one app never retires another app's current or previous pins.
    do {
        let dir = feedDir("other-app")
        let trash = root.appendingPathComponent("system-trash-other")
        var moved: [String] = []
        let retire: (URL) throws -> Void = { file in moved.append(file.lastPathComponent)
            _ = try Trash.move(file, into: trash) }
        try publish(dir, "alpha", "1.0.0", "a1", retire: retire)
        try publish(dir, "beta", "1.0.0", "b1", retire: retire)
        try publish(dir, "alpha", "1.0.1", "a2", retire: retire)
        try publish(dir, "beta", "1.0.1", "b2", retire: retire)
        let both = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        let alphaOldest = both.previous!["alpha"]!.file, betaOldest = both.previous!["beta"]!.file
        expect(moved.isEmpty && stored(dir).contains(alphaOldest) && stored(dir).contains(betaOldest),
               "RET both apps keep their two pins through each other's publish")
        try publish(dir, "alpha", "1.0.2", "a3", retire: retire)
        expect(moved == [alphaOldest], "RET alpha's own displaced installer retires and nothing else")
        let after = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        expect(stored(dir).contains(after.apps["beta"]!.file) && stored(dir).contains(after.previous!["beta"]!.file),
               "RET beta's current and previous survive alpha's retirement untouched")
    } catch { expect(false, "RET other app: \(error)") }

    // 4. A Trash failure is loud and retryable: the signed release and both pins stay live, no
    // artifact is lost, the same version stays refused (no blind republish), and the next normal
    // publish finishes the retirement — no --allow-same, no new command.
    do {
        let dir = feedDir("failed-trash")
        let trash = root.appendingPathComponent("system-trash-failed")
        let ok: (URL) throws -> Void = { _ = try Trash.move($0, into: trash) }
        try publish(dir, "media", "1.0.0", "v1", retire: ok)
        try publish(dir, "media", "1.0.1", "v2", retire: ok)
        let before = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        let oldest = before.previous!["media"]!.file, secondOldest = before.apps["media"]!.file
        var calls = 0
        expectThrows("RET a Trash failure is reported loudly", contains: "cannot be moved to the Trash") {
            try publish(dir, "media", "1.0.2", "v3", retire: { _ in calls += 1
                throw khuFail("fixture Trash unavailable") })
        }
        expect(calls == 1, "RET the failing Trash was actually attempted")
        let committed = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        expect(committed.apps["media"]?.version == "1.0.2" && committed.previous?["media"]?.version == "1.0.1",
               "RET the release and both pins are live despite the Trash failure")
        expect(stored(dir).contains(oldest) && stored(dir).contains(secondOldest)
               && stored(dir).contains(committed.apps["media"]!.file),
               "RET nothing was removed while the Trash failed")
        let pinned = committed.previous!["media"]!
        let pinnedFile = dir.appendingPathComponent("artifacts").appendingPathComponent(pinned.file)
        expect(try Signing.sha256Hex(fileAt: pinnedFile).hex == pinned.sha256,
               "RET the signed previous pin still verifies from disk after the failure")
        expectThrows("RET the same version stays refused — no blind republish", contains: "already has") {
            try publish(dir, "media", "1.0.2", "v3 other bytes", retire: ok)
        }
        try publish(dir, "media", "1.0.3", "v4", retire: ok)
        let settled = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        expect(trashed(trash) == [oldest, secondOldest] as Set<String>,
               "RET the next publish retires the leftovers the failed Trash left behind")
        expect(stored(dir) == Set([settled.apps["media"]!.file, settled.previous!["media"]!.file]),
               "RET after the retry only current and previous remain in artifacts")
    } catch { expect(false, "RET failed trash: \(error)") }

    // 5. The retention ledger's recovery pins survive a publish that no longer names them;
    // unreferenced junk with no ledger pin still retires.
    do {
        let dir = feedDir("ledger-pin")
        let trash = root.appendingPathComponent("system-trash-ledger")
        var moved: [String] = []
        let retire: (URL) throws -> Void = { file in moved.append(file.lastPathComponent)
            _ = try Trash.move(file, into: trash) }
        try publish(dir, "media", "1.0.0", "m1", retire: retire)
        let artifacts = dir.appendingPathComponent("artifacts")
        try Data("operator's older copy".utf8).write(to: artifacts.appendingPathComponent("orphan.bin"))
        try Data("leftover".utf8).write(to: artifacts.appendingPathComponent("junk.bin"))
        let orphanHash = try Signing.sha256Hex(fileAt: artifacts.appendingPathComponent("orphan.bin"))
        let seed = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        let ledger: [String: [String: [String: FeedApp]]] = [
            "apps": ["media": ["current": seed.apps["media"]!,
                               "previous": FeedApp(version: "0.9.0", file: "orphan.bin", sha256: orphanHash.hex,
                                                   bytes: orphanHash.bytes, kind: "fake-for-tests")]]]
        try AtomicFile.writeJSON(ledger, to: dir.appendingPathComponent("artifact-retention.json"))
        try publish(dir, "media", "1.0.1", "m2", retire: retire)
        let feed = try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!
        expect(feed.previous?["media"]?.version == "1.0.0",
               "RET the signed fallback is the displaced current, not the ledger seed")
        expect(stored(dir).contains("orphan.bin") && stored(dir).contains(feed.previous!["media"]!.file),
               "RET the ledger's recovery pin survives a publish that no longer names it")
        expect(moved == ["junk.bin"] && trashed(trash) == ["junk.bin"] as Set<String>,
               "RET unledgered junk still retires")
    } catch { expect(false, "RET ledger pin: \(error)") }

    // 6. Nothing injected: a fixture feed's default destination is the feed's own `_trash`, so
    // even the un-injected default can never reach the operator's real Trash from a test.
    do {
        let dir = feedDir("default-destination")
        try publish(dir, "media", "1.0.0", "d1")
        try publish(dir, "media", "1.0.1", "d2")
        let pinned = (try FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)!).previous!["media"]!
        try publish(dir, "media", "1.0.2", "d3")
        expect(trashed(Trash.root(in: dir)).contains(pinned.file),
               "RET the un-injected default retires into the fixture feed's own _trash")
        expect(!stored(dir).contains(pinned.file) && stored(dir).count == 2,
               "RET only current and previous remain in artifacts after the default retirement")
    } catch { expect(false, "RET default destination: \(error)") }
}
