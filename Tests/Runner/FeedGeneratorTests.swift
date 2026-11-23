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

private func releaseJSON(tag: String, asset: String, sha: String, bytes: Int,
                         digest: String? = nil, published: String = "2026-11-23T02:00:00Z") -> Data {
    var assetObject: [String: Any] = ["name": asset, "size": bytes,
                                      "browser_download_url": "https://github.com/o/r/releases/download/\(tag)/\(asset)"]
    if let digest { assetObject["digest"] = digest }
    let object: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
                                 "published_at": published, "assets": [assetObject]]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func metaJSON(_ fields: [String: String]) -> Data {
    let encoded = (try! JSONSerialization.data(withJSONObject: fields)).base64EncodedString()
    return try! JSONSerialization.data(withJSONObject: ["content": encoded])
}

/// `khu feed`: the published feed is generated from the app repos — one row per latest published
/// release, words from `app-meta.json` at that tag, and a refusal that names the repo and field when
/// a repo publishes without metadata.
func feedGeneratorTests() {
    let sha = String(repeating: "c", count: 64)
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
            "repos/\(storyRepo)/releases/latest": releaseJSON(tag: "1.4.418", asset: "Story.dmg", sha: sha, bytes: 42, digest: "sha256:\(sha)"),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
            "repos/\(hubRepo)/releases/latest": releaseJSON(tag: "0.6.257", asset: "Hub.dmg", sha: sha, bytes: 7, digest: "sha256:\(sha)"),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        let feed = try FeedGenerator.feed(apps: ["story": storyRepo, "hub": hubRepo], gh: gh)
        let story = feed.apps["story"], hub = feed.apps["hub"]
        expect(story?.version == "1.4.418" && story?.file == "Story.dmg" && story?.sha256 == sha && story?.bytes == 42,
               "FG1 the row is the tag's version and the DMG asset's digest and size")
        expect(story?.url == "https://github.com/o/r/releases/download/1.4.418/Story.dmg",
               "FG1 the row names the asset's absolute address")
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

    // FG2 a published repo with no app-meta.json refuses the WHOLE run, naming repo and field.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(storyRepo)/releases/latest": releaseJSON(tag: "1.4.418", asset: "Story.dmg", sha: sha, bytes: 42, digest: "sha256:\(sha)"),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
            "repos/\(hubRepo)/releases/latest": releaseJSON(tag: "0.6.257", asset: "Hub.dmg", sha: sha, bytes: 7, digest: "sha256:\(sha)"),
        ])
        do {
            _ = try FeedGenerator.feed(apps: ["story": storyRepo, "hub": hubRepo], gh: gh)
            expect(false, "FG2 a repo publishing without app-meta.json must refuse the run")
        } catch {
            let said = "\(error)"
            expect(said.contains(hubRepo) && said.contains("app-meta.json") && said.contains("Nothing was generated"),
                   "FG2 the refusal names the repo and the missing file (\(said))")
        }
    }

    // FG3 a field missing from the metadata refuses by name.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(tag: "0.6.257", asset: "Hub.dmg", sha: sha, bytes: 7, digest: "sha256:\(sha)"),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": metaJSON(["name": "Hub", "bundle_id": "com.t.hub", "type": "system", "tagline": "One hub."]),
        ])
        do {
            _ = try FeedGenerator.feed(apps: ["hub": hubRepo], gh: gh)
            expect(false, "FG3 metadata missing description must refuse")
        } catch {
            expect("\(error)".contains("description") && "\(error)".contains(hubRepo),
                   "FG3 the refusal names the missing field and the repo (\(error))")
        }
    }

    // FG4 a repo with no published release has no row, and does not fail the run.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(storyRepo)/releases/latest": releaseJSON(tag: "1.4.418", asset: "Story.dmg", sha: sha, bytes: 42, digest: "sha256:\(sha)"),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
        ])
        let feed = try FeedGenerator.feed(apps: ["story": storyRepo, "empty": "o/empty-kh"], gh: gh)
        expect(feed.apps.keys.sorted() == ["story"], "FG4 a repo with no published release contributes no row")
    } catch { expect(false, "FG4 fixture: \(error)") }

    // FG6 the encoder is stable: the same inputs at the same moment produce the same feed bytes, so
    // "already equal" means the encoder agrees, not that the clock changed. The envelope is not
    // byte-stable and never claimed to be — this CryptoKit's Ed25519 signatures differ between two
    // signings of identical bytes (measured 2026-11-23) — so the comparison is on `feed`.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(tag: "0.6.257", asset: "Hub.dmg", sha: sha, bytes: 7, digest: "sha256:\(sha)"),
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

    // FG7. The helper is not a feed app (owner ruling 2026-11-23): a line naming it produces no row,
    // and the generated feed carries no updater entry at all.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(tag: "0.6.257", asset: "Hub.dmg", sha: sha, bytes: 7, digest: "sha256:\(sha)"),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        let feed = try FeedGenerator.feed(apps: ["hub": hubRepo, "updater": "o/launcher-kh"], gh: gh)
        expect(feed.apps["updater"] == nil, "FG7 a line naming the helper produces no updater row")
        expect(feed.apps.keys.sorted() == ["hub"], "FG7 every other app is still generated")
    } catch { expect(false, "FG7 fixture: \(error)") }

    // FG5 an asset GitHub gives no digest for is refused, never hashed locally into the feed.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(tag: "0.6.257", asset: "Hub.dmg", sha: sha, bytes: 7),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        do {
            _ = try FeedGenerator.feed(apps: ["hub": hubRepo], gh: gh)
            expect(false, "FG5 a missing digest must refuse")
        } catch {
            expect("\(error)".contains("digest") && "\(error)".contains(hubRepo),
                   "FG5 the refusal names the missing digest (\(error))")
        }
    }
}
