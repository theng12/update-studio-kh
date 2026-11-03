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
        let (data, status): (Data, Int)
        do { (data, status) = try http.post(enrolURL, headers: ["Content-Type": "application/json"], body: body) }
        catch { throw khuFail("Update Studio could not be reached at \(pub.enrolURL) (\(error.localizedDescription))") }
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

    // MARK: staying connected (the settings page), never a second enrolment

    /// Carries the setup kit out of the Launcher bundle being replaced into its regenerated copy —
    /// byte for byte, so every pin, key and address stays exactly what shipped. A kit that no
    /// longer passes its own manifest check is not propagated, and a bundle with no kit has
    /// nothing to carry: both return false rather than inventing trust. Save Launcher needs this
    /// so an app this Mac regenerated can still be shared.
    @discardableResult
    public static func carryKit(from old: URL, into staging: URL) -> Bool {
        let source = old.appendingPathComponent("Contents/Resources/khu-agent")
        let destination = staging.appendingPathComponent("Contents/Resources/khu-agent")
        guard !FileManager.default.fileExists(atPath: destination.path),
              (try? publisher(kit: source)) != nil else { return false }
        guard ((try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)) != nil),
              (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { return false }
        return true
    }

    /// Ad-hoc signed the way packaging/build-launcher.sh signs the app it ships, so a regenerated
    /// Launcher still passes `codesign --verify --deep --strict`. Returns false — and says so on
    /// stderr instead of swallowing it — when codesign refused; the bundle itself is kept.
    @discardableResult
    public static func signBundle(_ bundle: URL, shell: Shell = SystemShell()) -> Bool {
        let outcome = try? shell.run("/usr/bin/codesign", arguments: ["--force", "--deep", "-s", "-", bundle.path], timeout: 60)
        if let outcome, outcome.exitCode == 0 { return true }
        let reason = outcome.map { $0.stderr.isEmpty ? "codesign exited \($0.exitCode)" : $0.stderr } ?? "codesign did not run"
        FileHandle.standardError.write(Data("regenerated Studio Launcher KH.app could not be signed: \(reason)\n".utf8))
        return false
    }

    /// The settings file the installer wrote: `<KHUpdater>/base/config.json`, beside the state
    /// folder. It holds this Mac's address, its pinned key and its token.
    public static func configFile(stateDir: URL) -> URL {
        stateDir.deletingLastPathComponent().appendingPathComponent("base/config.json")
    }

    /// Asks the publisher this Mac is already pinned to whether it still honours it: its signed
    /// `/commands` answer, checked against this Mac's own pinned key and its own name. The query
    /// carries no `capabilities`, so the publisher's record is not even touched (`## Server`);
    /// nothing here writes anything, and a Mac whose sign-in has stopped working is told so in a
    /// sentence — it is never re-enrolled by a check.
    public static func check(config: AgentConfig, http: HTTPClient = URLSessionHTTPClient(), now: Date = Date()) throws {
        guard let feed = URL(string: config.feedURL) else { throw khuFail("this Mac's update address is not a URL") }
        let url = feed.deletingLastPathComponent().appendingPathComponent("commands")
            .appendingQuery("machine", config.machine)
        let data: Data, status: Int
        do { (data, status) = try http.get(url, headers: ["Authorization": "Bearer \(config.token)"]) }
        catch { throw khuFail("Update Studio could not be reached at \(config.feedURL) (\(error.localizedDescription))") }
        guard status == 200 else {
            if status == 401 || status == 403 {
                // Its own type, so Settings can offer Pair again for exactly this and nothing else.
                throw SigninRefused(status: status)
            }
            throw khuFail("Update Studio answered the connection check with HTTP \(status).")
        }
        guard let signed = try? JSON.decode(SignedReply.self, from: data),
              let body = signed.replyData, let signature = signed.signatureData,
              let key = try? Signing.loadPublicKey(base64: config.publicKey),
              Signing.verify(body, signature: signature, publicKey: key) else {
            throw khuFail("the answer was not signed by this Mac's pinned key; this connection is not trusted")
        }
        let reply = try JSON.decode(CommandsReply.self, from: body)
        guard reply.machine == config.machine else {
            throw khuFail("the answer names \(reply.machine), not this Mac (\(config.machine)); refused")
        }
        guard let signedAt = ISO.date(reply.at), abs(signedAt.timeIntervalSince(now)) <= Agent.orderFreshness else {
            throw khuFail("the answer is not fresh (signed at \(reply.at)); try the check again")
        }
    }

    /// The address typed in Settings, normalised to this tool's one feed address: a plain IPv4 in
    /// the Tailscale range the Hub itself accepts (100.64.0.0/10), an optional port, http only.
    /// No DNS, no autodiscovery, nothing guessed — a bind outside that range is refused rather
    /// than adopted (`## Server`: the Hub's publisher_config accepts exactly this range).
    public static func destination(_ typed: String) throws -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("https://") {
            throw khuFail("Update Studio is reached over plain http on the tailnet, not https; type host or host:port")
        }
        if lower.hasPrefix("http://") { text = String(text.dropFirst(7)) }
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        if text.lowercased().hasSuffix("/release.json") { text = String(text.dropLast("/release.json".count)) }
        guard !text.contains("/") && !text.contains("@") && !text.contains(" ") else {
            throw khuFail("type just the Update Studio address (host or host:port), without a path")
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw khuFail("that does not look like host or host:port") }
        let host = String(parts[0])
        var port = ""
        if parts.count == 2 {
            let raw = String(parts[1])
            guard let number = Int(raw), String(number) == raw, (1...65535).contains(number) else {
                throw khuFail("'\(raw)' is not a port number (1–65535)")
            }
            port = ":\(number)"
        }
        let octets = host.split(separator: ".")
        guard octets.count == 4 else {
            throw khuFail("Update Studio's address is an IPv4 address in the Tailscale range 100.64.0.0/10, not \(host)")
        }
        var numbers: [Int] = []
        for octet in octets {
            guard let number = Int(octet), (0...255).contains(number), String(number) == octet else {
                throw khuFail("\(host) is not an IPv4 address; type the Tailscale address Update Studio serves on")
            }
            numbers.append(number)
        }
        guard numbers[0] == 100, (64...127).contains(numbers[1]) else {
            throw khuFail("\(host) is outside the Tailscale range 100.64.0.0/10 this tool accepts; no other address is used")
        }
        return "http://\(host)\(port)/release.json"
    }

    /// Points this Mac's settings at a new address for the SAME publisher. The typed destination
    /// must sit in the Tailscale range the Hub accepts and must serve the signed update feed that
    /// verifies against the key already pinned in this Mac's config — a different publisher's key
    /// cannot be typed into trust, only carried in by a setup kit this app trusts. Only `feedURL`
    /// is rewritten: the pin, this Mac's name and its token stay exactly as they were, the feed's
    /// own signature and validation run before anything is saved, and nobody is enrolled.
    public static func changeDestination(to typed: String, file: URL, http: HTTPClient = URLSessionHTTPClient(), now: Date = Date()) throws -> String {
        guard let raw = try? Data(contentsOf: file) else { throw khuFail("this Mac's updater settings could not be read (\(file.path))") }
        guard var settings = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw khuFail("this Mac's updater settings are not readable JSON")
        }
        guard let pinned = settings["publicKey"] as? String, !pinned.isEmpty else {
            throw khuFail("this Mac's updater settings hold no pinned key, so no address can be trusted from here")
        }
        let feedURL = try destination(typed)
        guard let url = URL(string: feedURL) else { throw khuFail("that address is not a URL") }
        let data: Data, status: Int
        do { (data, status) = try http.get(url, headers: [:]) }
        catch { throw khuFail("Update Studio could not be reached at \(feedURL) (\(error.localizedDescription))") }
        guard status == 200 else { throw khuFail("that address did not serve an update feed (HTTP \(status))") }
        let release: Release
        do { release = try JSON.decode(Release.self, from: data) }
        catch { throw khuFail("that address did not serve an update feed this tool understands") }
        guard let feedData = release.feedData, let signature = release.signatureData,
              let key = try? Signing.loadPublicKey(base64: pinned),
              Signing.verify(feedData, signature: signature, publicKey: key) else {
            throw khuFail("that address does not serve updates signed by this Mac's key. "
                + "Another Update Studio needs its setup kit — a typed address alone cannot establish trust")
        }
        _ = try JSON.decode(Feed.self, from: feedData).validated()
        settings["feedURL"] = feedURL
        let body = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
            throw khuFail("the new address could not be written next to \(file.lastPathComponent)")
        }
        do {
            guard try Data(contentsOf: file) == raw else {
                throw khuFail("these settings changed while the address was checked; try again with the current connection")
            }
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        } catch {
            _ = try? Trash.move(temp, into: file.deletingLastPathComponent().appendingPathComponent("_trash"))
            throw khuFail("the new address could not be saved: \(error)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return feedURL
    }

    // MARK: Pair again — explicit local recovery from a sign-in the publisher stopped honouring

    /// What a check's 401/403 means: the publisher no longer recognises this Mac's sign-in. Its
    /// own sentence stays the owner-facing text; Settings keys Pair again off this type alone.
    public struct SigninRefused: Error, CustomStringConvertible, Sendable {
        public let status: Int
        public var description: String {
            "Update Studio does not recognise this Mac's sign-in (HTTP \(status)). The fix is over there: "
                + "Remove this Mac in Update Studio, then pair it again with a new code. This Mac never re-enters itself."
        }
    }

    /// What Pair again will keep and where it will post: read from this Mac's own saved settings,
    /// never from a kit (a regenerated app may carry none) and never from the network.
    public struct RepairPlan: Sendable {
        public var machine: String
        public var feedURL: String
        public var publicKey: String
        public var enrolURL: String
    }

    public static func repairPlan(configFile: URL) throws -> RepairPlan {
        guard let raw = try? Data(contentsOf: configFile) else {
            throw khuFail("this Mac's updater settings could not be read (\(configFile.path))")
        }
        return try makePlan(from: raw)
    }

    private static func makePlan(from raw: Data) throws -> RepairPlan {
        guard let settings = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let machine = settings["machine"] as? String, !machine.isEmpty,
              let feed = settings["feedURL"] as? String, !feed.isEmpty,
              let pin = settings["publicKey"] as? String, !pin.isEmpty,
              let feedURL = URL(string: feed) else {
            throw khuFail("this Mac's updater settings do not hold a full sign-in, so there is nothing to pair again")
        }
        _ = try SafeName.component(machine, what: "name for this Mac")
        return RepairPlan(machine: machine, feedURL: feed, publicKey: pin,
                          enrolURL: feedURL.deletingLastPathComponent().appendingPathComponent("enrol").absoluteString)
    }

    /// Pair again: the explicit local recovery for a sign-in the publisher no longer honours.
    ///
    /// `confirmed` must be true only after the person read the plain confirmation — without it
    /// this returns before any network call or file write, so an unconfirmed attempt cannot
    /// enrol or touch anything. The pairing code is required (an empty one is refused here, never
    /// spent at the publisher). The reply must be signed by — and must name — the key already
    /// pinned in these settings, the same address and the same machine: pairing never adopts a
    /// different key or publisher. Only after every check passes are the current bytes preserved
    /// under this updater's own `_trash` (`<KHUpdater>/_trash/<machine>/`) and the token replaced;
    /// machine, pin, apps, automatic choices and every other setting stay exactly as they were.
    /// A reply that arrives after these settings changed is refused rather than applied. If the
    /// save itself fails, the preserved bytes are put back, so saved trust is never stranded.
    public static func repair(configFile: URL, code: String, confirmed: Bool,
                              http: HTTPClient = URLSessionHTTPClient(), now: Date = Date()) throws -> String {
        guard confirmed else { throw khuFail("pairing was not confirmed; nothing was sent") }
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw khuFail("type the pairing code from Update Studio") }
        guard let snapshot = try? Data(contentsOf: configFile) else {
            throw khuFail("this Mac's updater settings could not be read (\(configFile.path))")
        }
        let plan = try makePlan(from: snapshot)
        let nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        guard let enrolURL = URL(string: plan.enrolURL) else { throw khuFail("this Mac's saved publisher address is not a URL") }
        let body = try JSONSerialization.data(withJSONObject: ["machine": plan.machine, "nonce": nonce, "code": typed])
        let data: Data, status: Int
        do { (data, status) = try http.post(enrolURL, headers: ["Content-Type": "application/json"], body: body) }
        catch { throw khuFail("Update Studio could not be reached at \(plan.feedURL) (\(error.localizedDescription))") }
        guard status == 200 else {
            // The publisher's own sentence: wrong code, locked, or an id it still has a record of.
            let reason = String(decoding: data.prefix(512), as: UTF8.self).filter { !$0.isNewline }
            throw khuFail(reason.isEmpty ? "the publisher refused this pairing (\(status))" : reason)
        }
        let signed = try JSON.decode(SignedReply.self, from: data)
        guard let replyData = signed.replyData, let signature = signed.signatureData,
              let key = try? Signing.loadPublicKey(base64: plan.publicKey),
              Signing.verify(replyData, signature: signature, publicKey: key) else {
            throw khuFail("the publisher's reply was not signed by this Mac's pinned key; nothing was changed")
        }
        let reply = try JSON.decode(EnrolReply.self, from: replyData)
        guard reply.machine == plan.machine, reply.nonce == nonce, reply.feedURL == plan.feedURL,
              reply.publicKey == plan.publicKey,
              abs(now.timeIntervalSince1970 - Double(reply.issuedAt)) <= 300, reply.token.count >= 32 else {
            throw khuFail("the publisher's reply does not match this Mac's saved sign-in; nothing was changed")
        }
        // The settings may have changed while the request was in flight: a reply for the older
        // snapshot is refused rather than written over the newer sign-in.
        guard let current = try? Data(contentsOf: configFile), current == snapshot else {
            throw khuFail("these settings changed while pairing was in progress; nothing was changed — try Pair again")
        }
        let fm = FileManager.default
        let trash = Trash.root(in: configFile.deletingLastPathComponent().deletingLastPathComponent())
        let archiveDir = trash.appendingPathComponent(plan.machine)
        var settings = try JSONSerialization.jsonObject(with: snapshot) as! [String: Any]
        settings["token"] = reply.token
        let renewed = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        _ = try JSON.decode(AgentConfig.self, from: renewed)
        let temp = configFile.deletingLastPathComponent().appendingPathComponent(".\(configFile.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: renewed, attributes: [.posixPermissions: 0o600]) else {
            throw khuFail("the renewed sign-in could not be staged; the original settings are unchanged")
        }
        defer { _ = try? Trash.move(temp, into: trash) }
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = archiveDir.appendingPathComponent("config-\(UUID().uuidString).json")
        guard try Data(contentsOf: configFile) == snapshot else {
            throw khuFail("these settings changed while pairing was in progress; nothing was changed — try Pair again")
        }
        try fm.moveItem(at: configFile, to: archive)
        do {
            guard try Data(contentsOf: archive) == snapshot else {
                throw khuFail("these settings changed while pairing was in progress")
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            try fm.moveItem(at: temp, to: configFile)
        } catch {
            // Restore only a missing file: a newer writer's settings must never be overwritten.
            if !fm.fileExists(atPath: configFile.path) {
                do { try fm.copyItem(at: archive, to: configFile) }
                catch { throw khuFail("pairing could not save or restore the settings (\(error)); the preserved sign-in is at \(archive.path)") }
            }
            throw khuFail("pairing could not save the renewed sign-in (\(error)); the previous file is preserved at \(archive.path)")
        }
        return plan.machine
    }
}
