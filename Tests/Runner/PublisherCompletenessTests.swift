import Foundation
import CryptoKit

/// `FeedPublisher.publish(requireComplete:)` — the gate the CLI asks for: a fleet row must carry a
/// label and its words, a carried value never triggers the refusal, and a named word replaces only
/// itself. Fixtures that publish directly do not pass the flag and are not gated.
func publisherCompletenessTests() {
    let root = tmpDir("publisher-complete")
    let keyFile = root.appendingPathComponent("fixture.key")
    let key = Curve25519.Signing.PrivateKey()
    try! Signing.savePrivateKey(key, to: keyFile)

    func feedDir(_ tag: String) -> URL {
        let dir = root.appendingPathComponent(tag)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func publish(_ dir: URL, _ version: String, type: String? = "system", words: AppWords? = nil,
                 holdURL: String? = nil, complete: Bool = true, allowSame: Bool = false) throws {
        let src = root.appendingPathComponent("artifact-\(version).bin")
        try Data("bytes-\(version)".utf8).write(to: src)
        try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: version,
                                  artifact: src, kind: "fake-for-tests", allowSame: allowSame,
                                  words: words, holdURL: holdURL, type: type,
                                  requireComplete: complete, url: "https://example.test/artifacts/")
    }
    func feed(_ dir: URL) -> Feed? {
        (try? FeedPublisher.loadVerifiedFeed(from: dir, publicKey: key.publicKey)) ?? nil
    }
    func row(_ dir: URL, _ app: String = "launcher") -> FeedApp? {
        feed(dir)?.apps[app]
    }

    // PC1 a complete row publishes and keeps exactly what it named.
    do {
        let dir = feedDir("complete")
        try! publish(dir, "1.0.0", words: AppWords(tagline: "Every app, installed.", description: "Installs and keeps every KH Studio app current."))
        let e = row(dir)
        expect(e?.type == "system", "PC1a a complete row publishes with its label")
        expect(e?.tagline == "Every app, installed." && e?.description == "Installs and keeps every KH Studio app current.",
               "PC1b the words are written as named")
    }

    // PC2 each missing field refuses, and the sentence names the flag that fills it.
    for (label, type, words, wanted) in [
        ("type", nil, AppWords(tagline: "t", description: "d"), "--type"),
        ("tagline", "system", AppWords(description: "d"), "--tagline"),
        ("description", "system", AppWords(tagline: "t"), "--description"),
    ] as [(String, String?, AppWords, String)] {
        let dir = feedDir("missing-" + label)
        do {
            try publish(dir, "1.0.0", type: type, words: words)
            expect(false, "PC2 a row with no \(label) must be refused")
        } catch {
            expect("\(error)".contains(wanted), "PC2 the \(label) refusal names \(wanted) (\(error))")
            expect("\(error)".contains("Nothing was published"), "PC2 the \(label) refusal says nothing was published")
            expect(row(dir) == nil, "PC2 the \(label) refusal left the feed unwritten")
        }
    }

    // PC3 a carried value never triggers it: a complete row republished naming no flags still passes.
    do {
        let dir = feedDir("carried")
        try! publish(dir, "1.0.0", words: AppWords(tagline: "t", description: "d"))
        do {
            try publish(dir, "1.0.1")
            expect(row(dir)?.tagline == "t" && row(dir)?.description == "d" && row(dir)?.type == "system",
                   "PC3 a republish naming no flags carries label and words")
        } catch {
            expect(false, "PC3 a complete row must not be refused when nothing is named (\(error))")
        }
    }

    // PC4 a named word replaces only itself; the others survive. This is the defect that emptied rows.
    do {
        let dir = feedDir("merge")
        try! publish(dir, "1.0.0", words: AppWords(tagline: "old tagline", description: "old description",
                                                   accent: "#112233"))
        try! publish(dir, "1.0.1", words: AppWords(tagline: "new tagline"))
        let e = row(dir)
        expect(e?.tagline == "new tagline", "PC4 the named tagline is written")
        expect(e?.description == "old description", "PC4 the unnamed description survives")
        expect(e?.accent == "#112233", "PC4 the unnamed accent survives")
        // The other direction too: a description-only publish leaves the tagline intact.
        try! publish(dir, "1.0.2", words: AppWords(description: "newer description"))
        expect(row(dir)?.description == "newer description" && row(dir)?.tagline == "new tagline",
               "PC4 a description-only publish leaves the tagline intact")
    }

    // PC5 a row that already served a hold keeps one without naming it; dropping it is refused.
    do {
        let dir = feedDir("hold")
        try! publish(dir, "1.0.0", words: AppWords(tagline: "t", description: "d"), holdURL: "http://127.0.0.1:8790/api/maintenance/hold")
        try! publish(dir, "1.0.1")
        expect(row(dir)?.holdURL == "http://127.0.0.1:8790/api/maintenance/hold", "PC5 a carried hold survives a republish")

        // There is no way to drop a hold by publishing: `holdURL: nil` means carry, so the
        // 2.0.0 publish naming nothing still serves the same endpoint. That is the protection
        // itself — a hold leaves a row only when someone names a different one.
        let src = root.appendingPathComponent("artifact-2.0.0.bin")
        try! Data("bytes-2.0.0".utf8).write(to: src)
        try! FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: "2.0.0",
                                   artifact: src, kind: "fake-for-tests", allowSame: false, words: AppWords(tagline: "t", description: "d"), holdURL: nil,
                                   type: "system", requireComplete: true, url: "https://example.test/artifacts/")
        expect(row(dir)?.holdURL == "http://127.0.0.1:8790/api/maintenance/hold",
               "PC5 a hold is never silently dropped — nil carries it")
    }

    // PC6 an artifact already named for its own bytes keeps that name, never a doubled prefix.
    do {
        let dir = feedDir("prefixed")
        let bytes = Data("already-named".utf8)
        let sha = Signing.sha256Hex(bytes)
        let src = root.appendingPathComponent("\(sha.prefix(12))-payload.bin")
        try! bytes.write(to: src)
        try! FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: "1.0.0",
                                   artifact: src, kind: "fake-for-tests", allowSame: false, words: AppWords(tagline: "t", description: "d"), type: "system",
                                   requireComplete: true, url: "https://example.test/artifacts/")
        expect(row(dir)?.file == "\(sha.prefix(12))-payload.bin",
               "PC6 the stored name is the basename it was given (\(row(dir)?.file ?? "none"))")
    }

    // PC8 the registry, not the row, decides who serves a hold, and the pair is demanded: a first
    // publish is refused for the missing address, then for the missing since-version. Only the
    // helper is exempt, by kind; the Launcher is not exempt by name any more (S001, 2026-11-25).
    do {
        let dir = feedDir("registry")
        try! Data(#"["story","launcher"]"#.utf8).write(to: dir.appendingPathComponent("hold-apps.json"))
        func publishStory(_ version: String, holdURL: String? = nil, holdSince: String? = nil) throws {
            let src = root.appendingPathComponent("story-\(version).bin")
            try Data("story-\(version)".utf8).write(to: src)
            try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "story", version: version,
                                      artifact: src, kind: "fake-for-tests", allowSame: true, words: AppWords(tagline: "t", description: "d"),
                                      holdURL: holdURL, holdSince: holdSince, type: "system",
                                      requireComplete: true, url: "https://example.test/artifacts/")
        }
        do {
            try publishStory("1.0.0")
            expect(false, "PC8 a hold-serving app with no holdURL must be refused on its first publish")
        } catch {
            expect("\(error)".contains("--hold-url"), "PC8 the hold refusal names --hold-url (\(error))")
        }
        do {
            try publishStory("1.0.0", holdURL: "http://127.0.0.1:8790/api/maintenance/hold")
            expect(false, "PC8 a hold-serving app with no hold-since must be refused")
        } catch {
            expect("\(error)".contains("--hold-since"), "PC8 the refusal names --hold-since (\(error))")
        }
        try! publishStory("1.0.0", holdURL: "http://127.0.0.1:8790/api/maintenance/hold", holdSince: "0.9.0")
        expect(row(dir, "story")?.holdURL == "http://127.0.0.1:8790/api/maintenance/hold"
               && row(dir, "story")?.holdSince == "0.9.0", "PC8 the pair is written as named")
        // A carried pair survives a republish that names neither.
        try! publishStory("1.0.1")
        expect(row(dir, "story")?.holdURL == "http://127.0.0.1:8790/api/maintenance/hold"
               && row(dir, "story")?.holdSince == "0.9.0", "PC8 the pair is carried")
        // The Launcher used to pass here on its name alone: a publish that names no hold pair is now
        // refused for it too, so the fields cannot be dropped by a later publish unnoticed.
        do {
            try publish(dir, "1.0.0")
            expect(false, "PC8 a hold-serving Launcher with no hold pair must be refused")
        } catch {
            expect("\(error)".contains("--hold-url"), "PC8 the Launcher's refusal names --hold-url (\(error))")
            expect(row(dir, "launcher") == nil, "PC8 the Launcher's refusal left no row")
        }
    }

    // PC7 a catalogue row is exempt: an extension has no type or tagline by design.
    do {
        let dir = feedDir("extension")
        let src = root.appendingPathComponent("extension.zip")
        try! Data("extension-bytes".utf8).write(to: src)
        do {
            try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "ext-one", version: "1.0.0",
                                      artifact: src, kind: "extension", allowSame: false, requireComplete: true, url: "https://example.test/artifacts/")
            expect(row(dir, "ext-one")?.version == "1.0.0" && row(dir, "ext-one")?.type == nil,
                   "PC7 an extension row publishes without the app-only fields")
        } catch {
            expect(false, "PC7 an extension row must not be judged as an incomplete app (\(error))")
        }
    }

    // PC9 a metadata-only update changes one word and nothing else: version, file, sha256, bytes,
    // the unknown fields and the other words all survive, and published_at moves strictly forward.
    do {
        let dir = feedDir("meta")
        let sha = String(repeating: "b", count: 64)
        let json = """
        {"schema":1,"published_at":"2026-11-22T10:00:00Z",
         "apps":{"launcher":{"version":"1.2.3","file":"kept.bin","sha256":"\(sha)","bytes":42,
           "kind":"app-dmg","type":"system","tagline":"old tagline","description":"old description",
           "futureField":{"values":[1,true]}}}}
        """
        let data = Data(json.utf8)
        let release = Release(feed: data, signature: try! Signing.sign(data, with: key))
        try! AtomicFile.writeJSON(release, to: FeedPublisher.releaseFile(in: dir))
        let before = feed(dir)
        try! FeedPublisher.setMetadata(feedDir: dir, keyFile: keyFile, app: "launcher",
                                       words: AppWords(tagline: "new tagline"), type: nil)
        let after = feed(dir)
        let e = after?.apps["launcher"]
        expect(e?.tagline == "new tagline" && e?.description == "old description",
               "PC9 a metadata update replaces only the word it names")
        expect(e?.version == before?.apps["launcher"]?.version && e?.file == "kept.bin"
               && e?.sha256 == sha && e?.bytes == 42,
               "PC9 version, file, sha256 and bytes are untouched")
        expect(e?.extras["futureField"] != nil, "PC9 unknown row fields survive a metadata update")
        expect(after.map { $0.published_at > (before?.published_at ?? "") } ?? false,
               "PC9 published_at moves strictly forward")
        do {
            try FeedPublisher.setMetadata(feedDir: dir, keyFile: keyFile, app: "nosuch",
                                          words: AppWords(tagline: "x"), type: nil)
            expect(false, "PC9 a metadata update of an app the feed does not name is refused")
        } catch {
            expect("\(error)".contains("no nosuch row"), "PC9 the refusal names the missing row (\(error))")
        }
    }

    // PC11 a publish never writes a controller handoff into the feed every Mac reads, and asking
    // `khu network` to write one is refused by name — the handoff travels on that Mac instead.
    do {
        let dir = feedDir("controller")
        let sha = String(repeating: "d", count: 64)
        let json = """
        {"schema":1,"published_at":"2026-11-22T10:00:00Z",
         "network":{"feedURLs":["https://example.invalid/release.json"],"hosts":{},
           "controller":{"from":"https://a.example/release.json","to":"https://b.example/release.json"}},
         "apps":{"story":{"version":"1.0.0","file":"s.bin","sha256":"\(sha)","bytes":9,"kind":"app-dmg"}}}
        """
        let data = Data(json.utf8)
        try! AtomicFile.writeJSON(Release(feed: data, signature: try Signing.sign(data, with: key)),
                                  to: FeedPublisher.releaseFile(in: dir))
        let art = root.appendingPathComponent("controller-art.bin")
        try! Data("controller bytes".utf8).write(to: art)
        // `meta: nil` because this fixture is not a DMG: PC11 is about the network block, and the
        // DMG identity read has its own guard and its own tests.
        try! FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "story", version: "1.0.1",
                                   artifact: art, kind: "app-dmg", allowSame: false, meta: nil,
                                   requireComplete: false, url: "https://example.test/artifacts/")
        let after = feed(dir)
        expect(after?.network?.feedURLs == ["https://example.invalid/release.json"] && after?.network?.controller == nil,
               "PC11 a publish keeps feedURLs and never writes a controller handoff")
        do {
            try FeedPublisher.configureNetwork(feedDir: dir, keyFile: keyFile,
                                               network: FeedNetwork(feedURLs: ["https://example.invalid/release.json"], hosts: [:],
                                                                    controller: ControllerHandoff(from: "https://a.example/release.json",
                                                                                                  to: "https://b.example/release.json")))
            expect(false, "PC11 khu network must refuse a controller handoff")
        } catch {
            expect("\(error)".contains("controller handoff"), "PC11 the refusal names the handoff (\(error))")
        }
    }

    // PC10 --allow-same re-publishes a version only with its own bytes: the same bytes pass, a
    // different artifact under the same version is refused by name.
    do {
        let dir = feedDir("same")
        try! publish(dir, "1.0.0", words: AppWords(tagline: "t", description: "d"))
        let sha = row(dir)?.sha256
        try! publish(dir, "1.0.0", words: AppWords(tagline: "t2", description: "d"), allowSame: true)
        expect(row(dir)?.sha256 == sha && row(dir)?.tagline == "t2",
               "PC10 the same bytes republish the same version")
        let other = root.appendingPathComponent("different.bin")
        try! Data("different bytes".utf8).write(to: other)
        do {
            try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: "1.0.0",
                                      artifact: other, kind: "fake-for-tests", allowSame: true, words: AppWords(tagline: "t", description: "d"),
                                      type: "system", requireComplete: true, url: "https://example.test/artifacts/")
            expect(false, "PC10 different bytes under a published version must be refused")
        } catch {
            expect("\(error)".contains("--allow-same"), "PC10 the refusal names --allow-same (\(error))")
            expect(row(dir)?.sha256 == sha, "PC10 the refusal left the row's bytes unchanged")
        }
    }
}
