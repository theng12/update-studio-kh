import Foundation

extension Agent {
    /// Called only after this run's work; the next run reloads the saved connection.
    static func followControllerHandoff(release: Data, config: AgentConfig, memory: AgentMemory,
                                        file: URL, http: HTTPClient, now: Date) throws -> Bool {
        var checked = memory
        let feed = try checkedFeed(release, config: config, memory: &checked, now: now)
        guard let handoff = feed.network?.controller, handoff.from == config.feedURL else { return false }
        _ = try handoff.validated()
        let raw = try Data(contentsOf: file)
        let saved = try JSON.decode(AgentConfig.self, from: raw)
        guard saved.feedURL == config.feedURL, saved.publicKey == config.publicKey,
              saved.machine == config.machine, saved.token == config.token,
              saved.stateDir == config.stateDir, saved.stubBase == config.stubBase else {
            throw khuFail("controller move refused: the saved connection changed; retry with current settings")
        }
        let target = try FeedNetwork.feedURL(handoff.to)
        // No token goes to a new controller until it serves the exact already-verified handoff.
        guard try get(http, target) == release else {
            throw khuFail("controller move waits: the destination does not serve the same signed handoff")
        }
        var destination = config
        destination.feedURL = handoff.to
        // Proves the existing token, Mac identity, pinned signer and a fresh signed control reply.
        try Connect.check(config: destination, http: http, now: now)
        guard try Data(contentsOf: file) == raw else {
            throw khuFail("controller move refused: settings changed during the connection check")
        }
        let rollback = file.deletingLastPathComponent().appendingPathComponent("_trash/controller-handoff-" + UUID().uuidString)
            .appendingPathComponent("config.json")
        try AtomicFile.write(raw, to: rollback, permissions: 0o600)
        _ = try Connect.saveDestination(handoff.to, file: file, expected: raw)
        return true
    }
}
