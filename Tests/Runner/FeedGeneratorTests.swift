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

private func releaseJSON(repo: String, tag: String, body: String? = nil,
                         assets: [(name: String, sha: String, bytes: Int, digest: String?)]) -> Data {
    let list: [[String: Any]] = assets.map { asset in
        var object: [String: Any] = ["name": asset.name, "size": asset.bytes,
                                     "browser_download_url": "https://github.com/\(repo)/releases/download/\(tag)/\(asset.name)"]
        if let digest = asset.digest { object["digest"] = digest }
        return object
    }
    var object: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false,
                                 "published_at": "2026-11-23T02:00:00Z", "assets": list]
    if let body { object["body"] = body }
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
        let made = try FeedGenerator.generate(apps: ["story": storyRepo, "hub": hubRepo], gh: gh, verifier: UnverifiedAsset())
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
            _ = try FeedGenerator.generate(apps: ["story": storyRepo, "hub": hubRepo], gh: gh, verifier: UnverifiedAsset())
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
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], registry: registry(["hub": thin]), gh: gh, verifier: UnverifiedAsset())
            expect(false, "FG3 a registry entry missing description must refuse")
        } catch {
            expect("\(error)".contains("description") && "\(error)".contains(hubRepo),
                   "FG3 the refusal names the missing field and the repo (\(error))")
        }
        let full = registryWords(name: "Hub Studio KH", bundle: "com.t.hub")
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], registry: registry(["hub": full]), gh: gh, verifier: UnverifiedAsset())
        expect(made.feed.apps["hub"]?.tagline == "Scene by scene." && made.sources["hub"] == "registry",
               "FG3 the registry supplies the words and the row records that it did")
        expect(made.stale.isEmpty, "FG3 no stale note when the tag carries no metadata")
    } catch { expect(false, "FG3 fixture: \(error)") }

    // FG3b. A category is required: the Launcher sorts by it, so a row without one is refused
    // rather than published into the wrong place.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
        ])
        let noType = RegistryEntry(name: "Hub", bundle_id: "com.t.hub", tagline: "One hub.",
                                   description: "Everything in one place.")
        do {
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], registry: registry(["hub": noType]), gh: gh, verifier: UnverifiedAsset())
            expect(false, "FG3b a registry entry without type must refuse")
        } catch {
            expect("\(error)".contains("type") && "\(error)".contains(hubRepo),
                   "FG3b the refusal names the missing category and the repo (\(error))")
        }
        let tagless = metaJSON(["name": "Hub Studio KH", "bundle_id": "com.t.hub",
                                "tagline": "One hub.", "description": "Everything in one place."])
        let gh2 = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": tagless,
        ])
        do {
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh2, verifier: UnverifiedAsset())
            expect(false, "FG3b an app-meta.json without type must refuse")
        } catch {
            expect("\(error)".contains("type"),
                   "FG3b the tag's file is held to the same list (\(error))")
        }
    }

    // FG4 a repo with no published release has no row, is named as unpublished, and does not fail
    // the run — that list is the only thing a publish may let disappear.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(storyRepo)/releases/latest": releaseJSON(repo: storyRepo, tag: "1.4.418", assets: [("Story.dmg", sha, 42, digest)]),
            "repos/\(storyRepo)/contents/app-meta.json?ref=1.4.418": storyMeta,
        ])
        let made = try FeedGenerator.generate(apps: ["story": storyRepo, "empty": "o/empty-kh"], gh: gh, verifier: UnverifiedAsset())
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
            let envelope = try FeedGenerator.signed(FeedGenerator.feed(apps: ["hub": hubRepo], gh: gh, verifier: UnverifiedAsset(), now: date), keyFile: keyFile)
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
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh, verifier: UnverifiedAsset())
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
                                             registry: registry(["updater": helper]), gh: gh, verifier: UnverifiedAsset())
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
                                             registry: registry(["hub": registryWords(name: "Old Name", bundle: "com.t.hub")]), gh: gh, verifier: UnverifiedAsset())
        expect(made.feed.apps["hub"]?.name == "Hub Studio KH" && made.sources["hub"] == "tag:0.6.257",
               "FG8 the tag's app-meta.json wins over the registry")
        expect(made.stale.count == 1 && made.stale[0].contains("registry entry is stale")
               && made.stale[0].contains("0.6.257"),
               "FG8 the ignored registry entry is reported by name and tag (\(made.stale))")
    } catch { expect(false, "FG8 fixture: \(error)") }

    // FG10 the generated feed carries no `previous` block at all, whatever the old feed had: a pin
    // whose artifact is gone reads as a rollback that works and installs nothing.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        var live = FeedApp(version: "0.6.250", file: "Hub-0.6.250.dmg", sha256: sha, bytes: 5, kind: "app-dmg")
        live.url = "https://github.com/\(hubRepo)/releases/download/0.6.250/Hub-0.6.250.dmg"
        var oldFeed = Feed(published_at: "2026-11-22T00:00:00Z", apps: ["hub": live])
        oldFeed.previous = ["hub": live]
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: oldFeed, gh: gh, verifier: UnverifiedAsset())
        expect(made.feed.previous == nil, "FG10 no previous block is emitted, even from a pin with its own address")
    } catch { expect(false, "FG10 fixture: \(error)") }

    // FG11 a prefixed tag is accepted only for its own app; another app's prefix refuses.
    do {
        let repo = "o/wire-kh"
        let wireTag = releaseJSON(repo: repo, tag: "wire-0.5.0", assets: [("Wire.dmg", sha, 9, digest)])
        let gh = FakeGitHub(paths: [
            "repos/\(repo)/releases/latest": wireTag,
            "repos/\(repo)/contents/app-meta.json?ref=wire-0.5.0": metaJSON([
                "name": "Wire Studio KH", "bundle_id": "com.t.wire", "type": "media",
                "tagline": "One caption.", "description": "Posts it."]),
        ])
        let made = try FeedGenerator.generate(apps: ["wire": repo], gh: gh, verifier: UnverifiedAsset())
        expect(made.feed.apps["wire"]?.version == "0.5.0",
               "FG11 `wire-0.5.0` is read as version 0.5.0 for the wire app")
        // Another app's tag in this repo is a stray: no row for hub, printed by name, no refusal.
        let stray = try FeedGenerator.generate(apps: ["hub": repo], gh: gh, verifier: UnverifiedAsset())
        expect(stray.feed.apps.isEmpty && stray.unpublished == ["hub"],
               "FG11 a repo holding only another app's release gives that app no row")
        expect(stray.notes.contains { $0.contains("stray release ignored") && $0.contains("wire-0.5.0") },
               "FG11 the stray release is printed by name (\(stray.notes))")
        // With an older acceptable release behind it, the run falls through to that one.
        var older = releaseJSON(repo: repo, tag: "hub-0.6.1", assets: [("Hub.dmg", sha, 8, digest)])
        let listed = try! JSONSerialization.jsonObject(with: releaseJSON(repo: repo, tag: "hub-0.6.1",
                                assets: [("Hub-0.6.1.dmg", sha, 8, digest)])) as! [String: Any]
        _ = older
        let listJSON = try! JSONSerialization.data(withJSONObject: [listed])
        let hubMetaAt = metaJSON(["name": "Hub Studio KH", "bundle_id": "com.t.hub", "type": "system",
                                  "tagline": "One hub.", "description": "Everything."])
        let gh2 = FakeGitHub(paths: [
            "repos/\(repo)/releases/latest": wireTag,
            "repos/\(repo)/releases?per_page=20": listJSON,
            "repos/\(repo)/contents/app-meta.json?ref=hub-0.6.1": hubMetaAt,
        ])
        let fell = try FeedGenerator.generate(apps: ["hub": repo], gh: gh2, verifier: UnverifiedAsset())
        expect(fell.feed.apps["hub"]?.version == "0.6.1" && (fell.feed.apps["hub"]?.file ?? "").contains("0.6.1"),
               "FG11 the run falls through to the repo's next acceptable release (\(fell.feed.apps["hub"]?.version ?? "nil"))")
        expect(fell.notes.contains { $0.contains("wire-0.5.0") },
               "FG11 the skipped stray is still printed (\(fell.notes))")
    } catch { expect(false, "FG11 fixture: \(error)") }

    // FG12 the row's file is the release's own asset name; a registry pin from an older version is
    // reported and ignored, never shipped — a version and its file name can never disagree.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.258", assets: [("Hub-0.6.258.dmg", sha, 7, digest)]),
        ])
        var stale = registryWords(name: "Hub Studio KH", bundle: "com.t.hub")
        stale.file = "Hub-0.6.250.dmg"
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], registry: registry(["hub": stale]), gh: gh, verifier: UnverifiedAsset())
        expect(made.feed.apps["hub"]?.file == "Hub-0.6.258.dmg",
               "FG12 the row names the release's own file (\(made.feed.apps["hub"]?.file ?? "nil"))")
        expect(made.stale.contains { $0.contains("Hub-0.6.250.dmg") && $0.contains("ignored") },
               "FG12 the stale registry file is reported, not silently dropped (\(made.stale))")
    } catch { expect(false, "FG12 fixture: \(error)") }

    // FG15 an icon is the app's identity and carries across a version change; so do the notes,
    // unless that release carries its own body — which is this version's changelog and wins.
    do {
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.258", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.258": hubMeta,
        ])
        var old = FeedApp(version: "0.6.257", file: "Hub.dmg", sha256: sha, bytes: 7, kind: "app-dmg")
        old.icon = "421c66bdb1cc-icon.png"; old.iconSha256 = "aa11"; old.notes = "What 0.6.257 changed."
        old.features = [AppFeature(title: "Old", text: "Only in 0.6.257.")]
        let before = Feed(published_at: "2026-11-22T00:00:00Z", apps: ["hub": old])
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: before, gh: gh, verifier: UnverifiedAsset())
        expect(made.feed.apps["hub"]?.icon == "421c66bdb1cc-icon.png"
               && made.feed.apps["hub"]?.iconSha256 == "aa11",
               "FG15 the icon carries across a version change")
        expect(made.feed.apps["hub"]?.notes == "What 0.6.257 changed.",
               "FG15 with no release body the served notes are carried")
        // A version bump is not a reason to forget what a publish wrote: features carry, and a
        // release whose own app-meta states features wins over the served list.
        expect(made.feed.apps["hub"]?.features?.first?.title == "Old",
               "FG15 features written by a publish carry across a version change")
        let withBody = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.258",
                                                             body: "What 0.6.258 changed.", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.258": hubMeta,
        ])
        let bodied = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: before, gh: withBody, verifier: UnverifiedAsset())
        expect(bodied.feed.apps["hub"]?.notes == "What 0.6.258 changed.",
               "FG15 on a version change the release body is this version's notes and wins (\(bodied.feed.apps["hub"]?.notes ?? "nil"))")
        // An untouched row keeps its served notes even though its release carries a body.
        let sameVersion = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: bodied.feed, gh: withBody, verifier: UnverifiedAsset())
        expect(sameVersion.feed.apps["hub"]?.notes == "What 0.6.258 changed.",
               "FG15 an unchanged version keeps the notes it already serves")
    } catch { expect(false, "FG15 fixture: \(error)") }

    // FG16 an untouched row is untouched, byte for byte: same version, spaced local `file`, curated
    // notes, an icon — and a release whose body is the 39-character placeholder the feed's own tool
    // writes. This is the exact shape that failed twice tonight, so it is a guard, not a one-off.
    do {
        let body = "Signed release from the KH Studio feed."
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", body: body,
                                                             assets: [("Hub-0.6.257.dmg", sha, 7, digest)]),
        ])
        var served = FeedApp(version: "0.6.257", file: "2b5b71b24b31-Hub Studio KH-0.6.257.dmg",
                             sha256: sha, bytes: 7, kind: "app-dmg")
        served.url = "https://github.com/\(hubRepo)/releases/download/0.6.257/Hub-0.6.257.dmg"
        served.name = "Hub Studio KH"; served.bundleID = "com.t.hub"; served.type = "system"
        served.tagline = "One hub."; served.description = "Everything in one place."
        served.notes = "- **A curated note.** It is long, and it is not the placeholder."
        served.icon = "2b5b71b24b31-icon.png"; served.iconSha256 = "ff00"
        served.released = "2026-11-23T02:00:00Z"
        let before = Feed(published_at: "2026-11-22T00:00:00Z", apps: ["hub": served])
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], previous: before, gh: gh, verifier: UnverifiedAsset())
        let after = made.feed.apps["hub"]
        expect(after == served, "FG16 an untouched row is byte-identical to the served one")
        expect(after?.file == "2b5b71b24b31-Hub Studio KH-0.6.257.dmg",
               "FG16 the spaced local file name is not normalised")
        expect(after?.notes != body, "FG16 the release body does not replace an untouched row's notes")
    } catch { expect(false, "FG16 fixture: \(error)") }

    // FG14 an asset that does not download anonymously is a finding, never a row. The check runs
    // before the row is built, so a draft or orphan release passes nothing through.
    do {
        struct Missing: AssetVerifier {
            func prove(url: String, repo: String, tag: String, asset: String, expectedSha: String, expectedBytes: Int64) throws {
                throw khuFail("answered 404")
            }
        }
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": hubMeta,
        ])
        do {
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh, verifier: Missing())
            expect(false, "FG14 an asset that does not download must refuse")
        } catch {
            expect("\(error)".contains("404"),
                   "FG14 the refusal carries the download's own answer (\(error))")
        }
    } catch { expect(false, "FG14 fixture: \(error)") }

    // FG13 a row may not vanish while its repo still publishes.
    do {
        var old = FeedApp(version: "0.4.3", file: "Wire.dmg", sha256: sha, bytes: 9, kind: "app-dmg")
        old.url = "https://github.com/o/wire-kh/releases/download/wire-0.4.3/Wire.dmg"
        let before = Feed(published_at: "2026-11-22T00:00:00Z", apps: ["wire": old])
        let gh = FakeGitHub(paths: [
            "repos/o/wire-kh/releases/latest": releaseJSON(repo: "o/wire-kh", tag: "wire-0.5.0", assets: [("Wire.dmg", sha, 9, digest)]),
        ])
        do {
            _ = try FeedGenerator.generate(apps: [:], previous: before, gh: gh, verifier: UnverifiedAsset())
            expect(false, "FG13 a row disappearing while its repo publishes must refuse")
        } catch {
            expect("\(error)".contains("wire") && "\(error)".contains("still publishes"),
                   "FG13 the refusal names the row and the repo (\(error))")
        }
    } catch { expect(false, "FG13 fixture: \(error)") }

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
                _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh, verifier: UnverifiedAsset())
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
            _ = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh, verifier: UnverifiedAsset())
            expect(false, "FG9 a missing .dmg asset must refuse")
        } catch {
            expect("\(error)".contains("no .dmg asset"),
                   "FG9 a missing asset refuses by name (\(error))")
        }
    }

    // FG17 a dropped connection is not a bad asset: measured 2026-11-23, three publishes died on
    // transient NSURLErrorNetworkConnectionLost while curl fetched the same URL in 33 s. The proof
    // tries again, and when every attempt fails the refusal is the one it always was.
    do {
        let body = Data("asset bytes".utf8)
        let bodySha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlakyAssetProtocol.self]
        let session = URLSession(configuration: config)
        let url = "https://example.test/Flaky.dmg"

        FlakyAssetProtocol.body = body
        FlakyAssetProtocol.failuresLeft = 2
        let recovered = AnonymousAsset(attempts: 3, backoff: 0.05, session: session)
        do {
            try recovered.prove(url: url, repo: "o/r", tag: "1.0.0", asset: "Flaky.dmg",
                                expectedSha: bodySha, expectedBytes: Int64(body.count))
            expect(true, "FG17 two dropped connections, the third attempt proves the asset")
        } catch {
            expect(false, "FG17 a transient drop must not refuse a good asset (\(error))")
        }

        FlakyAssetProtocol.failuresLeft = 9
        do {
            try recovered.prove(url: url, repo: "o/r", tag: "1.0.0", asset: "Flaky.dmg",
                                expectedSha: bodySha, expectedBytes: Int64(body.count))
            expect(false, "FG17 a URL that never answers must still refuse")
        } catch {
            expect("\(error)".contains("did not download anonymously"),
                   "FG17 the refusal is unchanged when every attempt fails (\(error))")
        }

        // And the guarantee itself is untouched: an asset that arrives but hashes differently is refused.
        FlakyAssetProtocol.failuresLeft = 0
        do {
            try recovered.prove(url: url, repo: "o/r", tag: "1.0.0", asset: "Flaky.dmg",
                                expectedSha: String(repeating: "0", count: 64), expectedBytes: Int64(body.count))
            expect(false, "FG17 a wrong sha must still refuse")
        } catch {
            expect("\(error)".contains("downloaded") && "\(error)".contains("nothing was generated"),
                   "FG17 the byte guarantee survives the retry (\(error))")
        }
    }

    // FG20 a release tag that names the app's own local artifact file keeps that name in `file`,
    // while `url` stays how GitHub stores the bytes (RELEASE-POLICY §229). Measured 2026-11-23, the
    // generator wrote the dotted stored name and split a row from the name it had served for months.
    do {
        let local = metaJSON(["name": "Hub Studio KH", "bundle_id": "com.t.hub", "type": "system",
                              "tagline": "One hub.", "description": "Everything in one place.",
                              "localFile": "Hub Studio KH-0.6.257.dmg"])
        let gh = FakeGitHub(paths: [
            "repos/\(hubRepo)/releases/latest": releaseJSON(repo: hubRepo, tag: "0.6.257", assets: [("Hub.Studio.KH-0.6.257.dmg", sha, 7, digest)]),
            "repos/\(hubRepo)/contents/app-meta.json?ref=0.6.257": local,
        ])
        let made = try FeedGenerator.generate(apps: ["hub": hubRepo], gh: gh, verifier: UnverifiedAsset())
        let hub = made.feed.apps["hub"]
        expect(hub?.file == "Hub Studio KH-0.6.257.dmg",
               "FG20 the tag's local file name is the row's file (\(hub?.file ?? "nil"))")
        expect(hub?.url?.hasSuffix("Hub.Studio.KH-0.6.257.dmg") == true,
               "FG20 the url keeps GitHub's stored name (\(hub?.url ?? "nil"))")
    }
}

/// Drops the first N requests, then serves `body` — the flaky connection a publish actually met.
final class FlakyAssetProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var failuresLeft = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.failuresLeft > 0 {
            Self.failuresLeft -= 1
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(Self.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
