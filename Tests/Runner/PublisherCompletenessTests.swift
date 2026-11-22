import Foundation
import CryptoKit

/// `FeedPublisher.publish(requireComplete:)` — the gate the CLI asks for: a fleet row must carry a
/// label and its words, a carried value never triggers the refusal, and a named word replaces only
/// itself. Fixtures that publish directly do not pass the flag and are not gated.
func publisherCompletenessTests() {
    let root = tmpDir("publisher-complete")
    let keyFile = root.appendingPathComponent("fixture.key")
    try! Signing.savePrivateKey(Curve25519.Signing.PrivateKey(), to: keyFile)

    func feedDir(_ tag: String) -> URL {
        let dir = root.appendingPathComponent(tag)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func publish(_ dir: URL, _ version: String, type: String? = "system", words: AppWords? = nil,
                 holdURL: String? = nil, complete: Bool = true) {
        let src = root.appendingPathComponent("artifact-\(version).bin")
        try Data("bytes-\(version)".utf8).write(to: src)
        try! FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: version,
                                   artifact: src, kind: "fake-for-tests", allowSame: false,
                                   words: words, holdURL: holdURL, type: type,
                                   requireComplete: complete)
    }
    func row(_ dir: URL, _ app: String = "launcher") -> FeedApp? {
        (try? FeedPublisher.loadVerifiedFeed(from: dir, publicKey: try! Signing.loadPrivateKey(from: keyFile).publicKey))??.apps[app]
    }

    // PC1 a complete row publishes and keeps exactly what it named.
    do {
        let dir = feedDir("complete")
        publish(dir, "1.0.0", words: AppWords(tagline: "Every app, installed.", description: "Installs and keeps every KH Studio app current."))
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
            publish(dir, "1.0.0", type: type, words: words)
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
        publish(dir, "1.0.0", words: AppWords(tagline: "t", description: "d"))
        do {
            publish(dir, "1.0.1")
            expect(row(dir)?.tagline == "t" && row(dir)?.description == "d" && row(dir)?.type == "system",
                   "PC3 a republish naming no flags carries label and words")
        } catch {
            expect(false, "PC3 a complete row must not be refused when nothing is named (\(error))")
        }
    }

    // PC4 a named word replaces only itself; the others survive. This is the defect that emptied rows.
    do {
        let dir = feedDir("merge")
        publish(dir, "1.0.0", words: AppWords(tagline: "old tagline", description: "old description",
                                                  accent: "#112233"))
        publish(dir, "1.0.1", words: AppWords(tagline: "new tagline"))
        let e = row(dir)
        expect(e?.tagline == "new tagline", "PC4 the named tagline is written")
        expect(e?.description == "old description", "PC4 the unnamed description survives")
        expect(e?.accent == "#112233", "PC4 the unnamed accent survives")
    }

    // PC5 a row that already served a hold keeps one without naming it; dropping it is refused.
    do {
        let dir = feedDir("hold")
        publish(dir, "1.0.0", words: AppWords(tagline: "t", description: "d"), holdURL: "http://100.64.0.7:8790/hold")
        publish(dir, "1.0.1")
        expect(row(dir)?.holdURL == "http://100.64.0.7:8790/hold", "PC5 a carried hold survives a republish")

        let src = root.appendingPathComponent("artifact-2.0.0.bin")
        try Data("bytes-2.0.0".utf8).write(to: src)
        do {
            try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: "2.0.0",
                                      artifact: src, kind: "fake-for-tests", allowSame: false,
                                      words: AppWords(tagline: "t", description: "d"), holdURL: nil,
                                      type: "system", requireComplete: true)
            expect(false, "PC5 clearing a hold that existed must be refused")
        } catch {
            expect("\(error)".contains("--hold-url"), "PC5 the hold refusal names --hold-url (\(error))")
        }
    }

    // PC6 an artifact already named for its own bytes keeps that name, never a doubled prefix.
    do {
        let dir = feedDir("prefixed")
        let bytes = Data("already-named".utf8)
        let sha = Signing.sha256Hex(bytes)
        let src = root.appendingPathComponent("\(sha.prefix(12))-payload.bin")
        try bytes.write(to: src)
        try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "launcher", version: "1.0.0",
                                  artifact: src, kind: "fake-for-tests", allowSame: false,
                                  words: AppWords(tagline: "t", description: "d"), type: "system",
                                  requireComplete: true)
        expect(row(dir)?.file == "\(sha.prefix(12))-payload.bin",
               "PC6 the stored name is the basename it was given (\(row(dir)?.file ?? "none"))")
    }

    // PC8 the registry, not the row, decides who serves a hold, and the pair is demanded: a first
    // publish is refused for the missing address, then for the missing since-version. `launcher` and
    // `updater` are exempt by name, so this uses an id the registry marks hold-serving.
    do {
        let dir = feedDir("registry")
        try Data(#"["story"]"#.utf8).write(to: dir.appendingPathComponent("hold-apps.json"))
        func publishStory(_ version: String, holdURL: String? = nil, holdSince: String? = nil) throws {
            let src = root.appendingPathComponent("story-\(version).bin")
            try Data("story-\(version)".utf8).write(to: src)
            try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "story", version: version,
                                      artifact: src, kind: "fake-for-tests", allowSame: true,
                                      words: AppWords(tagline: "t", description: "d"),
                                      holdURL: holdURL, holdSince: holdSince, type: "system",
                                      requireComplete: true)
        }
        do {
            try publishStory("1.0.0")
            expect(false, "PC8 a hold-serving app with no holdURL must be refused on its first publish")
        } catch {
            expect("\(error)".contains("--hold-url"), "PC8 the hold refusal names --hold-url (\(error))")
        }
        do {
            try publishStory("1.0.0", holdURL: "http://100.64.0.7:8790/hold")
            expect(false, "PC8 a hold-serving app with no hold-since must be refused")
        } catch {
            expect("\(error)".contains("--hold-since"), "PC8 the refusal names --hold-since (\(error))")
        }
        try publishStory("1.0.0", holdURL: "http://100.64.0.7:8790/hold", holdSince: "0.9.0")
        expect(row(dir, "story")?.holdURL == "http://100.64.0.7:8790/hold"
               && row(dir, "story")?.holdSince == "0.9.0", "PC8 the pair is written as named")
        // A carried pair survives a republish that names neither.
        try publishStory("1.0.1")
        expect(row(dir, "story")?.holdURL == "http://100.64.0.7:8790/hold"
               && row(dir, "story")?.holdSince == "0.9.0", "PC8 the pair is carried")
    }

    // PC7 a catalogue row is exempt: an extension has no type or tagline by design.
    do {
        let dir = feedDir("extension")
        let src = root.appendingPathComponent("extension.zip")
        try Data("extension-bytes".utf8).write(to: src)
        do {
            try FeedPublisher.publish(feedDir: dir, keyFile: keyFile, app: "ext-one", version: "1.0.0",
                                      artifact: src, kind: "extension", allowSame: false,
                                      requireComplete: true)
            expect(row(dir, "ext-one")?.version == "1.0.0" && row(dir, "ext-one")?.type == nil,
                   "PC7 an extension row publishes without the app-only fields")
        } catch {
            expect(false, "PC7 an extension row must not be judged as an incomplete app (\(error))")
        }
    }
}
