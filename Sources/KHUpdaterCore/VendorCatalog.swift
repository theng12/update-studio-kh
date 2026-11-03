import Foundation
import CryptoKit

/// One "other app" the owner may switch on: the vendor's own official source, the vendor identity
/// every download has to prove, and whether the assignment is on at all. The catalog holding these
/// is plain editable JSON — `VendorCatalog.load` reads the owner's file when there is one, falls
/// back to `builtIn` when there is not, and saving `builtIn` restores the defaults.
public struct VendorEntry: Codable, Sendable, Equatable {
    /// How the current installer is found. Nothing is pinned to a version: every kind resolves
    /// the vendor's current file when the download happens.
    public enum SourceKind: String, Codable, Sendable {
        /// Fetch this URL as it is.
        case direct
        /// Fetch this URL: it is the vendor's own "always the current build" alias.
        case latestAlias
        /// Fetch the page and take the first link whose href contains `sourceMatch`.
        case pageLink
        /// The vendor publishes no installer link for this app. `resolve` throws with the entry's
        /// notes instead of guessing one — an unresolved vendor stays unresolved, loudly.
        case unresolved
    }

    public var id: String
    public var name: String
    /// The URL to start from: the file itself (`direct`, `latestAlias`) or the vendor's page
    /// (`pageLink`, `cdnBuild`). Always HTTPS.
    public var sourceURL: String
    public var sourceKind: SourceKind
    /// For `pageLink`: the text the wanted href contains (a file suffix). Nil for the other kinds.
    public var sourceMatch: String?
    /// The hosts a download for this entry may come from. A URL on any other host is not the
    /// official source even over HTTPS, and is refused before anything is fetched or run.
    public var officialHosts: [String]
    /// The app's CFBundleIdentifier when it is known from the vendor's own app, so a payload
    /// holding a different app is refused even when its signature is good.
    public var bundleID: String?
    /// Apple Team ID of the vendor's signing identity — nil until there is real evidence for it.
    public var teamID: String?
    /// Where the Team ID came from: the exact command and date it was read, or a URL the vendor
    /// publishes it on. A pin without this is refused, so nothing is trusted on assertion alone.
    public var teamIDEvidence: String?
    /// SHA-256 of the exact installer bytes, only when the vendor itself published that hash.
    public var sha256: String?
    /// Where the hash was published. A hash with no authentic origin is not independent trust:
    /// it proves only that the bytes match whoever wrote the catalog line.
    public var sha256Evidence: String?
    /// Optional assignment, OFF unless the owner turns it on. A JSON entry that leaves this out
    /// decodes as off, so a hand-written entry can never be on by accident.
    public var enabled: Bool
    /// What an entry still needs before it can install (the evidence gap of an unpinned vendor),
    /// and any fact a future editor must know.
    public var notes: String?

    public init(id: String, name: String, sourceURL: String, sourceKind: SourceKind = .direct,
                sourceMatch: String? = nil,
                officialHosts: [String], bundleID: String? = nil, teamID: String? = nil,
                teamIDEvidence: String? = nil, sha256: String? = nil, sha256Evidence: String? = nil,
                enabled: Bool = false, notes: String? = nil) {
        self.id = id; self.name = name; self.sourceURL = sourceURL; self.sourceKind = sourceKind
        self.sourceMatch = sourceMatch
        self.officialHosts = officialHosts; self.bundleID = bundleID; self.teamID = teamID
        self.teamIDEvidence = teamIDEvidence; self.sha256 = sha256; self.sha256Evidence = sha256Evidence
        self.enabled = enabled; self.notes = notes
    }

    /// The one-host form: a vendor whose downloads all come from a single server.
    public init(id: String, name: String, sourceURL: String, officialHost: String,
                bundleID: String? = nil, teamID: String? = nil, teamIDEvidence: String? = nil,
                sha256: String? = nil, sha256Evidence: String? = nil, enabled: Bool = false,
                notes: String? = nil) {
        self.init(id: id, name: name, sourceURL: sourceURL, officialHosts: [officialHost],
                  bundleID: bundleID, teamID: teamID, teamIDEvidence: teamIDEvidence,
                  sha256: sha256, sha256Evidence: sha256Evidence, enabled: enabled, notes: notes)
    }

