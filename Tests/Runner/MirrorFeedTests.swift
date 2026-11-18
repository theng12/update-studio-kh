import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// A one-route HTTP server: `/start…` answers 302 to `/final…`, which serves the bytes. The real
/// client is driven against it, so the redirect decision is exercised by the code that makes it.
private final class RedirectFixture: @unchecked Sendable {
    let fd: Int32
    let port: Int
    let bytes: Data
    private let lock = NSLock()
    private var seen: [String] = []
    var hits: [String] { lock.lock(); defer { lock.unlock() }; return seen }

    init(bytes: Data) throws {
        self.bytes = bytes
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw khuFail("socket failed") }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(sock, 8) == 0 else { close(sock); throw khuFail("fixture listen failed") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        fd = sock
        port = Int(UInt16(bigEndian: actual.sin_port))
        Thread.detachNewThread { self.serve() }
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { close(client); continue }
            let head = String(decoding: buffer.prefix(count), as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.lock(); seen.append(path); lock.unlock()
            let out: Data
            if path.hasPrefix("/final/") {
                out = Data("HTTP/1.1 200 OK\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
            } else {
                out = Data("HTTP/1.1 302 Found\r\nLocation: /final/artifact.dmg\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            out.withUnsafeBytes { _ = write(client, $0.baseAddress, out.count) }
            close(client)
        }
    }

    func stop() { close(fd) }
}

/// Records where an artifact was fetched from and serves the bytes it was given.
private final class MirrorHTTP: HTTPClient, @unchecked Sendable {
    var requested: [URL] = []
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { (Data(), 404) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) { (Data(), 404) }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        requested.append(url)
        try bytes.write(to: file)
        return 200
    }
}

func mirrorFeedTests() {
    // MF1. The rule the artifact fetch relies on: an unauthenticated HTTPS request may follow a
    // redirect anywhere (GitHub answers 302 to objects.githubusercontent.com); one that carried
    // the token, or a vendor request bounded to its official hosts, still may not.
    do {
        let destination = URL(string: "https://objects.githubusercontent.com/asset/1")!
        var anonymous = URLRequest(url: URL(string: "https://github.com/theng12/kh-releases/releases/download/app-1.0.0/app.dmg")!)
        expect(URLSessionHTTPClient.allowsRedirect(original: anonymous, destination: destination, officialHosts: nil),
               "MF1 an unauthenticated artifact request follows an HTTPS redirect to any host")
        anonymous.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        expect(!URLSessionHTTPClient.allowsRedirect(original: anonymous, destination: destination, officialHosts: nil),
               "MF1 an authenticated request never follows a redirect")
        let vendor = URLRequest(url: URL(string: "https://vendor.example/a.dmg")!)
        expect(!URLSessionHTTPClient.allowsRedirect(original: vendor, destination: destination, officialHosts: ["vendor.example"]),
               "MF1 a vendor request stays on its official hosts")
    }

    // MF2. Validation: an absolute https address with no sign-in detail is the only form accepted.
    do {
        func entry(_ url: String?) -> FeedApp {
            var app = FeedApp(version: "1.0.0", file: "a.dmg", sha256: String(repeating: "a", count: 64),
                              bytes: 10, kind: "fake-for-tests")
            app.url = url
            return app
        }
        func feed(_ app: FeedApp) -> Feed { Feed(published_at: ISO.string(Date()), apps: ["demo": app]) }
        expect((try? feed(entry("https://github.com/theng12/kh-releases/releases/download/demo-1.0.0/a.dmg")).validated()) != nil,
               "MF2 an absolute https artifact address is accepted")
        expect((try? feed(entry(nil)).validated()) != nil, "MF2 an entry without an address is unchanged")
        for bad in ["http://example.com/a.dmg", "artifacts/a.dmg", "file:///tmp/a.dmg",
                    "https://user:pw@example.com/a.dmg"] {
            expectThrows("MF2 \(bad) is refused", contains: "absolute https") { _ = try feed(entry(bad)).validated() }
        }
    }

    // MF3. An entry without an address is fetched exactly as before; one with an address is fetched
    // from it — the same code path the agent's install uses.
    do {
        let bytes = Data((0..<20_000).map { UInt8($0 % 251) })
        let sha = Signing.sha256Hex(bytes)
        var entry = FeedApp(version: "2.0.0", file: "demo.dmg", sha256: sha, bytes: Int64(bytes.count), kind: "fake-for-tests")
        let base = URL(string: "http://100.64.0.1:8790")!
        expect(entry.location(beside: base).absoluteString == "http://100.64.0.1:8790/artifacts/demo.dmg",
               "MF3 an entry without an address keeps today's relative path")

        let old = MirrorHTTP(bytes: bytes)
        let oldDir = tmpDir("mirror-url-none")
        _ = try? Agent.download(entry, app: "demo", serverBase: base, stateDir: oldDir, http: old)
        expect(old.requested == [URL(string: "http://100.64.0.1:8790/artifacts/demo.dmg")!],
               "MF3 the download asks the publisher's own artifacts path")

        entry.url = "https://github.com/theng12/kh-releases/releases/download/demo-2.0.0/demo.dmg"
        let mirror = MirrorHTTP(bytes: bytes)
        let mirrorDir = tmpDir("mirror-url-set")
        let artifact = try? Agent.download(entry, app: "demo", serverBase: base, stateDir: mirrorDir, http: mirror)
        expect(mirror.requested == [URL(string: entry.url!)!] && artifact != nil
               && (try? Data(contentsOf: artifact!)) == bytes,
               "MF3 the download uses the entry's own absolute address and verifies the signed bytes")
    }

    // MF4. The real client against a local fixture that answers 302: the download follows it and
    // keeps the signed size and hash check. (This proves the local path, not a live GitHub 302.)
    do {
        let bytes = Data((0..<40_000).map { UInt8($0 % 241) })
        do {
            let fixture = try RedirectFixture(bytes: bytes)
            defer { fixture.stop() }
            let part = tmpDir("mirror-redirect").appendingPathComponent("artifact.part")
            let code = try URLSessionHTTPClient().download(URL(string: "http://127.0.0.1:\(fixture.port)/start/artifact.dmg")!,
                                                           headers: [:], to: part, limit: Int64(bytes.count))
            expect(code == 200 && (try? Data(contentsOf: part)) == bytes && fixture.hits.count == 2,
                   "MF4 an unauthenticated artifact download follows a 302 and lands the signed bytes")
            let refused = tmpDir("mirror-redirect-auth").appendingPathComponent("artifact.part")
            var why = ""
            do {
                _ = try URLSessionHTTPClient().download(URL(string: "http://127.0.0.1:\(fixture.port)/start/artifact.dmg")!,
                                                        headers: ["Authorization": "Bearer fixture-token"],
                                                        to: refused, limit: Int64(bytes.count))
            } catch { why = "\(error)" }
            expect(why.contains("redirect refused") && fixture.hits == ["/start/artifact.dmg", "/final/artifact.dmg", "/start/artifact.dmg"],
                   "MF4 an authenticated download refuses the redirect instead of following it")
        } catch { expect(false, "MF4 fixture: \(error)") }
    }

    // MF5. Two feeds naming the same artifacts at the same published_at are equivalent whatever
    // their URLs or network block say; a different artifact is still refused, by name.
    do {
        let key = Curve25519.Signing.PrivateKey()
        let at = Date()
        let root = tmpDir("mirror-identity")
        let config = AgentConfig(feedURL: "http://100.64.0.1:8790/release.json",
                                 publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                 stateDir: root.appendingPathComponent("state").path, machine: "mirror-mac", token: "fixture-token")
        func signed(_ feed: Feed) throws -> Data {
            let body = JSON.encode(feed)
            return JSON.encode(Release(feed: body, signature: try Signing.sign(body, with: key)))
        }
        let sha = String(repeating: "b", count: 64)
        var plain = Feed(published_at: ISO.string(at),
                         apps: ["demo": FeedApp(version: "1.0.0", file: "demo.dmg", sha256: sha, bytes: 10, kind: "fake-for-tests")])
        var mirrored = plain
        mirrored.apps["demo"]?.url = "https://github.com/theng12/kh-releases/releases/download/demo-1.0.0/demo.dmg"
        mirrored.network = FeedNetwork()

        var memory = AgentMemory()
        expect((try? Agent.checkedFeed(try signed(plain), config: config, memory: &memory, now: at)) != nil,
               "MF5 the first feed is accepted")
        let checked = try? Agent.checkFeed(try signed(mirrored), config: config, memory: &memory, now: at)
        expect(checked?.feed.apps["demo"]?.url != nil,
               "MF5 the mirrored feed counts as the same release at the same published_at")
        expect(checked?.note?.contains("different packaging") == true,
               "MF5 the run note says the two feeds differ only in packaging")

        var different = plain
        different.apps["demo"]?.sha256 = String(repeating: "c", count: 64)
        expectThrows("MF5 a different artifact at the same published_at is refused",
                     contains: "different artifact identity") {
            _ = try Agent.checkedFeed(try signed(different), config: config, memory: &memory, now: at)
        }
    }

    // MF6. An open enrolment window enrols a NEW Mac and never replaces one already enrolled.
    do {
        let r = EnrolRig("mirror-enrol")
        let real = try! Enrolment.enrol(stateDir: r.rig.state, machine: "mac1")
        let hash = r.machines["mac1"]?.tokenHash
        r.openWindow(30)
        let take = enrolPost(r.server, machine: "mac1", nonce: enrolNonce())
        expect(take.status == 409 && r.machines["mac1"]?.tokenHash == hash,
               "MF6 an open window cannot replace an existing machine record (\(take.status))")
        expect(enrolStatusPost(r.server, machine: "mac1", token: real, body: ["machine": "mac1"]).status == 200,
               "MF6 the enrolled Mac's own token is untouched")
        expect(enrolPost(r.server, machine: "mac9", nonce: enrolNonce()).status == 200 && r.machines["mac9"] != nil,
               "MF6 the same window still takes a genuinely new Mac")
        // The pairing code remains the one way to reclaim a name.
        try? Enrolment.ensurePairingCode(stateDir: r.rig.state)
        if let code = (try? StateStore.load(from: r.rig.state))?.pairing?.code {
            let body = try! JSONSerialization.data(withJSONObject: ["machine": "mac1", "nonce": enrolNonce(), "code": code])
            let reclaim = r.server.handleRequest(HTTPRequest(method: "POST", path: "/enrol",
                                                             headers: ["content-type": "application/json"], body: body),
                                                 remote: "100.64.0.9")
            expect(reclaim.status == 200, "MF6 the pairing code still reclaims an enrolled Mac")
        } else { expect(false, "MF6 no pairing code on record") }
    }

    // MF7. 0.0.0.0 is never a hosting address, and the role is validated when serving starts too.
    do {
        expectThrows("MF7 0.0.0.0 cannot be resolved as a bind address", contains: "0.0.0.0") {
            _ = try BindAddress.resolve("0.0.0.0")
        }
        expectThrows("MF7 0.0.0.0 fails role validation") {
            _ = try FeedHostRole(enabled: true, bind: "0.0.0.0").validated()
        }
        let status = FeedHostService.ensure(role: FeedHostRole(enabled: true, bind: "0.0.0.0"),
                                            stateDir: tmpDir("mirror-host-refuse"))
        expect(status.contains("off") || status.contains("refused"),
               "MF7 serving refuses an invalid role instead of opening a listener (\(status))")
    }

    // MF8. A publish id must be one this fleet or the feed already knows; retire removes an entry.
    do {
        let rig = Rig("mirror-appids")
        expect(!FeedPublisher.isKnownApp("printer", in: rig.feed),
               "MF8 a mistyped id is not known")
        expect(FeedPublisher.isKnownApp("printer-studio", in: rig.feed), "MF8 a fleet id is known")
        expect(FeedPublisher.isKnownApp("brand-new", in: rig.feed, allowNew: true),
               "MF8 --new-app states a genuinely new app")
        // The CLI refuses the mistyped id before anything is written, and accepts --new-app.
        let khu = URL(fileURLWithPath: "build/khu").standardizedFileURL.path
        let log = rig.root.appendingPathComponent("notes.md")
        try! "## 1.0.0 — 2026-11-19\n- x\n".write(to: log, atomically: true, encoding: .utf8)
        let art = rig.artifact("printer.dmg", "printer-bytes").path
        let refused = try? SystemShell().run(khu, arguments: ["publish", "--feed", rig.feed.path, "--key", rig.key.path,
                                                              "--app", "printer", "--version", "1.0.0", "--artifact", art,
                                                              "--kind", "fake-for-tests", "--changelog", log.path], timeout: 20)
        expect(refused?.exitCode != 0 && (refused?.stderr ?? "").contains("not an app this fleet publishes")
               && FeedPublisher.loadFeed(from: rig.feed)?.apps["printer"] == nil,
               "MF8 a wrong publish id is refused and creates no entry")
        let created = try? SystemShell().run(khu, arguments: ["publish", "--feed", rig.feed.path, "--key", rig.key.path,
                                                              "--app", "printer", "--version", "1.0.0", "--artifact", art,
                                                              "--kind", "fake-for-tests", "--changelog", log.path, "--new-app"], timeout: 20)
        expect(created?.exitCode == 0 && FeedPublisher.isKnownApp("printer", in: rig.feed),
               "MF8 --new-app publishes a genuinely new app")
        // The CLI path, exactly as the owner will run it on the publisher host.
        let retired = try? SystemShell().run(khu, arguments: ["retire", "--feed", rig.feed.path, "--key", rig.key.path,
                                                              "--app", "printer"], timeout: 15)
        let feed = try? FeedPublisher.loadVerifiedFeed(from: rig.feed, publicKey: rig.pair.privateKey.publicKey)
        expect(retired?.exitCode == 0 && (retired?.stdout ?? "").contains("retired printer")
               && feed?.apps["printer"] == nil, "MF8 retire removes the entry from the signed feed")
        expect(FileManager.default.fileExists(atPath: rig.feed.appendingPathComponent("artifacts").path),
               "MF8 retire leaves published artifacts on disk")
    }
}
