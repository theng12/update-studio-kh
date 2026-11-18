import Foundation
import CryptoKit

/// FH: the helper serving this Mac's feed itself must serve exactly the bytes the publisher does,
/// and must come back on its own after it stops — the failure that took the feed down on 17 Nov was
/// a separate job that did not load after a reboot while the agent did.
func feedHostTests() {
    let root = tmpDir("feed-host")
    let feedDir = root.appendingPathComponent("feed")
    let stateDir = root.appendingPathComponent("state")
    try! fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let pair = Signing.generateKeyPair()
    let keyFile = root.appendingPathComponent("private.key")
    try! Signing.savePrivateKey(pair.privateKey, to: keyFile)
    let artifact = root.appendingPathComponent("fixture.bin")
    try! Data("installer bytes".utf8).write(to: artifact)
    try! FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "fixture", version: "1.0.0",
                               artifact: artifact, kind: "fake-for-tests", allowSame: false, meta: nil)
    let secondArtifact = root.appendingPathComponent("second.bin")
    try! Data("second installer bytes".utf8).write(to: secondArtifact)
    try! FeedPublisher.publish(feedDir: feedDir, keyFile: keyFile, app: "second", version: "2.1.0",
                               artifact: secondArtifact, kind: "fake-for-tests", allowSame: false, meta: nil)

    // What the publisher serves today, read off its own socket.
    let publisher = FeedServer(feedDir: feedDir, stateDir: root.appendingPathComponent("publisher-state"),
                               bind: "127.0.0.1", port: 0, commandKey: pair.privateKey)
    let publisherFD = try! publisher.listen()
    let publisherPort = FeedServer.boundPort(publisherFD)
    Thread { try? publisher.serve(on: publisherFD) }.start()
    defer { publisher.stopListening() }
    let served = URL(string: "http://127.0.0.1:\(publisherPort)/release.json")!
    guard let (published, code) = try? URLSessionHTTPClient().get(served, headers: [:]) else {
        expect(false, "FH1 the publisher fixture did not answer")
        return
    }
    expect(code == 200, "FH1 the publisher fixture serves its feed (\(code))")

    // The mirror the helper keeps, and the role that makes it serve it.
    let mirror = FeedHostRole.feedDirectory(in: stateDir)
    _ = try? FeedMirror.sync(releaseData: published, sourceBase: URL(string: "http://127.0.0.1:\(publisherPort)")!, root: mirror,
                             publicKey: pair.privateKey.publicKey.rawRepresentation.base64EncodedString(),
                             http: URLSessionHTTPClient(), now: Date())
    let mirrored = (try? Data(contentsOf: mirror.appendingPathComponent("release.json"))) ?? Data()
    expect(mirrored == published, "FH1 the helper's mirror is byte-identical to the publisher's feed")

    let role = FeedHostRole(enabled: true, bind: "127.0.0.1", port: 0)
    let started = FeedHostService.ensure(role: role, stateDir: stateDir)
    guard let port = FeedHostService.servingPorts.first else {
        expect(false, "FH2 the helper did not start serving (\(started))")
        return
    }
    let hostFeed = URL(string: "http://127.0.0.1:\(port)/release.json")!
    guard let (hostBytes, hostCode) = try? URLSessionHTTPClient().get(hostFeed, headers: [:]) else {
        expect(false, "FH2 the helper's own feed did not answer")
        return
    }
    let verifiedFeed = try? FeedPublisher.loadVerifiedFeed(from: feedDir, publicKey: pair.privateKey.publicKey)
    var allAppsMatch = verifiedFeed?.apps.count == 2
    for (_, appEntry) in verifiedFeed?.apps ?? [:] {
        let pubArt = try? URLSessionHTTPClient().get(URL(string: "http://127.0.0.1:\(publisherPort)/artifacts/\(appEntry.file)")!, headers: [:])
        let hostArt = try? URLSessionHTTPClient().get(URL(string: "http://127.0.0.1:\(port)/artifacts/\(appEntry.file)")!, headers: [:])
        if pubArt?.1 != 200 || hostArt?.1 != 200 || pubArt?.0 != hostArt?.0 { allAppsMatch = false }
    }
    expect(hostCode == 200 && hostBytes == published && allAppsMatch,
           "FH2 with hosting on, release.json and every app's artifact are byte-identical to the publisher's (\(hostCode), \(hostBytes.count) B)")

    // The reboot case: the process that served it stops. Nothing else is running, so the feed must
    // come back when that process starts again — no separate job to load.
    expect(FeedHostService.stop().contains("off"), "FH3 stopping hosting says so")
    let down = (try? URLSessionHTTPClient().get(hostFeed, headers: [:]))?.1
    expect(down == nil, "FH3 nothing answers while hosting is stopped")
    _ = FeedHostService.ensure(role: role, stateDir: stateDir)
    guard let revived = FeedHostService.servingPorts.first else {
        expect(false, "FH4 hosting did not start again")
        return
    }
    let again = (try? URLSessionHTTPClient().get(URL(string: "http://127.0.0.1:\(revived)/release.json")!, headers: [:]))
    expect(again?.1 == 200 && again?.0 == published,
           "FH4 starting the helper again brings the feed back by itself (\(again?.1 ?? -1))")
    _ = FeedHostService.stop()
}
