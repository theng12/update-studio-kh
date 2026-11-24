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
        /// The published size, used as the download ceiling before anything is kept.
        public var bytes: Int64?
        /// The tile's own picture and a picture of the extension working. Both are plain public
        /// addresses the page loads directly: nothing is fetched, kept or unpacked here.
        public var iconURL: URL?
        public var screenshotURL: URL?

        public init(id: String, name: String, version: String, summary: String, kind: String = "extension",
                    downloadURL: URL? = nil, sha256: String? = nil, bytes: Int64? = nil,
                    iconURL: URL? = nil, screenshotURL: URL? = nil) {
            self.id = id; self.name = name; self.version = version; self.summary = summary
            self.kind = kind; self.downloadURL = downloadURL; self.sha256 = sha256; self.bytes = bytes
            self.iconURL = iconURL; self.screenshotURL = screenshotURL
        }
    }

    /// The one published index. It is served from a fixed HTTPS path on the project's own repo, so a
    /// network attacker cannot redirect it; the per-file SHA-256 in that index is checked after the
    /// download. If it is ever re-signed with the fleet key, that envelope is verified as well.
    public static let endpoint = URL(string: "https://raw.githubusercontent.com/theng12/kh-extensions/main/extensions.json")!
    static let downloadHost = "github.com", downloadPath = "/theng12/kh-extensions/"

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
        var download: String?
        var sha256: String?
        var bytes: Int64?
        var icon: String?
        var screenshot: String?
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

        var body = data
        if let release = try? JSON.decode(Release.self, from: data),
           let signed = release.feedData, let signature = release.signatureData {
            guard let publishedKey = key ?? PinnedKey.base64 else {
                throw khuFail("no pinned publisher key: extension catalogue was not verified")
            }
            let publicKey = try Signing.loadPublicKey(base64: publishedKey)
            guard Signing.verify(signed, signature: signature, publicKey: publicKey) else {
                throw khuFail("extension catalogue signature is invalid")
            }
            body = signed
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

    /// Download one published file. Nothing is kept unless its bytes and SHA-256 match the index
    /// entry, so a truncated file or a swapped asset is refused in plain words rather than handed on.
    public static func fetch(_ entry: Entry, to file: URL, http: HTTPClient = URLSessionHTTPClient()) throws {
        guard let url = entry.downloadURL, let expected = entry.sha256 else {
            throw khuFail("\(entry.name) has no published download")
        }
        let fm = FileManager.default
        let holding = file.appendingPathExtension("part")
        try? fm.removeItem(at: holding)
        do {
            let code = try http.download(url, headers: [:], to: holding, limit: entry.bytes ?? (64 << 20))
            guard (200..<300).contains(code) else { throw khuFail("the download answered \(code)") }
            let size = ((try? fm.attributesOfItem(atPath: holding.path))?[.size] as? NSNumber)?.int64Value
            if let published = entry.bytes, size != published {
                throw khuFail("the download was \(size ?? 0) bytes, not the published \(published)")
            }
            guard let actual = try? Signing.sha256Hex(fileAt: holding).hex, actual == expected else {
                throw khuFail("the download did not match the published checksum")
            }
            try? fm.removeItem(at: file)
            try fm.moveItem(at: holding, to: file)
        } catch {
            try? fm.removeItem(at: holding)
            throw error
        }
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
        if let address = raw.download {
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
        if kind == "extension", let size = raw.bytes, size <= 0 {
            throw khuFail("extension \(id) declares an impossible size")
        }
        // A picture is a picture: it never blocks an entry, but an address that is not on the
        // project's own paths is refused by name rather than dropped silently.
        let icon = try picture(raw.icon, kind: kind, id: id, what: "icon")
        let screenshot = try picture(raw.screenshot, kind: kind, id: id, what: "screenshot")
        return Entry(id: id, name: name, version: raw.version, summary: summary, kind: kind,
                     downloadURL: url, sha256: hash, bytes: raw.bytes, iconURL: icon, screenshotURL: screenshot)
    }

    private static func text(_ raw: String, limit: Int, what: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= limit,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw khuFail("refused \(what): \(raw)")
        }
        return trimmed
    }

    private static func picture(_ raw: String?, kind: String, id: String, what: String) throws -> URL? {
        guard let raw else { return nil }
        guard let parsed = publicAssetURL(raw) else {
            throw khuFail("\(kind) \(id) \(what) address is not a public HTTPS URL on the project's own paths: \(raw)")
        }
        return parsed
    }

    /// Pictures come from the same project, from either of the two paths its files really live on:
    /// release assets on github.com, and repo files on raw.githubusercontent.com. Every rule the
    /// download address follows applies here too, so a picture can never point anywhere else.
    static func publicAssetURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= maxURLBytes, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port.map({ $0 == 443 }) ?? true, let host = url.host else { return nil }
        let lower = host.lowercased()
        let allowed: Bool
        switch lower {
        case "github.com": allowed = url.path.hasPrefix(downloadPath)
        case "raw.githubusercontent.com": allowed = url.path.hasPrefix("/theng12/kh-extensions/")
        default: allowed = false
        }
        guard allowed, FeedNetwork.isPublicHostName(host) else { return nil }
        let labels = lower.split(separator: ".")
        guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let privateSuffixes = [".local", ".internal", ".localhost", ".test", ".invalid", ".arpa", ".ts.net"]
        guard !privateSuffixes.contains(where: { lower.hasSuffix($0) }) else { return nil }
        return url
    }

    /// Downloads must come from the project's own release path, so the index cannot point the app at
    /// any other host, and the address still passes every public-URL rule below.
    private static func publicDownloadURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= maxURLBytes, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port.map({ $0 == 443 }) ?? true,
              let host = url.host, host == downloadHost, url.path.hasPrefix(downloadPath),
              FeedNetwork.isPublicHostName(host) else { return nil }
        let lower = host.lowercased()
        let labels = lower.split(separator: ".")
        guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let privateSuffixes = [".local", ".internal", ".localhost", ".test", ".invalid", ".arpa", ".ts.net"]
        guard !privateSuffixes.contains(where: { lower.hasSuffix($0) }) else { return nil }
        return url
    }
}