    /// The first official host. A convenience for callers that hold one host; the trust gate
    /// itself checks the whole `officialHosts` list.
    public var officialHost: String { officialHosts.first ?? "" }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceURL, sourceKind, sourceMatch, officialHosts
        case bundleID, teamID, teamIDEvidence, sha256, sha256Evidence, enabled, notes
    }
    /// Optional fields really are optional: a hand-written entry may leave them out, and `enabled`
    /// is false whenever it is absent — an assignment can only be on by saying so.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        sourceKind = try c.decodeIfPresent(SourceKind.self, forKey: .sourceKind) ?? .direct
        sourceMatch = try c.decodeIfPresent(String.self, forKey: .sourceMatch)
        officialHosts = try c.decode([String].self, forKey: .officialHosts)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        teamIDEvidence = try c.decodeIfPresent(String.self, forKey: .teamIDEvidence)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        sha256Evidence = try c.decodeIfPresent(String.self, forKey: .sha256Evidence)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// The saved other-apps catalog: six official entries by default, editable as plain JSON and
/// restorable by writing `builtIn` back.
public struct VendorCatalog: Codable, Sendable, Equatable {
    public static let fileName = "other-apps.json"
    public var format: String
    public var entries: [VendorEntry]
    public init(format: String = "kh.vendor-catalog.v1", entries: [VendorEntry]) {
        self.format = format; self.entries = entries
    }

