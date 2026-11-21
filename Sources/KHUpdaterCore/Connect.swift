import Foundation

/// Sets up the helper from the verified kit inside Studio Launcher KH.app. A signed pairing
/// reply comes before installation; incomplete local files select the installer's repair mode,
/// and the same claim survives a failed install so another attempt can finish it.
public enum Connect {
    /// A kit built for public download carries the pinned key and no address; an absent address
    /// means "not connected yet", never a broken kit.
    public struct Publisher: Codable, Sendable { public var feedURL: String?; public var enrolURL: String?; public var publicKey: String }
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
        guard manifest.files["publisher.json"] != nil, manifest.files["install-agent.sh"] != nil else {
            throw khuFail("the setup kit is missing its pinned publisher or installer")
        }
        let root = kit.resolvingSymlinksInPath().path + "/"
        for (name, pin) in manifest.files {
            let file = kit.appendingPathComponent(name)
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                  file.resolvingSymlinksInPath().path.hasPrefix(root),
                  let data = try? Data(contentsOf: file),
                  data.count == pin.bytes, Signing.sha256Hex(data) == pin.sha256 else {
                throw khuFail("the setup kit inside this app was changed (\(name)); use a fresh copy from the SSD")
            }
        }
        return try JSON.decode(Publisher.self, from: Data(contentsOf: kit.appendingPathComponent("publisher.json")))
    }

    public static func run(kit: URL, home: URL, machine: String, code: String, destination typed: String? = nil,
                           http: HTTPClient = URLSessionHTTPClient(),
                           shell: Shell = SystemShell(), now: Date = Date()) throws -> String {
        try FileLock.withExclusive(home.appendingPathComponent("Library/.khu-connect.lock")) {
            try runLocked(kit: kit, home: home, machine: machine, code: code, destination: typed,
                          http: http, shell: shell, now: now)
        }
    }

    private static func runLocked(kit: URL, home: URL, machine: String, code: String, destination typed: String?,
                                  http: HTTPClient, shell: Shell, now: Date) throws -> String {
        guard !isSetUp(home: home) else { throw khuFail("Studio Launcher KH is already set up on this Mac") }
        _ = try SafeName.component(machine, what: "name for this Mac")
        var pub = try publisher(kit: kit)
        // First setup adopts the kit's key as this Mac's trust, so the kit must name the key sealed
        // inside this copy; otherwise the helper it installs would refuse the saved config at once.
        try PinnedKey.requireKit(pub.publicKey)
        if let typed {
            let feed = try destination(typed)
            pub.feedURL = feed
            pub.enrolURL = URL(string: feed)!.deletingLastPathComponent().appendingPathComponent("enrol").absoluteString
        }
        guard let feedText = pub.feedURL, let feedURL = URL(string: feedText) else {
            throw khuFail("This copy of Studio Launcher KH is not connected to an Update Studio yet. "
                + "Type the address of the Mac running it, shown on that Mac's Update Studio window.")
        }
        guard let enrolURL = URL(string: pub.enrolURL
            ?? feedURL.deletingLastPathComponent().appendingPathComponent("enrol").absoluteString) else {
            throw khuFail("the kit's publisher address is not a URL")
        }
        // Keep the same claim after a failed local install, so retrying can recover its signed reply.
        let library = home.appendingPathComponent("Library")
        let claimFile = library.appendingPathComponent(".khu-connect-claim.json")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        struct Claim: Codable { var machine: String; var feedURL: String; var publicKey: String; var nonce: String }
        let savedClaim = (try? Data(contentsOf: claimFile)).flatMap { try? JSON.decode(Claim.self, from: $0) }
        let nonce: String
        if let claim = savedClaim, claim.machine == machine, claim.feedURL == feedText,
           claim.publicKey == pub.publicKey, claim.nonce.count == 64,
           claim.nonce.allSatisfy({ "0123456789abcdef".contains($0) }) {
            nonce = claim.nonce
        } else {
            nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            if FileManager.default.fileExists(atPath: claimFile.path) {
                _ = try Trash.move(claimFile, into: library.appendingPathComponent("_trash"))
            }
            let claim = Claim(machine: machine, feedURL: feedText, publicKey: pub.publicKey, nonce: nonce)
            guard FileManager.default.createFile(atPath: claimFile.path, contents: JSON.encode(claim),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw khuFail("This Mac could not save the connection attempt. Try connecting again.")
            }
        }
        let body = try JSONSerialization.data(withJSONObject: ["machine": machine, "nonce": nonce, "code": code])
        let (data, status): (Data, Int)
        do { (data, status) = try http.post(enrolURL, headers: ["Content-Type": "application/json"], body: body) }
        catch { throw unreachable(enrolURL, error: error) }
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
        guard reply.machine == machine, reply.nonce == nonce, reply.feedURL == feedText, reply.publicKey == pub.publicKey,
              abs(now.timeIntervalSince1970 - Double(reply.issuedAt)) <= 300, reply.token.count >= 32 else {
            throw khuFail("the publisher's reply does not match this request; nothing was installed")
        }
        // Only the updater is listed: the helper finds the other apps by bundle ID on every run.
        let config: [String: Any] = [
            "feedURL": feedText, "publicKey": pub.publicKey, "machine": machine, "token": reply.token,
            "stateDir": "set-by-installer", "intervalMinutes": 5, "once": false,
            "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": true]],
        ]
        let temp = library.appendingPathComponent(".khu-connect-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temp.path, contents: try JSONSerialization.data(withJSONObject: config),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw khuFail("This Mac could not save its setup settings. Try connecting again.")
        }
        defer { _ = try? Trash.move(temp, into: library.appendingPathComponent("_trash")) }
        let remnants = ["Library/KHUpdater", "Library/LaunchAgents/com.khupdater.agent.plist"].contains {
            (try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent($0).path)) != nil
        }
        let selectedKit = try setupKit(kit, publisher: pub, library: library, http: http)
        defer {
            if selectedKit != kit { _ = try? Trash.move(selectedKit, into: library.appendingPathComponent("_trash")) }
        }
        var arguments = [selectedKit.appendingPathComponent("install-agent.sh").path, temp.path, home.path]
        if remnants { arguments.append("--repair") }
        let result = try shell.run("/bin/bash", arguments: arguments, timeout: 120)
        guard result.exitCode == 0 else {
            if isSetUp(home: home) {
                throw khuFail("Setup finished, but Studio Launcher could not start. Close this window and open Studio Launcher again.")
            }
            throw khuFail("Local setup could not be completed. Your saved data is kept. Try Connect again.")
        }
        _ = try? Trash.move(claimFile, into: library.appendingPathComponent("_trash"))
        let source = selectedKit == kit ? "the verified copy inside this Launcher" : "the publisher's verified download"
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + "\nSetup used \(source)."
    }

    /// Set this Mac up from a public, signed feed: no publisher, no pairing code, no token. The link
    /// is fetched and its signature verified against the key pinned in this build before a helper is
    /// installed for it, and this Mac then reports nothing to anyone — it installs only what that
    /// feed signs. A publisher's own address is refused here: that is the pairing flow.
    public static func usePublicFeed(kit: URL, home: URL, machine: String, address typed: String,
                                     http: HTTPClient = URLSessionHTTPClient(), shell: Shell = SystemShell()) throws -> String {
        try FileLock.withExclusive(home.appendingPathComponent("Library/.khu-connect.lock")) {
            guard !isSetUp(home: home) else { throw khuFail("Studio Launcher KH is already set up on this Mac") }
            _ = try SafeName.component(machine, what: "name for this Mac")
            let pub = try publisher(kit: kit)
            try PinnedKey.requireKit(pub.publicKey)
            let feedText = try destination(typed)
            guard let feedURL = URL(string: feedText), feedURL.scheme?.lowercased() == "https",
                  !FeedNetwork.authenticated(feedURL) else {
                throw khuFail("That is a publisher's address. Choose Connect and type the pairing code from Update Studio instead.")
            }
            // The link must be this fleet's signed feed before any helper is installed for it.
            let data: Data, status: Int
            do { (data, status) = try http.get(feedURL, headers: [:]) }
            catch { throw unreachable(feedURL, error: error) }
            guard status == 200 else { throw khuFail("that feed link answered HTTP \(status); nothing was installed") }
            let release = try JSON.decode(Release.self, from: data)
            guard let body = release.feedData, let signature = release.signatureData,
                  let key = try? Signing.loadPublicKey(base64: PinnedKey.trusted(pub.publicKey)),
                  Signing.verify(body, signature: signature, publicKey: key) else {
                throw khuFail("that link does not serve a feed signed by this fleet's key; nothing was installed")
            }
            let feed = try JSON.decode(Feed.self, from: body).validated()
            guard feed.apps["updater"] != nil else { throw khuFail("that feed offers no helper for this Mac; nothing was installed") }
            let library = home.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let config: [String: Any] = [
                "feedURL": feedText, "publicKey": PinnedKey.trusted(pub.publicKey), "machine": machine, "token": "",
                "stateDir": "set-by-installer", "intervalMinutes": 5, "once": false,
                "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": true]],
            ]
            let temp = library.appendingPathComponent(".khu-connect-\(UUID().uuidString).json")
            guard FileManager.default.createFile(atPath: temp.path, contents: try JSONSerialization.data(withJSONObject: config),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw khuFail("This Mac could not save its setup settings. Try again.")
            }
            defer { _ = try? Trash.move(temp, into: library.appendingPathComponent("_trash")) }
            let result = try shell.run("/bin/bash", arguments: [kit.appendingPathComponent("install-agent.sh").path, temp.path, home.path],
                                       timeout: 120)
            guard result.exitCode == 0 else {
                if isSetUp(home: home) {
                    throw khuFail("Setup finished, but Studio Launcher could not start. Close this window and open Studio Launcher again.")
                }
                throw khuFail("Local setup could not be completed. Your saved data is kept. Try again.")
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\nThis Mac updates from the public feed and reports nothing to anyone."
        }
    }

    /// Pairing still requires the controller. Only transport failure falls back to the verified
    /// local kit; a bad signature, refused request or mismatched download must stay an error.
    static func setupKit(_ kit: URL, publisher pub: Publisher, library: URL, http: HTTPClient) throws -> URL {
        guard try publisher(kit: kit).publicKey == pub.publicKey else { throw khuFail("the setup publisher does not match this kit's pin") }
        guard let feedText = pub.feedURL, let feedURL = URL(string: feedText) else {
            throw khuFail("the kit's feed address is not a URL")
        }
        let data: Data, status: Int
        do { (data, status) = try http.get(feedURL, headers: [:]) }
        catch let error as URLError where [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(error.code) {
            return kit
        }
        if status == 404 || (500...599).contains(status) { return kit }
        guard status == 200 else { throw khuFail("Update Studio refused the setup download (HTTP \(status)); nothing was installed") }
        let release = try JSON.decode(Release.self, from: data)
        guard let body = release.feedData, let signature = release.signatureData,
              Signing.verify(body, signature: signature, publicKey: try Signing.loadPublicKey(base64: pub.publicKey)) else {
            throw khuFail("the setup feed was not signed by the kit's publisher; nothing was installed")
        }
        let feed = try JSON.decode(Feed.self, from: body).validated()
        guard let entry = feed.apps["updater"] else { return kit }
        guard entry.kind == "updater" else { throw khuFail("the setup feed does not describe a helper binary") }
        let localVersion = (try? String(contentsOf: kit.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let localVersion, VersionCompare.isNewer(localVersion, than: entry.version) { return kit }
        let staging = library.appendingPathComponent(".khu-connect-kit-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: kit, to: staging)
        do {
            let binary = staging.appendingPathComponent("bin/khu")
            let part = staging.appendingPathComponent("helper.part")
            let code: Int
            do {
                code = try http.download(entry.location(beside: feedURL.deletingLastPathComponent()),
                                         headers: [:], to: part, limit: entry.bytes)
            } catch let error as URLError where [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost].contains(error.code) {
                try Trash.move(staging, into: library.appendingPathComponent("_trash"))
                return kit
            }
            if (500...599).contains(code) {
                try Trash.move(staging, into: library.appendingPathComponent("_trash"))
                return kit
            }
            guard code == 200 else { throw khuFail("the setup helper download was refused (HTTP \(code))") }
            let digest = try Signing.sha256Hex(fileAt: part)
            guard digest.bytes == entry.bytes, digest.hex == entry.sha256 else {
                throw khuFail("the setup helper does not match its signed size and checksum; nothing was installed")
            }
            try Trash.move(binary, into: staging.appendingPathComponent("_trash"))
            try FileManager.default.moveItem(at: part, to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            let version = staging.appendingPathComponent("VERSION")
            try Data((entry.version + "\n").utf8).write(to: version, options: .atomic)
            let manifestURL = staging.appendingPathComponent("MANIFEST.json")
            var manifest = try JSON.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            for name in ["bin/khu", "VERSION"] {
                let bytes = try Data(contentsOf: staging.appendingPathComponent(name))
                manifest.files[name] = Manifest.Pin(bytes: bytes.count, sha256: Signing.sha256Hex(bytes))
            }
            // Keep the kit's manifest metadata, including its format and bootstrap stage.
            guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
                  let encoded = try JSONSerialization.jsonObject(with: JSON.encode(manifest)) as? [String: Any] else {
                throw khuFail("the setup kit manifest is not an object")
            }
            object["files"] = encoded["files"]
            object["agent_version"] = entry.version
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
            _ = try publisher(kit: staging)
            return staging
        } catch {
            _ = try? Trash.move(staging, into: library.appendingPathComponent("_trash"))
            throw error
        }
    }

    /// Retry a completed setup whose LaunchAgent could not start; never start a second copy.
    public static func startInstalledAgent(home: URL, shell: Shell = SystemShell()) throws {
        let domain = "gui/\(getuid())", label = "com.khupdater.agent"
        let kept = "Your saved connection and settings are kept."
        func query(_ arguments: [String], timeout: TimeInterval = 15) throws -> ShellResult {
            do { return try shell.run("/bin/launchctl", arguments: arguments, timeout: timeout) }
            catch { throw khuFail("macOS startup could not be confirmed (\(arguments[0])). \(kept) Share this startup reason for repair.") }
        }
        let loaded = try query(["print", "\(domain)/\(label)"])
        if loaded.exitCode == 0 { return }
        guard loaded.exitCode == 113 else {
            throw khuFail("macOS could not read the helper's startup status (print exit \(loaded.exitCode)). No startup was attempted. \(kept) Share this startup reason for repair.")
        }
        let disabled = try query(["print-disabled", domain])
        guard let isDisabled = Self.disabledState(disabled) else {
            throw khuFail("macOS could not confirm whether the helper is disabled (print-disabled exit \(disabled.exitCode)). No startup was attempted. \(kept) Share this startup reason for repair.")
        }
        if isDisabled {
            throw khuFail("The helper is disabled in macOS. If you want it running, review System Settings > General > Login Items & Extensions. Nothing was enabled automatically. \(kept)")
        }
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard let data = try? Data(contentsOf: plist) else {
            throw khuFail("The saved helper start file is missing or unreadable. \(kept) The existing installation needs its start file repaired; connecting again will not repair it.")
        }
        guard let job = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              job["Label"] as? String == label,
              let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first,
              program.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: program) else {
            throw khuFail("The saved helper start file or its executable is incomplete. \(kept) The existing installation needs its helper files repaired; connecting again will not repair it.")
        }
        let result = try query(["bootstrap", domain, plist.path], timeout: 30)
        if result.exitCode == 0 { return }
        // Another normal launcher can win registration between the first print and bootstrap.
        if let again = try? query(["print", "\(domain)/\(label)"]), again.exitCode == 0 { return }
        throw khuFail("macOS refused to register the saved helper (bootstrap exit \(result.exitCode)). \(kept) Share this startup reason for repair; restarting alone does not identify the cause.")
    }

    /// Reads `launchctl print-disabled` strictly: true when this helper is disabled, false when
    /// it is not, nil when the answer cannot be read safely — nothing is enabled on a guess.
    static func disabledState(_ result: ShellResult) -> Bool? {
        let label = "com.khupdater.agent"
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, result.stderr.isEmpty,
              text.hasPrefix("disabled services = {"), text.hasSuffix("}") else { return nil }
        let entries = text.components(separatedBy: "\n").filter { $0.contains("\"\(label)\"") }
        let pattern = "^\\s*\"" + NSRegularExpression.escapedPattern(for: label) + "\"\\s*=>\\s*(true|false)\\s*;?\\s*$"
        guard entries.count <= 1, entries.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }) else {
            return nil
        }
        return entries.first?.range(of: "=>\\s*true", options: .regularExpression) != nil
    }

    /// Repair an existing, saved setup without a pairing code: keep every saved byte and rebuild
    /// the incomplete helper files and start file from this Launcher's verified kit. The saved
    /// trust, controller, name, apps, settings and pauses are never rewritten, and nobody is
    /// enrolled. A paused, busy or disabled Mac is refused before anything runs; a kit for another
    /// publisher, or one older than the helper already on this Mac, is refused too.
    public static func repairSetup(kit: URL, home: URL, shell: Shell = SystemShell(),
                                   now: Date = Date()) throws -> RecipeResult {
        let base = home.appendingPathComponent("Library/KHUpdater/base")
        let file = base.appendingPathComponent("config.json")
        let state = home.appendingPathComponent("Library/KHUpdater/state")
        guard let saved = try? Data(contentsOf: file) else {
            throw khuFail("This Mac has no saved connection to repair. Pair it with a code first.")
        }
        let config = try JSON.decode(AgentConfig.self, from: saved)
        guard URL(fileURLWithPath: config.stateDir).standardizedFileURL == state.standardizedFileURL,
              config.stubBase.map({ URL(fileURLWithPath: $0).standardizedFileURL }) == base.standardizedFileURL else {
            throw khuFail("This Mac uses a different helper layout; its saved settings were left unchanged.")
        }
        // The saved trust must be this build's pin, and the kit must name that same key: repair
        // never introduces a publisher this copy was not sealed for.
        try PinnedKey.require(config.publicKey)
        let kitKey = try publisher(kit: kit).publicKey
        try PinnedKey.requireKit(kitKey)
        guard kitKey == PinnedKey.trusted(config.publicKey) else {
            throw khuFail("This Launcher's setup kit belongs to a different Update Studio; this Mac's saved trust was kept. "
                + "Open the Studio Launcher KH copy this Mac was set up with.")
        }
        // The connect lock keeps a second enrolment out; the agent lock keeps a helper that is
        // mid-run (its own agent.lock) from being stopped under it. Both are taken before any
        // launchctl or installer call.
        return try FileLock.withExclusive(home.appendingPathComponent("Library/.khu-connect.lock"), wait: false) {
            try FileLock.withExclusive(state.appendingPathComponent("agent.lock"), wait: false) {
                guard (try? Data(contentsOf: file)) == saved else {
                    throw khuFail("This Mac's saved settings changed while repairing; try again.")
                }
                if HelperSettings.load(from: state).paused(at: now) {
                    return RecipeResult(status: "paused", reason: "Helper updates are paused on this Mac. Its pause was kept.")
                }
                if let current = StubLayout(base: base).currentBinary() {
                    let installed = StubLayout.version(of: current)
                    let raw = (try? String(contentsOf: kit.appendingPathComponent("VERSION"), encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let version = raw, let order = VersionCompare.compare(version, installed) else {
                        throw khuFail("The helper version could not be compared; the saved setup was left unchanged.")
                    }
                    if order < 0 {
                        return RecipeResult(status: "current",
                                            reason: "This Mac already has a newer helper (\(installed)); the saved setup was left unchanged.")
                    }
                }
                // The installer starts the job whenever launchctl says it is not loaded, so the
                // disabled state must be read here and honoured; nothing is enabled automatically.
                let disabled = try shell.run("/bin/launchctl", arguments: ["print-disabled", "gui/\(getuid())"], timeout: 15)
                guard let isDisabled = Self.disabledState(disabled) else {
                    throw khuFail("macOS could not confirm whether the helper is disabled (print-disabled exit \(disabled.exitCode)). Nothing was changed.")
                }
                if isDisabled {
                    throw khuFail("The helper is disabled in macOS, so it was not repaired. If you want it running, review System Settings > General > Login Items & Extensions. Nothing was enabled automatically. Your saved connection and settings are kept.")
                }
                let script = kit.appendingPathComponent("install-agent.sh")
                let result = try shell.run("/bin/bash", arguments: [script.path, file.path, home.path, "--repair-saved"],
                                           timeout: 120)
                guard result.exitCode == 0 else {
                    let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw khuFail(reason.isEmpty ? "The saved helper could not be repaired. Your settings and data are kept." : reason)
                }
                guard (try? Data(contentsOf: file)) == saved else {
                    throw khuFail("This Mac's saved settings were changed during repair; nothing else was touched.")
                }
                return RecipeResult(status: "repaired",
                                    reason: "The helper files and start file were rebuilt from this Launcher's verified kit; the saved connection was kept.")
            }
        }
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

    /// Verification only: a target Mac never signs or regenerates the packaged Launcher.
    public static func packagedLauncherVerifies(_ bundle: URL, shell: Shell = SystemShell()) -> Bool {
        guard (try? BundleInfo.read(bundle.path))?.identifier == "com.khupdater.launcher" else { return false }
        return (try? shell.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", bundle.path], timeout: 60))?.exitCode == 0
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
    /// One sentence for an address that did not answer. A refused address (ATS) is named as the
    /// setting it is; anything else says where it tried, in plain words — Foundation's own text
    /// ("Code=-1022 … requires a secure connection") tells a person nothing they can act on.
    static func unreachable(_ url: URL, error: Error) -> KHUError {
        khuFail(Agent.plainUnreachable(url, error: error))
    }

    public static func check(config: AgentConfig, http: HTTPClient = URLSessionHTTPClient(), now: Date = Date()) throws {
        try PinnedKey.require(config.publicKey)
        guard let feed = URL(string: config.feedURL) else { throw khuFail("this Mac's update address is not a URL") }
        guard FeedNetwork.authenticated(feed) else {
            throw khuFail("This Mac reads a public feed. There is no publisher to check in with: updates come from that signed feed, and nothing is reported to it.")
        }
        let url = feed.deletingLastPathComponent().appendingPathComponent("commands")
            .appendingQuery("machine", config.machine)
        let data: Data, status: Int
        do { (data, status) = try http.get(url, headers: ["Authorization": "Bearer \(config.token)"]) }
        catch {
            // Foundation's own text ("Code=-1022 … requires a secure connection") is not something
            // a person can act on; each cause gets the sentence that names it.
            throw khuFail(Agent.plainUnreachable(feed, error: error))
        }
        guard status == 200 else {
            if status == 401 || status == 403 {
                // Its own type, so Settings can offer Pair again for exactly this and nothing else.
                throw SigninRefused(status: status)
            }
            throw khuFail("Update Studio answered the connection check with HTTP \(status).")
        }
        guard let signed = try? JSON.decode(SignedReply.self, from: data),
              let body = signed.replyData, let signature = signed.signatureData,
              let key = try? Signing.loadPublicKey(base64: PinnedKey.trusted(config.publicKey)),
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

    /// The address typed in Settings, normalised to this tool's one feed address: the publisher's
    /// Tailscale DNS name (ending in `.ts.net`), an optional port, http only. A numeric IP is
    /// refused with the ATS reason: the app cannot reach it with plain http.
    /// No DNS, no autodiscovery, nothing guessed — a bind outside that range is refused rather
    /// than adopted (`## Server`: the Hub's publisher_config accepts exactly this range).
    public static func destination(_ typed: String) throws -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("https://") {
            if let url = URL(string: text), let host = url.host, FeedNetwork.authenticated(url) {
                // A publisher in this fleet serves plain http on its own port. https there is the
                // wrong scheme, said plainly instead of surfacing as a TLS or ATS failure.
                let port = url.port.map { ":\($0)" } ?? ":8790"
                throw khuFail("Update Studio serves plain http on its own port, not https, so \(host) will not answer this way. Type http://\(host)\(port)/release.json — or use GitHub releases.")
            }
            // A public feed's own link, pasted as it appears on the download page. Used exactly as
            // given: `FeedNetwork.feedURL` is the one place that decides what a feed address is.
            return (try FeedNetwork.feedURL(text)).absoluteString
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
        // The app's Info.plist exempts only the tailnet's own DNS suffix for plain http (ATS). A
        // numeric IP is blocked inside the app before any request leaves it, so it is refused here
        // with the reason — a transport error would leave the field looking broken.
        let octets = host.split(separator: ".")
        let numeric = octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.allSatisfy { $0.isNumber }
        }
        if numeric {
            throw khuFail("type the publisher's Tailscale name, not the numeric IP \(host): macOS blocks plain http to an IP address (App Transport Security). The name ends in .ts.net and is shown on the publisher's Update Studio window, or use GitHub releases instead.")
        }
        guard host.lowercased().hasSuffix(".ts.net") else {
            throw khuFail("type the publisher's Tailscale name ending in .ts.net: macOS only allows plain http to that name (App Transport Security), not to \(host).")
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
        try PinnedKey.require(pinned)
        let feedURL = try destination(typed)
        guard let url = URL(string: feedURL) else { throw khuFail("that address is not a URL") }
        let data: Data, status: Int
        do { (data, status) = try http.get(url, headers: [:]) }
        catch { throw unreachable(url, error: error) }
        guard status == 200 else { throw khuFail("that address did not serve an update feed (HTTP \(status))") }
        let release: Release
        do { release = try JSON.decode(Release.self, from: data) }
        catch { throw khuFail("that address did not serve an update feed this tool understands") }
        guard let feedData = release.feedData, let signature = release.signatureData,
              let key = try? Signing.loadPublicKey(base64: PinnedKey.trusted(pinned)),
              Signing.verify(feedData, signature: signature, publicKey: key) else {
            throw khuFail("that address does not serve updates signed by this Mac's key. "
                + "Another Update Studio needs its setup kit — a typed address alone cannot establish trust")
        }
        _ = try JSON.decode(Feed.self, from: feedData).validated()
        return try saveDestination(feedURL, file: file, expected: raw)
    }

    /// Shared compare-before-replace save; preserves unknown settings and refuses a concurrent edit.
    static func saveDestination(_ feedURL: String, file: URL, expected raw: Data) throws -> String {
        guard var settings = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw khuFail("this Mac's updater settings are not readable JSON")
        }
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
        // Pairing again keeps this Mac's trust, and that trust must be the key inside this build.
        try PinnedKey.require(pin)
        return RepairPlan(machine: machine, feedURL: feed, publicKey: pin,
                          enrolURL: feedURL.deletingLastPathComponent().appendingPathComponent("enrol").absoluteString)
    }

    /// Pair again: the explicit local recovery for a sign-in the publisher no longer honours.
    ///
    /// `confirmed` must be true only after the person read the plain confirmation — without it
    /// this returns before any network call or file write, so an unconfirmed attempt cannot
    /// enrol or touch anything. The pairing code may be left empty when the publisher's owner has
    /// opened its allow-a-Mac window: that window is the authorisation, and the publisher replaces
    /// the machine's earlier sign-in; a wrong or missing code without a window is the publisher's
    /// refusal, never a client-side guess. The reply must be signed by — and must name — the key already
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
        guard let snapshot = try? Data(contentsOf: configFile) else {
            throw khuFail("this Mac's updater settings could not be read (\(configFile.path))")
        }
        let plan = try makePlan(from: snapshot)
        let nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        guard let enrolURL = URL(string: plan.enrolURL) else { throw khuFail("this Mac's saved publisher address is not a URL") }
        var body: [String: Any] = ["machine": plan.machine, "nonce": nonce]
        if !typed.isEmpty { body["code"] = typed }
        let data: Data, status: Int
        do { (data, status) = try http.post(enrolURL, headers: ["Content-Type": "application/json"],
                                            body: try JSONSerialization.data(withJSONObject: body)) }
        catch { throw unreachable(enrolURL, error: error) }
        guard status == 200 else {
            // The publisher's own sentence, with the address that answered: a wrong code, a lock,
            // or a different publisher at this address must be told apart, never guessed at.
            let host = URL(string: plan.feedURL)?.host ?? plan.feedURL
            let sentence = String(decoding: data.prefix(512), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.isEmpty {
                throw khuFail("Update Studio at \(host) refused this pairing (HTTP \(status)); nothing was changed")
            }
            if sentence.hasPrefix("<") {
                throw khuFail("the address \(host) answered with a web page, not a pairing reply (HTTP \(status)); check the address in Settings")
            }
            throw khuFail("Update Studio at \(host) said: \(sentence)")
        }
        let signed = try JSON.decode(SignedReply.self, from: data)
        guard let replyData = signed.replyData, let signature = signed.signatureData,
              let key = try? Signing.loadPublicKey(base64: PinnedKey.trusted(plan.publicKey)),
              Signing.verify(replyData, signature: signature, publicKey: key) else {
            throw khuFail("the publisher's reply was not signed by this Mac's pinned key; nothing was changed")
        }
        let reply = try JSON.decode(EnrolReply.self, from: replyData)
        // One sentence per failed agreement, so a reply from the wrong address, a clock difference
        // and a wrong key are never collapsed into "does not match".
        guard reply.machine == plan.machine else {
            throw khuFail("the publisher answered for \(reply.machine), not this Mac (\(plan.machine)); nothing was changed")
        }
        guard reply.nonce == nonce else {
            throw khuFail("the publisher's reply does not answer this pairing request; nothing was changed")
        }
        guard reply.feedURL == plan.feedURL else {
            throw khuFail("the publisher named \(reply.feedURL) in its reply, but this Mac's saved address is \(plan.feedURL); nothing was changed — check the address in Settings")
        }
        guard reply.publicKey == PinnedKey.trusted(plan.publicKey) else {
            throw khuFail("the reply names a different publisher key than this Mac pins; nothing was changed")
        }
        guard abs(now.timeIntervalSince1970 - Double(reply.issuedAt)) <= 300 else {
            throw khuFail("this Mac's clock and the publisher's differ by more than five minutes; use the same time on both and try Pair again")
        }
        guard reply.token.count >= 32 else {
            throw khuFail("the publisher's reply carried no usable token; nothing was changed")
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
