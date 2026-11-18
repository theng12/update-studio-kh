import Foundation

/// Serves this Mac's signed feed from inside the helper, so the publisher needs no separate
/// launchd job.
///
/// The job it replaces (`com.khupdater.feed-host`, and before it `com.khupdater.publisher`) failed
/// to load after a reboot on 17 Nov while `com.khupdater.agent` from the same folder came up fine;
/// the agent already starts by itself and carries the same key, so it is the one process that
/// should hold the feed. This is only used when the signed network settings name the hosting role
/// for this Mac — off everywhere else, so installing this changes nothing on a client Mac.
///
/// Process-wide and idempotent: the helper's loop calls `ensure` on every run, and the servers are
/// started once and left running. A restarted helper starts them again, which is what makes the
/// feed come back without anyone touching the Mac.
public enum FeedHostService {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Running?

    private struct Running {
        var signature: String
        var servers: [FeedServer]
        var addresses: [String]
    }

    public static var isServing: Bool { lock.lock(); defer { lock.unlock() }; return running != nil }

    /// The ports actually served, for a fixture that asked for port 0.
    public static var servingPorts: [Int] {
        lock.lock(); let now = running; lock.unlock()
        return (now?.servers ?? []).compactMap { $0.boundPort() }
    }

    /// Starts serving this Mac's mirror if it is not already, and reports what is true in one line.
    public static func ensure(role: FeedHostRole, stateDir: URL) -> String {
        let feedDir = FeedHostRole.feedDirectory(in: stateDir)
        guard FileManager.default.fileExists(atPath: feedDir.appendingPathComponent("release.json").path) else {
            return "feed hosting is on but this Mac has no published mirror yet; nothing is served"
        }
        let signature = "\(role.bind):\(role.port):\(feedDir.path)"
        lock.lock()
        if let running, running.signature == signature {
            lock.unlock()
            return "serving this Mac's feed itself on \(running.addresses.joined(separator: ", ")):\(role.port)"
        }
        let previous = running
        running = nil
        lock.unlock()
        stop(previous)

        let addresses: [String]
        do { addresses = try [role.bind].map { try BindAddress.resolve($0) } }
        catch { return "the hosting address could not be used: \(error)" }

        var servers: [FeedServer] = []
        for address in addresses {
            let server = FeedServer(feedDir: feedDir, stateDir: stateDir.appendingPathComponent("feed-host/server-state"),
                                    bind: address, port: role.port, commandKey: nil, feedOnly: true)
            do {
                let fd = try server.listen()
                Thread { do { try server.serve(on: fd) } catch {
                    FileHandle.standardError.write(Data("feed host stopped serving on \(address): \(error)\n".utf8))
                } }.start()
                servers.append(server)
            } catch {
                // Every address is bound before any is served, or none is: a half-served host would
                // answer on one address and refuse on another and look like a broken feed.
                for started in servers { started.stopListening() }
                return "feed hosting could not start on \(address):\(role.port): \(error)"
            }
        }
        lock.lock(); running = Running(signature: signature, servers: servers, addresses: addresses); lock.unlock()
        return "serving this Mac's feed itself on \(addresses.joined(separator: ", ")):\(role.port)"
    }

    /// Stops serving, for a role that has been switched off. Says nothing when nothing ran.
    public static func stop() -> String {
        lock.lock(); let previous = running; running = nil; lock.unlock()
        guard previous != nil else { return "feed hosting is off on this Mac (it does not host the feed)" }
        stop(previous)
        return "feed hosting was switched off on this Mac; it stopped serving"
    }

    private static func stop(_ running: Running?) {
        guard let running else { return }
        for server in running.servers { server.stopListening() }
    }
}
