import Foundation

// Focused tests for the Connect to Update Studio flow: the front door's attempt outcomes, the
// settings connection check and change of address, and a regenerated Launcher keeping a kit it
// can still verify. Everything runs against temporary homes and the in-process publisher fakes —
// no real home, no real publisher, no key written anywhere but a test temp dir.
//
// Registration (Tests/Runner/main.swift is main's file): call `connectionFlowTests()` wherever
// `launcherTests()` is called — both the E_ONLY short-circuit and the full run at the bottom.

/// A publisher that answers nothing: used for the "cannot be reached" sentences.
private struct OfflineHTTP: HTTPClient {
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { throw URLError(.cannotConnectToHost) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw URLError(.cannotConnectToHost) }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { throw URLError(.cannotConnectToHost) }
}

private struct ConcurrentConfigHTTP: HTTPClient {
    let inner: HTTPClient
    let file: URL
    let replacement: Data
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        try replacement.write(to: file, options: .atomic)
        return try inner.get(url, headers: headers)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        // The settings are replaced while the request is in flight — the recovery's own guard
        // must refuse the reply rather than write over the newer sign-in.
        try replacement.write(to: file, options: .atomic)
        return try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { try inner.download(url, headers: headers, to: file, limit: limit) }
}

/// Counts the requests that actually left: the confirmation-refusal cases must stay at zero.
private final class CountingHTTP: HTTPClient, @unchecked Sendable {
    let inner: HTTPClient
    private(set) var posts = 0
    init(_ inner: HTTPClient) { self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { try inner.get(url, headers: headers) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        posts += 1
        return try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        try inner.download(url, headers: headers, to: file, limit: limit)
    }
}

func connectionFlowTests() {
    /// A kit for this rig: publisher record and install script, pinned by MANIFEST.json. The
    /// script really writes the config into the temp home when a real shell runs it (the
    /// success/persistence cases), and a capture shell simply records it elsewhere.
    func kit(for r: EnrolRig) -> URL {
        let k = r.rig.root.appendingPathComponent("kit")
        try! fm.createDirectory(at: k, withIntermediateDirectories: true)
        let pub = try! JSONSerialization.data(withJSONObject: [
            "feedURL": "http://\(r.bind):\(r.port)/release.json",
            "enrolURL": "http://\(r.bind):\(r.port)/enrol",
            "publicKey": r.rig.pair.publicKeyBase64,
        ])
        try! pub.write(to: k.appendingPathComponent("publisher.json"))
        let script = """
        #!/bin/bash
        set -e
        mkdir -p "$2/Library/KHUpdater/base"
        cp "$1" "$2/Library/KHUpdater/base/config.json"
        echo "Agent installed and started."
        """
        try! Data(script.utf8).write(to: k.appendingPathComponent("install-agent.sh"))
        var files: [String: Any] = [:]
        for name in ["publisher.json", "install-agent.sh"] {
            let data = try! Data(contentsOf: k.appendingPathComponent(name))
            files[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
        }
        try! JSONSerialization.data(withJSONObject: ["files": files]).write(to: k.appendingPathComponent("MANIFEST.json"))
        return k
    }
    func pairingCode(_ r: EnrolRig) -> String {
        try! Enrolment.ensurePairingCode(stateDir: r.rig.state)
        return (try! StateStore.load(from: r.rig.state)).pairing!.code
    }

    // CF1. A wrong pairing code is refused with the publisher's own sentence and installs nothing.
    do {
        let r = EnrolRig("cf1")
        let code = pairingCode(r)
        let home = r.rig.root.appendingPathComponent("home")
        let shell = CaptureShell()
        expectThrows("CF1 a wrong pairing code is refused with the publisher's own sentence", contains: "pairing code is wrong") {
            _ = try Connect.run(kit: kit(for: r), home: home, machine: "cf-mac",
                                code: code == "000000" ? "000001" : "000000",
                                http: InProcessClient(server: r.server), shell: shell)
        }
        expect(shell.calls.isEmpty && !Connect.isSetUp(home: home), "CF1 a refused code installs nothing and sets nothing up")
        expect(r.machines["cf-mac"] == nil, "CF1 a refused code enrols nobody")
    }

    // CF2. An unreachable Update Studio is said as one plain sentence, and nothing runs after it.
    do {
        let r = EnrolRig("cf2")
        let home = r.rig.root.appendingPathComponent("home")
        let shell = CaptureShell()
        expectThrows("CF2 an unreachable Update Studio is one honest sentence, and installs nothing", contains: "could not be reached") {
            _ = try Connect.run(kit: kit(for: r), home: home, machine: "cf-mac", code: "123456",
                                http: OfflineHTTP(), shell: shell)
        }
        expect(shell.calls.isEmpty && !Connect.isSetUp(home: home), "CF2 an unreachable publisher runs no install script")
    }

    // CF3 + CF4. The right code sets the Mac up — the config persists where the front door looks
    // for it — and a second attempt is refused as already connected before anything is sent.
    do {
        let r = EnrolRig("cf34")
        let code = pairingCode(r)
        let k = kit(for: r)
        let home = r.rig.root.appendingPathComponent("home")
        let client = InProcessClient(server: r.server)
        let out = try? Connect.run(kit: k, home: home, machine: "cf-mac", code: code, http: client, shell: SystemShell())
        expect(out?.contains("Agent installed") == true, "CF3 the right code runs the kit's own install script")
        expect(Connect.isSetUp(home: home), "CF4 after connecting, this Mac reads as set up (the setup persists)")
        let configFile = home.appendingPathComponent("Library/KHUpdater/base/config.json")
        let saved = (try? JSON.decode(AgentConfig.self, from: Data(contentsOf: configFile)))
        expect(saved?.machine == "cf-mac" && saved?.publicKey == r.rig.pair.publicKeyBase64
               && (saved?.token.count ?? 0) >= 32
               && saved?.feedURL == "http://\(r.bind):\(r.port)/release.json",
               "CF4 the saved settings carry this Mac's name, the pinned key, its token and the kit's address")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: home.appendingPathComponent("Library").path)) ?? [])
            .filter { $0.hasPrefix(".khu-connect-") }
        expect(leftovers.isEmpty, "CF4 the temporary file holding the token is not left behind")
        expectThrows("CF4 a second connect is refused as already connected before anything is sent", contains: "already set up") {
            _ = try Connect.run(kit: k, home: home, machine: "cf-mac", code: code, http: OfflineHTTP(), shell: SystemShell())
        }
        expect(r.machines["cf-mac"] != nil && saved.map { r.machines["cf-mac"]?.tokenHash == Enrolment.sha256Hex($0.token) } == true,
               "CF4 the publisher record and the stored token still match each other")
    }

    // CF16. Incomplete local files select the installer repair path without discarding saved data.
    for remnant in ["Library/KHUpdater/state/keep.txt", "Library/LaunchAgents/com.khupdater.agent.plist"] {
        let r = EnrolRig("cf16-" + (remnant.contains("state") ? "state" : "plist"))
        let code = pairingCode(r)
        let home = r.rig.root.appendingPathComponent("home")
        let saved = home.appendingPathComponent(remnant)
        try! fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("saved-data".utf8).write(to: saved)
        let shell = CaptureShell()
        let result = try? Connect.run(kit: kit(for: r), home: home, machine: "repair-mac", code: code,
                                      http: InProcessClient(server: r.server), shell: shell)
        expect(result != nil && shell.calls.last?.last == "--repair",
               "CF16 existing local files choose repair instead of the fresh installer")
        expect((try? Data(contentsOf: saved)) == Data("saved-data".utf8),
               "CF16 connection does not discard old files")
    }

    // CF17. A failed local install retries its original claim, without another Remove Mac.
    do {
        let r = EnrolRig("cf17")
        let code = pairingCode(r)
        let home = r.rig.root.appendingPathComponent("home")
        let k = kit(for: r)
        let client = InProcessClient(server: r.server)
        let failed = CaptureShell(); failed.exitCode = 1
        expectThrows("CF17 a failed local install explains retry in plain words", contains: "Try Connect again") {
            _ = try Connect.run(kit: k, home: home, machine: "retry-mac", code: code, http: client, shell: failed)
        }
        let claim = home.appendingPathComponent("Library/.khu-connect-claim.json")
        let firstNonce = r.machines["retry-mac"]?.enrolNonceHash
        expect(firstNonce != nil && fm.fileExists(atPath: claim.path), "CF17 a failed setup keeps its pending claim")
        expect((try! fm.attributesOfItem(atPath: claim.path))[.posixPermissions] as? Int == 0o600,
               "CF17 pending connection claims are private")
        let result = try? Connect.run(kit: k, home: home, machine: "retry-mac", code: code,
                                      http: client, shell: SystemShell())
        expect(result != nil && Connect.isSetUp(home: home) && r.machines["retry-mac"]?.enrolNonceHash == firstNonce,
               "CF17 retry completes with the same signed claim rather than a duplicate-name refusal")
        expect(!fm.fileExists(atPath: claim.path), "CF17 completed connection retires its pending claim")
    }

    // CF18. Reopening uses only the exact saved job and bounded launchctl calls.
    do {
        struct Call: Equatable {
            var executable: String = "/bin/launchctl"
            var arguments: [String]
            var timeout: TimeInterval = 15
        }
        final class StartupShell: Shell, @unchecked Sendable {
            var calls: [Call] = []
            var replies: [ShellResult]
            init(_ replies: [ShellResult]) { self.replies = replies }
            func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
                calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
                guard !replies.isEmpty else { throw khuFail("Unexpected startup fixture call") }
                return replies.removeFirst()
            }
        }
        let home = tmpDir("cf18")
        let domain = "gui/\(getuid())"
        let probe = Call(arguments: ["print", "\(domain)/com.khupdater.agent"])
        let success = ShellResult(exitCode: 0, stdout: "", stderr: "")
        let loaded = StartupShell([success])
        expect((try? Connect.startInstalledAgent(home: home, shell: loaded)) != nil
               && loaded.calls == [probe] && loaded.replies.isEmpty,
               "CF18 a loaded helper receives only the exact bounded print call")
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.khupdater.agent.plist")
        try! fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job: [String: Any] = ["Label": "com.khupdater.agent", "ProgramArguments": ["/usr/bin/true"]]
        try! PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        let missing = ShellResult(exitCode: 113, stdout: "", stderr: "Could not find service")
        let enabled = ShellResult(exitCode: 0, stdout: "disabled services = {\n}\n", stderr: "")
        let calls = [probe, Call(arguments: ["print-disabled", domain]),
                     Call(arguments: ["bootstrap", domain, plist.path], timeout: 30)]
        let absent = StartupShell([missing, enabled, success])
        expect((try? Connect.startInstalledAgent(home: home, shell: absent)) != nil
               && absent.calls == calls && absent.replies.isEmpty,
               "CF18 an absent enabled helper uses the current UID, exact plist and bounded calls only")
        let refused = StartupShell([missing, enabled,
            ShellResult(exitCode: 5, stdout: "", stderr: "private diagnostic"), missing])
        expectThrows("CF18 a refusal reports its phase/code without repeated restart advice", contains: "bootstrap exit 5") {
            try Connect.startInstalledAgent(home: home, shell: refused)
        }
        expect(refused.calls == calls + [probe] && refused.replies.isEmpty,
               "CF18 refused bootstrap permits one exact read-only race check and no extra calls")
    }

    // CF5. The settings connection check: this Mac's own credentials answer, and each refusal is
    // a sentence. It never enrols and never writes.
    do {
        let r = EnrolRig("cf5")
        let code = pairingCode(r)
        let k = kit(for: r)
        let home = r.rig.root.appendingPathComponent("home")
        _ = try? Connect.run(kit: k, home: home, machine: "cf-mac", code: code,
                             http: InProcessClient(server: r.server), shell: SystemShell())
        let configFile = home.appendingPathComponent("Library/KHUpdater/base/config.json")
        let good = try! JSON.decode(AgentConfig.self, from: Data(contentsOf: configFile))
        expect((try? Connect.check(config: good, http: InProcessClient(server: r.server))) != nil,
               "CF5 a connected Mac's check is answered and verifies against its pin")
        var stale = good; stale.token = "not-the-token"
        expectThrows("CF5 a sign the publisher no longer honours says so and never re-enrols", contains: "does not recognise") {
            try Connect.check(config: stale, http: InProcessClient(server: r.server))
        }
        var stranger = good; stranger.publicKey = Signing.generateKeyPair().publicKeyBase64
        expectThrows("CF5 an answer not signed by this Mac's pinned key is refused", contains: "pinned key") {
            try Connect.check(config: stranger, http: InProcessClient(server: r.server))
        }
        expectThrows("CF5 an unreachable publisher is one honest sentence", contains: "could not be reached") {
            try Connect.check(config: good, http: OfflineHTTP())
        }
        expect(r.machines["cf-mac"] != nil && Connect.isSetUp(home: home),
               "CF5 a check changed nothing: same record, same setup")
    }

    // CF6. Change of address: a typed destination is only saved when it is in the Tailscale
    // range the Hub accepts and serves this Mac's own signed feed — pin, token and apps stay,
    // and every refusal leaves the settings file byte for byte as it was.
    do {
        let r = EnrolRig("cf6")
        try! r.rig.publish("demo", "1.0.0", r.rig.artifact("demo.zip", "demo-bytes"))
        let file = r.rig.root.appendingPathComponent("base/config.json")
        try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = [
            "feedURL": "http://100.64.0.9:1/release.json",
            "publicKey": r.rig.pair.publicKeyBase64,
            "stateDir": r.rig.root.appendingPathComponent("state").path,
            "machine": "cf-mac", "token": "tok-abc-0123456789",
            "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": true]],
            "intervalMinutes": 5, "once": false,
        ]
        try! JSONSerialization.data(withJSONObject: original).write(to: file)
        let client = InProcessClient(server: r.server)

        let saved = try! Connect.changeDestination(to: "100.64.0.7:8790", file: file, http: client)
        expect(saved == "http://100.64.0.7:8790/release.json", "CF6 a Tailscale address serving this Mac's signed feed is saved")
        let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        expect(after?["feedURL"] as? String == saved && after?["token"] as? String == "tok-abc-0123456789"
               && after?["publicKey"] as? String == r.rig.pair.publicKeyBase64
               && ((after?["apps"] as? [String: Any])?["updater"] as? [String: Any]) != nil,
               "CF6 only the address changes: pin, token and the apps stay exactly as they were")
        let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
        expect(mode == 0o600, "CF6 the settings file stays private (got \(String(describing: mode)))")

        let afterSuccess = try! Data(contentsOf: file)
        expectThrows("CF6 an address outside the Tailscale range is refused", contains: "100.64.0.0/10") {
            _ = try Connect.changeDestination(to: "192.168.1.9:8790", file: file, http: client)
        }
        expectThrows("CF6 a path on the typed address is refused", contains: "without a path") {
            _ = try Connect.changeDestination(to: "100.64.0.7:8790/not-the-feed", file: file, http: client)
        }
        expectThrows("CF6 an https address is refused rather than assumed", contains: "plain http") {
            _ = try Connect.changeDestination(to: "https://100.64.0.7:8790", file: file, http: client)
        }
        expectThrows("CF6 an unreachable address is one honest sentence", contains: "could not be reached") {
            _ = try Connect.changeDestination(to: "100.64.0.7:8790", file: file, http: OfflineHTTP())
        }
        expect(try! Data(contentsOf: file) == afterSuccess, "CF6 every refused address left the saved settings byte for byte as they were")
        var impostor = original
        impostor["publicKey"] = Signing.generateKeyPair().publicKeyBase64
        try! JSONSerialization.data(withJSONObject: impostor).write(to: file)
        let impostorBytes = try! Data(contentsOf: file)
        expectThrows("CF6 an address not serving this Mac's signed updates is refused: trust needs a kit, not a typed address",
                     contains: "setup kit") {
            _ = try Connect.changeDestination(to: "100.64.0.7:8790", file: file, http: client)
        }
        expect(try! Data(contentsOf: file) == impostorBytes, "CF6 the trust refusal wrote nothing either")
        try! JSONSerialization.data(withJSONObject: original).write(to: file)
        var concurrent = original
        concurrent["token"] = "fixture-fresh-connection-token"
        let concurrentBytes = try! JSONSerialization.data(withJSONObject: concurrent, options: [.sortedKeys])
        expectThrows("CF6 a connection replaced during an address check is preserved", contains: "settings changed") {
            _ = try Connect.changeDestination(to: "100.64.0.7:8790", file: file,
                http: ConcurrentConfigHTTP(inner: client, file: file, replacement: concurrentBytes))
        }
        expect(try! Data(contentsOf: file) == concurrentBytes, "CF6 saving an address never restores a superseded sign-in")
    }

    // CF7. The address grammar itself: only what the Hub's own scope allows gets through.
    do {
        expect((try? Connect.destination("100.64.0.7:8790")) == "http://100.64.0.7:8790/release.json",
               "CF7 host:port is normalised to the feed address")
        expect((try? Connect.destination("http://100.127.1.2/")) == "http://100.127.1.2/release.json",
               "CF7 the top of the Tailscale range and a trailing slash are fine")
        expect((try? Connect.destination("100.64.0.7:8790/release.json")) == "http://100.64.0.7:8790/release.json",
               "CF7 the full feed URL is accepted as typed")
        expectThrows("CF7 below the Tailscale range is refused", contains: "100.64.0.0/10") { _ = try Connect.destination("100.63.0.1") }
        expectThrows("CF7 a name is refused instead of being resolved", contains: "IPv4") { _ = try Connect.destination("update-studio.example") }
        expectThrows("CF7 a zero port is refused", contains: "port") { _ = try Connect.destination("100.64.0.7:0") }
        expectThrows("CF7 a leading-zero octet is refused", contains: "IPv4") { _ = try Connect.destination("100.064.0.7") }
        expectThrows("CF7 https is refused", contains: "plain http") { _ = try Connect.destination("https://100.64.0.7:8790") }
    }

    // CF14. Editing the first-run route never replaces the kit's pinned key.
    for scenario in ["success", "public-address", "wrong-pin"] {
        let r = EnrolRig("edited-" + scenario)
        let code = pairingCode(r)
        let k = kit(for: r)
        let home = r.rig.root.appendingPathComponent("edited-home")
        var pub = try! JSONSerialization.jsonObject(with: Data(contentsOf: k.appendingPathComponent("publisher.json"))) as! [String: Any]
        pub["feedURL"] = "http://100.64.0.8:8790/release.json"
        pub["enrolURL"] = "http://100.64.0.8:8790/enrol"
        if scenario == "wrong-pin" { pub["publicKey"] = Signing.generateKeyPair().publicKeyBase64 }
        let bytes = try! JSONSerialization.data(withJSONObject: pub)
        try! bytes.write(to: k.appendingPathComponent("publisher.json"))
        var manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: k.appendingPathComponent("MANIFEST.json"))) as! [String: Any]
        var files = manifest["files"] as! [String: Any]
        files["publisher.json"] = ["bytes": bytes.count, "sha256": Signing.sha256Hex(bytes)]
        manifest["files"] = files
        try! JSONSerialization.data(withJSONObject: manifest).write(to: k.appendingPathComponent("MANIFEST.json"))
        let client = CountingHTTP(InProcessClient(server: r.server))
        if scenario == "success" {
            let out = try? Connect.run(kit: k, home: home, machine: "edited-mac", code: code,
                destination: "100.64.0.7:8790", http: client, shell: SystemShell())
            let file = home.appendingPathComponent("Library/KHUpdater/base/config.json")
            let saved = try? JSON.decode(AgentConfig.self, from: Data(contentsOf: file))
            expect(out != nil && saved?.feedURL == "http://100.64.0.7:8790/release.json"
                   && saved?.publicKey == r.rig.pair.publicKeyBase64,
                   "CF14 edited first-run address is used and saved with the original pin")
        } else {
            expectThrows("CF14 invalid destination or different publisher cannot install", contains: scenario == "wrong-pin" ? "not signed" : "Tailscale range") {
                _ = try Connect.run(kit: k, home: home, machine: "edited-mac", code: code,
                    destination: scenario == "wrong-pin" ? "100.64.0.7:8790" : "8.8.8.8:8790",
                    http: client, shell: SystemShell())
            }
            expect(!Connect.isSetUp(home: home) && (scenario != "public-address" || client.posts == 0),
                   "CF14 public addresses send nothing and a wrong key installs nothing")
        }
    }

    // CF15. Exercise the actual bundle writer: generated and packaged Launchers share this policy.
    do {
        let r = EnrolRig("ats-plist")
        let app = r.rig.root.appendingPathComponent("Launcher.app")
        let result = try? SystemShell().run(fm.currentDirectoryPath + "/build/khu",
            arguments: ["launcher-bundle", "--out", app.path, "--version", "0.1.7", "--kit", kit(for: r).path], timeout: 30)
        let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let ats = plist?["NSAppTransportSecurity"] as? [String: Any]
        let domains = ats?["NSExceptionDomains"] as? [String: [String: Any]]
        expect(result?.exitCode == 0 && ats?.count == 1 && domains?.count == 1
               && domains?["100.64.0.0/10"]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true,
               "CF15 bundled ATS permits only tailnet HTTP without arbitrary-load or local-network bypass")
    }

    // CF9–CF13. Re-pair from saved trust only, without an embedded kit or installer.
    for scenario in ["unconfirmed", "wrong-code", "wrong-pin", "concurrent", "success"] {
        let r = EnrolRig("repair-" + scenario)
        let code = pairingCode(r)
        let file = r.rig.root.appendingPathComponent("base/config.json")
        try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var original: [String: Any] = [
            "feedURL": "http://\(r.bind):\(r.port)/release.json", "publicKey": r.rig.pair.publicKeyBase64,
            "stateDir": r.rig.root.appendingPathComponent("client-state").path,
            "machine": "repair-mac", "token": "old-fixture-token", "intervalMinutes": 60, "once": false,
            "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": false]], "extra": "preserve-me",
        ]
        if scenario == "wrong-pin" { original["publicKey"] = Signing.generateKeyPair().publicKeyBase64 }
        let before = try! JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        try! before.write(to: file)
        try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let inode = (try! fm.attributesOfItem(atPath: file.path))[.systemFileNumber] as! NSNumber
        let client = CountingHTTP(InProcessClient(server: r.server))
        if scenario == "unconfirmed" {
            expectThrows("CF9 unconfirmed recovery sends nothing", contains: "not confirmed") {
                _ = try Connect.repair(configFile: file, code: code, confirmed: false, http: client)
            }
            expectThrows("CF9 a pairing code is required even after confirmation", contains: "type the pairing code") {
                _ = try Connect.repair(configFile: file, code: " ", confirmed: true, http: client)
            }
            expect(client.posts == 0 && r.machines["repair-mac"] == nil && (try! Data(contentsOf: file)) == before,
                   "CF9 refusal before confirmation or code preserves the existing sign-in and enrols nobody")
        } else if scenario == "wrong-code" {
            expectThrows("CF10 wrong recovery code is refused", contains: "pairing code is wrong") {
                _ = try Connect.repair(configFile: file, code: code == "000000" ? "000001" : "000000", confirmed: true, http: client)
            }
            expect((try! Data(contentsOf: file)) == before && r.machines["repair-mac"] == nil,
                   "CF10 wrong code keeps the current config and creates no enrolment")
        } else if scenario == "wrong-pin" {
            expectThrows("CF11 recovery cannot adopt a different publisher key", contains: "pinned key") {
                _ = try Connect.repair(configFile: file, code: code, confirmed: true, http: client)
            }
            expect((try! Data(contentsOf: file)) == before, "CF11 signature mismatch leaves saved trust byte-for-byte intact")
        } else if scenario == "concurrent" {
            var replacement = original; replacement["token"] = "newer-local-sign-in"
            let bytes = try! JSONSerialization.data(withJSONObject: replacement, options: [.sortedKeys])
            expectThrows("CF12 concurrent recovery refuses a superseded snapshot", contains: "settings changed") {
                _ = try Connect.repair(configFile: file, code: code, confirmed: true,
                    http: ConcurrentConfigHTTP(inner: client, file: file, replacement: bytes))
            }
            expect((try! Data(contentsOf: file)) == bytes, "CF12 failed recovery never overwrites a newer sign-in")
        } else {
            expect((try? Connect.repair(configFile: file, code: code, confirmed: true, http: client)) == "repair-mac",
                   "CF13 confirmed recovery succeeds from saved config without a kit")
            let bytes = try! Data(contentsOf: file)
            let after = try! JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let token = after["token"] as! String
            var expected = original; expected["token"] = token
            expect(token != (original["token"] as? String) && r.machines["repair-mac"]?.tokenHash == Enrolment.sha256Hex(token)
                   && (try! JSONSerialization.data(withJSONObject: after, options: [.sortedKeys])) == (try! JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])),
                   "CF13 only the token changes; identity, pin, automation and unknown settings are preserved")
            let trash = r.rig.root.appendingPathComponent("_trash/repair-mac")
            let archived = (try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
            expect(archived.count == 1 && (try? Data(contentsOf: archived[0])) == before,
                   "CF13 the exact old config is restorable in this updater's _trash")
            if let archive = archived.first {
                let attrs = try! fm.attributesOfItem(atPath: archive.path)
                expect(attrs[.systemFileNumber] as? NSNumber == inode && attrs[.posixPermissions] as? Int == 0o600,
                       "CF13 the old file is moved, preserving its inode and private permissions")
            }
            expect((try! fm.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int == 0o600,
                   "CF13 renewed credentials stay private")
        }
    }

    // CF8. A regenerated Studio Launcher KH.app keeps a kit it can still verify (byte for byte —
    // no pin, key or address changes) and is signed the way packaging signs it, so the control
    // side's Save Launcher (strict codesign + manifest pins) can still export it.
    do {
        let root = tmpDir("cf8")
        let exe = root.appendingPathComponent("khu-bin")
        try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        func bundle(_ name: String, _ version: String) -> URL {
            let app = root.appendingPathComponent(name)
            let contents = app.appendingPathComponent("Contents")
            try! fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "com.khupdater.launcher", "CFBundleName": name,
                                        "CFBundleDisplayName": name, "CFBundleExecutable": "khu-bin", "CFBundlePackageType": "APPL",
                                        "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                        "LSMinimumSystemVersion": "13.0"]
            try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try! fm.copyItem(at: exe, to: contents.appendingPathComponent("MacOS/khu-bin"))
            return app
        }
        func addKit(to app: URL) -> URL {
            let k = app.appendingPathComponent("Contents/Resources/khu-agent")
            try! fm.createDirectory(at: k, withIntermediateDirectories: true)
            try! Data(#"{"feedURL":"http://100.64.0.7:8790/release.json","enrolURL":"http://100.64.0.7:8790/enrol","publicKey":"k"}"#.utf8)
                .write(to: k.appendingPathComponent("publisher.json"))
            try! Data("#!/bin/bash\n".utf8).write(to: k.appendingPathComponent("install-agent.sh"))
            var files: [String: Any] = [:]
            for name in ["publisher.json", "install-agent.sh"] {
                let data = try! Data(contentsOf: k.appendingPathComponent(name))
                files[name] = ["bytes": data.count, "sha256": Signing.sha256Hex(data)]
            }
            try! JSONSerialization.data(withJSONObject: ["files": files]).write(to: k.appendingPathComponent("MANIFEST.json"))
            return k
        }

        let old = bundle("Old.app", "0.1.4")
        let kitDir = addKit(to: old)
        let staging = bundle("New.app", "0.1.5")
        expect(Connect.carryKit(from: old, into: staging), "CF8 a verified kit is carried into the regenerated bundle")
        let carried = staging.appendingPathComponent("Contents/Resources/khu-agent")
        expect((try? Data(contentsOf: carried.appendingPathComponent("publisher.json")))
               == (try? Data(contentsOf: kitDir.appendingPathComponent("publisher.json")))
               && (try? Connect.publisher(kit: carried)) != nil,
               "CF8 the carried kit is byte-identical and still passes its manifest check")
        let verifier = CaptureShell()
        expect(Connect.packagedLauncherVerifies(staging, shell: verifier), "CF8 an intact packaged Launcher is kept")
        expect(verifier.calls == [["/usr/bin/codesign", "--verify", "--deep", "--strict", staging.path]],
               "CF8 runtime only verifies the existing bundle; no signing key or bundle rewrite")
        let refused = CaptureShell(); refused.exitCode = 1
        expect(!Connect.packagedLauncherVerifies(staging, shell: refused), "CF8 a damaged signature is not accepted")
        expect(!Connect.packagedLauncherVerifies(root.appendingPathComponent("Absent.app"), shell: verifier),
               "CF8 a missing Launcher needs the signed installer")

        let tampered = bundle("Tampered.app", "0.1.4")
        _ = addKit(to: tampered)
        try! Data("#!/bin/bash\necho changed\n".utf8).write(to: tampered.appendingPathComponent("Contents/Resources/khu-agent/install-agent.sh"))
        let staging2 = bundle("New2.app", "0.1.5")
        expect(!Connect.carryKit(from: tampered, into: staging2),
               "CF8 a kit that fails its manifest is not carried into the new bundle")

        let bare = bundle("Bare.app", "0.1.4")
        let staging3 = bundle("New3.app", "0.1.5")
        expect(!Connect.carryKit(from: bare, into: staging3),
               "CF8 a bundle with no kit simply has nothing to carry")
    }

    // CF19. A saved setup is repaired without a code: the kit's own installer rebuilds the helper
    // files and start file in its saved-setup mode, and the saved connection is never rewritten.
    // A missing saved setup, another studio's kit, a different layout, a paused Mac and a second
    // repair already running each refuse before anything runs.
    do {
        func saved(_ tag: String) -> (EnrolRig, URL, URL, URL, Data) {
            let r = EnrolRig("cf19-" + tag)
            let k = kit(for: r)
            let home = r.rig.root.appendingPathComponent("home")
            let file = home.appendingPathComponent("Library/KHUpdater/base/config.json")
            let config: [String: Any] = [
                "feedURL": "http://\(r.bind):\(r.port)/release.json",
                "publicKey": r.rig.pair.publicKeyBase64,
                "stateDir": home.appendingPathComponent("Library/KHUpdater/state").path,
                "stubBase": home.appendingPathComponent("Library/KHUpdater/base").path,
                "machine": "saved-mac", "token": "saved-fixture-token", "intervalMinutes": 60,
                "once": false, "apps": ["updater": ["bundlePath": "", "recipe": "updater", "automatic": true]],
            ]
            let bytes = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            try! fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! bytes.write(to: file)
            return (r, k, home, file, bytes)
        }

        /// Answers the disabled-state read like launchctl and records every call; the installer
        /// call alone can be made to fail.
        final class RepairShell: Shell, @unchecked Sendable {
            var calls: [[String]] = []
            var disabled = "disabled services = {\n}\n"
            var installerExit: Int32 = 0
            func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
                calls.append([executable] + arguments)
                if executable == "/bin/launchctl" { return ShellResult(exitCode: 0, stdout: disabled, stderr: "") }
                return ShellResult(exitCode: installerExit, stdout: "",
                                   stderr: installerExit == 0 ? "" : "launchctl said no")
            }
        }

        // Missing: a Mac with nothing saved has nothing to repair and runs no installer.
        do {
            let r = EnrolRig("cf19-none")
            let home = r.rig.root.appendingPathComponent("home")
            let shell = RepairShell()
            expectThrows("CF19 a Mac with no saved connection is refused before anything runs", contains: "no saved connection") {
                _ = try Connect.repairSetup(kit: kit(for: r), home: home, shell: shell)
            }
            expect(shell.calls.isEmpty, "CF19 repair with nothing saved runs no installer")
        }

        // Mismatched trust: another Update Studio's kit cannot repair this Mac.
        do {
            let (r, _, home, file, bytes) = saved("pin")
            let k = kit(for: r)
            var pub = try! JSONSerialization.jsonObject(with: Data(contentsOf: k.appendingPathComponent("publisher.json"))) as! [String: Any]
            pub["publicKey"] = Signing.generateKeyPair().publicKeyBase64
            let pubBytes = try! JSONSerialization.data(withJSONObject: pub)
            try! pubBytes.write(to: k.appendingPathComponent("publisher.json"))
            var manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: k.appendingPathComponent("MANIFEST.json"))) as! [String: Any]
            var files = manifest["files"] as! [String: Any]
            files["publisher.json"] = ["bytes": pubBytes.count, "sha256": Signing.sha256Hex(pubBytes)]
            manifest["files"] = files
            try! JSONSerialization.data(withJSONObject: manifest).write(to: k.appendingPathComponent("MANIFEST.json"))
            let shell = RepairShell()
            expectThrows("CF19 a kit for another Update Studio cannot repair this Mac", contains: "different Update Studio") {
                _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
            }
            expect(shell.calls.isEmpty && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a mismatched kit runs nothing and keeps the saved trust byte for byte")
        }

        // Paused: the person's pause is honoured, not repaired around.
        do {
            let (_, k, home, file, bytes) = saved("paused")
            let state = home.appendingPathComponent("Library/KHUpdater/state")
            try! fm.createDirectory(at: state, withIntermediateDirectories: true)
            try! HelperSettings(pausedUntil: ISO.string(Date().addingTimeInterval(3600))).save(to: state)
            let shell = RepairShell()
            let out = try? Connect.repairSetup(kit: k, home: home, shell: shell)
            expect(out?.status == "paused" && shell.calls.isEmpty && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a paused Mac reports its pause, runs nothing and keeps its settings")
        }

        // Different layout: the saved paths are this Mac's, so no other layout is written into.
        do {
            let (r, k, home, file, _) = saved("layout")
            var config = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            config["stateDir"] = r.rig.root.appendingPathComponent("elsewhere").path
            let bytes = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            try! bytes.write(to: file)
            let shell = RepairShell()
            expectThrows("CF19 a saved setup under a different layout is refused", contains: "different helper layout") {
                _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
            }
            expect(shell.calls.isEmpty && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a layout mismatch runs nothing and writes nothing")
        }

        // Valid: only the kit's own installer, in its saved-setup mode, with the exact paths.
        do {
            let (_, k, home, file, bytes) = saved("ok")
            let shell = RepairShell()
            let out = try? Connect.repairSetup(kit: k, home: home, shell: shell)
            expect(out?.status == "repaired", "CF19 a saved setup is repaired without a code")
            expect(shell.calls == [["/bin/launchctl", "print-disabled", "gui/\(getuid())"],
                                   ["/bin/bash", k.appendingPathComponent("install-agent.sh").path, file.path, home.path,
                                    "--repair-saved"]],
                   "CF19 repair confirms the disabled state, then runs only the kit's own installer in its saved-setup mode")
            expect((try! Data(contentsOf: file)) == bytes, "CF19 the saved connection is byte for byte unchanged")
        }

        // Failed installer: its own reason is shown and the saved settings stay as they were.
        do {
            let (_, k, home, file, bytes) = saved("fail")
            let shell = RepairShell(); shell.installerExit = 1
            expectThrows("CF19 a failed repair says the installer's reason", contains: "launchctl said no") {
                _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
            }
            expect((try! Data(contentsOf: file)) == bytes, "CF19 a failed repair never rewrites the saved settings")
        }

        // Settings replaced while the installer runs: the newer connection is kept, never accepted.
        do {
            final class ChangingShell: Shell, @unchecked Sendable {
                let file: URL
                init(_ file: URL) { self.file = file }
                func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
                    guard executable != "/bin/launchctl" else {
                        return ShellResult(exitCode: 0, stdout: "disabled services = {\n}\n", stderr: "")
                    }
                    try Data("{\"machine\":\"replaced\"}".utf8).write(to: file, options: .atomic)
                    return ShellResult(exitCode: 0, stdout: "", stderr: "")
                }
            }
            let (_, k, home, file, _) = saved("changed")
            expectThrows("CF19 a connection replaced during repair is never accepted", contains: "changed during repair") {
                _ = try Connect.repairSetup(kit: k, home: home, shell: ChangingShell(file))
            }
        }

        // Busy: one repair at a time; a second attempt leaves the saved setup untouched.
        do {
            let (_, k, home, file, bytes) = saved("busy")
            let shell = RepairShell()
            expectThrows("CF19 a second repair while one is running is refused", contains: "another KH Updater process") {
                _ = try FileLock.withExclusive(home.appendingPathComponent("Library/.khu-connect.lock"), wait: false) {
                    _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
                }
            }
            expect(shell.calls.isEmpty && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a busy Mac runs nothing and keeps its settings")
        }

        // Busy helper: an agent that is mid-run holds its own lock, so nothing is stopped under it.
        do {
            let (_, k, home, file, bytes) = saved("agent-busy")
            let state = home.appendingPathComponent("Library/KHUpdater/state")
            let shell = RepairShell()
            expectThrows("CF19 a helper that is mid-run is not stopped for a repair", contains: "another KH Updater process") {
                _ = try FileLock.withExclusive(state.appendingPathComponent("agent.lock"), wait: false) {
                    _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
                }
            }
            expect(shell.calls.isEmpty && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a busy helper runs nothing and keeps its settings")
        }

        // Disabled in macOS: the person's login-item choice is never repaired around.
        do {
            let (_, k, home, file, bytes) = saved("disabled")
            let shell = RepairShell()
            shell.disabled = "disabled services = {\n\t\"com.khupdater.agent\" => true\n}\n"
            expectThrows("CF19 a helper disabled in macOS is refused, not enabled", contains: "disabled in macOS") {
                _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
            }
            expect(shell.calls == [["/bin/launchctl", "print-disabled", "gui/\(getuid())"]]
                   && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a disabled helper runs no installer and keeps its settings")
        }

        // Unknown startup state: no installer runs on a guess.
        do {
            let (_, k, home, file, bytes) = saved("unknown")
            let shell = RepairShell()
            shell.disabled = "launchctl: unexpected output"
            expectThrows("CF19 an unreadable disabled state is refused", contains: "could not confirm") {
                _ = try Connect.repairSetup(kit: k, home: home, shell: shell)
            }
            expect(shell.calls.count == 1 && (try! Data(contentsOf: file)) == bytes,
                   "CF19 an unknown startup state runs no installer and writes nothing")
        }

        // An older kit never replaces a newer helper already on this Mac.
        do {
            let (_, k, home, file, bytes) = saved("older")
            try! Data("1.0.0\n".utf8).write(to: k.appendingPathComponent("VERSION"))
            let base = home.appendingPathComponent("Library/KHUpdater/base")
            let binary = base.appendingPathComponent("versions/9.0.0/khu")
            try! fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data("newer".utf8).write(to: binary)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try! fm.createSymbolicLink(atPath: base.appendingPathComponent("current").path,
                                       withDestinationPath: "versions/9.0.0/khu")
            let shell = RepairShell()
            let out = try? Connect.repairSetup(kit: k, home: home, shell: shell)
            expect(out?.status == "current" && shell.calls.isEmpty && (try! Data(contentsOf: file)) == bytes,
                   "CF19 an older kit leaves this Mac's newer helper and saved setup untouched")
        }

        // A newer verified kit still repairs an older installed helper.
        do {
            let (_, k, home, file, bytes) = saved("newer")
            try! Data("2.0.0\n".utf8).write(to: k.appendingPathComponent("VERSION"))
            let base = home.appendingPathComponent("Library/KHUpdater/base")
            let binary = base.appendingPathComponent("versions/1.0.0/khu")
            try! fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data("older".utf8).write(to: binary)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try! fm.createSymbolicLink(atPath: base.appendingPathComponent("current").path,
                                       withDestinationPath: "versions/1.0.0/khu")
            let shell = RepairShell()
            let out = try? Connect.repairSetup(kit: k, home: home, shell: shell)
            expect(out?.status == "repaired" && shell.calls.count == 2 && (try! Data(contentsOf: file)) == bytes,
                   "CF19 a newer verified kit repairs an older installed helper")
        }
    }
}
