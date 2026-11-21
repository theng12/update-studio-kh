import Foundation

struct FeedUnavailable: Error, CustomStringConvertible {
    var description: String { "Update Studio is unreachable. Server versions are unknown; verified SSD installers remain available." }
}

extension Agent {
    struct SelectedFeed {
        let feed: Feed
        let release: Data
        let base: URL
        /// Something worth saying about how this feed was judged; nil when nothing was unusual.
        var note: String?
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

    /// One sentence a person can act on, for the window and the log. Never Foundation's own text:
    /// an address macOS refuses is a setting to change, not a network failure to retry.
    public static func plainUnreachable(_ url: URL, error: Error) -> String {
        let host = url.host ?? url.absoluteString
        if blockedByTransportSecurity(error) {
            return FeedNetwork.isAddressLiteral(host)
                ? "the saved address \(host) is a bare IP, which macOS refuses for an unencrypted feed; use the publisher's host name instead"
                : "macOS refused \(host) because it is not a secure address; use the publisher's host name instead"
        }
        // A tailnet name that will not resolve is Tailscale's DNS, not a dead publisher; a person
        // can fix that or take the public feed, and the sentence must say which.
        if let urlError = error as? URLError, [.cannotFindHost, .dnsLookupFailed].contains(urlError.code),
           host.lowercased().hasSuffix(".ts.net") {
            return "\(host) cannot be found: Tailscale's DNS is not answering on this Mac. Bring Tailscale up, or use GitHub releases instead."
        }
        return "Update Studio could not be reached at \(host)"
    }

    /// An address macOS refuses on sight: plain HTTP to a bare IP (ATS). It is dropped from the
    /// cached list only once a check has proved it and succeeded somewhere else, so a Mac with no
    /// other source is never left with none.
    static func isUnusable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && FeedNetwork.isAddressLiteral(url.host ?? "")
    }

    /// This Mac's own settings outrank a cached copy: `agent-memory.json` keeps the last *signed*
    /// network block so an offline Mac still knows its mirrors, and a stale one must never override
    /// what this Mac's config file names. Whatever the config does not name still comes from memory
    /// — the host roles and a controller handoff live only in the signed block.
    static func effectiveNetwork(config: AgentConfig, memory: AgentMemory) -> FeedNetwork? {
        guard let saved = config.network else { return memory.feedNetwork }
        var merged = memory.feedNetwork ?? saved
        // A saved list that can never work does not outrank one that can; a *usable* saved list
        // always wins, even when it differs from memory, so an operator's deliberate change is
        // never reverted by a stale block. Bounded on "unusable", never on "different".
        if saved.feedURLs.isEmpty {
            merged.feedURLs = saved.feedURLs
        } else if saved.feedURLs.contains(where: { !FeedNetwork.isUnusable($0) }) {
            merged.feedURLs = saved.feedURLs
        }
        if !saved.hosts.isEmpty { merged.hosts = saved.hosts }
        merged.controller = saved.controller ?? merged.controller
        return merged
    }

    static func feedSources(config: AgentConfig, memory: AgentMemory, serverBase: URL) throws -> [URL] {
        let network = effectiveNetwork(config: config, memory: memory)
        // A host mirrors *to* other Macs, never *from* its own mirror, so it reads its original
        // signer first — whether or not its hosting role is on. An install on the publisher's own
        // Mac therefore never depends on `FeedHostRuntime`; a client still prefers its mirrors.
        let isHost = network?.hosts[config.machine] != nil
        let original = serverBase.appendingPathComponent("release.json")
        // A mirror whose address cannot work is dropped, not allowed to fail the whole check: one bad
        // entry in a pushed list must not leave every Mac with no feed at all.
        var sources = (network?.feedURLs ?? []).compactMap { try? FeedNetwork.feedURL($0) }
        sources.removeAll { $0 == original }
        // The address the person saved is what the very next check uses, without a restart. Mirrors
        // lead only when this Mac already reached the publisher at that same saved address; a newly
        // saved one has not been reached yet, so it goes first until it answers once.
        let mirrorsLead = !isHost && (memory.lastGoodFeedURL == nil || memory.lastGoodFeedURL == config.feedURL)
        if !mirrorsLead { sources.insert(original, at: 0) } else { sources.append(original) }
        return sources
    }

    static func selectFeed(http: HTTPClient, serverBase: URL, config: AgentConfig,
                           memory: inout AgentMemory, now: Date) throws -> SelectedFeed {
        var lastError: Error = FeedUnavailable()
        var refusal: Error?
        var unusable: [String] = []
        for source in try feedSources(config: config, memory: memory, serverBase: serverBase) {
            let release: Data
            do { release = try get(http, source) }
            catch {
                if blockedByTransportSecurity(error) {
                    // Proved unusable by this check: remembered only so a successful run can forget it.
                    if isUnusable(source) { unusable.append(source.absoluteString) }
                    refusal = khuFail(plainUnreachable(source, error: error))
                } else if transportUnavailable(error) { lastError = FeedUnavailable() }
                else { refusal = error }
                continue
            }
            if !unusable.isEmpty, var network = memory.feedNetwork {
                // A cached address macOS will always refuse is not worth retrying: the check that
                // just succeeded elsewhere drops it, so the next run starts from what works.
                network.feedURLs.removeAll { unusable.contains($0) }
                memory.feedNetwork = network
            }
            do {
                var candidate = memory
                let checked = try checkFeed(release, config: config, memory: &candidate, now: now)
                memory = candidate
                return SelectedFeed(feed: checked.feed, release: release, base: source.deletingLastPathComponent(),
                                    note: checked.note)
            } catch { refusal = error }
        }
        throw refusal ?? lastError
    }
}
