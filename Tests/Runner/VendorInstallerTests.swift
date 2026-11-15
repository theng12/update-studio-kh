import Foundation

/// The other-apps installer: the gates that come before a download, the trust that comes before
/// an install, and the honest answers when something needs a person. Payloads are fake files, the
/// HTTP client is fake, and every helper is scripted — nothing here reaches the network, /Applications
/// or a real installer.

/// An HTTP client that writes bytes and reports a status; nothing leaves this Mac.
final class VendorHTTP: HTTPClient, @unchecked Sendable {
    var status = 200
    var bytes = Data("fake-payload".utf8)
    /// Refuse like the real client does when the payload is larger than the limit.
    var oversize = false
    var downloads = 0
    var lastURL: URL?
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { (Data(), status) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { (Data(), status) }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        downloads += 1
        lastURL = url
        if oversize { throw DeliveryMismatch(description: "response is larger than expected") }
        try bytes.write(to: file)
        return status
    }
}

/// A scripted helper set: the DMG mount is a folder the test prepares, `codesign` and `pkgutil`
/// are answers, `ditto` really copies. Every call is recorded, so a test can prove that no
/// installer was ever run.
final class VendorShell: Shell, @unchecked Sendable {
    let mount: URL
    var teamID = "ABCDE12345"
    var identifier = "com.example.foo"
    var pkgExit: Int32 = 0
    var pkgListing = ""
    var spctlExit: Int32 = 0
    var codesignVerifyExit: Int32 = 0
    var rejectStagedSignature = false
    var rejectSignatureAt: String?
    var detachExit: Int32 = 0
    var calls: [String] = []
    private let lock = NSLock()

    init(mount: URL) { self.mount = mount }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        let key = ([executable] + arguments).joined(separator: " ")
        lock.lock(); calls.append(key); lock.unlock()
        if executable == "/usr/bin/hdiutil" {
            if arguments.first == "attach" {
                let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": mount.path]]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            return ShellResult(exitCode: detachExit, stdout: "", stderr: "")
        }
        if executable == "/usr/bin/codesign" {
            if arguments.first == "-dvv" {
                return ShellResult(exitCode: 0, stdout: "",
                                   stderr: "Identifier=\(identifier)\nTeamIdentifier=\(teamID)\n")
            }
            if (rejectStagedSignature && arguments.last?.contains(".khu-staging") == true) || arguments.last == rejectSignatureAt {
                return ShellResult(exitCode: 1, stdout: "", stderr: "staged signature altered")
            }
            return ShellResult(exitCode: codesignVerifyExit, stdout: "",
                               stderr: codesignVerifyExit == 0 ? "" : "code object is not signed at all")
        }
        if executable == "/usr/sbin/pkgutil" {
            return ShellResult(exitCode: pkgExit, stdout: pkgListing, stderr: pkgExit == 0 ? "" : "no receipt")
        }
        if executable == "/usr/sbin/spctl" {
            // Gatekeeper's own verdict: accepted, and accepted because it is notarized.
            return ShellResult(exitCode: spctlExit, stdout: "", stderr: spctlExit == 0
                ? "accepted\nsource=Notarized Developer ID\n"
                : "rejected (the code is valid but does not seem to be an app)")
        }
        if executable == "/usr/bin/ditto" {
            return try SystemShell().run(executable, arguments: arguments, timeout: timeout)
        }
        // Nothing else may run: an installer, a privilege helper or a launcher would be a
        // regression, and the test must fail loudly rather than reach the owner's desktop.
        throw khuFail("REGRESSION: helper \(executable) was invoked during a vendor install")
    }

    var ranInstaller: Bool { calls.contains { $0.contains("installer") || $0.contains("sudo") } }

    /// A `pkgutil --check-signature` listing: Apple's chain and the notary service, and the leaf
    /// that names the signing vendor.
    static func pkgListing(team: String) -> String {
        "Status: signed by a developer certificate issued by Apple for distribution\n"
            + "Notarization: trusted by the Apple notary service\n"
            + "1. Developer ID Installer: Example, Inc. (\(team))\n"
            + "2. Developer ID Certification Authority\n"
            + "3. Apple Root CA\n"
    }
}

/// One rig: a fake DMG mount, a destination, a state directory, and the control the installer
/// drives. The control never launches anything real.
final class VendorRig {
    let root: URL, apps: URL, installed: URL, mount: URL, state: URL
    let shell: VendorShell
    var quitCalls = 0
    var launchCalls = 0
    // A vendor app has no hold endpoint, so a running one is refused before any byte.
    var running = false

