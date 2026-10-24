import Foundation
import CryptoKit

public struct AgentRunResult: Sendable, Equatable {
    public var statusPosted: Bool
    public var commandsRun: Int
    public var updates: Int
    public var restartRequested = false
    public init(statusPosted: Bool = false, commandsRun: Int = 0, updates: Int = 0) {
        self.statusPosted = statusPosted; self.commandsRun = commandsRun; self.updates = updates
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int)
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        var req = URLRequest(url: url); req.httpMethod = "GET"
        for (k,v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int, Error?) = (Data(), 0, nil)
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            result = (data ?? Data(), code, err)
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let e = result.2 { throw e }
        return (result.0, result.1)
    }
    public func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = body
        for (k,v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int, Error?) = (Data(), 0, nil)
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            result = (data ?? Data(), code, err)
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let e = result.2 { throw e }
        return (result.0, result.1)
    }
}

public enum Agent {
    /// Recipes that never install from KH Updater in v1: those apps keep their own updaters, which
    /// let running work finish first.
    static let statusOnly: Set<String> = ["story", "hub", "status"]

    static func get(_ http: HTTPClient, _ url: URL, headers: [String: String] = [:]) throws -> Data {
        let (data, code) = try http.get(url, headers: headers)
        guard code == 200 else { throw khuFail("GET \(url.path) answered \(code)") }
        return data
    }

