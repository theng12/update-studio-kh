import Foundation

extension FeedPublisher {
    public static func configureNetwork(feedDir: URL, keyFile: URL, network: FeedNetwork, now: Date = Date()) throws {
        let checked = try network.validated()
        // Owner policy (RELEASE-POLICY §2c): a one-shot controller handoff carries private addresses
        // and the signed feed is read by every Mac, so it is never written there. Refused by name,
        // never stripped: a caller asking for it must learn it is not how a handoff travels.
        guard checked.controller == nil else {
            throw khuFail("refused: a controller handoff is not written into the signed feed; it carries private addresses every Mac would read. Set the connection on that Mac instead.")
        }
        let key = try Signing.loadPrivateKey(from: keyFile)
        try FileLock.withExclusive(feedDir.appendingPathComponent("publish.lock")) {
            guard var feed = try loadVerifiedFeed(from: feedDir, publicKey: key.publicKey) else {
                throw khuFail("publish the apps before configuring a feed host")
            }
            feed = try withPreviousInstallers(feed, in: feedDir)
            feed.network = checked
            feed.published_at = ISO.string(max(now, (feed.publishedAt ?? .distantPast).addingTimeInterval(0.001)))
            try saveFeed(try feed.validated(), to: feedDir, key: key)
        }
    }
}