    init(_ tag: String, dmgVersion: String = "1.2.3", dmgID: String = "com.example.foo", installedVersion: String? = "1.0.0") {
        root = tmpDir(tag)
        apps = root.appendingPathComponent("Applications")
        installed = apps.appendingPathComponent("Foo.app")
        try! fm.createDirectory(at: apps, withIntermediateDirectories: true)
        if let installedVersion { makeApp(installed, version: installedVersion) }
        mount = root.appendingPathComponent("Volumes/X")
        try! fm.createDirectory(at: mount, withIntermediateDirectories: true)
        makeApp(mount.appendingPathComponent("Foo.app"), version: dmgVersion, id: dmgID)
        state = root.appendingPathComponent("state")
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        shell = VendorShell(mount: mount)
    }

    var control: AppControl {
        AppControl(isRunning: { self.running },
                   quit: { self.quitCalls += 1; self.running = false; return true },
                   launch: { self.launchCalls += 1; self.running = true },
                   stopService: { true },
                   healthy: { expected in
                       self.running && (try? BundleInfo.read(self.installed.path))?.version == expected
                   },
                   healthTimeout: 0.3, pollInterval: 0.05, healthSettle: 0)
    }

    /// `officialHosts` is the vendor's own server, always `vendor.example` here; `host` is where
    /// the entry's URL points, which may be another host — and then the download is refused.
    func entry(id: String = "example-app", name: String = "Example",
               host: String = "vendor.example", scheme: String = "https",
               path: String = "/downloads/example.dmg",
               teamID: String? = "ABCDE12345", bundleID: String? = "com.example.foo",
               enabled: Bool = true) -> VendorEntry {
        VendorEntry(id: id, name: name, sourceURL: "\(scheme)://\(host)\(path)", officialHosts: ["vendor.example"],
                    bundleID: bundleID, teamID: teamID,
                    teamIDEvidence: teamID == nil ? nil : "read with codesign -dv on this Mac",
                    enabled: enabled)
    }

    /// The URL the caller resolved for the entry — the bytes come from here.
    func resolved(_ entry: VendorEntry, host: String = "vendor.example") -> URL {
        URL(string: "https://\(host)\(URL(string: entry.sourceURL)?.path ?? "")")!
    }

    func install(_ entry: VendorEntry, kind: VendorInstaller.Kind = .dmg, http: VendorHTTP,
                 byteCap: Int64 = 1 << 20, sourceURL: URL? = nil) -> VendorInstaller.Outcome {
        VendorInstaller.install(entry: entry, kind: kind, sourceURL: sourceURL ?? resolved(entry),
                                stateDir: state.path, destination: installed.path,
                                http: http, shell: shell, control: control, byteCap: byteCap)
    }

    var downloadDir: URL { state.appendingPathComponent("vendor-downloads").appendingPathComponent("example-app") }
}

