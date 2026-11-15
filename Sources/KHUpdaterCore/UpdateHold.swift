import Foundation

/// The app-side update hold every KH app implements (`_orchestra/youtube-stack/update-hold/CONTRACT.md`):
/// POST pauses dispatch and settles in-flight work within a bounded window, DELETE resumes. The
/// endpoint is a loopback address the signed feed names for that app — anything else is not a
/// trusted update target.
public enum UpdateHold {
    public struct Reply: Decodable, Sendable, Equatable {
        public var safe: Bool
        public var unsettled: [String]?
        public var inFlight: Int?
        public var pausedSeconds: Int?
        enum CodingKeys: String, CodingKey {
            case safe, unsettled
            case inFlight = "in_flight"
            case pausedSeconds = "dispatch_paused_s"
        }
        public var summary: String {
            let jobs = inFlight ?? 0
            let paused = pausedSeconds.map { "; new work paused \($0) s" } ?? ""
            return jobs > 0 ? "held (\(jobs) job\(jobs == 1 ? "" : "s") in flight\(paused))" : "held\(paused)"
        }
    }

    /// The trusted endpoint for a feed entry: plain HTTP on this Mac's loopback, an explicit port,
    /// and exactly the contract's two paths. A remote or malformed URL is no endpoint at all.
    public static func trusted(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
              url.port != nil, url.user == nil, url.password == nil,
              ["/api/maintenance/hold", "/api/maintenance/drain"].contains(url.path) else { return nil }
        return url
    }

    /// The contract's ceiling: no wait on an app may outlast one settle window.
    public static let ceiling: TimeInterval = 30

    /// Pauses dispatch and waits for the app's bounded settle. `timeoutS` never exceeds the
    /// contract's 30 s ceiling; 0 renews an existing hold without waiting. The request itself is
    /// bounded too: `deadline` caps how much of the window is left, so a silent endpoint fails
    /// closed inside 30 s instead of inheriting the client's 60 s/600 s defaults.
    public static func begin(_ endpoint: URL, http: HTTPClient, timeoutS: Int = 20, pauseS: Int = 120,
                             deadline: Date? = nil) throws -> Reply {
        let timeout = max(0, min(30, timeoutS))
        let url = endpoint.appendingQuery("timeout_s", "\(timeout)").appendingQuery("pause_s", "\(max(1, pauseS))")
        let wait = max(1, min(ceiling, deadline?.timeIntervalSinceNow ?? ceiling))
        let (data, code) = try http.post(url, headers: [:], body: Data(), timeout: wait)
        guard code == 200 else { throw khuFail("the app's update hold answered \(code); nothing was changed") }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw khuFail("the app's update hold did not answer with the contract's reply; nothing was changed")
        }
        return reply
    }

    /// Best effort: the pause is in-memory and expires by itself, so a failed DELETE never leaves
    /// an app that has stopped taking work.
    public static func resume(_ endpoint: URL, http: HTTPClient) {
        _ = try? http.delete(endpoint, headers: [:], timeout: ceiling)
    }
}
