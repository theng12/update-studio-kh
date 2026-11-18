import Foundation

/// The address a server binds, resolved at start rather than kept in a file. A tailnet address
/// changes when Tailscale renumbers a Mac; a stored literal then binds nothing and every Mac sees
/// an empty publisher page with no reason.
public enum BindAddress {
    /// "auto" means this Mac's current tailnet address; a host name is looked up now. Anything that
    /// resolves to nothing on the tailnet fails with the reason, so the publisher stops loudly
    /// instead of serving where nobody can reach it.
    public static func resolve(_ value: String) throws -> String {
        if value == "0.0.0.0" || value == "127.0.0.1" || FeedServer.isTailnet(value) { return value }
        if value == "auto" {
            guard let ip = MacInventory.interfaceAddresses().tailscaleIPv4 else {
                throw khuFail("this Mac has no tailnet address right now (is Tailscale running?), so the publisher cannot bind \"auto\"")
            }
            return ip
        }
        guard isHostName(value) else { throw khuFail("\(value) is not an IPv4 address, a host name or \"auto\"") }
        guard let ip = lookup(value) else { throw khuFail("\(value) does not resolve to an address on this Mac; the publisher cannot start") }
        guard FeedServer.isTailnet(ip) else {
            throw khuFail("\(value) resolves to \(ip), which is not a tailnet address (100.64.0.0/10)")
        }
        return ip
    }

    /// Letters, digits, dots and hyphens, and not an IPv4 literal. Kept strict so a typo in a bind
    /// value fails at validation instead of at DNS.
    public static func isHostName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253, !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        guard value.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "." || $0 == "-" }) else { return false }
        return value.contains { $0.isLetter }
    }

    /// First IPv4 the name resolves to, preferring a tailnet one.
    private static func lookup(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var fallback: String?
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let address = current.pointee.ai_addr {
                var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: text)
                    if FeedServer.isTailnet(ip) { return ip }
                    fallback = fallback ?? ip
                }
            }
            node = current.pointee.ai_next
        }
        return fallback
    }
}

public struct FeedHostRole: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var bind: String
    public var port: Int
    public init(enabled: Bool = false, bind: String, port: Int = 8790) {
        self.enabled = enabled; self.bind = bind; self.port = port
    }
    public func validated() throws -> FeedHostRole {
        // "auto" and a host name are resolved when the server starts, so a host whose address
        // moved still serves at whatever address it has then.
        let deferred = bind == "auto" || BindAddress.isHostName(bind)
        guard (FeedServer.isTailnet(bind) || deferred || bind == "127.0.0.1"), (1...65535).contains(port) else {
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
              let host = url.host, FeedServer.isTailnet(host) || host == "127.0.0.1" || isMagicDNS(host),
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw khuFail("feed address must be an HTTP release.json on the existing tailnet, its Tailscale DNS name or loopback")
        }
        return url
    }

    /// A Tailscale DNS name (`*.ts.net`), the one host name macOS will fetch plain HTTP from: the
    /// app's ATS exception covers `ts.net` and its subdomains. Kept a name, resolved on every
    /// request, so a Mac whose tailnet address moved is still reached.
    public static func isMagicDNS(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.hasSuffix(".ts.net") && BindAddress.isHostName(lower)
    }

    /// An IPv4 literal, which Tailscale also reports for a Mac's address.
    public static func isAddressLiteral(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255 }
    }
}