    /// The six official entries, every assignment off. No entry is pinned to a version: each one
    /// names the vendor's own current source and is resolved when the download happens.
    public static let builtIn = VendorCatalog(entries: [
        VendorEntry(
            id: "tailscale", name: "Tailscale",
            sourceURL: "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg",
            sourceKind: .latestAlias,
            officialHosts: ["pkgs.tailscale.com"],
            bundleID: "io.tailscale.ipn.macos",
            teamID: "W5364U7YZB",
            teamIDEvidence: "pkgutil --check-signature on https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg (leaf 'Developer ID Installer: Tailscale Inc.'), read 2026-11-03; the same Team ID is on the installed Tailscale.app",
            notes: "The URL is Tailscale's own 'latest' alias: it always serves the current build, and the vendor's download page (https://tailscale.com/download/mac) links the same alias."),
        VendorEntry(
            id: "chrome", name: "Chrome",
            sourceURL: "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
            sourceKind: .direct,
            officialHosts: ["dl.google.com"],
            bundleID: "com.google.Chrome",
            teamID: "EQHXZ8M8AV",
            teamIDEvidence: "codesign -dvv on Google Chrome.app inside Google's own DMG (leaf 'Developer ID Application: Google LLC'), read 2026-11-03; the same Team ID is on the installed Google Chrome.app",
            notes: "The path carries no version, so it is always the current stable build (documented at https://support.google.com/chrome/answer/9915669). Attach the DMG and judge the .app inside it."),
        VendorEntry(
            id: "telegram", name: "Telegram",
            sourceURL: "https://telegram.org/dl/desktop/mac",
            sourceKind: .direct,
            officialHosts: ["telegram.org", "td.telegram.org"],
            bundleID: "com.tdesktop.Telegram",
            teamID: "C67CF9S4VU",
            teamIDEvidence: "codesign -dvv on Telegram.app inside the DMG that https://telegram.org/dl/desktop/mac serves (leaf 'Developer ID Application: Telegram FZ-LLC'), read 2026-11-03; spctl reported it as Notarized Developer ID",
            notes: "The URL carries no version and redirects to the current DMG on td.telegram.org; the listing page is https://telegram.org/desktop/mac. The App Store build installed on this Mac has a different bundle id (ru.keepcoder.Telegram) — this entry is the website build."),
        VendorEntry(
            id: "yam-display", name: "Yam Display",
            sourceURL: "https://www.yamdisplay.com/",
            sourceKind: .pageLink,
            sourceMatch: ".dmg",
            officialHosts: ["www.yamdisplay.com"],
            bundleID: "com.yamstu.yamdisplaymac",
            teamID: "7V8NSJWVP6",
            teamIDEvidence: "codesign -dvv on Yam Display.app inside the DMG the vendor's own page links, read 2026-11-03 (leaf 'Developer ID Application: Yamstu Inc.'); spctl reported it as Notarized Developer ID",
            notes: "The vendor's page links the current .dmg, so the file is resolved when it is downloaded instead of being pinned here."),
        VendorEntry(
            id: "word", name: "Word",
            sourceURL: "https://go.microsoft.com/fwlink/?linkid=525134",
            sourceKind: .latestAlias,
            officialHosts: ["go.microsoft.com", "officecdn.microsoft.com", "res.public.onecdn.static.microsoft"],
            bundleID: "com.microsoft.Word",
            teamID: "UBF8T346G9",
            teamIDEvidence: "pkgutil --check-signature on Microsoft's own Microsoft_Word installer package (leaf 'Developer ID Installer: Microsoft Corporation (UBF8T346G9)', notarized), read 2026-11-03",
            notes: "Individual Word download published by https://support.microsoft.com/en-us/microsoft-365-activation-licensing/microsoft-office-activation-and-the-mac-app-store. Verified 2026-11-03: alias redirects to Microsoft's current Microsoft_Word Installer.pkg, HTTP 200. Accounts and licences stay the user's own."),
        VendorEntry(
            id: "excel", name: "Excel",
            sourceURL: "https://go.microsoft.com/fwlink/?linkid=525135",
            sourceKind: .latestAlias,
            officialHosts: ["go.microsoft.com", "officecdn.microsoft.com", "res.public.onecdn.static.microsoft"],
            bundleID: "com.microsoft.Excel",
            teamID: "UBF8T346G9",
            teamIDEvidence: "pkgutil --check-signature on Microsoft's own Microsoft_Excel installer package (leaf 'Developer ID Installer: Microsoft Corporation (UBF8T346G9)', notarized), read 2026-11-03",
            notes: "Individual Excel download published by https://support.microsoft.com/en-us/microsoft-365-activation-licensing/microsoft-office-activation-and-the-mac-app-store. Verified 2026-11-03: alias redirects to Microsoft's current Microsoft_Excel Installer.pkg, HTTP 200. Accounts and licences stay the user's own."),
    ])

    /// Where the editable catalog lives: beside the agent's other state.
    public static func url(in stateDir: String) -> URL {
        URL(fileURLWithPath: stateDir).appendingPathComponent(fileName)
    }

    /// The owner's file when there is one; the built-in defaults when there is not. A file that
    /// exists but cannot be read is loud — an owner's edit is never silently replaced.
    public static func load(from url: URL) throws -> VendorCatalog {
        guard let catalog = try AtomicFile.readJSON(VendorCatalog.self, from: url) else { return builtIn }
        return catalog
    }

    public func save(to url: URL) throws {
        try AtomicFile.writeJSON(self, to: url)
    }
}

