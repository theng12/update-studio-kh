import Foundation
import CryptoKit

/// A GitHub that answers from a table; a path it does not hold is a 404.
private struct FakeGitHub: GitHubReader {
    var paths: [String: Data]
    func json(_ path: String) throws -> Data {
        guard let data = paths[path] else { throw khuFail("gh api \(path) answered 404") }
        return data
    }
}

private func releaseJSON(repo: String, tag: String,
                         assets: [(name: String, sha: String, bytes: Int, digest: String?)]) -> Data {
    let list: [[String: Any]] = assets.map { asset in
        var object: [String: Any] = ["name": asset.name, "size": asset.bytes,
                                     "browser_download_url": "https://github.com/\(repo)/releases/download/\(tag)/\(asset.name)"]
        if let digest = asset.digest { object["digest"] = digest }
        return object
    }
    let object: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
                                 "published_at": "2026-11-23T02:00:00Z", "assets": list]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func metaJSON(_ fields: [String: String]) -> Data {
    let encoded = (try! JSONSerialization.data(withJSONObject: fields)).base64EncodedString()
    return try! JSONSerialization.data(withJSONObject: ["content": encoded])
}

private func registry(_ entries: [String: RegistryEntry]) -> FeedRegistry { FeedRegistry(apps: entries) }

private func registryWords(name: String, bundle: String) -> RegistryEntry {
    RegistryEntry(name: name, bundle_id: bundle, type: "media", tagline: "Scene by scene.",
                  description: "Scripts, shots and voice.")
}

