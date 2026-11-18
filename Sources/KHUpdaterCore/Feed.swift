import Foundation

public struct FeedApp: Codable, Sendable, Equatable {
    public var version: String
    public var file: String
    public var sha256: String
    public var bytes: Int64
    public var kind: String
    public var notes: String?
    /// Read from the app's own bundle when it is published, so the Launcher can list a new app
    /// with no code change. All optional: a feed written before they existed decodes as it did.
    public var name: String?
    public var bundleID: String?
    public var bundleName: String?
    /// A 128-point PNG of the app's icon, stored beside the artifacts, and its SHA-256.
    public var icon: String?
    public var iconSha256: String?
    /// What the Launcher's card and details show. Each is optional: a missing one shows less.
    public var tagline: String?
    public var description: String?
    public var features: [AppFeature]?
    public var accent: String?
    /// When this version was published.
    public var released: String?
    /// Shown in the Launcher only on a Mac that already has it.
    public var mainMacOnly: Bool?
    /// The optional incremental delivery for this artifact: the patch that turns the previous
    /// version's exact bytes into this one. A Mac that does not know it downloads the whole
    /// signed artifact, exactly as before.
    public var delta: ArtifactDelta?
    /// Where a running copy of this app takes an update hold (`…/api/maintenance/hold` or
    /// `…/api/maintenance/drain` on this Mac's loopback). Signed by the publisher; nil means the
    /// app has no hold endpoint, so an install over a running copy is refused rather than silent.
    public var holdURL: String?
    /// The first version published with this `holdURL`. A build older than it predates the hold, so
    /// its 401/403/404 there means "no endpoint yet", not a refused credential. nil when unknown.
    public var holdSince: String?
    /// An absolute `https` address for this artifact, used instead of `<feed base>/artifacts/<file>`.
    /// A mirror feed names its own artifact addresses; the whole envelope is signed, so this is
    /// covered by the publisher's signature. nil keeps the old relative behaviour exactly.
    public var url: String?

    /// Where this artifact is fetched from: its own signed address when it names one, else beside
    /// the feed it came from.
    public func location(beside base: URL) -> URL {
        url.flatMap(URL.init(string:)) ?? base.appendingPathComponent("artifacts").appendingPathComponent(file)
    }

    public init(version: String, file: String, sha256: String, bytes: Int64, kind: String, notes: String? = nil) {
        self.version = version; self.file = file; self.sha256 = sha256
        self.bytes = bytes; self.kind = kind; self.notes = notes
    }
}

/// One numbered feature in the Launcher's details panel.
public struct AppFeature: Codable, Sendable, Equatable {
    public var title: String
    public var text: String?
    public init(title: String, text: String? = nil) { self.title = title; self.text = text }
}

/// The words an app's card and details show, carried by the feed and an SSD's apps.json alike.
public struct AppWords: Codable, Sendable, Equatable {
    public var tagline: String?
    public var description: String?
    public var features: [AppFeature]?
    public var accent: String?
    public init(tagline: String? = nil, description: String? = nil, features: [AppFeature]? = nil, accent: String? = nil) {
        self.tagline = tagline; self.description = description; self.features = features; self.accent = accent
    }
    public var isEmpty: Bool { tagline == nil && description == nil && features == nil && accent == nil }
}

public struct Feed: Codable, Sendable, Equatable {
    public static let supportedSchema = 1

    public var schema: Int
    public var published_at: String
    public var apps: [String: FeedApp]
    /// Signed fallback pins for distributors; older clients keep reading only `apps`.
    public var previous: [String: FeedApp]?
    public var network: FeedNetwork?

    public init(schema: Int = Feed.supportedSchema, published_at: String, apps: [String: FeedApp] = [:]) {
        self.schema = schema; self.published_at = published_at; self.apps = apps
    }

    public var publishedAt: Date? { ISO.date(published_at) }

    /// What this feed actually offers, one sorted line per artifact in `apps` and `previous`. Two
    /// feeds naming the same artifacts are equivalent whatever their URLs or `network` block say —
    /// which is what a mirror feed is — while a different artifact at the same `published_at` is not.
    public var artifactIdentity: String {
        func lines(_ entries: [String: FeedApp], _ mark: String) -> [String] {
            entries.map { mark + $0.key + "|" + $0.value.version + "|" + $0.value.sha256 + "|" + String($0.value.bytes) }.sorted()
        }
        return (lines(apps, "app:") + lines(previous ?? [:], "previous:")).joined(separator: "\n")
    }