    public static func runOnce(config: AgentConfig, http: HTTPClient = URLSessionHTTPClient(), shell: Shell = SystemShell()) throws -> AgentRunResult {
        guard let feedURL = URL(string: config.feedURL) else { throw khuFail("feedURL is not a URL") }
        let serverBase = feedURL.deletingLastPathComponent()
        let feedData = try get(http, feedURL)
        let sigData = try get(http, serverBase.appendingPathComponent("feed.json.sig"))
        let pub = try Signing.loadPublicKey(base64: config.publicKey)
        guard Signing.verify(feedData, signature: sigData, publicKey: pub) else { throw khuFail("invalid feed signature") }
        let feed = try JSON.decode(Feed.self, from: feedData)

        let stateDir = URL(fileURLWithPath: config.stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let seenFile = stateDir.appendingPathComponent("highest_published_at.txt")
        let seen = (try? String(contentsOf: seenFile, encoding: .utf8)) ?? ""
        if let d1 = ISO.date(seen), let d2 = feed.publishedAt, d2 < d1 {
            throw khuFail("feed rollback refused: published_at is older than one already seen")
        }
        if let d2 = feed.publishedAt { try AtomicFile.write(Data(ISO.string(d2).utf8), to: seenFile) }

        var installed: [String: String] = [:]
        var health: [String: String] = [:]
        for (app, cfg) in config.apps {
            let plist = URL(fileURLWithPath: cfg.bundlePath).appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let v = dict["CFBundleShortVersionString"] as? String {
                installed[app] = v
                health[app] = LiveControl.running(cfg.bundlePath, shell: shell) ? "running" : "not running"
            } else {
                health[app] = cfg.recipe == "updater" ? "running" : "not installed"
            }
        }
        if let stubVersion = config.updaterVersion { installed["updater"] = stubVersion; health["updater"] = "running" }

        let headers = ["Authorization": "Bearer \(config.token)"]
        let statusBody = try JSONSerialization.data(withJSONObject: ["machine": config.machine, "installed": installed, "health": health])
        let (_, statusCode) = try http.post(serverBase.appendingPathComponent("status"), headers: headers, body: statusBody)
        guard statusCode == 200 else { throw khuFail("status was refused (\(statusCode))") }
        var result = AgentRunResult(statusPosted: true)

        let reply = try get(http, serverBase.appendingPathComponent("commands").appendingQuery("machine", config.machine), headers: headers)
        let orders = (try? JSONDecoder().decode(CommandsReply.self, from: reply))
            ?? CommandsReply(commands: (try? JSONDecoder().decode([ServerCommand].self, from: reply)) ?? [], automatic: [:])

        var todo: [(app: String, id: String?)] = orders.commands.map { ($0.app, $0.id) }
        for (app, cfg) in config.apps where (orders.automatic[app] ?? cfg.automatic) && !statusOnly.contains(cfg.recipe) {
            guard !todo.contains(where: { $0.app == app }), let fv = feed.apps[app]?.version else { continue }
            if installed[app].map({ VersionCompare.isNewer(fv, than: $0) }) ?? true { todo.append((app, nil)) }
        }

        // One install at a time; a failure is reported and the next app still runs.
        for (app, commandID) in todo {
            let res: RecipeResult
            do { res = try install(app: app, feed: feed, config: config, serverBase: serverBase, stateDir: stateDir, http: http, shell: shell, result: &result) }
            catch { res = RecipeResult(status: "failed", reason: "\(error)") }
            let body = try JSONSerialization.data(withJSONObject: ["machine": config.machine, "app": app, "status": res.status, "reason": res.reason ?? ""])
            _ = try? http.post(serverBase.appendingPathComponent("commands").appendingPathComponent(commandID ?? "auto-\(app)-\(UUID().uuidString)").appendingPathComponent("result"), headers: headers, body: body)
            result.commandsRun += 1
            if ["updated", "switched"].contains(res.status) { result.updates += 1 }
            if res.status == "switched" { result.restartRequested = true; break }
        }
        return result
    }

    static func install(app: String, feed: Feed, config: AgentConfig, serverBase: URL, stateDir: URL,
                        http: HTTPClient, shell: Shell, result: inout AgentRunResult) throws -> RecipeResult {
        guard let cfg = config.apps[app] else { throw khuFail("\(app) is not configured on this Mac") }
        if statusOnly.contains(cfg.recipe) { return RecipeResult(status: "status_only", reason: "updated by its own updater") }
        guard let entry = feed.apps[app] else { throw khuFail("the feed has no \(app)") }
        _ = try SafeName.component(entry.file, what: "artifact name")
        let data = try get(http, serverBase.appendingPathComponent("artifacts").appendingPathComponent(entry.file))
        guard Int64(data.count) == entry.bytes else { throw khuFail("artifact size mismatch; nothing was changed") }
        guard Signing.sha256Hex(data) == entry.sha256 else { throw khuFail("artifact sha256 mismatch; nothing was changed") }
        let work = stateDir.appendingPathComponent("downloads").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let artifact = work.appendingPathComponent(entry.file)
        try data.write(to: artifact)
        let trash = stateDir.appendingPathComponent("_trash").path
        let rollback = stateDir.appendingPathComponent("rollback-\(app)").path
        switch cfg.recipe {
        case "app-dmg":
            return try Recipe.appDmg(shell: shell, installedPath: cfg.bundlePath, artifactPath: artifact.path, feedVersion: entry.version,
                                     rollbackDir: rollback, trashDir: trash, control: LiveControl.appDmg(cfg.bundlePath, feedVersion: entry.version, shell: shell))
        case "gateway":
            return try Recipe.appDmg(shell: shell, installedPath: cfg.bundlePath, artifactPath: artifact.path, feedVersion: entry.version,
                                     rollbackDir: rollback, trashDir: trash, control: LiveControl.gateway(cfg.bundlePath, feedVersion: entry.version, shell: shell))
        case "updater":
            guard let base = config.stubBase else { throw khuFail("no stub layout is configured on this Mac") }
            let layout = StubLayout(base: URL(fileURLWithPath: base))
            let binary = try layout.binary(for: entry.version)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: binary.path) { try Trash.move(binary, into: layout.base.appendingPathComponent("_trash")) }
            try FileManager.default.copyItem(at: artifact, to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try StubSwitcher(layout: layout).install(version: entry.version)
            return RecipeResult(status: "switched", reason: "the stub starts \(entry.version) next and rolls back if it misbehaves")
        case "fake-for-tests":
            return RecipeResult(status: "updated")
        default:
            throw khuFail("unknown recipe \(cfg.recipe)")
        }
    }
}

public struct CommandsReply: Codable, Sendable, Equatable {
    public var commands: [ServerCommand]
    public var automatic: [String: Bool]
}

extension URL {
    func appendingQuery(_ name: String, _ value: String) -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? self
    }
}
