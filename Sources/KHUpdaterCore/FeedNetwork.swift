import Foundation

public struct FeedHostRole: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var bind: String
    public var port: Int
    public init(enabled: Bool = false, bind: String, port: Int = 8790) {
        self.enabled = enabled; self.bind = bind; self.port = port
    }
    public func validated() throws -> FeedHostRole {
        guard (FeedServer.isTailnet(bind) || bind == "127.0.0.1"), (1...65535).contains(port) else {
            throw khuFail("feed hosting requires this Mac's existing tailnet address and a port from 1 to 65535")
        }
        return self
    }
    public static func feedDirectory(in stateDir: URL) -> URL {
        stateDir.appendingPathComponent("feed-host/feed")
    }
}

/// An explicit same-signer controller move; download mirrors alone never receive credentials.
public struct ControllerHandoff: Codable, Sendable, Equatable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
    public func validated() throws -> ControllerHandoff {
        _ = try FeedNetwork.feedURL(from)
        _ = try FeedNetwork.feedURL(to)
        guard from != to else { throw khuFail("controller handoff requires different source and destination addresses") }
        return self
    }
}

/// Carried inside the signed feed; absent means no host role or connection change.
public struct FeedNetwork: Codable, Sendable, Equatable {
    public var feedURLs: [String]
    public var hosts: [String: FeedHostRole]
    public var controller: ControllerHandoff?
    public init(feedURLs: [String] = [], hosts: [String: FeedHostRole] = [:], controller: ControllerHandoff? = nil) {
        self.feedURLs = feedURLs; self.hosts = hosts; self.controller = controller
    }
    public func validated() throws -> FeedNetwork {
        _ = try controller?.validated()
        for address in feedURLs { _ = try Self.feedURL(address) }
        guard Set(feedURLs).count == feedURLs.count else { throw khuFail("feed addresses must not repeat") }
        for (machine, role) in hosts {
            _ = try SafeName.component(machine, what: "feed host machine")
            _ = try role.validated()
        }
        return self
    }
    public static func feedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "http", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path == "/release.json",
              let host = url.host, FeedServer.isTailnet(host) || host == "127.0.0.1",
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw khuFail("feed address must be an HTTP release.json on the existing tailnet or loopback")
        }
        return url
    }
}
