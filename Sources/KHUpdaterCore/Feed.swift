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
    public var schema: Int
    public var published_at: String
    public var apps: [String: FeedApp]

    public init(schema: Int = 1, published_at: String, apps: [String: FeedApp] = [:]) {
        self.schema = schema; self.published_at = published_at; self.apps = apps
    }

    public var publishedAt: Date? { ISO.date(published_at) }
}
