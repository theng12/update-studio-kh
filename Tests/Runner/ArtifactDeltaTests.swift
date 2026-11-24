import Foundation
import CryptoKit

/// The publisher's artifacts served to one Mac, with every byte counted.
private final class ArtifactClient: HTTPClient, @unchecked Sendable {
    var files: [String: Data] = [:]
    var requests: [String] = []
    var phases: [String] = []
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64, phase: String) throws -> Int {
        phases.append(phase)
        DownloadControl.updateProgress(phase)
        return try download(url, headers: headers, to: file, limit: limit)
    }
    var servedBytes = 0
    var cancelNext = false
    var cancelAfterWrite = false
    /// Hosts that serve nothing, so one source of an operation can be given no patch at all.
    var failingHosts: Set<String> = []
    /// Every URL asked for, with the source it was asked of.
    var requestURLs: [String] = []
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { throw khuFail("unexpected GET \(url.path)") }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw khuFail("unexpected POST \(url.path)") }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        requests.append(url.lastPathComponent)
        requestURLs.append(url.absoluteString)
        if cancelNext {
            cancelNext = false
            DownloadControl.cancel()
            throw khuFail("cancelled on this Mac; nothing was changed")
        }
        guard let data = files[url.lastPathComponent], !failingHosts.contains(url.host ?? "") else { throw URLError(.cannotConnectToHost) }
        guard data.count <= limit else { throw DeliveryMismatch(description: "larger than expected") }
        try data.write(to: file)
        servedBytes += data.count
        if cancelAfterWrite { cancelAfterWrite = false; DownloadControl.cancel() }
        return 200
    }
}

