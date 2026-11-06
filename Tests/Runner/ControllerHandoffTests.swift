import Foundation
import CryptoKit

private final class HandoffHTTP: HTTPClient, @unchecked Sendable {
    var release: Data
    var reply: Data
    var commandStatus = 200
    var requests: [(URL, Bool)] = []
    var posts: [String] = []
    var events: [String] = []
    var artifact: Data?
    var duringProbe: (() throws -> Void)?
    init(release: Data, reply: Data) { self.release = release; self.reply = reply }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        requests.append((url, headers["Authorization"] != nil))
        events.append("GET \(url.host ?? "")\(url.path)")
        if url.path == "/release.json" { return (release, 200) }
        if url.path == "/commands" { try duringProbe?(); return (reply, commandStatus) }
        throw khuFail("unexpected handoff fixture request")
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        posts.append(url.path)
        events.append("POST \(url.host ?? "")\(url.path)")
        guard url.path == "/status" || (artifact != nil && url.path.hasPrefix("/automatic/") && url.path.hasSuffix("/result")) else {
            throw khuFail("handoff must not enrol or dispatch")
        }
        return (Data(), 200)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        guard let artifact else { throw khuFail("handoff must not download an installer") }
        events.append("DOWNLOAD \(url.host ?? "")\(url.path)")
        try artifact.write(to: file)
        return 200
    }
}
private struct HandoffShell: Shell {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

func controllerHandoffTests() {
    let root = tmpDir("controller-handoff")
    let file = root.appendingPathComponent("config.json")
    let key = Curve25519.Signing.PrivateKey()
    let old = "http://100.64.0.1:8790/release.json"
    let next = "http://100.64.0.2:8790/release.json"
    let now = Date()
    let config = AgentConfig(feedURL: old, publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
        stateDir: root.appendingPathComponent("state").path, machine: "handoff-mac", token: "fixture-sign-in")
    func save(_ value: AgentConfig = config) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSON.encode(value)) as! [String: Any]
        object["owner_extra"] = ["keep": true]
        let raw = try JSONSerialization.data(withJSONObject: object)
        try AtomicFile.write(raw, to: file, permissions: 0o600)
        return raw
    }
    func signed(_ move: ControllerHandoff?, apps: [String: FeedApp] = [:], at: Date = now, signer: Curve25519.Signing.PrivateKey = key) throws -> Data {
        var feed = Feed(published_at: ISO.string(at), apps: apps)
        feed.network = FeedNetwork(controller: move)
        let body = JSON.encode(feed)
        return JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: signer)))
    }
    func reply(machine: String = config.machine, at: Date = now, signer: Curve25519.Signing.PrivateKey = key) throws -> Data {
        let body = JSON.encode(CommandsReply(machine: machine, at: ISO.string(at), commands: [], automatic: [:]))
        return JSON.encode(SignedReply(reply: body, signature: try Signing.sign(body, with: signer)))
    }
    let move = ControllerHandoff(from: old, to: next)
    var request = URLRequest(url: URL(string: old)!)
    request.setValue("fixture-token", forHTTPHeaderField: "Authorization")
    expect(!URLSessionHTTPClient.allowsRedirect(original: request, destination: URL(string: next)!, officialHosts: nil),
           "CH0 credentials cannot follow a redirect to another controller")
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    expect(URLSessionHTTPClient.allowsRedirect(original: request, destination: URL(string: next)!, officialHosts: nil),
           "CH0 public feed redirects retain existing behavior")
    expect(!URLSessionHTTPClient.allowsRedirect(original: request, destination: URL(string: next)!, officialHosts: ["vendor.example"]),
           "CH0 vendor redirect restrictions remain in force")
    do {
        let original = try save()
        let release = try signed(nil)
        let http = HandoffHTTP(release: release, reply: try reply())
        let moved = try Agent.followControllerHandoff(release: release, config: config, memory: AgentMemory(), file: file, http: http, now: now)
        let unchanged = try Data(contentsOf: file) == original
        expect(!moved && http.requests.isEmpty && unchanged,
               "CH1 legacy feed never changes the controller")
    } catch { expect(false, "CH1 legacy: \(error)") }
    do {
        let original = try save()
        let release = try signed(move)
        let http = HandoffHTTP(release: release, reply: try reply())
        let moved = try Agent.followControllerHandoff(release: release, config: config, memory: AgentMemory(), file: file, http: http, now: now)
        let saved = try JSON.decode(AgentConfig.self, from: Data(contentsOf: file))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        expect(moved && saved.feedURL == next && saved.token == config.token && saved.publicKey == config.publicKey
            && saved.machine == config.machine && saved.apps == config.apps && saved.stateDir == config.stateDir,
               "CH2 signed handoff preserves enrolment and app settings")
        expect((object["owner_extra"] as? [String: Bool])?["keep"] == true, "CH2 unknown owner settings survive")
        expect(http.requests.count == 2 && !http.requests[0].1 && http.requests[1].1 && http.posts.isEmpty,
               "CH2 exact public feed precedes authenticated probe without re-enrolment")
        let backups = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("_trash"), includingPropertiesForKeys: nil)) ?? []
        let backup = backups.first { $0.lastPathComponent.hasPrefix("controller-handoff-") }?.appendingPathComponent("config.json")
        let backupData = backup.flatMap { try? Data(contentsOf: $0) }
        expect(backupData == original, "CH2 original connection has a restorable rollback copy")
        let mode = backup.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber }
        expect(mode?.intValue == 0o600, "CH2 rollback connection remains private")
        let again = try Agent.followControllerHandoff(release: release, config: saved, memory: AgentMemory(), file: file, http: http, now: now)
        expect(!again && http.requests.count == 2, "CH2 moved clients do not bounce back or repeat the handoff")
        let reversed = try signed(ControllerHandoff(from: next, to: old), at: now.addingTimeInterval(1))
        let rollback = HandoffHTTP(release: reversed, reply: try reply(at: now.addingTimeInterval(1)))
        let restored = try Agent.followControllerHandoff(release: reversed, config: saved, memory: AgentMemory(), file: file,
                                                        http: rollback, now: now.addingTimeInterval(1))
        let back = try JSON.decode(AgentConfig.self, from: Data(contentsOf: file))
        expect(restored && back.feedURL == old && back.token == config.token, "CH2 a newer signed reverse handoff restores the connection")
    } catch { expect(false, "CH2 move: \(error)") }
    do {
        let original = try save()
        let release = try signed(move)
        let http = HandoffHTTP(release: Data("different endpoint bytes".utf8), reply: try reply())
        expectThrows("CH3 different target feed blocks credentials and migration", contains: "same signed handoff") {
            _ = try Agent.followControllerHandoff(release: release, config: config, memory: AgentMemory(), file: file, http: http, now: now)
        }
        let unchanged = try Data(contentsOf: file) == original
        expect(http.requests.count == 1 && !http.requests[0].1 && unchanged,
               "CH3 unconfirmed target gets no token and changes no config")
        let untrusted = try signed(move, signer: Curve25519.Signing.PrivateKey())
        http.requests = []
        expectThrows("CH3 unsigned or differently signed handoff is refused", contains: "signature") {
            _ = try Agent.followControllerHandoff(release: untrusted, config: config, memory: AgentMemory(), file: file, http: http, now: now)
        }
        expect(http.requests.isEmpty, "CH3 invalid source never contacts a target")
        var memory = AgentMemory(); memory.feedPublishedAt = ISO.string(now.addingTimeInterval(5))
        expectThrows("CH3 stale handoff cannot roll the controller back", contains: "rollback") {
            _ = try Agent.followControllerHandoff(release: release, config: config, memory: memory, file: file, http: http, now: now)
        }
    } catch { expect(false, "CH3 trust: \(error)") }
    do {
        let release = try signed(move)
        let failures: [(Data, Int, String)] = [(try reply(), 401, "sign-in (HTTP 401)"),
            (try reply(machine: "wrong-mac"), 200, "names"),
            (try reply(signer: Curve25519.Signing.PrivateKey()), 200, "pinned key"),
            (try reply(at: now.addingTimeInterval(-7200)), 200, "fresh")]
        for (data, status, reason) in failures {
            let original = try save()
            let http = HandoffHTTP(release: release, reply: data); http.commandStatus = status
            expectThrows("CH4 target probe rejects \(reason)", contains: reason) {
                _ = try Agent.followControllerHandoff(release: release, config: config, memory: AgentMemory(), file: file, http: http, now: now)
            }
            expect(try Data(contentsOf: file) == original, "CH4 refused target leaves the saved connection intact")
        }
        _ = try save()
        let http = HandoffHTTP(release: release, reply: try reply())
        var changed = config; changed.token = "new-local-sign-in"
        let replacement = JSON.encode(changed)
        http.duringProbe = { try AtomicFile.write(replacement, to: file, permissions: 0o600) }
        expectThrows("CH4 concurrent local changes are never overwritten", contains: "settings changed") {
            _ = try Agent.followControllerHandoff(release: release, config: config, memory: AgentMemory(), file: file, http: http, now: now)
        }
        expect(try Data(contentsOf: file) == replacement, "CH4 concurrent sign-in survives")
    } catch { expect(false, "CH4 probe: \(error)") }
    for target in [old, "https://100.64.0.2/release.json", "http://evil.example/release.json", "http://100.64.0.2/release.json?token=x"] {
        expectThrows("CH5 unsafe or self handoff is refused", contains: target == old ? "different" : "feed address") {
            _ = try ControllerHandoff(from: old, to: target).validated()
        }
    }
    do {
        var local = config
        local.stateDir = root.appendingPathComponent("integration-state").path
        local.apps = ["fixture": AppConfig(bundlePath: root.appendingPathComponent("missing.app").path, recipe: "fake-for-tests", automatic: true)]
        _ = try save(local)
        let bytes = Data("CH6 verified fixture install".utf8)
        let entry = FeedApp(version: "1.0.0", file: "fixture.bin", sha256: Signing.sha256Hex(bytes), bytes: Int64(bytes.count), kind: "app-dmg")
        let release = try signed(move, apps: ["fixture": entry])
        let http = HandoffHTTP(release: release, reply: try reply()); http.artifact = bytes
        let result = try Agent.runOnce(config: local, http: http, shell: HandoffShell(), now: now,
                                       appFolders: [], connectionFile: file)
        let saved = try JSON.decode(AgentConfig.self, from: Data(contentsOf: file))
        expect(result.statusPosted && result.updates == 1 && saved.feedURL == next && result.notes.contains { $0.contains("controller connection moved") },
               "CH6 production run follows handoff after completing the old controller work")
        let status = http.events.firstIndex(of: "POST 100.64.0.1/status")
        let download = http.events.firstIndex { $0.hasPrefix("DOWNLOAD 100.64.0.1/") }
        let completed = http.events.firstIndex { $0.hasPrefix("POST 100.64.0.1/automatic/") }
        let destination = http.events.firstIndex(of: "GET 100.64.0.2/release.json")
        let probe = http.events.firstIndex(of: "GET 100.64.0.2/commands")
        if let status, let download, let completed, let destination, let probe {
            expect(status < download && download < completed && completed < destination && destination < probe,
                   "CH6 handoff waits for status, install and result acknowledgement in exact order")
        } else { expect(false, "CH6 handoff waits for status, install and result acknowledgement in exact order") }
        expect(!http.posts.contains { $0 == "/enrol" || $0.hasPrefix("/commands/") }, "CH6 no manual order or enrolment is dispatched")
    } catch { expect(false, "CH6 integration: \(error)") }
}
