import Foundation
import CryptoKit

/// A page server the resolver reads from: these tests never touch the network.
private struct VendorPageHTTP: HTTPClient {
    var pages: [String: (Data, Int)]
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        guard let hit = pages[url.absoluteString] else { throw khuFail("no page for \(url)") }
        return hit
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { throw khuFail("unused") }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { throw khuFail("unused") }
}

/// The other-apps vendor catalog and the trust gate in front of any install of it: wrong vendor,
/// broken signature, non-official or non-HTTPS source, hash-only "trust", an unresolved vendor, and
/// the default-off state of every optional assignment. Payloads are fake files and every helper is
/// scripted — no real vendor installer is needed here.
func vendorCatalogTests() {
    func blockedReason(_ verdict: VendorTrust.Verdict) -> String? {
        if case .blocked(let reason) = verdict { return reason }
        return nil
    }
    func judge(_ entry: VendorEntry, _ payload: String, _ shell: Shell = FakeShell()) -> String? {
        blockedReason(VendorTrust.verify(entry: entry, sourceURL: URL(string: entry.sourceURL)!, payload: payload, shell: shell))
    }

    let builtIn = VendorCatalog.builtIn
    expect(builtIn.entries.count == 6, "VC1 the six official entries are built in")
    expect(builtIn.entries.allSatisfy { !$0.enabled }, "VC2 every optional assignment is off by default")
    expect(Set(builtIn.entries.map(\.id)) == ["tailscale", "chrome", "telegram", "yam-display", "word", "excel"],
           "VC3 the six ids are the six apps")
    expect(builtIn.entries.allSatisfy { $0.sourceURL.hasPrefix("https://") && !$0.officialHosts.isEmpty },
           "VC4 every built-in source is HTTPS on a named official host")
    expect(builtIn.entries.allSatisfy { $0.teamID?.isEmpty == false && $0.teamIDEvidence?.isEmpty == false },
           "VC5 every Team ID pin carries evidence of where it came from")
    expect(builtIn.entries.filter { $0.sha256 != nil }.allSatisfy { $0.sha256Evidence?.isEmpty == false },
           "VC6 every hash pin carries the publication it came from")
    let versionPattern = try! Regex("\\d+\\.\\d+")
    expect(builtIn.entries.allSatisfy { !$0.sourceURL.contains(versionPattern) },
           "VC7 no built-in entry is pinned to a fixed version file")

    // Storage: a missing file falls back to the defaults, a hand edit survives a reload, and
    // saving the built-in catalog restores the default-off entries.
    let state = tmpDir("vendor-catalog")
    let file = VendorCatalog.url(in: state.path)
    expect((try? VendorCatalog.load(from: file)) == builtIn, "VC8 a missing catalog falls back to the built-in entries")
    try! builtIn.save(to: file)
    var edited = try! VendorCatalog.load(from: file)
    edited.entries[0].enabled = true
    try! edited.save(to: file)
    expect(try! VendorCatalog.load(from: file).entries[0].enabled, "VC9 a hand edit to the catalog survives a reload")
    try! VendorCatalog.builtIn.save(to: file)
    expect(try! VendorCatalog.load(from: file).entries.allSatisfy { !$0.enabled },
           "VC10 restoring the built-in catalog puts every assignment back off")
    let broken = state.appendingPathComponent("broken.json")
    try! "{not json".write(to: broken, atomically: true, encoding: .utf8)
    expectThrows("VC11 a corrupt catalog is loud, never silently replaced", contains: "cannot read") {
        _ = try VendorCatalog.load(from: broken)
    }

    // Off by default: refused before any helper would be asked to run.
    var chrome = builtIn.entries.first { $0.id == "chrome" }!
    let payload = "/tmp/does-not-matter.pkg"
    expect(judge(chrome, payload)?.contains("not enabled") == true,
           "VC12 an assignment left off is blocked without running anything")

    chrome.enabled = true
    var http = chrome
    http.sourceURL = "http://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
    expect(judge(http, payload)?.contains("not an official host") == true, "VC13 a non-HTTPS source is refused")
    var elsewhere = chrome
    elsewhere.sourceURL = "https://evil.example/googlechrome.dmg"
    expect(judge(elsewhere, payload)?.contains("not an official host") == true,
           "VC14 a source on any other host is refused even over HTTPS")

    // A .pkg is judged by its own installer signature: the signing leaf, Apple's chain and the
    // notary. A Team ID that appears only in some other line of the listing is not a match.
    let dir = tmpDir("vendor-payloads")
    let pkg = dir.appendingPathComponent("installer.pkg")
    try! Data("fake".utf8).write(to: pkg)
    func pkgShell(_ stdout: String, exitCode: Int32 = 0) -> FakeShell {
        FakeShell(responses: ["/usr/sbin/pkgutil --check-signature":
                                ShellResult(exitCode: exitCode, stdout: stdout, stderr: exitCode == 0 ? "" : "no signature")])
    }
    let team = chrome.teamID!
    let signedListing = """
    Package "installer.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Certificate Chain:
        1. Developer ID Installer: Google LLC (\(team))
           Expires: 2027-01-01 00:00:00 +0000
        2. Developer ID Certification Authority
        3. Apple Root CA
    """
    expect(judge(chrome, pkg.path, pkgShell(signedListing)) == nil, "VC15 a pkg signed by the pinned Team ID is trusted")
    let wrongLeaf = signedListing.replacingOccurrences(of: "Developer ID Installer: Google LLC (\(team))",
                                                       with: "Developer ID Installer: Someone Else, Inc. (WRONGTEAM1)")
    expect(judge(chrome, pkg.path, pkgShell(wrongLeaf))?.contains("different vendor") == true,
           "VC16 a pkg whose signing leaf names another vendor is refused")
    let teamElsewhere = """
    Package "installer.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Notarization: trusted by the Apple notary service
       Certificate Chain:
        1. Developer ID Installer: Someone Else, Inc. (WRONGTEAM1)
       Referenced by \(team) in a note
        2. Developer ID Certification Authority
        3. Apple Root CA
    """
    expect(judge(chrome, pkg.path, pkgShell(teamElsewhere))?.contains("different vendor") == true,
           "VC17 a Team ID in another line of the listing is not a match")
    let unnotarized = signedListing.replacingOccurrences(of: "Notarization: trusted by the Apple notary service",
                                                         with: "Notarization: no trustworthy timestamp")
    expect(judge(chrome, pkg.path, pkgShell(unnotarized))?.contains("not notarized") == true,
           "VC18 a pkg that is not notarized by Apple is refused")
    let noChain = signedListing.replacingOccurrences(of: "Apple Root CA", with: "Some Other CA")
    expect(judge(chrome, pkg.path, pkgShell(noChain))?.contains("does not reach Apple's Developer ID authority") == true,
           "VC19 a pkg whose chain does not reach Apple's Developer ID authority is refused")
    expect(judge(chrome, pkg.path, pkgShell("Package \"installer.pkg\":\n   Status: no signature", exitCode: 1))?.contains("does not verify") == true,
           "VC20 a pkg whose signature does not verify is refused")

    // A .app is judged by its seal, its Team ID, Gatekeeper's notarization verdict and its bundle id.
    let app = makeApp(dir.appendingPathComponent("Chrome.app"), version: "1.0.0", id: "com.google.Chrome")
    func appShell(verifyExit: Int32, describeExit: Int32, teamLine: String, spctlExit: Int32, spctlText: String) -> FakeShell {
        FakeShell(responses: [
            "/usr/bin/codesign --verify": ShellResult(exitCode: verifyExit, stdout: "", stderr: verifyExit == 0 ? "" : "code object is not signed at all"),
            "/usr/bin/codesign -dvv": ShellResult(exitCode: describeExit, stdout: "", stderr: describeExit == 0 ? "Identifier=com.google.Chrome\nTeamIdentifier=\(teamLine)\n" : "codesign: failed to load"),
            "/usr/sbin/spctl --assess": ShellResult(exitCode: spctlExit, stdout: spctlText, stderr: ""),
        ])
    }
    let notarized = "accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Google LLC (\(team))"
    expect(judge(chrome, app.path, appShell(verifyExit: 0, describeExit: 0, teamLine: team, spctlExit: 0, spctlText: notarized)) == nil,
           "VC21 an app whose seal verifies under the pinned Team ID and is notarized is trusted")
    expect(judge(chrome, app.path, appShell(verifyExit: 1, describeExit: 0, teamLine: team, spctlExit: 0, spctlText: notarized))?.contains("does not verify") == true,
           "VC22 an app whose seal does not verify is refused")
    expect(judge(chrome, app.path, appShell(verifyExit: 0, describeExit: 1, teamLine: team, spctlExit: 0, spctlText: notarized))?.contains("could not describe") == true,
           "VC23 an app codesign cannot describe is refused")
    expect(judge(chrome, app.path, appShell(verifyExit: 0, describeExit: 0, teamLine: "WRONGTEAM1", spctlExit: 0, spctlText: notarized))?.contains("different vendor") == true,
           "VC24 an app signed by another vendor is refused")
    expect(judge(chrome, app.path, appShell(verifyExit: 0, describeExit: 0, teamLine: team, spctlExit: 1, spctlText: "rejected\nsource=Developer ID Application"))?.contains("not accepted by Gatekeeper") == true,
           "VC25 an app Gatekeeper rejects is refused")
    expect(judge(chrome, app.path, appShell(verifyExit: 0, describeExit: 0, teamLine: team, spctlExit: 0, spctlText: "accepted\nsource=Developer ID Application"))?.contains("not notarized") == true,
           "VC26 an app that is not notarized is refused")
    var wantsWord = chrome
    wantsWord.bundleID = "com.microsoft.Word"
    expect(judge(wantsWord, app.path, appShell(verifyExit: 0, describeExit: 0, teamLine: team, spctlExit: 0, spctlText: notarized))?.contains("expected com.microsoft.Word") == true,
           "VC27 an app holding a different bundle identifier is refused")

    // Something that is neither pkg nor app cannot be judged as bytes.
    let dmg = dir.appendingPathComponent("chrome.dmg")
    try! Data("fake".utf8).write(to: dmg)
    expect(judge(chrome, dmg.path)?.contains("attach a .dmg") == true,
           "VC28 a dmg is refused here; the app inside it is what gets judged")

    let pages = VendorPageHTTP(pages: [:])
    for (id, link) in [("word", "525134"), ("excel", "525135")] {
        let entry = builtIn.entries.first { $0.id == id }!
        expect((try? VendorSource.resolve(entry, http: pages))?.absoluteString == "https://go.microsoft.com/fwlink/?linkid=" + link,
               "VC29 official individual \(id) alias is used without constructing a package URL")
    }
    var unresolved = builtIn.entries.first { $0.id == "word" }!
    unresolved.sourceKind = .unresolved
    expectThrows("VC29 unresolved source remains loud", contains: "no published installer link") {
        _ = try VendorSource.resolve(unresolved, http: pages)
    }

    // A hash is a checksum, never authorization: only a pinned Team ID with evidence can install.
    var hashOnly = chrome
    hashOnly.teamID = nil; hashOnly.teamIDEvidence = nil
    hashOnly.sha256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    hashOnly.sha256Evidence = "https://vendor.example/checksums"
    let hello = dir.appendingPathComponent("hello.bin")
    try! Data("hello".utf8).write(to: hello)
    expect(judge(hashOnly, hello.path)?.contains("checksum, not authorization") == true,
           "VC30 a hash alone never authorizes an install")
    // Beside a signature, a published hash must also match — auxiliary, on top of the signature.
    var hashBeside = chrome
    hashBeside.sha256 = String(repeating: "0", count: 64)
    hashBeside.sha256Evidence = "https://vendor.example/checksums"
    expect(judge(hashBeside, pkg.path, pkgShell(signedListing))?.contains("does not match") == true,
           "VC31 a published hash that does not match is refused even when the signature is good")
    var hashMatching = chrome
    hashMatching.sha256 = SHA256.hash(data: Data("fake".utf8)).map { String(format: "%02x", $0) }.joined()
    hashMatching.sha256Evidence = "https://vendor.example/checksums"
    expect(judge(hashMatching, pkg.path, pkgShell(signedListing)) == nil,
           "VC32 a matching published hash beside a good signature is trusted")
    expect(judge(hashBeside, pkg.path, pkgShell(signedListing.replacingOccurrences(of: "matching", with: "matching"))) != nil,
           "VC33 the mismatch blocks on its own, not by accident of another rule")

    // The source resolver: the vendor's own current link, found at download time.
    let page = """
    <a href="/app/YamDisplay2.4.7.dmg">Download Yam Display for Mac</a>
    <a href="https://other.example/thing.dmg">not ours</a>
    """
    let yamEntry = builtIn.entries.first { $0.id == "yam-display" }!
    let yamHTTP = VendorPageHTTP(pages: ["https://www.yamdisplay.com/": (Data(page.utf8), 200)])
    let resolvedYam = try! VendorSource.resolve(yamEntry, http: yamHTTP)
    expect(resolvedYam.absoluteString == "https://www.yamdisplay.com/app/YamDisplay2.4.7.dmg",
           "VC34 the vendor's page link is resolved to the vendor's own file")
    let evilHTTP = VendorPageHTTP(pages: ["https://www.yamdisplay.com/": (Data("<a href=\"https://other.example/x.dmg\">x</a>".utf8), 200)])
    expectThrows("VC35 a page link off the vendor's hosts is refused", contains: "not on an official host") {
        _ = try VendorSource.resolve(yamEntry, http: evilHTTP)
    }
    var noMatch = yamEntry
    noMatch.sourceMatch = ".zip"
    expectThrows("VC36 a page without the wanted link is refused", contains: "no link containing") {
        _ = try VendorSource.resolve(noMatch, http: yamHTTP)
    }
    var offHost = yamEntry
    offHost.sourceURL = "http://www.yamdisplay.com/"
    expectThrows("VC37 a non-HTTPS source is refused", contains: "not the official HTTPS URL") {
        _ = try VendorSource.resolve(offHost, http: yamHTTP)
    }
    let failingHTTP = VendorPageHTTP(pages: ["https://www.yamdisplay.com/": (Data(), 500)])
    expectThrows("VC38 a page that does not answer 200 is refused", contains: "answered 500") {
        _ = try VendorSource.resolve(yamEntry, http: failingHTTP)
    }
}