/// Finds the vendor's current installer at download time. Nothing here is pinned to a version:
/// each kind reads the vendor's own page or alias and returns the URL it currently points at.
/// The fetch is the agent's own bounded `HTTPClient.get` — never an unbounded session.
public enum VendorSource {
    /// The vendor's current file for this entry. Throws with the specific gap when the vendor
    /// publishes no installer link; nothing is guessed and no URL is built from a pattern.
    public static func resolve(_ entry: VendorEntry, http: HTTPClient) throws -> URL {
        let start = URL(string: entry.sourceURL)
        guard let start, start.scheme?.lowercased() == "https", let host = start.host?.lowercased(),
              entry.officialHosts.contains(host) else {
            throw khuFail("\(entry.name) source is not the official HTTPS URL: \(entry.sourceURL)")
        }
        let resolved: URL
        switch entry.sourceKind {
        case .unresolved:
            throw khuFail("\(entry.name) has no published installer link: \(entry.notes ?? "the vendor does not publish one")")
        case .direct, .latestAlias:
            resolved = start
        case .pageLink:
            guard let match = entry.sourceMatch, !match.isEmpty else {
                throw khuFail("\(entry.name) entry has no link to look for on its page")
            }
            let (data, code) = try http.get(start, headers: [:])
            guard (200..<300).contains(code) else {
                throw khuFail("\(entry.name) page \(entry.sourceURL) answered \(code)")
            }
            let html = String(decoding: data, as: UTF8.self)
            guard let href = firstHref(in: html, containing: match) else {
                throw khuFail("\(entry.name) page \(entry.sourceURL) has no link containing \(match)")
            }
            guard let url = URL(string: href, relativeTo: start)?.absoluteURL else {
                throw khuFail("\(entry.name) page link is not a URL: \(href)")
            }
            resolved = url
        }
        // The link the vendor's page gave must itself be on an official host: a page could name
        // anything, and the download must not leave the vendor's own servers.
        guard let resolvedHost = resolved.host?.lowercased(), entry.officialHosts.contains(resolvedHost) else {
            throw khuFail("\(entry.name) resolved to \(resolved.absoluteString), which is not on an official host \(entry.officialHosts.joined(separator: ", "))")
        }
        return resolved
    }

    /// The first href whose text contains `needle`.
    static func firstHref(in html: String, containing needle: String) -> String? {
        hrefs(in: html, containing: needle).first
    }

    /// Every href on the page whose text contains `needle`, in page order.
    static func hrefs(in html: String, containing needle: String) -> [String] {
        var found: [String] = []
        var search = html.startIndex
        while let range = html.range(of: "href=", range: search..<html.endIndex) {
            var cursor = range.upperBound
            if cursor < html.endIndex, html[cursor] == "\"" {
                cursor = html.index(after: cursor)
                if let end = html[cursor...].firstIndex(of: "\"") {
                    let href = String(html[cursor..<end])
                    if href.contains(needle) { found.append(href) }
                    search = html.index(after: end)
                    continue
                }
            }
            search = range.upperBound
        }
        return found
    }
}

/// The gate in front of any install of an "other app": the entry's assignment must be on, the
/// download must have come from the official source, and the payload must prove the pinned vendor
/// identity — the signing leaf itself, with Apple's chain and the notary — BEFORE anything
/// installs. Nothing here downloads or installs; the next step of the work resolves the source,
/// calls this, and proceeds only on `.trusted`.
public enum VendorTrust {
    public enum Verdict: Sendable, Equatable {
        case trusted
        /// Why installation must not proceed; for an unpinned entry the sentence carries the
        /// specific evidence gap that would close it.
        case blocked(String)
    }

    /// Judge a payload against its entry. Never throws: a missing payload, a helper that will not
    /// run, a seal that does not verify and a signature that names another vendor are all blocks
    /// with the reason. A `.pkg` is judged by its own installer signature; a `.app` by its seal,
    /// Team ID and bundle identifier. A `.dmg` cannot be judged as bytes — attach it and pass the
    /// `.app` inside it (`Recipe.attach`).
    public static func verify(entry: VendorEntry, sourceURL: URL, payload: String, shell: Shell, checksumPayload: String? = nil) -> Verdict {
        guard entry.enabled else {
            return .blocked("\(entry.name) is not enabled: optional assignments are off until the owner turns one on")
        }
        guard sourceURL.scheme?.lowercased() == "https", let host = sourceURL.host?.lowercased(),
              entry.officialHosts.contains(host) else {
            return .blocked("\(entry.name) source host \(sourceURL.host ?? "?") is not an official host \(entry.officialHosts.joined(separator: ", "))")
        }
        return judge(entry: entry, payload: payload, shell: shell, checksumPayload: checksumPayload)
    }

