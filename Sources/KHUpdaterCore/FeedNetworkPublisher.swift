import Foundation

extension FeedPublisher {
    public static func configureNetwork(feedDir: URL, keyFile: URL, network: FeedNetwork, now: Date = Date()) throws {
        let checked = try network.validated()
        let key = try Signing.loadPrivateKey(from: keyFile)
        try FileLock.withExclusive(feedDir.appendingPathComponent("publish.lock")) {
            guard var feed = try loadVerifiedFeed(from: feedDir, publicKey: key.publicKey) else {
                throw khuFail("publish the apps before configuring a feed host")
            }
            feed.network = checked
            feed.published_at = ISO.string(max(now, (feed.publishedAt ?? .distantPast).addingTimeInterval(0.001)))
            try saveFeed(try feed.validated(), to: feedDir, key: key)
        }
    }
}
