import Foundation

/// `gh api` as the reader the generator uses. One process per call, no daemon.
public struct GhReader: GitHubReader {
    public init() {}
    public func json(_ path: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "api", path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw khuFail("cannot run gh: \(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let said = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw khuFail("gh api \(path) failed: \(said.isEmpty ? "exit \(process.terminationStatus)" : said)")
        }
        return data
    }
}

/// Publishing the generated feed: the exact signed bytes go into the public repo, are read back
/// from both the commit and the public address, and one asset is downloaded and hash-matched, so
/// "published" is a measurement rather than an intention.
public enum FeedPages {
    /// Commit `envelope` as `release.json` (only when the bytes differ), then prove it.
    public static func publish(_ envelope: Data, repo: String, pagesURL: URL? = nil,
                               wait: TimeInterval = 180, http: HTTPClient = URLSessionHTTPClient()) throws {
        var blobSHA: String?
        var same = false
        if let held = try? GhReader().json("repos/\(repo)/contents/release.json"),
           let object = try? JSONSerialization.jsonObject(with: held) as? [String: Any] {
            let content = (object["content"] as? String).map { $0.filter { !$0.isWhitespace } }
                .flatMap { Data(base64Encoded: $0) }
            same = content == envelope
            blobSHA = object["sha"] as? String
        }
        if same {
            print("feed: \(repo)/release.json already holds these exact bytes; no commit made")
        } else {
            try put(envelope, repo: repo, blobSHA: blobSHA)
            let back = try GhReader().json("repos/\(repo)/contents/release.json")
            guard let object = try? JSONSerialization.jsonObject(with: back) as? [String: Any],
                  let content = (object["content"] as? String).map({ $0.filter { !$0.isWhitespace } })
                    .flatMap({ Data(base64Encoded: $0) }), content == envelope else {
                throw khuFail("the committed release.json is not the bytes that were signed")
            }
            print("feed: committed sha256 \(Signing.sha256Hex(envelope)) to \(repo)")
        }
        let pages = pagesURL ?? URL(string: "https://\(repo.split(separator: "/").first ?? "").github.io/\(repo.split(separator: "/").last ?? "")/release.json")!
        // The page proves the publish, not the commit: bounded, and the expiry sentence names the
        // URL, the bytes expected and the bytes still served.
        let deadline = Date().addingTimeInterval(wait)
        var served = "nothing (no answer)"
        while Date() < deadline {
            if let (data, code) = try? http.get(pages, headers: [:]) {
                if code == 200, data == envelope {
                    print("feed: \(pages.absoluteString) serves the exact signed bytes")
                    // The commit and this readback already proved the feed. A probe that cannot
                    // fetch one asset is a missing piece of evidence, not a failed publish
                    // (row 20261125-37: one transient 5xx failed two published passes).
                    if let incomplete = verifyOneAsset(envelope: envelope, http: http) {
                        print("published; probe incomplete: \(incomplete)")
                    }
                    return
                }
                served = code == 200 ? "sha256 \(Signing.sha256Hex(data))" : "HTTP \(code)"
            }
            Thread.sleep(forTimeInterval: 5)
        }
        throw khuFail("\(pages.absoluteString) does not serve the signed bytes within \(Int(wait))s "
                      + "(expected sha256 \(Signing.sha256Hex(envelope)); it still serves \(served)). "
                      + "The commit was made; re-run the readback when Pages has built.")
    }

    /// Downloads one asset the feed names and matches its sha256 and size against the row.
    /// Returns nil when it matched, or `<app> (<reason>)` when the check could not be completed;
    /// it retries with bounded backoff first, because one transient 5xx on the alphabetically first
    /// asset used to condemn a feed whose signed bytes were already served (row 20261125-37).
    static func verifyOneAsset(envelope: Data, http: HTTPClient, attempts: Int = 3,
                               pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let encoded = object["feed"] as? String, let feedData = Data(base64Encoded: encoded),
              let feed = try? JSON.decode(Feed.self, from: feedData),
              let (app, row) = feed.apps.sorted(by: { $0.key < $1.key }).first else {
            return "the feed names no app to verify"
        }
        guard let url = row.url.flatMap(URL.init(string:)) else {
            return "\(app) names no absolute address to verify"
        }
        var reason = "did not answer"
        for attempt in 1...max(1, attempts) {
            if let (data, code) = try? http.get(url, headers: [:]), code == 200 {
                if data.count == Int(row.bytes), Signing.sha256Hex(data) == row.sha256 {
                    print("feed: \(app) \(row.version) asset matches its signed sha256 \(row.sha256.prefix(12))…")
                    return nil
                }
                reason = "does not match the row's sha256/size (\(data.count) bytes, sha256 \(Signing.sha256Hex(data).prefix(12))…)"
            }
            if attempt < attempts { pause(TimeInterval(attempt * 2)) }
        }
        return "\(app) (\(reason))"
    }

    /// The address a feed commit carries. Neutral by default, so no pass ever attributes public
    /// feed history to a personal account by forgetting to export a variable; the environment
    /// stays as an override for a pass that must say something else (S001, 2026-11-25).
    static func commitEmail(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let given = (environment["KH_FEED_COMMIT_EMAIL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return given.isEmpty ? "kh-studio@invalid" : given
    }

    private static func put(_ envelope: Data, repo: String, blobSHA: String?) throws {
        // The address is supplied by the machine that publishes, never compiled into the app: a
        // personal address written into the source ships inside every copy (measured 2026-11-25,
        // Launcher 0.1.82). It is neutral unless the pass names one.
        let email = commitEmail()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["gh", "api", "-X", "PUT", "repos/\(repo)/contents/release.json",
                         "-f", "message=release.json: generated from the app repos",
                         "-f", "content=\(envelope.base64EncodedString())", "-f", "branch=main",
                         "-f", "committer[name]=KH Studio",
                         "-f", "committer[email]=\(email)",
                         "-f", "author[name]=KH Studio",
                         "-f", "author[email]=\(email)"]
        if let blobSHA { arguments += ["-f", "sha=\(blobSHA)"] }
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw khuFail("cannot run gh: \(error)") }
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw khuFail("committing release.json to \(repo) failed: \(said.isEmpty ? "exit \(process.terminationStatus)" : said)")
        }
    }
}
