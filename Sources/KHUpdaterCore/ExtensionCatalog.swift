import Foundation

/// A catalogue of optional extensions offered beside the public feed. It is read on demand and
/// returns addresses only: nothing here downloads, installs or registers an extension. The caller
/// hands `downloadURL` to the native browser. The whole list is signed by the fleet key inside the
/// same `Release` envelope as the feed, so a changed address or name is a changed signed document.
public enum ExtensionCatalog {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var name: String
        public var version: String
        public var summary: String
        /// A public HTTPS address for the browser, never for `HTTPClient.download`.
        /// The house category this row belongs to: `extension` or `plugin`. Never an app.
        public var kind: String
        /// Present only when a public download exists; a plugin may have none yet.
        public var downloadURL: URL?
        public var sha256: String?

        public init(id: String, name: String, version: String, summary: String, kind: String = "extension",
                    downloadURL: URL? = nil, sha256: String? = nil) {
            self.id = id; self.name = name; self.version = version; self.summary = summary
            self.kind = kind; self.downloadURL = downloadURL; self.sha256 = sha256
        }
    }

    /// `extensions.json` beside the public `release.json`, read anonymously.
    public static let endpoint: URL =
        URL(string: Connect.publicFeedURL)!.deletingLastPathComponent().appendingPathComponent("extensions.json")

    private static let maxResponseBytes = 256 << 10
    private static let maxEntries = 64
    private static let maxIDBytes = 64
    private static let maxNameBytes = 120
    private static let maxSummaryBytes = 280
    private static let maxURLBytes = 2_048

    private struct Wire: Decodable { var extensions: [WireEntry] }
    private struct WireEntry: Decodable {
        var id: String
        var name: String
        var version: String
        var summary: String
        var kind: String?
        var downloadURL: String?
        var sha256: String?
    }

    /// Nil means no catalogue is published (404/410); an empty array is a signed empty catalogue.
    /// Anything else — a network error, a bad status, a signature that does not verify, or an
    /// invalid entry — throws. `key` and `http` exist so tests can use their own fixture signer and
    /// a recorded HTTP client; production uses the pinned key and an ordinary bounded GET.
    public static func load(http: HTTPClient = URLSessionHTTPClient(), key: String? = nil) throws -> [Entry]? {
        let (data, code) = try http.get(endpoint, headers: [:])
        if code == 404 || code == 410 { return nil }
        if code == 204 || code == 205 { return nil }
        guard (200..<300).contains(code) else {
            throw khuFail("extension catalogue at \(endpoint.absoluteString) answered \(code)")
        }
        guard !data.isEmpty, data.count <= maxResponseBytes else {
            throw khuFail("extension catalogue is empty or larger than \(maxResponseBytes) bytes")
        }

        let release = try JSON.decode(Release.self, from: data)
        guard let body = release.feedData, let signature = release.signatureData else {
            throw khuFail("extension catalogue has no signed bytes or signature")
        }
        guard let publishedKey = key ?? PinnedKey.base64 else {
            throw khuFail("no pinned publisher key: extension catalogue was not verified")
        }
        let publicKey = try Signing.loadPublicKey(base64: publishedKey)
        guard Signing.verify(body, signature: signature, publicKey: publicKey) else {
            throw khuFail("extension catalogue signature is invalid")
        }

        let wire = try JSON.decode(Wire.self, from: body)
        guard wire.extensions.count <= maxEntries else {
            throw khuFail("extension catalogue has more than \(maxEntries) entries")
        }
        var entries: [Entry] = []
        var ids: Set<String> = []
        for raw in wire.extensions {
            let entry = try validate(raw)
            guard ids.insert(entry.id).inserted else { throw khuFail("duplicate extension id \(entry.id)") }
            entries.append(entry)
        }
        return entries
    }

    private static func validate(_ raw: WireEntry) throws -> Entry {
        let id = raw.id
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789._-"
        guard !id.isEmpty, id.utf8.count <= maxIDBytes, id == id.lowercased(),
              !id.hasPrefix("."), !id.hasPrefix("-"),
              id.unicodeScalars.allSatisfy({ allowed.unicodeScalars.contains($0) }) else {
            throw khuFail("refused unsafe extension id: \(id)")
        }
        let name = try text(raw.name, limit: maxNameBytes, what: "extension name")
        let summary = try text(raw.summary, limit: maxSummaryBytes, what: "extension summary")
        guard VersionCompare.isValid(raw.version) else { throw khuFail("invalid extension version \(raw.version)") }
        let kind = raw.kind ?? "extension"
        guard kind == "extension" || kind == "plugin" else {
            throw khuFail("refused category \(kind) for \(id): only extension or plugin")
        }
        var url: URL?
        if let address = raw.downloadURL {
            guard let parsed = publicDownloadURL(address) else {
                throw khuFail("\(kind) \(id) download address is not a public HTTPS URL: \(address)")
            }
            url = parsed
        }
        var hash: String?
        if let rawHash = raw.sha256 {
            let lower = rawHash.lowercased()
            guard lower.utf8.count == 64, lower.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw khuFail("\(kind) \(id) has no usable sha256") }
            hash = lower
        }
        // A Chrome extension is installable only from a published file; a plugin may simply be
        // listed until its distribution exists, so only an extension demands both.
        if kind == "extension", url == nil || hash == nil {
            throw khuFail("extension \(id) needs a public download address and sha256")
        }
        return Entry(id: id, name: name, version: raw.version, summary: summary, kind: kind, downloadURL: url, sha256: hash)
    }

    private static func text(_ raw: String, limit: Int, what: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= limit,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw khuFail("refused \(what): \(raw)")
        }
        return trimmed
    }

    /// No credentials, no private names or address literals, no odd port: this is an address a
    /// person may open in their browser, not a shortcut to a service on the sender's network.
    private static func publicDownloadURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= maxURLBytes, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port.map({ $0 == 443 }) ?? true,
              let host = url.host, FeedNetwork.isPublicHostName(host) else { return nil }
        let lower = host.lowercased()
        let labels = lower.split(separator: ".")
        guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let privateSuffixes = [".local", ".internal", ".localhost", ".test", ".invalid", ".arpa", ".ts.net"]
        guard !privateSuffixes.contains(where: { lower.hasSuffix($0) }) else { return nil }
        return url
    }
}