/// `khu feed`: the published feed is generated from the app repos — one row per latest published
/// release, the asset's own absolute address, GitHub's digest, the words from the tag's
/// `app-meta.json` else the registry, and a refusal that names the repo and field otherwise.
func feedGeneratorTests() {
    let sha = String(repeating: "c", count: 64)
    let digest = "sha256:\(sha)"
    let storyRepo = "o/story-kh", hubRepo = "o/hub-kh"
    let storyMeta = metaJSON(["name": "Story Studio KH", "bundle_id": "com.t.story",
                              "bundle_name": "Story Studio KH.app", "type": "media",
                              "tagline": "Scene by scene.", "description": "Scripts, shots and voice.",
                              "hold_url": "http://127.0.0.1:8790/api/maintenance/hold", "hold_since": "1.4.300"])
    let hubMeta = metaJSON(["name": "Hub Studio KH", "bundle_id": "com.t.hub", "type": "system",
                            "tagline": "One hub.", "description": "Everything in one place."])

    // FG1 two published repos become two rows with the asset's own address and GitHub's digest.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(storyRepo)/releases/latest": releaseJSON(repo: storyRepo, tag: "1.4.418", assets: [("Story.dmg", sha, 42, digest)]),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        let made = try FeedGenerator.generate(apps: ["story": storyRepo, "hub": hubRepo], gh: gh)
        let feed = made.feed
        let story = feed.apps["story"], hub = feed.apps["hub"]
        expect(story?.version == "1.4.418" && story?.file == "Story.dmg" && story?.sha256 == sha && story?.bytes == 42,
               "FG1 the row is the tag's version and the DMG asset's digest and size")
        expect(story?.url == "https://github.com/\(storyRepo)/releases/download/1.4.418/Story.dmg",
               "FG1 the row names the asset's absolute address on github.com")
        expect(made.sources == ["story": "tag:1.4.418", "hub": "tag:0.6.257"],
               "FG1 each row records the tag its words came from (\(made.sources))")
        expect(story?.bundleID == "com.t.story" && story?.name == "Story Studio KH"
               && story?.type == "media" && story?.tagline == "Scene by scene."
               && story?.description == "Scripts, shots and voice."
               && story?.holdURL == "http://127.0.0.1:8790/api/maintenance/hold" && story?.holdSince == "1.4.300",
               "FG1 identity and words come from app-meta.json at that tag")
        expect(hub?.type == "system" && hub?.kind == "app-dmg" && feed.previous == nil && feed.network == nil,
               "FG1 no previous rows and no network block are generated")
        let text = String(decoding: try! JSON.encode(feed), as: UTF8.self)
        expect(!text.contains("\"previous\"") && !text.contains("controller") && !text.contains("\"network\""),
               "FG1 the generated feed carries no previous, network or controller")
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = tmpDir("feed-generator").appendingPathComponent("fixture.key")
        try! Signing.savePrivateKey(key, to: keyFile)
        let envelope = try FeedGenerator.signed(feed, keyFile: keyFile)
        let release = try JSON.decode(Release.self, from: envelope)
        expect(release.feedData.flatMap { data in
                   release.signatureData.map { Signing.verify(data, signature: $0, publicKey: key.publicKey) }
               } == true,
               "FG1 the envelope verifies against the signing key before it is published")
    } catch { expect(false, "FG1 fixture: \(error)") }

    // FG2 a published repo with neither a tag's app-meta.json nor a registry entry refuses the
    // WHOLE run, naming repo and field.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(storyRepo)/releases/latest": releaseJSON(repo: storyRepo, tag: "1.4.418", assets: [("Story.dmg", sha, 42, digest)]),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
        ])
        do {
            _ = try FeedGenerator.generate(apps: ["story": storyRepo, "hub": hubRepo], gh: gh)
            expect(false, "FG2 a repo publishing without words must refuse the run")
        } catch {
            let said = "\(error)"
            expect(said.contains(hubRepo) && said.contains("app-meta.json") && said.contains("Nothing was generated"),
                   "FG2 the refusal names the repo and the missing file (\(said))")
        }
    }

    // FG3 the registry covers an app the tag does not; a field missing from it refuses by name.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
        ])
        let thin = RegistryEntry(name: "Hub", bundle_id: "com.t.hub", type: "system", tagline: "One hub.")
        do {
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], registry: registry(["hub": thin]), gh: gh)
            expect(false, "FG3 a registry entry missing description must refuse")
        } catch {
            expect("\(error)".contains("description") && "\(error)".contains(hubRepo),
                   "FG3 the refusal names the missing field and the repo (\(error))")
        }
        let full = registryWords(name: "Hub Studio KH", bundle: "com.t.hub")
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], registry: registry(["hub": full]), gh: gh)
        expect(made.feed.apps["hub"]?.tagline == "Scene by scene." && made.sources["hub"] == "registry",
               "FG3 the registry supplies the words and the row records that it did")
        expect(made.stale.isEmpty, "FG3 no stale note when the tag carries no metadata")
    } catch { expect(false, "FG3 fixture: \(error)") }

    // FG4 a repo with no published release has no row, is named as unpublished, and does not fail
    // the run — that list is the only thing a publish may let disappear.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(storyRepo)/releases/latest": releaseJSON(repo: storyRepo, tag: "1.4.418", assets: [("Story.dmg", sha, 42, digest)]),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
        ])
        let made = try FeedGenerator.generate(apps: ["story": storyRepo, "empty": "o/empty-kh"], gh: gh)
        expect(made.feed.apps.keys.sorted() == ["story"], "FG4 a repo with no published release contributes no row")
        expect(made.unpublished == ["empty"], "FG4 it is named in the run's unpublished list (\(made.unpublished))")
    } catch { expect(false, "FG4 fixture: \(error)") }

    // FG6 the encoder is stable: the same inputs at the same moment produce the same feed bytes, so
    // "already equal" means the encoder agrees, not that the clock changed. The envelope is not
    // byte-stable and never claimed to be — this CryptoKit's Ed25519 signatures differ between two
    // signings of identical bytes (measured 2026-11-23) — so the comparison is on `feed`.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        let key = Curve25519.Signing.PrivateKey()
        let keyFile = tmpDir("feed-stable").appendingPathComponent("stable.key")
        try! Signing.savePrivateKey(key, to: keyFile)
        func signedFeed(at date: Date) throws -> Data {
            let envelope = try FeedGenerator.signed(FeedGenerator.feed(apps: ["hub": hubRepo], gh: gh, now: date), keyFile: keyFile)
            let release = try JSON.decode(Release.self, from: envelope)
            guard let data = release.feedData, let signature = release.signatureData,
                  Signing.verify(data, signature: signature, publicKey: key.publicKey) else {
                throw khuFail("the envelope does not verify")
            }
            return data
        }
        let first = try signedFeed(at: moment), second = try signedFeed(at: moment)
        expect(first == second, "FG6 the feed is byte-stable for the same inputs and the same moment")
        let later = try signedFeed(at: moment.addingTimeInterval(1))
        expect(first != later, "FG6 a later generation changes published_at and therefore the bytes")
    } catch { expect(false, "FG6 fixture: \(error)") }

    // FG5 an asset GitHub gives no digest for is refused, never hashed locally into the feed.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, nil)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        do {
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh)
            expect(false, "FG5 a missing digest must refuse")
        } catch {
            expect("\(error)".contains("digest") && "\(error)".contains(hubRepo),
                   "FG5 the refusal names the missing digest (\(error))")
        }
    }

    // FG7 one repo, two rows: the registry's per-entry asset selector picks the `.dmg` for the
    // Launcher and the bare `khu` for the helper. A field, not an `if app == "updater"`.
    do {
        let repo = "o/update-kh"
        let gh = FakeGitHub(paths: [
            "repos/\(repo)/releases/latest": releaseJSON(repo: repo, tag: "0.1.80", assets: [
                ("Studio.Launcher.KH-0.1.80.dmg", sha, 100, digest),
                ("10e22658328f-khu", sha, 200, digest),
            ]),
            "repos/\(repo)/contents/app-meta.json?ref=0.1.80": metaJSON([
                "name": "Studio Launcher KH", "bundle_id": "com.khupdater.launcher", "type": "system",
                "tagline": "Every KH Studio app.", "description": "One window."]),
        ])
        let helper = RegistryEntry(asset: "khu", file: "10e22658328f-khu", name: "Studio Launcher KH Helper",
                                   bundle_id: "com.khupdater.agent", type: "system",
                                   tagline: "Keeps apps up to date.", description: "Background checks.")
        let made = try FeedGenerator.generate(apps: ["launcher": repo, "updater": repo],
                                             registry: registry(["updater": helper]), gh: gh)
        expect(made.feed.apps["launcher"]?.file == "Studio.Launcher.KH-0.1.80.dmg",
               "FG7 the Launcher row is the DMG")
        expect(made.feed.apps["updater"]?.file == "10e22658328f-khu"
               && made.feed.apps["updater"]?.url == "https://github.com/\(repo)/releases/download/0.1.80/10e22658328f-khu",
               "FG7 the helper row is the khu asset's own address (\(made.feed.apps["updater"]?.url ?? "nil"))")
        expect(made.feed.apps["updater"]?.bundleID == "com.khupdater.agent"
               && made.feed.apps["updater"]?.type == "system",
               "FG7 the helper row carries its own words from the registry")
    } catch { expect(false, "FG7 fixture: \(error)") }

    // FG8 the tag wins over the registry, and a registry entry the tag has superseded is reported
    // as stale — never silently used, never silently ignored.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo],
                                             registry: registry(["hub": registryWords(name: "Old Name", bundle: "com.t.hub")]), gh: gh)
        expect(made.feed.apps["hub"]?.name == "Hub Studio KH" && made.sources["hub"] == "tag:0.6.257",
               "FG8 the tag's app-meta.json wins over the registry")
        expect(made.stale.count == 1 && made.stale[0].contains("registry entry is stale")
               && made.stale[0].contains("0.6.257"),
               "FG8 the ignored registry entry is reported by name and tag (\(made.stale))")
    } catch { expect(false, "FG8 fixture: \(error)") }

    // FG10 a fallback pin is only kept when it carries its own address. The 2026-11-23 pins all
    // pointed at artifacts that no longer exist, so the generated feed carries no `previous` at all.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        var dead = FeedApp(version: "0.6.250", file: "Hub-0.6.250.dmg", sha256: sha, bytes: 5, kind: "app-dmg")
        dead.url = nil
        var oldFeed = Feed(published_at: "2026-11-22T00:00:00Z", apps: ["hub": dead])
        oldFeed.previous = ["hub": dead]
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: oldFeed, gh: gh)
        expect(made.feed.previous == nil, "FG10 a url-less fallback pin is dropped, not republished")
        var live = dead; live.url = "https://github.com/\(hubRepo)/releases/download/0.6.250/Hub-0.6.250.dmg"
        var oldLive = Feed(published_at: "2026-11-22T00:00:00Z", apps: ["hub": live])
        oldLive.previous = ["hub": live]
        let kept = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: oldLive, gh: gh)
        expect(kept.feed.previous?["hub"]?.url == live.url && kept.feed.previous?["hub"]?.version == "0.6.250",
               "FG10 a fallback pin with its own address is kept")
    } catch { expect(false, "FG10 fixture: \(error)") }

    // FG9 the address guards: a relative url, a foreign host, or a url outside the app's own repo
    // refuses the whole run. This is the negative control for the 2026-11-23 outage.
    do {
        let cases = [
            ("relative", "artifacts/Hub.dmg"),
            ("foreign host", "https://example.com/\(hubRepo)/releases/download/0.6.257/Hub.dmg"),
            ("another repo", "https://github.com/o/other/releases/download/0.6.257/Hub.dmg"),
        ]
        for (label, url) in cases {
            let object: [String: Any] = ["tag_name": "0.6.257", "draft": false, "prerelease": false,
                                         "published_at": "2026-11-23T02:00:00Z",
                                         "assets": [["name": "Hub.dmg", "size": 7, "digest": digest,
                                                     "browser_download_url": url]]]
            let gh = FakeGitHub(paths: [
                "repos/\(hubRepo)/releases/latest": try! JSONSerialization.data(withJSONObject: object),
                "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
            ])
            do {
                _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh)
                expect(false, "FG9 a \(label) url must refuse the whole run")
            } catch {
                expect("\(error)".contains("refused") && "\(error)".contains(hubRepo),
                       "FG9 a \(label) url refuses, naming the repo (\(error))")
            }
        }
        // A release with no .dmg asset refuses rather than emitting some other asset as the row.
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.zip", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        do {
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh)
            expect(false, "FG9 a missing .dmg asset must refuse")
        } catch {
            expect("\(error)".contains("no .dmg asset"),
                   "FG9 a missing asset refuses by name (\(error))")
        }
    }
}
