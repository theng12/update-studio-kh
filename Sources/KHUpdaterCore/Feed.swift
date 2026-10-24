import Foundation

public struct FeedApp: Codable, Sendable, Equatable {
    public var version: String
    public var file: String
    public var sha256: String
    public var bytes: Int64
    public var kind: String
    public var notes: String?

    public init(version: String, file: String, sha256: String, bytes: Int64, kind: String, notes: String? = nil) {
        self.version = version; self.file = file; self.sha256 = sha256
        self.bytes = bytes; self.kind = kind; self.notes = notes
    }
}

public struct Feed: Codable, Sendable, Equatable {
    public static let supportedSchema = 1

    public var schema: Int
    public var published_at: String
    public var apps: [String: FeedApp]

    public init(schema: Int = Feed.supportedSchema, published_at: String, apps: [String: FeedApp] = [:]) {
        self.schema = schema; self.published_at = published_at; self.apps = apps
    }

    public var publishedAt: Date? { ISO.date(published_at) }

    /// A signed feed is still refused when it is not one this build understands.
    public func validated() throws -> Feed {
        guard schema == Feed.supportedSchema else { throw khuFail("feed schema \(schema) is not supported") }
        guard publishedAt != nil else { throw khuFail("feed published_at is not a date: \(published_at)") }
        for (app, entry) in apps {
            _ = try SafeName.component(app, what: "app id")
            _ = try SafeName.component(entry.file, what: "artifact name")
            guard VersionCompare.isValid(entry.version) else { throw khuFail("\(app) has an invalid version \(entry.version)") }
            guard entry.sha256.count == 64, entry.bytes > 0 else { throw khuFail("\(app) has no usable sha256/size") }
        }
        return self
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
