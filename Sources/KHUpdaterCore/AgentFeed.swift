import Foundation

extension Agent {
    struct SelectedFeed {
        let feed: Feed
        let release: Data
        let base: URL
    }

    static func feedSources(config: AgentConfig, memory: AgentMemory, serverBase: URL) throws -> [URL] {
        let network = memory.feedNetwork ?? config.network
        // A host always refreshes from its original signer, never from its own mirror.
        let addresses = network?.hosts[config.machine]?.enabled == true ? [] : (network?.feedURLs ?? [])
        var sources = try addresses.map { try FeedNetwork.feedURL($0) }
        let original = serverBase.appendingPathComponent("release.json")
        if !sources.contains(original) { sources.append(original) }
        return sources
    }

    static func selectFeed(http: HTTPClient, serverBase: URL, config: AgentConfig,
                           memory: inout AgentMemory, now: Date) throws -> SelectedFeed {
        var lastError: Error = khuFail("no update feed could be reached")
        for source in try feedSources(config: config, memory: memory, serverBase: serverBase) {
            do {
                let release = try get(http, source)
                var candidate = memory
                let feed = try checkedFeed(release, config: config, memory: &candidate, now: now)
                memory = candidate
                return SelectedFeed(feed: feed, release: release, base: source.deletingLastPathComponent())
            } catch { lastError = error }
        }
        throw lastError
    }
}
