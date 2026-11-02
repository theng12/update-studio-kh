import Foundation

/// Sets up the helper on a Mac that has none, from the agent kit inside Studio Launcher KH.app:
/// the same steps as the Connect kit's installer (check the kit, claim a token with the pairing
/// code, check the signed reply, then the kit's own `install-agent.sh` installs and starts it).
public enum Connect {
    public struct Publisher: Codable, Sendable { public var feedURL: String; public var enrolURL: String; public var publicKey: String }
    struct Manifest: Codable { struct Pin: Codable { var bytes: Int; var sha256: String }; var files: [String: Pin] }

    public static func isSetUp(home: URL) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/KHUpdater/base/config.json").path)
    }

    /// The name this Mac proposes: its computer name, in the characters a machine id allows.
    public static func proposedName() -> String {
        let raw = (Host.current().localizedName ?? "mac").lowercased()
        let mapped = raw.map { "abcdefghijklmnopqrstuvwxyz0123456789._-".contains($0) ? $0 : "-" }
        let name = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return name.isEmpty ? "mac" : name
    }

    /// A kit altered on the drive, or one with no publisher record, is refused before anything is sent.
    public static func publisher(kit: URL) throws -> Publisher {
        guard let manifest = try? JSON.decode(Manifest.self, from: Data(contentsOf: kit.appendingPathComponent("MANIFEST.json"))) else {
            throw khuFail("this copy of Studio Launcher KH has no setup kit inside it")
        }
        for (name, pin) in manifest.files {
            guard let data = try? Data(contentsOf: kit.appendingPathComponent(name)),
                  data.count == pin.bytes, Signing.sha256Hex(data) == pin.sha256 else {
                throw khuFail("the setup kit inside this app was changed (\(name)); use a fresh copy from the SSD")
            }
        }
        return try JSON.decode(Publisher.self, from: Data(contentsOf: kit.appendingPathComponent("publisher.json")))
    }

    public static func run(kit: URL, home: URL, machine: String, code: String, http: HTTPClient = URLSessionHTTPClient(),
                           shell: Shell = SystemShell(), now: Date = Date()) throws -> String {
        guard !isSetUp(home: home) else { throw khuFail("Studio Launcher KH is already set up on this Mac") }
        _ = try SafeName.component(machine, what: "name for this Mac")
        let pub = try publisher(kit: kit)
        guard let enrolURL = URL(string: pub.enrolURL) else { throw khuFail("the kit's publisher address is not a URL") }
        let nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let body = try JSONSerialization.data(withJSONObject: ["machine": machine, "nonce": nonce, "code": code])
        let (data, status) = try http.post(enrolURL, headers: ["Content-Type": "application/json"], body: body)
        guard status == 200 else {
            // The publisher's own sentence: wrong code, locked, or a name already taken.
            let reason = String(decoding: data.prefix(512), as: UTF8.self).filter { !$0.isNewline }
            throw khuFail(reason.isEmpty ? "the publisher refused this Mac (\(status))" : reason)
        }
        let signed = try JSON.decode(SignedReply.self, from: data)
        guard let replyData = signed.replyData, let signature = signed.signatureData,
              Signing.verify(replyData, signature: signature, publicKey: try Signing.loadPublicKey(base64: pub.publicKey)) else {
            throw khuFail("the publisher's reply was not signed by its key; nothing was installed")
        }
        let reply = try JSON.decode(EnrolReply.self, from: replyData)
        guard reply.machine == machine, reply.nonce == nonce, reply.feedURL == pub.feedURL, reply.publicKey == pub.publicKey,
              abs(now.timeIntervalSince1970 - Double(reply.issuedAt)) <= 300, reply.token.count >= 32 else {
            throw khuFail("the publisher's reply does not match this request; nothing was installed")
        }
        // Only the updater is listed: the helper finds the other apps by bundle ID on every run.
        let config: [String: Any] = [
            "feedURL": pub.feedURL, "publicKey": pub.publicKey, "machine": machine, "token": reply.token,
            "stateDir": "set-by-installer", "intervalMinutes": 5, "once": false,
            "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": true]],
        ]
        let library = home.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let temp = library.appendingPathComponent(".khu-connect-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: temp.path, contents: try JSONSerialization.data(withJSONObject: config),
                                       attributes: [.posixPermissions: 0o600])
        defer { _ = try? Trash.move(temp, into: library.appendingPathComponent("_trash")) }
        let result = try shell.run("/bin/bash", arguments: [kit.appendingPathComponent("install-agent.sh").path, temp.path, home.path], timeout: 120)
        guard result.exitCode == 0 else {
            throw khuFail((result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
