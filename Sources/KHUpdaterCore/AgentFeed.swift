import Foundation

struct FeedUnavailable: Error, CustomStringConvertible {
    var description: String { "Update Studio is unreachable. Server versions are unknown; verified SSD installers remain available." }
}

extension Agent {
    struct SelectedFeed {
        let feed: Feed
        let release: Data
        let base: URL
    }

    static func transportUnavailable(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
                .callIsActive, .dataNotAllowed].contains(error.code)
    }

    /// macOS refused a cleartext address (ATS). It is not a network blip: retrying the same address
    /// can never succeed, and the reason must say so rather than read as "unreachable".
    static func blockedByTransportSecurity(_ error: Error) -> Bool {
        (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection
            || (error as NSError).code == -1022 && (error as NSError).domain == NSURLErrorDomain
    }

    static func feedSources(config: AgentConfig, memory: AgentMemory, serverBase: URL) throws -> [URL] {
        let network = memory.feedNetwork ?? config.network
        // A host mirrors *to* other Macs, never *from* its own mirror, so it reads its original
        // signer first — whether or not its hosting role is on. An install on the publisher's own
        // Mac therefore never depends on `FeedHostRuntime`; a client still prefers its mirrors.
        let isHost = network?.hosts[config.machine] != nil
        let original = serverBase.appendingPathComponent("release.json")
        // A mirror whose address cannot work is dropped, not allowed to fail the whole check: one bad
        // entry in a pushed list must not leave every Mac with no feed at all. A bare IP is dropped
        // for a second reason: macOS refuses plain HTTP to an address (ATS -1022) every time, so it
        // is not a slower fallback but one that can never answer.
        var sources = (network?.feedURLs ?? []).compactMap { try? FeedNetwork.feedURL($0) }
            .filter { !(FeedNetwork.isAddressLiteral($0.host ?? "")) }
        sources.removeAll { $0 == original }
        if isHost { sources.insert(original, at: 0) } else { sources.append(original) }
        return sources
    }

    static func selectFeed(http: HTTPClient, serverBase: URL, config: AgentConfig,
                           memory: inout AgentMemory, now: Date) throws -> SelectedFeed {
        var lastError: Error = FeedUnavailable()
        var refusal: Error?
        for source in try feedSources(config: config, memory: memory, serverBase: serverBase) {
            let release: Data
            do { release = try get(http, source) }
            catch {
                if blockedByTransportSecurity(error) {
                    refusal = khuFail("macOS refused \(source.host ?? "the feed address") because it is not a secure address: the feed must be named by its host name, never by a bare IP. Nothing was changed.")
                } else if transportUnavailable(error) { lastError = FeedUnavailable() }
                else { refusal = error }
                continue
            }
            do {
                var candidate = memory
                let feed = try checkedFeed(release, config: config, memory: &candidate, now: now)
                memory = candidate
                return SelectedFeed(feed: feed, release: release, base: source.deletingLastPathComponent())
            } catch { refusal = error }
        }
        throw refusal ?? lastError
    }
}