func vendorInstallerTests() {
    do {
        let rig = VendorRig("vendor-running")
        rig.running = true
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(), http: http)
        expect(outcome.status == "blocked" && (outcome.reason ?? "").contains("running") && http.downloads == 0,
               "VI1b a running vendor app is refused before any byte")
    }
    do {
        // A vendor app is refused while it runs (VI1b), so an install reaches the recipe only while
        // it is closed; a closed app's health is not asserted, and nothing is rolled back falsely.
        let rig = VendorRig("vendor-closed-install")
        let outcome = rig.install(rig.entry(), http: VendorHTTP())
        expect(outcome.status == "installed" && outcome.version == "1.2.3" && marker(rig.installed) == "1.2.3",
               "VI42 a closed vendor app installs without a false rollback (\(outcome.status))")
    }
    do {
        let rig = VendorRig("vendor-final-verification")
        rig.shell.rejectSignatureAt = rig.installed.path
        let outcome = rig.install(rig.entry(), http: VendorHTTP())
        expect(outcome.status == "installed", "VI43 trust is decided on the staged copy before execution, not after promotion")
    }
    do {
        let rig = VendorRig("vendor-dmg-checksum")
        let http = VendorHTTP()
        var entry = rig.entry()
        entry.sha256 = Signing.sha256Hex(http.bytes)
        entry.sha256Evidence = "https://vendor.example/checksums"
        expect(rig.install(entry, http: http).status == "installed", "VI44 DMG checksum hashes installer bytes while signature checks the app")
        let bad = VendorRig("vendor-dmg-checksum-wrong")
        entry.sha256 = String(repeating: "0", count: 64)
        expect(bad.install(entry, http: VendorHTTP()).status == "blocked" && bad.quitCalls == 0,
               "VI45 wrong auxiliary DMG checksum refuses before touching an app")
    }
    do {
        let rig = VendorRig("vendor-detach-failure")
        rig.shell.detachExit = 1
        let outcome = rig.install(rig.entry(), http: VendorHTTP())
        expect(outcome.status == "needs_person" && outcome.reason?.contains("still mounted") == true && rig.quitCalls == 0,
               "VI46 mount cleanup failure is visible and preserves the installed app")
    }
    do {
        let rig = VendorRig("vendor-staged-signature")
        rig.shell.rejectStagedSignature = true
        let outcome = rig.install(rig.entry(), http: VendorHTTP())
        expect(outcome.status == "failed" && outcome.reason?.contains("staged vendor signature refused") == true,
               "VI40 altered staged vendor signature refuses installation")
        expect(marker(rig.installed) == "1.0.0" && rig.quitCalls == 0 && rig.launchCalls == 0,
               "VI41 staged trust failure preserves the existing app without executing payload")
    }
    // The gate comes first: an assignment left off costs one sentence and no download.
    do {
        let rig = VendorRig("off")
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(enabled: false), http: http)
        expect(outcome.status == "blocked" && outcome.reason?.contains("not enabled") == true,
               "VI1 an assignment left off is blocked")
        expect(http.downloads == 0, "VI2 nothing is downloaded while the assignment is off")
        expect(marker(rig.installed) == "1.0.0", "VI3 the installed app is untouched while the assignment is off")
    }

    // The source must be the official HTTPS URL.
    do {
        let rig = VendorRig("source")
        let plain = VendorHTTP()
        let outcome = rig.install(rig.entry(scheme: "http"), http: plain,
                                  sourceURL: URL(string: "http://vendor.example/downloads/example.dmg")!)
        expect(outcome.status == "blocked" && outcome.reason?.contains("official HTTPS") == true,
               "VI4 a non-HTTPS source is blocked before any download")
        expect(plain.downloads == 0, "VI5 a non-HTTPS source is not fetched")
        let elsewhere = VendorHTTP()
        let other = rig.install(rig.entry(host: "evil.example"), http: elsewhere,
                                sourceURL: URL(string: "https://evil.example/downloads/example.dmg")!)
        expect(other.status == "blocked" && other.reason?.contains("official host") == true,
               "VI6 a source on another host is blocked")
        expect(elsewhere.downloads == 0, "VI7 a source on another host is not fetched")
    }

    // The bytes must come from an official host even when the entry's own URL is official: a
    // resolved link that points elsewhere is refused before the fetch.
    do {
        let rig = VendorRig("offsite")
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(), http: http,
                                  sourceURL: URL(string: "https://cdn.evil.example/downloads/example.dmg")!)
        expect(outcome.status == "blocked" && outcome.reason?.contains("not an official host") == true,
               "VI30 a resolved URL on another host is blocked (got \(outcome.status): \(outcome.reason ?? ""))")
        expect(http.downloads == 0, "VI31 a resolved URL on another host is not fetched")
        expect(marker(rig.installed) == "1.0.0", "VI32 the installed app is untouched for an off-host source")
    }

    // The happy path: a trusted DMG is installed, and the version is read back off the disk.
    do {
        let rig = VendorRig("dmg-ok")
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(), http: http)
        expect(outcome.status == "installed", "VI8 a trusted DMG is installed (got \(outcome.status): \(outcome.reason ?? ""))")
        expect(outcome.version == "1.2.3", "VI9 the installed version is the one proven on disk")
        expect(marker(rig.installed) == "1.2.3", "VI10 the new bundle is at the destination")
        expect(marker(rig.state.appendingPathComponent("rollback-vendor-example-app/Foo.app")) == "1.0.0",
               "VI11 the previous bundle is kept as the rollback")
        expect(http.downloads == 1 && http.lastURL?.absoluteString == "https://vendor.example/downloads/example.dmg",
               "VI12 the payload came from the official URL")
        expect(rig.shell.ranInstaller == false, "VI13 no installer was run for an app")
    }

    // The wrong vendor is refused before anything is touched.
    do {
        let rig = VendorRig("dmg-wrong")
        rig.shell.teamID = "WRONGTEAM1"
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(), http: http)
        expect(outcome.status == "blocked" && outcome.reason?.contains("different vendor") == true,
               "VI14 a DMG signed by another vendor is blocked (got \(outcome.status): \(outcome.reason ?? ""))")
        expect(rig.quitCalls == 0 && rig.launchCalls == 0, "VI15 nothing running was touched for the wrong vendor")
        expect(marker(rig.installed) == "1.0.0", "VI16 the installed app is unchanged for the wrong vendor")
    }

    // A payload that is too large and a bad answer both leave nothing installed.
    do {
        let rig = VendorRig("oversize")
        let http = VendorHTTP()
        http.oversize = true
        let outcome = rig.install(rig.entry(), http: http)
        expect(outcome.status == "download_mismatch", "VI17 a payload over the byte cap is refused (got \(outcome.status))")
        expect(marker(rig.installed) == "1.0.0" && rig.quitCalls == 0, "VI18 an oversize payload changes nothing")
        let rig2 = VendorRig("badhttp")
        let http2 = VendorHTTP()
        http2.status = 503
        let outcome2 = rig2.install(rig2.entry(), http: http2)
        expect(outcome2.status == "download_failed" && outcome2.reason?.contains("503") == true,
               "VI19 a bad HTTP answer is reported (got \(outcome2.status))")
        expect(marker(rig2.installed) == "1.0.0" && rig2.quitCalls == 0, "VI20 a bad HTTP answer changes nothing")
    }

    // A package is judged, then handed back: it is never run and never claims to be installed.
    do {
        let rig = VendorRig("pkg")
        rig.shell.pkgListing = VendorShell.pkgListing(team: "ABCDE12345")
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(path: "/downloads/example.pkg", bundleID: nil), kind: .pkg, http: http)
        expect(outcome.status == "needs_admin", "VI21 a verified package comes back as needing an administrator (got \(outcome.status))")
        expect(outcome.version == nil, "VI22 a package is never claimed installed")
        let installerPath = outcome.installerPath
        expect(installerPath != nil && fm.fileExists(atPath: installerPath!), "VI23 the verified installer file is kept for the owner")
        expect(rig.shell.ranInstaller == false, "VI24 no installer was executed")
        expect(!rig.shell.calls.contains { $0.contains("sudo") }, "VI25 no privilege was asked for")
    }

    // A package signed by somebody else is refused, still without running anything.
    do {
        let rig = VendorRig("pkg-wrong")
        rig.shell.pkgListing = VendorShell.pkgListing(team: "WRONGTEAM1")
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(path: "/downloads/example.pkg", bundleID: nil), kind: .pkg, http: http)
        expect(outcome.status == "blocked" && outcome.reason?.contains("different vendor") == true,
               "VI26 a package signed by another vendor is blocked")
        expect(rig.shell.ranInstaller == false, "VI27 a refused package is never run")
    }

    // A different bundle already at the destination is never replaced: the owner decides which
    // one stays (Telegram from the App Store and Telegram from the vendor's DMG are two apps).
    do {
        let rig = VendorRig("collision", installedVersion: "5.0.0")
        makeApp(rig.installed, version: "5.0.0", id: "com.example.appstore")
        let http = VendorHTTP()
        let outcome = rig.install(rig.entry(), http: http)
        expect(outcome.status == "refused" && outcome.reason?.contains("different bundle") == true,
               "VI33 a different bundle at the destination is refused (got \(outcome.status): \(outcome.reason ?? ""))")
        expect(rig.quitCalls == 0 && marker(rig.installed) == "5.0.0", "VI34 the other bundle is untouched and still runs")
        expect(http.downloads == 1, "VI35 the payload was fetched but nothing was replaced")
    }

    // The owner requires signatures: a published hash alone is not enough to install.
    do {
        let rig = VendorRig("hashonly")
        var entry = rig.entry()
        entry.teamID = nil
        entry.teamIDEvidence = nil
        entry.sha256 = String(repeating: "a", count: 64)
        entry.sha256Evidence = "https://vendor.example/checksums"
        let http = VendorHTTP()
        let outcome = rig.install(entry, http: http)
        expect(outcome.status == "blocked" && outcome.reason?.contains("signature") == true,
               "VI36 a hash-only entry is refused before any download (got \(outcome.status): \(outcome.reason ?? ""))")
        expect(http.downloads == 0, "VI37 a hash-only entry is not fetched")
    }

    // The file kind carries into an order as plain data.
    do {
        let json = #"{"rawValue":"pkg"}"#.data(using: .utf8)!
        let kind = try? JSONDecoder().decode(VendorInstaller.Kind.self, from: #""pkg""#.data(using: .utf8)!)
        expect(kind == .pkg, "VI38 the kind decodes from JSON for a VendorOrder")
        let encoded = (try? JSONEncoder().encode(VendorInstaller.Kind.dmg)).flatMap { String(data: $0, encoding: .utf8) }
        expect(encoded == #""dmg""#, "VI39 the kind encodes back to JSON")
        _ = json
    }

    // The previous download is moved to `_trash`, not deleted: it stays restorable.
    do {
        let rig = VendorRig("trash")
        _ = rig.install(rig.entry(), http: VendorHTTP())
        _ = rig.install(rig.entry(), http: VendorHTTP())
        let trash = rig.state.appendingPathComponent("_trash")
        let kept = (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
        let folders = kept.flatMap { (try? fm.contentsOfDirectory(atPath: trash.appendingPathComponent($0).path)) ?? [] }
        expect(folders.contains("example-app"), "VI28 the previous download is kept in _trash (got \(folders))")
        expect(fm.fileExists(atPath: rig.downloadDir.path), "VI29 the new download has its own folder")
    }
}
