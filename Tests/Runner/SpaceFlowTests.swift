import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A download client that fails if called — proves a refusal happened before any network work.
private final class FailIfCalledHTTP: HTTPClient, @unchecked Sendable {
    var called = false
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        called = true; throw khuFail("HTTP should not have been called")
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        called = true; throw khuFail("HTTP should not have been called")
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        called = true; throw khuFail("HTTP should not have been called")
    }
}

func spaceFlowTests() {
    // SF1: a download refused for space throws Space.NoSpace before any HTTP call; the error's
    // description carries the free-space number and nothing is written into downloads/<app>.
    do {
        let rig = Rig("space-refuse")
        try rig.publish("demo", "2.0.0", rig.artifact("demo.dmg", "not a real disk image"))
        guard let feed = try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey),
              let entry = feed.apps["demo"] else { expect(false, "SF1 fixture feed"); return }
        let stateDir = URL(fileURLWithPath: rig.state.path)
        let http = FailIfCalledHTTP()
        let nearlyFull: UInt64 = 1000
        var caught: Space.NoSpace?
        do {
            _ = try Agent.download(entry, app: "demo", serverBase: URL(string: "http://127.0.0.1:8790")!,
                                   stateDir: stateDir, http: http,
                                   freeSpace: { _ in nearlyFull })
        } catch let error as Space.NoSpace {
            caught = error
        }
        expect(caught != nil, "SF1 download throws Space.NoSpace when free < artifact + reserve")
        if let e = caught {
            expect(e.description.contains(Space.gigabytes(nearlyFull)),
                   "SF1 error description carries the free-space number (\(e.description))")
        }
        expect(!http.called, "SF1 no HTTP call when free space is insufficient")
        let dir = stateDir.appendingPathComponent("downloads/demo")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        expect(contents.isEmpty, "SF1 nothing written into downloads/demo on refusal (\(contents))")
    } catch { expect(false, "SF1 space-refuse: \(error)") }

    // SF2: Space.sweep keeps only the named artifact (and its .part), removes old bytes outright
    // (not moved into _trash), and the state dir's _trash gains nothing.
    do {
        let dir = tmpDir("space-sweep")
        let fm = FileManager.default
        let keep = dir.appendingPathComponent("artifact-2.0.0.dmg")
        let old = dir.appendingPathComponent("artifact-1.0.0.dmg")
        let part = dir.appendingPathComponent("artifact-2.0.0.dmg.part")
        try Data("keep".utf8).write(to: keep)
        try Data("old".utf8).write(to: old)
        try Data("part".utf8).write(to: part)
        let stateDir = dir.deletingLastPathComponent()
        let trashBefore = (try? fm.contentsOfDirectory(at: Trash.root(in: stateDir), includingPropertiesForKeys: nil))?.count ?? 0
        let swept = Space.sweep(dir, keeping: ["artifact-2.0.0.dmg", "artifact-2.0.0.dmg.part"])
        expect(fm.fileExists(atPath: keep.path), "SF2 kept artifact survives sweep")
        expect(fm.fileExists(atPath: part.path), "SF2 kept .part survives sweep")
        expect(!fm.fileExists(atPath: old.path), "SF2 old artifact is removed by sweep")
        expect(swept.removed == 1 && swept.bytes > 0, "SF2 sweep reports one removal (\(swept))")
        let trashAfter = (try? fm.contentsOfDirectory(at: Trash.root(in: stateDir), includingPropertiesForKeys: nil))?.count ?? 0
        expect(trashAfter == trashBefore, "SF2 sweep does not grow _trash (\(trashBefore) → \(trashAfter))")
    } catch { expect(false, "SF2 sweep: \(error)") }

    // SF3: pruneTrash(keeping: defaultBucketsKept) on three buckets removes only the oldest;
    // immutable flags are cleared first so even uchg-marked entries go.
    do {
        let stateDir = tmpDir("space-prune")
        let fm = FileManager.default
        let trash = Trash.root(in: stateDir)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let names = ["2026-11-17T10-00-00", "2026-11-17T09-00-00", "2026-11-17T08-00-00"]
        for name in names {
            let bucket = trash.appendingPathComponent(name)
            try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: bucket.appendingPathComponent("payload"))
        }
        for name in names {
            _ = try? SystemShell().run("/usr/bin/chflags", arguments: ["-R", "uchg", trash.appendingPathComponent(name).path], timeout: 10)
        }
        let swept = Space.pruneTrash(in: stateDir, keeping: Space.defaultBucketsKept)
        let remaining = ((try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent).sorted(by: >)
        expect(remaining.count == Space.defaultBucketsKept,
               "SF3 only the newest \(Space.defaultBucketsKept) bucket(s) remain after prune (\(remaining))")
        expect(swept.removed == names.count - Space.defaultBucketsKept,
               "SF3 oldest buckets were removed (\(swept.removed))")
    } catch { expect(false, "SF3 prune: \(error)") }

    // SF4: calling the same prune path that runLocked uses, with the configured keeping value,
    // clears older buckets and produces the words line. Wiring a full runOnce would duplicate
    // existing install fixtures; the prune path itself is what matters.
    do {
        let stateDir = tmpDir("space-prune-note")
        let fm = FileManager.default
        let trash = Trash.root(in: stateDir)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let names = ["2026-11-17T12-00-00", "2026-11-17T11-00-00", "2026-11-17T10-00-00"]
        for name in names {
            let bucket = trash.appendingPathComponent(name)
            try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: bucket.appendingPathComponent("data"))
        }
        let kept = max(1, Space.defaultBucketsKept)
        let swept = Space.pruneTrash(in: stateDir, keeping: kept)
        let remaining = ((try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent).sorted(by: >)
        expect(remaining.count == kept, "SF4 prune leaves exactly \(kept) bucket(s) (\(remaining))")
        expect(!swept.isEmpty, "SF4 prune reports work done")
        expect(swept.words.contains("cleared"), "SF4 words line describes what was cleared (\(swept.words))")
    } catch { expect(false, "SF4 prune-note: \(error)") }
}