    /// An entry's optional absolute artifact address, refused unless it is a plain `https` URL with
    /// no sign-in detail: an `http` address, a relative one, `file:` or embedded credentials would
    /// all let a signed feed fetch bytes from somewhere a client never agreed to.
    public static func artifactURL(_ text: String, app: String) throws -> URL {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw khuFail("\(app)'s artifact address must be an absolute https URL with no sign-in detail, not \(text)")
        }
        return url
    }

    /// A signed feed is still refused when it is not one this build understands.
    public func validated() throws -> Feed {
        guard schema == Feed.supportedSchema else { throw khuFail("feed schema \(schema) is not supported") }
        guard publishedAt != nil else { throw khuFail("feed published_at is not a date: \(published_at)") }
        _ = try network?.validated()
        var result = self
        func validate(_ app: String, _ entry: inout FeedApp) throws {
            _ = try SafeName.component(app, what: "app id")
            _ = try SafeName.component(entry.file, what: "artifact name")
            guard VersionCompare.isValid(entry.version) else { throw khuFail("\(app) has an invalid version \(entry.version)") }
            guard entry.sha256.count == 64, entry.bytes > 0 else { throw khuFail("\(app) has no usable sha256/size") }
            if let url = entry.url {
                _ = try Feed.artifactURL(url, app: app)
            }
            // Optional delivery must never block the independently signed full installer.
            if let delta = entry.delta,
               (try? delta.validated()) == nil || delta.file == entry.file || delta.bytes >= entry.bytes {
                entry.delta = nil
            }
            // An endpoint that is not this Mac's loopback hold path is no endpoint: the app is then
            // "unsupported" and a running install over it is refused, never silently interrupted.
            if let holdURL = entry.holdURL, UpdateHold.trusted(holdURL) == nil { entry.holdURL = nil }
            if entry.holdURL == nil || !VersionCompare.isValid(entry.holdSince ?? "") { entry.holdSince = nil }
        }
        for (app, var entry) in apps {
            try validate(app, &entry)
            result.apps[app] = entry
        }
        for (app, var entry) in previous ?? [:] {
            try validate(app, &entry)
            guard let current = apps[app], VersionCompare.isNewer(current.version, than: entry.version),
                  current.file != entry.file else {
                throw khuFail("\(app) previous installer must be older than its current version")
            }
            result.previous?[app] = entry
        }
        return result
    }
}

/// The feed and its signature as ONE file, written in one rename: a reader can never see a new
/// feed with an old signature (or the reverse), and the agent fetches both in one request.
public struct Release: Codable, Sendable, Equatable {
    public var feed: String       // base64 of the exact signed bytes
    public var signature: String  // base64 Ed25519 signature over those bytes

    public init(feed: Data, signature: Data) {
        self.feed = feed.base64EncodedString(); self.signature = signature.base64EncodedString()
    }

    public var feedData: Data? { Data(base64Encoded: feed) }
    public var signatureData: Data? { Data(base64Encoded: signature) }
}

/// The publisher's answer to `GET /commands` and its signature in ONE body, the same way the feed
/// travels: orders and status cross the tailnet as plain text, so the reply is signed with the key
/// every agent is pinned to and carries this Mac's id and the moment it was made. The agent refuses
/// one it cannot verify, one for another Mac, and one that is not fresh.
public struct SignedReply: Codable, Sendable, Equatable {
    public var reply: String      // base64 of the exact signed bytes
    public var signature: String  // base64 Ed25519 signature over those bytes

    public init(reply: Data, signature: Data) {
        self.reply = reply.base64EncodedString(); self.signature = signature.base64EncodedString()
    }

    public var replyData: Data? { Data(base64Encoded: reply) }
    public var signatureData: Data? { Data(base64Encoded: signature) }
}

/// What `POST /enrol` answers with, inside `SignedReply`: the fields the Mac needs to write its own
/// config, plus a fresh token. It names this Mac and echoes the nonce the Mac sent, so a reply
/// meant for another Mac, or one replayed at a hardening window that asked a different question, is
/// refused by the Mac. `issuedAt` is unix seconds, the unit the Mac compares against its own clock.
///
/// The Mac writes `feedURL`, `publicKey`, `machine` and `token` into its config and checks that the
/// first two are what its kit's publisher.json says; anything else in this reply is ignored.
public struct EnrolReply: Codable, Sendable, Equatable {
    public var machine: String
    public var nonce: String
    public var feedURL: String
    public var publicKey: String
    public var issuedAt: Int
    public var token: String

    public init(machine: String, nonce: String, feedURL: String, publicKey: String, issuedAt: Int, token: String) {
        self.machine = machine; self.nonce = nonce; self.feedURL = feedURL
        self.publicKey = publicKey; self.issuedAt = issuedAt; self.token = token
    }
}