/// A Mac that already holds a whole artifact: the only base a patch may be applied to.
func artifactDeltaTests() {
    do {
        let root = tmpDir("artifact-delta")
        let feedDir = root.appendingPathComponent("feed")
        try fm.createDirectory(at: feedDir, withIntermediateDirectories: true)
        let pair = Signing.generateKeyPair()
        let keyFile = root.appendingPathComponent("private.key")
        try Signing.savePrivateKey(pair.privateKey, to: keyFile)

        // The installer a Mac already has, and the one that replaces it: they differ in one block.
        let pattern = Data((0..<4096).map { UInt8($0 % 251) })
        var base = Data()
        while base.count < 256 * 1024 { base.append(pattern) }
        var target = base
        target.replaceSubrange(70_000..<70_512, with: Data(repeating: 0xAB, count: 512))
        let baseURL = root.appendingPathComponent("base.dmg")
        let targetURL = root.appendingPathComponent("target.dmg")
        try base.write(to: baseURL)
        try target.write(to: targetURL)

        try FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "fixture", version: "1.0.0",
                                  artifact: baseURL, kind: "fake-for-tests", allowSame: false, meta: nil, url: "https://example.test/\(baseURL.lastPathComponent)")
        try FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "fixture", version: "1.0.1",
                                  artifact: targetURL, kind: "fake-for-tests", allowSame: false, meta: nil, url: "https://example.test/\(targetURL.lastPathComponent)")
        let feed = try FeedPublisher.loadVerifiedFeed(from: feedDir, publicKey: pair.privateKey.publicKey)!
        let current = feed.apps["fixture"]!
        let older = feed.previous?["fixture"]
        expect(older != nil, "AD1 the displaced installer stays pinned as the fallback")
        expect(older?.delta == nil, "AD1 the displaced installer carries no patch of its own")
        guard let delta = current.delta, let old = older else {
            expect(false, "AD1 a publish that replaces an installer carries a patch")
            return
        }
        expect(delta.baseSHA256 == old.sha256 && delta.baseBytes == old.bytes,
               "AD2 the patch is built for the exact bytes of the installer it replaces")
        let patchFile = feedDir.appendingPathComponent("artifacts").appendingPathComponent(delta.file)
        let patch = try Signing.sha256Hex(fileAt: patchFile)
        expect(patch.hex == delta.sha256 && patch.bytes == delta.bytes, "AD2 the patch is stored under its own signed hash")
        expect(delta.bytes > 0 && delta.bytes < current.bytes,
               "AD2 the patch is smaller than the whole artifact (\(delta.bytes) of \(current.bytes) bytes)")

        // An agent built before patches existed reads the very same signed feed.
        struct LegacyApp: Decodable { var version: String; var file: String; var sha256: String; var bytes: Int64; var kind: String }
        struct LegacyFeed: Decodable { var schema: Int; var published_at: String; var apps: [String: LegacyApp] }
        let releaseData = try Data(contentsOf: FeedPublisher.releaseFile(in: feedDir))
        let release = try JSON.decode(Release.self, from: releaseData)
        let legacy = try JSON.decode(LegacyFeed.self, from: release.feedData!)
        expect(legacy.apps["fixture"]?.version == "1.0.1" && legacy.apps["fixture"]?.sha256 == current.sha256,
               "AD3 a client that does not know patches reads the signed feed unchanged")

        let client = ArtifactClient()
        let serverBase = URL(string: "http://127.0.0.1:8790")!
        client.files[old.file] = base
        client.files[current.file] = target
        client.files[delta.file] = try Data(contentsOf: patchFile)
        func freshState(_ tag: String) throws -> URL {
            let state = root.appendingPathComponent("state-\(tag)-\(UUID().uuidString.prefix(6))")
            try fm.createDirectory(at: state, withIntermediateDirectories: true)
            return state
        }
        func deliver(_ state: URL, _ entry: FeedApp) throws -> (URL, Int, [String]) {
            let before = client.servedBytes
            client.requests.removeAll()
            client.phases.removeAll()
            let url = try Agent.download(entry, app: "fixture", serverBase: serverBase, stateDir: state, http: client)
            return (url, client.servedBytes - before, client.requests)
        }
        /// One operation with a named first source and the sources it may fall back to.
        func deliverFrom(_ state: URL, _ entry: FeedApp, _ first: URL, _ fallbacks: [URL]) throws -> (URL, Int, [String]) {
            let before = client.servedBytes
            client.requests.removeAll()
            client.phases.removeAll()
            client.requestURLs.removeAll()
            let url = try Agent.download(entry, app: "fixture", serverBase: first, stateDir: state, http: client, fallbacks: fallbacks)
            return (url, client.servedBytes - before, client.requestURLs)
        }

        // The first installer: nothing to patch from, so it is fetched whole.
        let firstState = try freshState("full")
        let (firstFile, firstBytes, firstRequests) = try deliver(firstState, old)
        expect(firstBytes == base.count && firstRequests == [old.file], "AD4 an artifact with no patch is fetched whole")
        expect((try? Signing.sha256Hex(fileAt: firstFile).hex) == old.sha256, "AD4 the whole artifact matches its signed hash")

        // The next one: the patch alone.
        let secondState = try freshState("delta")
        _ = try deliver(secondState, old)
        let (secondFile, secondBytes, secondRequests) = try deliver(secondState, current)
        expect(secondRequests == [delta.file], "AD5 the newer artifact arrives as a patch only")
        expect(secondBytes == delta.bytes && secondBytes < current.bytes,
               "AD5 the patch transfers \(secondBytes) bytes instead of the whole \(current.bytes)")
        let rebuilt = try Signing.sha256Hex(fileAt: secondFile)
        expect(rebuilt.hex == current.sha256 && rebuilt.bytes == current.bytes,
               "AD5 the rebuilt artifact matches the signed size and hash")

        let ssdState = try freshState("ssd-base")
        let local = CatalogEntry.Local(volume: "Fixture SSD", file: baseURL.path, sha256: old.sha256, version: old.version, bytes: old.bytes)
        let cfg = AppConfig(bundlePath: root.appendingPathComponent("Fixture.app").path, recipe: "fake-for-tests")
        let localResult = try Agent.installLocal(local, app: "fixture", installed: nil, cfg: cfg, stateDir: ssdState,
                                                shell: RecordingShell(mount: root), control: { _, _ in
            AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true }, healthSettle: 0)
        })
        let (fromSSD, ssdBytes, ssdRequests) = try deliver(ssdState, current)
        expect(localResult.status == "updated" && ssdRequests == [delta.file] && ssdBytes == delta.bytes,
               "AD5 a verified older SSD install supplies the next server patch base")
        expect((try? Signing.sha256Hex(fileAt: fromSSD).hex) == current.sha256, "AD5 SSD-based reconstruction matches the signed target")

        // A base that no longer matches its signed hash: the whole artifact is fetched instead.
        let brokenState = try freshState("broken")
        let (brokenBase, _, _) = try deliver(brokenState, old)
        var damaged = try Data(contentsOf: brokenBase)
        damaged[0] = damaged[0] ^ 0xFF
        try damaged.write(to: brokenBase)
        let (afterBreak, breakBytes, breakRequests) = try deliver(brokenState, current)
        expect(breakRequests == [current.file] && breakBytes == current.bytes,
               "AD6 a modified base falls back to the whole signed artifact")
        expect((try? Signing.sha256Hex(fileAt: afterBreak).hex) == current.sha256,
               "AD6 the fallback still delivers the signed artifact")

        // A patch whose bytes do not match what the feed signed for it.
        let corruptState = try freshState("corrupt")
        _ = try deliver(corruptState, old)
        client.files[delta.file] = Data("not the patch".utf8)
        let (afterCorrupt, corruptBytes, corruptRequests) = try deliver(corruptState, current)
        expect(corruptRequests.last == current.file && corruptBytes >= current.bytes,
               "AD7 a corrupt patch falls back to the whole signed artifact")
        expect((try? Signing.sha256Hex(fileAt: afterCorrupt).hex) == current.sha256,
               "AD7 the fallback still delivers the signed artifact")
        expect(client.phases == ["delta-downloading", "full-fallback"], "AD7 full fallback keeps its transfer label")
        let refused = (try? fm.contentsOfDirectory(atPath: corruptState.appendingPathComponent("downloads/fixture").path)) ?? []
        expect(!refused.contains { $0.hasSuffix(".part") }, "AD16 a refused patch leaves no partial file behind")
        client.files[delta.file] = try Data(contentsOf: patchFile)

        // A patch the server does not have at all.
        let missingState = try freshState("missing")
        _ = try deliver(missingState, old)
        client.files.removeValue(forKey: delta.file)
        let (afterMissing, missingBytes, missingRequests) = try deliver(missingState, current)
        expect(missingRequests.last == current.file && missingBytes == current.bytes,
               "AD8 a missing patch falls back to the whole signed artifact")
        expect((try? Signing.sha256Hex(fileAt: afterMissing).hex) == current.sha256,
               "AD8 the fallback still delivers the signed artifact")
        client.files[delta.file] = try Data(contentsOf: patchFile)

        // A source with no patch must not take the exact base away from the next source.
        let retryState = try freshState("source-retry")
        _ = try deliver(retryState, old)
        let first = URL(string: "http://a.invalid")!
        let second = URL(string: "http://b.invalid")!
        client.failingHosts = ["a.invalid"]
        let (fromSecond, retryBytes, retryURLs) = try deliverFrom(retryState, current, first, [second])
        expect(retryURLs.contains("http://b.invalid/artifacts/\(delta.file)"),
               "AD14 the next source is offered the patch, not only the whole artifact")
        expect(retryBytes == delta.bytes, "AD14 the next source's patch is used, not the whole artifact")
        expect((try? Signing.sha256Hex(fileAt: fromSecond).hex) == current.sha256,
               "AD14 the second source still delivers the signed artifact")

        // Both sources failing keeps the exact base, so a later run still patches.
        let keptState = try freshState("kept-base")
        _ = try deliver(keptState, old)
        client.failingHosts = ["a.invalid", "c.invalid"]
        var bothFailed = false
        do { _ = try deliverFrom(keptState, current, first, [URL(string: "http://c.invalid")!]) } catch { bothFailed = true }
        expect(bothFailed, "AD15 both sources failing is reported, not swallowed")
        client.failingHosts = []
        let (keptFile, keptBytes, _) = try deliverFrom(keptState, current, second, [])
        expect(keptBytes == delta.bytes, "AD15 the exact base survived the failed sources, so only the patch is fetched")
        expect((try? Signing.sha256Hex(fileAt: keptFile).hex) == current.sha256,
               "AD15 the surviving base still builds the signed artifact")

        // A base left over from another patch is retired, not used and not stranded.
        let changeState = try freshState("base-change")
        _ = try deliver(changeState, old)
        let slot = changeState.appendingPathComponent("downloads/.khu-patch-base-fixture")
        try Data(repeating: 0x5A, count: 1024).write(to: slot)
        let (changedFile, changedBytes, _) = try deliver(changeState, current)
        expect(changedBytes == delta.bytes, "AD17 a base for another patch is retired, not used")
        expect((try? Signing.sha256Hex(fileAt: changedFile).hex) == current.sha256,
               "AD17 the signed artifact is still built from the signed base")
        expect(!fm.fileExists(atPath: slot.path), "AD17 the one slot per app holds no base after the replacement")

        // A release with no patch retires the kept base once the new artifact is in place.
        let retireState = try freshState("retire-slot")
        _ = try deliver(retireState, old)
        client.failingHosts = ["a.invalid"]
        var slotFailed = false
        do { _ = try deliverFrom(retireState, current, first, []) } catch { slotFailed = true }
        expect(slotFailed, "AD18 the failing operation is reported")
        client.failingHosts = []
        let retireSlot = retireState.appendingPathComponent("downloads/.khu-patch-base-fixture")
        expect((try? Signing.sha256Hex(fileAt: retireSlot).hex) == old.sha256,
               "AD18 a failed operation keeps the exact base in its slot")
        _ = try deliver(retireState, old)
        expect(!fm.fileExists(atPath: retireSlot.path),
               "AD18 a successful full replacement retires the kept base")

        // A cancel stops the delivery: it does not start a second, whole download.
        let cancelState = try freshState("cancel")
        _ = try deliver(cancelState, old)
        DownloadControl.reset()
        client.cancelNext = true
        var cancelled = false
        do { _ = try deliver(cancelState, current) } catch { cancelled = true }
        expect(cancelled && client.requests == [delta.file], "AD9 a cancelled patch stops instead of fetching the whole artifact")
        DownloadControl.reset()

        let afterWriteState = try freshState("cancel-after-patch")
        _ = try deliver(afterWriteState, old)
        client.cancelAfterWrite = true
        expectThrows("AD9 cancellation before short reconstruction stops delivery", contains: "cancelled") {
            _ = try deliver(afterWriteState, current)
        }
        expect(client.requests == [delta.file], "AD9 reconstruction cancellation never starts a full fallback")
        DownloadControl.reset()

        // Invalid optional delivery does not disable a valid full installer.
        var invalid = [ArtifactDelta]()
        var bad = delta; bad.file = "../escape"; invalid.append(bad)
        bad = delta; bad.file = current.file; invalid.append(bad)
        bad = delta; bad.bytes = current.bytes; invalid.append(bad)
        bad = delta; bad.baseBytes = 0; invalid.append(bad)
        bad = delta; bad.sha256 = "invalid"; invalid.append(bad)
        for descriptor in invalid {
            var candidate = feed
            candidate.apps["fixture"]?.delta = descriptor
            let usable = try candidate.validated().apps["fixture"]!
            expect(usable.delta == nil && usable.sha256 == current.sha256, "AD13 invalid optional metadata keeps the full signed artifact")
            let state = try freshState("invalid-metadata")
            _ = try deliver(state, old)
            let (_, bytes, requests) = try deliver(state, usable)
            expect(requests == [current.file] && bytes == current.bytes, "AD13 invalid optional metadata uses only the full installer")
        }

        // The mirror serves the patch as well, so a Mac at the mirror can use it too.
        let mirrorRoot = root.appendingPathComponent("mirror")
        _ = try FeedMirror.sync(releaseData: releaseData, sourceBase: serverBase, root: mirrorRoot,
                                publicKey: pair.publicKeyBase64, http: client, now: Date(),
                                retireArtifact: { _ = try Trash.move($0, into: mirrorRoot.appendingPathComponent("fixture-trash")) })
        expect(fm.fileExists(atPath: mirrorRoot.appendingPathComponent("artifacts/\(delta.file)").path),
               "AD10 the mirror serves the patch beside the installers it keeps")

        client.files.removeValue(forKey: delta.file)
        let missingMirror = root.appendingPathComponent("mirror-without-patch")
        let fullMirror = try FeedMirror.sync(releaseData: releaseData, sourceBase: serverBase, root: missingMirror,
                                             publicKey: pair.publicKeyBase64, http: client,
                                             retireArtifact: { _ = try Trash.move($0, into: missingMirror.appendingPathComponent("fixture-trash")) })
        expect(fullMirror.apps["fixture"]?.sha256 == current.sha256
               && (try? Signing.sha256Hex(fileAt: missingMirror.appendingPathComponent("artifacts/\(current.file)")).hex) == current.sha256,
               "AD10 unavailable optional patch does not block a verified full mirror")
        client.files[delta.file] = try Data(contentsOf: patchFile)

        // A patch that would not be smaller than the whole artifact is not published at all.
        let noiseA = Data((0..<64 * 1024).map { UInt8($0 % 251) })
        let noiseB = Data((0..<64 * 1024).map { UInt8(($0 * 7) % 253) })
        let noiseAURL = root.appendingPathComponent("noise-a.dmg")
        let noiseBURL = root.appendingPathComponent("noise-b.dmg")
        try noiseA.write(to: noiseAURL)
        try noiseB.write(to: noiseBURL)
        try FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "noise", version: "1.0.0",
                                  artifact: noiseAURL, kind: "fake-for-tests", allowSame: false, meta: nil, url: "https://example.test/\(noiseAURL.lastPathComponent)")
        try FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "noise", version: "1.0.1",
                                  artifact: noiseBURL, kind: "fake-for-tests", allowSame: false, meta: nil, url: "https://example.test/\(noiseBURL.lastPathComponent)")
        let withNoise = try FeedPublisher.loadVerifiedFeed(from: feedDir, publicKey: pair.privateKey.publicKey)!
        expect(withNoise.apps["noise"]?.delta == nil, "AD11 a patch that saves nothing is not published")

        // The patch format refuses anything outside the sizes it was signed for.
        func header(_ baseBytes: Int64, _ targetBytes: Int64) -> Data {
            var data = Data("KHUD1".utf8)
            func append(_ value: UInt64) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            append(UInt64(baseBytes)); append(UInt64(targetBytes))
            var block = UInt32(65536).littleEndian
            withUnsafeBytes(of: &block) { data.append(contentsOf: $0) }
            return data
        }
        func append(_ data: inout Data, _ value: UInt64) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append(_ data: inout Data, _ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let badPatch = root.appendingPathComponent("bad.patch")
        let outFile = root.appendingPathComponent("bad.out")
        let smallBase = root.appendingPathComponent("small.base")
        try Data(repeating: 7, count: 1024).write(to: smallBase)
        var outside = header(1024, 1024)
        outside.append(0x02); append(&outside, UInt64(4096)); append(&outside, UInt64(16))
        try outside.write(to: badPatch)
        expectThrows("AD12 a patch that copies outside its base is refused", contains: "copies outside") {
            _ = try ArtifactDeltaPatch.apply(base: smallBase, patch: badPatch, to: outFile, baseBytes: 1024, targetBytes: 1024)
        }
        var incomplete = header(1024, 1024)
        incomplete.append(0x02); append(&incomplete, UInt64(0)); append(&incomplete, UInt64(16))
        try incomplete.write(to: badPatch)
        expectThrows("AD12 a patch that does not build the signed artifact is refused", contains: "does not build") {
            _ = try ArtifactDeltaPatch.apply(base: smallBase, patch: badPatch, to: outFile, baseBytes: 1024, targetBytes: 1024)
        }
        var oversized = header(1024, 16)
        oversized.append(0x01); append(&oversized, UInt32(32))
        try oversized.write(to: badPatch)
        expectThrows("AD12 a patch that writes past the signed artifact is refused", contains: "writes past") {
            _ = try ArtifactDeltaPatch.apply(base: smallBase, patch: badPatch, to: outFile, baseBytes: 1024, targetBytes: 16)
        }
        var otherBase = header(2048, 1024)
        otherBase.append(0x02); append(&otherBase, UInt64(0)); append(&otherBase, UInt64(1024))
        try otherBase.write(to: badPatch)
        expectThrows("AD12 a patch built for another base is refused", contains: "different base") {
            _ = try ArtifactDeltaPatch.apply(base: smallBase, patch: badPatch, to: outFile, baseBytes: 1024, targetBytes: 1024)
        }
    } catch { expect(false, "AD artifact delta checks: \(error)") }
}