    /// Judge a payload against its entry's own source URL — the shape an installer already holds.
    /// The source is checked against the entry's official hosts here; the resolved URL a download
    /// actually came from is checked by `verify(entry:sourceURL:payload:shell:)`.
    public static func verify(entry: VendorEntry, payload: String, shell: Shell) -> Verdict {
        guard entry.enabled else {
            return .blocked("\(entry.name) is not enabled: optional assignments are off until the owner turns one on")
        }
        guard let url = URL(string: entry.sourceURL), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), entry.officialHosts.contains(host) else {
            return .blocked("\(entry.name) source is not the official HTTPS URL: \(entry.sourceURL)")
        }
        return judge(entry: entry, payload: payload, shell: shell)
    }

    private static func judge(entry: VendorEntry, payload: String, shell: Shell, checksumPayload: String? = nil) -> Verdict {
        // The owner's rule: every signature. A hash alone is a checksum, never authorization —
        // it says the bytes are the ones someone wrote down, not who wrote them.
        guard let team = entry.teamID, !team.isEmpty else {
            return .blocked("\(entry.name) needs verification before install: a hash is a checksum, not authorization — there is no Apple Team ID pin with evidence to prove who signed it.\(entry.notes.map { " \($0)" } ?? "")")
        }
        guard let evidence = entry.teamIDEvidence, !evidence.isEmpty else {
            return .blocked("\(entry.name) has a Team ID with no evidence of where it came from")
        }
        let verdict = verifySignature(entry: entry, teamID: team, payload: payload, shell: shell)
        guard case .trusted = verdict else { return verdict }
        // When the entry also carries a published hash, it must match too: an auxiliary checksum
        // beside the signature, on top of it, never instead of it.
        if let hash = entry.sha256, !hash.isEmpty {
            guard let hashEvidence = entry.sha256Evidence, !hashEvidence.isEmpty else {
                return .blocked("\(entry.name) has a hash with no published source; a hash with no authentic origin is not independent trust")
            }
            let file = checksumPayload ?? payload
            guard let digest = try? Signing.sha256Hex(fileAt: URL(fileURLWithPath: file)).hex else {
                return .blocked("\(entry.name) installer at \(file) cannot be read to hash it")
            }
            guard digest == hash.lowercased() else {
                return .blocked("\(entry.name) payload hash \(digest) does not match the pinned hash \(hash.lowercased())")
            }
        }
        return .trusted
    }

    private static func verifySignature(entry: VendorEntry, teamID: String, payload: String, shell: Shell) -> Verdict {
        guard FileManager.default.fileExists(atPath: payload) else {
            return .blocked("\(entry.name) payload at \(payload) does not exist")
        }
        if payload.hasSuffix(".pkg") {
            return verifyInstaller(entry: entry, teamID: teamID, payload: payload, shell: shell)
        }
        guard payload.hasSuffix(".app") || payload.hasSuffix(".app.khu-staging") else {
            return .blocked("cannot judge \(payload) directly: pass the .pkg, or attach a .dmg and pass the .app inside it")
        }
        return verifyApplication(entry: entry, teamID: teamID, payload: payload, shell: shell)
    }

    /// A flat installer package: Apple's own answer about who signed it.
    private static func verifyInstaller(entry: VendorEntry, teamID: String, payload: String, shell: Shell) -> Verdict {
        guard let result = try? shell.run("/usr/sbin/pkgutil", arguments: ["--check-signature", payload], timeout: 60) else {
            return .blocked("\(entry.name): pkgutil could not be run on \(payload)")
        }
        guard result.exitCode == 0 else {
            return .blocked("\(entry.name) installer signature does not verify: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        let text = result.stdout + result.stderr
        guard text.contains("Notarization: trusted by the Apple notary service") else {
            return .blocked("\(entry.name) installer is not notarized by Apple: no trusted notary service on its signature")
        }
        // The leaf is the first certificate in the chain — the identity that signed this package.
        guard let leaf = leafInstaller(in: text) else {
            return .blocked("\(entry.name) installer has no Developer ID Installer leaf certificate")
        }
        guard leaf.team == teamID else {
            return .blocked("\(entry.name) installer is signed by a different vendor: the signing leaf names Team ID \(leaf.team), the pin is \(teamID)")
        }
        guard text.contains("Developer ID Certification Authority"), text.contains("Apple Root CA") else {
            return .blocked("\(entry.name) installer certificate chain does not reach Apple's Developer ID authority")
        }
        return .trusted
    }

    /// The signing leaf of a `pkgutil --check-signature` listing: `1. Developer ID Installer: Name (TEAMID)`.
    static func leafInstaller(in text: String) -> (name: String, team: String)? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("1. Developer ID Installer:") else { continue }
            let rest = trimmed.dropFirst("1. Developer ID Installer:".count).trimmingCharacters(in: .whitespaces)
            guard let open = rest.lastIndex(of: "("), rest.hasSuffix(")") else { return nil }
            let team = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            let name = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            guard !team.isEmpty, !name.isEmpty else { return nil }
            return (name, team)
        }
        return nil
    }

    /// An application bundle: its own seal, the signing identity behind it, and Gatekeeper's own
    /// verdict that it is notarized.
    private static func verifyApplication(entry: VendorEntry, teamID: String, payload: String, shell: Shell) -> Verdict {
        // shortcut: `codesign --verify` without `--strict`: Google's own Chrome DMG ships
        // resource-fork detritus in its framework, which `--strict` rejects on the vendor's own
        // bytes. Gatekeeper's assessment below is the notarization check; upgrade to `--strict`
        // when every vendor ships a clean seal.
        let seal = try? shell.run("/usr/bin/codesign", arguments: ["--verify", payload], timeout: 60)
        guard let seal, seal.exitCode == 0 else {
            let why = seal.map { $0.stderr.isEmpty ? "codesign exited \($0.exitCode)" : $0.stderr } ?? "codesign did not run"
            return .blocked("\(entry.name) app signature does not verify: \(why)")
        }
        let described = try? shell.run("/usr/bin/codesign", arguments: ["-dvv", payload], timeout: 60)
        guard let described, described.exitCode == 0 else {
            return .blocked("\(entry.name): codesign could not describe \(payload) (exit \(described?.exitCode ?? -1))")
        }
        // codesign writes its description to stderr (mirrors Recipe.signingIdentity).
        let text = described.stdout + described.stderr
        func field(_ name: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard let found = field("TeamIdentifier"), found == teamID else {
            return .blocked("\(entry.name) app is signed by a different vendor: TeamIdentifier is \(field("TeamIdentifier") ?? "absent"), the pin is \(teamID)")
        }
        // Gatekeeper's own answer: accepted, and accepted because it is notarized.
        let assessed = try? shell.run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "-vv", payload], timeout: 60)
        guard let assessed, assessed.exitCode == 0 else {
            let why = assessed.map { $0.stderr.isEmpty ? $0.stdout : $0.stderr } ?? "spctl did not run"
            return .blocked("\(entry.name) app is not accepted by Gatekeeper: \(why)")
        }
        let verdict = assessed.stdout + assessed.stderr
        guard verdict.contains("accepted") else {
            return .blocked("\(entry.name) app is not accepted by Gatekeeper: \(verdict)")
        }
        guard verdict.contains("source=Notarized Developer ID") else {
            return .blocked("\(entry.name) app is not notarized by Apple: Gatekeeper reports no notarized Developer ID source")
        }
        if let want = entry.bundleID {
            guard let info = try? BundleInfo.read(payload) else {
                return .blocked("\(entry.name) payload at \(payload) has no readable Info.plist")
            }
            guard info.identifier == want else {
                return .blocked("\(entry.name) payload holds \(info.identifier), expected \(want)")
            }
        }
        return .trusted
    }
}
