import Foundation
#if canImport(Darwin)
import Darwin
#endif

// F4 evidence (verification-check 1, 2026-11-07): a marketing version alone never proves the
// installed build. These checks pin the agent's own report and the snapshot the menu reads —
// what an installed bundle actually carries — while comparing it against a release's expected
// build belongs to the verification run against real signed release identity. The publisher
// retains only the latest bounded maps; absent identity remains unknown.

/// Rewrite the fixture bundle's Info.plist, with or without a CFBundleVersion.
func identitySetBuild(_ app: URL, _ build: Any?) {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    var dict = try! PropertyListSerialization.propertyList(from: try! Data(contentsOf: plist), format: nil) as! [String: Any]
    dict["CFBundleVersion"] = build
    try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plist)
}

/// The fixture's executable bytes: same marketing version, whatever bytes the caller wants.
func identitySetExecutable(_ app: URL, _ text: String) {
    let exe = app.appendingPathComponent("Contents/MacOS/Foo")
    try! text.write(to: exe, atomically: false, encoding: .utf8)
    chmod(exe.path, 0o755)
}

/// The real run's `/status` body, captured as it is posted.
final class StatusRecorder: HTTPClient, @unchecked Sendable {
    let inner: HTTPClient
    var lastStatus: Data?
    init(_ inner: HTTPClient) { self.inner = inner }
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) { try inner.get(url, headers: headers) }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        if url.path.hasSuffix("/status") { lastStatus = body }
        return try inner.post(url, headers: headers, body: body)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int {
        try inner.download(url, headers: headers, to: file, limit: limit)
    }
    func statusBody() -> [String: Any]? {
        lastStatus.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

func installedIdentityTests() {
    // 1. BundleInfo carries the build only when the bundle carries one, and hashes real bytes.
    do {
        let root = tmpDir("identity-bundle")
        defer { _ = try? Trash.move(root, into: root.deletingLastPathComponent().appendingPathComponent("_trash")) }

        let one = makeApp(root.appendingPathComponent("One.app"), version: "1.0.0")
        identitySetBuild(one, "701")
        let two = makeApp(root.appendingPathComponent("Two.app"), version: "1.0.0")
        identitySetExecutable(two, "#!/bin/sh\nexit 0\n# different bytes\n")
        let plain = makeApp(root.appendingPathComponent("Plain.app"), version: "1.0.0")

        let oneInfo = try BundleInfo.read(one.path)
        expect(oneInfo.version == "1.0.0" && oneInfo.build == "701", "BundleInfo reads CFBundleVersion beside the marketing version")
        let plainInfo = try BundleInfo.read(plain.path)
        expect(plainInfo.build == nil, "an app with no CFBundleVersion has no build: missing stays unknown, never derived")
        let twoInfo = try BundleInfo.read(two.path)
        expect(twoInfo.version == oneInfo.version && twoInfo.build == nil && oneInfo.build != nil,
               "equal marketing version, different build evidence: only the bundle that carries one reports it")

        let oneSha = try Signing.sha256Hex(fileAt: one.appendingPathComponent("Contents/MacOS/Foo")).hex
        let twoSha = try Signing.sha256Hex(fileAt: two.appendingPathComponent("Contents/MacOS/Foo")).hex
        expect(oneInfo.executableSha256(in: one.path) == oneSha, "the executable hash is the installed file's own bytes")
        expect(oneSha != twoSha && oneInfo.executableSha256(in: one.path) != twoInfo.executableSha256(in: two.path),
               "equal marketing version with different executable bytes hashes differently")

        identitySetBuild(one, NSNumber(value: 701))
        expect(try BundleInfo.read(one.path).build == "701", "a numeric CFBundleVersion still reads as the build")
        identitySetBuild(one, String(repeating: "b", count: ReportPolicy.maxVersionCharacters + 1))
        expect(try BundleInfo.read(one.path).build == nil, "a build longer than the report bound is not reported")
        identitySetBuild(one, String(repeating: "ក", count: ReportPolicy.maxVersionCharacters / 3 + 1))
        expect(try BundleInfo.read(one.path).build == nil, "the build bound counts UTF-8 bytes like the report receiver")
        identitySetBuild(one, "12\n34")
        expect(try BundleInfo.read(one.path).build == nil, "a build carrying control characters is not reported")
        let missing = BundleInfo(version: "1", identifier: "com.example.missing", executable: "Missing")
        expect(missing.executableSha256(in: one.path) == nil, "an unreadable executable stays unknown")
        let alias = one.appendingPathComponent("Contents/MacOS/Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: one.appendingPathComponent("Contents/MacOS/Foo"))
        let aliased = BundleInfo(version: "1", identifier: "com.example.alias", executable: "Alias")
        expect(aliased.executableSha256(in: one.path) == nil, "an executable alias is not reported as verified bundle bytes")
        expect(BundleInfo(version: "1.0.0", identifier: "com.example.foo", executable: "Foo").build == nil,
               "a BundleInfo without a build defaults to unknown")
    } catch { expect(false, "installed identity bundle regression: \(error)") }

    // 2. The snapshot the menu reads: equal version, different build and different executable
    //    bytes are three distinguishable rows; the app with no build stays nil there too.
    do {
        let rig = Rig("identity-snapshot")
        let one = makeApp(rig.root.appendingPathComponent("One.app"), version: "1.0.0")
        identitySetBuild(one, "12")
        let two = makeApp(rig.root.appendingPathComponent("Two.app"), version: "1.0.0")
        identitySetBuild(two, "13")
        identitySetExecutable(two, "#!/bin/sh\nexit 0\n# build thirteen\n")
        let none = makeApp(rig.root.appendingPathComponent("None.app"), version: "1.0.0")
        let cfg = agentConfig(rig, token: "unused", apps: [
            "one": AppConfig(bundlePath: one.path, recipe: "fake-for-tests"),
            "two": AppConfig(bundlePath: two.path, recipe: "fake-for-tests"),
            "none": AppConfig(bundlePath: none.path, recipe: "fake-for-tests"),
        ])
        let rows = Agent.snapshot(config: cfg, feed: Feed(published_at: ISO.string(Date()), apps: [:]),
                                  catalog: [], orders: try JSONDecoder().decode(CommandsReply.self,
                                      from: Data(#"{"machine":"mac1","at":"2026-11-09T00:00:00Z","commands":[],"automatic":{}}"#.utf8)),
                                  helper: HelperSettings(), memory: AgentMemory(), executable: nil,
                                  http: InProcessClient(server: rig.server),
                                  serverBase: URL(string: "http://pub.test/artifacts")!,
                                  stateDir: URL(fileURLWithPath: cfg.stateDir))
        let row = { (app: String) in rows.first { $0.app == app } }
        expect(row("one")?.installed == "1.0.0" && row("two")?.installed == "1.0.0" && row("none")?.installed == "1.0.0",
               "the snapshot's installed version is unchanged: still one marketing version per app")
        expect(row("one")?.installedBuild == "12" && row("two")?.installedBuild == "13",
               "equal marketing version, different builds: the snapshot shows both")
        expect(row("none")?.installedBuild == nil, "an app with no build reads nil in the snapshot: not checked, not matching")
        expect(row("one")?.installedExecutableSha256?.count == 64 && row("two")?.installedExecutableSha256?.count == 64,
               "the snapshot carries a SHA-256 for each installed executable")
        expect(row("one")?.installedExecutableSha256 != row("two")?.installedExecutableSha256,
               "different executable bytes are different evidence in the snapshot")
        expect(row("one")?.installedExecutableSha256 == (try? Signing.sha256Hex(fileAt: one.appendingPathComponent("Contents/MacOS/Foo")).hex),
               "the snapshot's hash is the bundle's own executable bytes")
        expect(row("none")?.installedExecutableSha256 != nil, "an app with no build still reports its executable bytes")
    } catch { expect(false, "installed identity snapshot regression: \(error)") }

    // 3. The real run's /status body: two optional keys beside an untouched `installed`.
    do {
        let rig = Rig("identity-report")
        let built = makeApp(rig.root.appendingPathComponent("Built.app"), version: "3.4.5")
        identitySetBuild(built, "3450")
        try? rig.publish("demo", "9.9.9", rig.artifact("demo.zip", "demo-bytes"))
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let cfg = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: built.path, recipe: "fake-for-tests")])

        let first = StatusRecorder(InProcessClient(server: rig.server))
        let ran = try? Agent.runOnce(config: cfg, http: first)
        expect(ran?.statusPosted == true, "the identity report run posts status")
        let body = first.statusBody()
        expect(body?["installed"] as? [String: String] == ["demo": "3.4.5"],
               "the report's installed map is exactly what every older publisher already reads: one version per app")
        expect(body?["installed_build"] as? [String: String] == ["demo": "3450"],
               "the report carries the bundle's CFBundleVersion beside the version")
        let expectedSha = (try? Signing.sha256Hex(fileAt: built.appendingPathComponent("Contents/MacOS/Foo"))).map(\.hex)
        let reportedSha = (body?["installed_executable_sha256"] as? [String: String])?["demo"]
        expect(reportedSha != nil && reportedSha == expectedSha,
               "the report's hash is the installed executable's bytes, not any release artifact's")

        // Same marketing version, no CFBundleVersion: the keys simply do not appear.
        let plain = makeApp(rig.root.appendingPathComponent("Plain.app"), version: "3.4.5")
        let cfgPlain = agentConfig(rig, token: token, apps: ["demo": AppConfig(bundlePath: plain.path, recipe: "fake-for-tests")])
        let second = StatusRecorder(InProcessClient(server: rig.server))
        _ = try? Agent.runOnce(config: cfgPlain, http: second)
        let plainBody = second.statusBody()
        expect(plainBody?["installed"] as? [String: String] == ["demo": "3.4.5"] && plainBody?["installed_build"] == nil,
               "an app with no build reports no build key: absent stays not checked, never inferred from the version")
        expect((plainBody?["installed_executable_sha256"] as? [String: String])?["demo"]?.count == 64,
               "the executable hash is reported even when the bundle carries no build")
    } catch { expect(false, "installed identity report regression: \(error)") }

    // 4. The latest bounded identity survives publisher readback; rejected reports cannot replace it.
    do {
        let rig = Rig("identity-bounds")
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let builds = Dictionary(uniqueKeysWithValues: (0..<ReportPolicy.maxApps).map { ("app\($0)", "1") })
        let hashes = builds.mapValues { _ in String(repeating: "a", count: 64) }
        let ok = enrolStatusPost(rig.server, machine: "mac1", token: token,
                                 body: ["machine": "mac1", "installed_build": builds, "installed_executable_sha256": hashes])
        expect(ok.status == 200, "a bounded build/hash report is accepted")
        let saved = try StateStore.load(from: rig.state).machines["mac1"]!
        expect(saved.installedBuild == builds && saved.installedExecutableSha256 == hashes,
               "publisher state persists actual reported identity for independent readback")
        let stateURL = rig.state.appendingPathComponent("state.json")
        let before = try Data(contentsOf: stateURL)
        var tooMany = builds; tooMany["extra"] = "1"
        let invalid: [[String: Any]] = [
            ["installed_build": ["app0": String(repeating: "b", count: ReportPolicy.maxVersionCharacters + 1)]],
            ["installed_build": tooMany], ["installed_build": ["app0": "12\n34"]],
            ["installed_build": ["app0": ""]], ["installed_build": "wrong type"],
            ["installed_executable_sha256": ["app0": "not-a-sha"]],
            ["installed_executable_sha256": ["app0": String(repeating: "z", count: 64)]],
            ["installed_executable_sha256": ["app0": 12]],
        ]
        for bad in invalid {
            var body = bad; body["machine"] = "mac1"
            let result = enrolStatusPost(rig.server, machine: "mac1", token: token, body: body)
            expect(result.status == 400 && (try? Data(contentsOf: stateURL)) == before,
                   "malformed or oversized identity is refused without changing stored evidence")
        }
        let oldHelper = enrolStatusPost(rig.server, machine: "mac1", token: token,
                                       body: ["machine": "mac1", "installed": ["app0": "1"]])
        let unknown = try StateStore.load(from: rig.state).machines["mac1"]!
        expect(oldHelper.status == 200 && unknown.installedBuild == nil && unknown.installedExecutableSha256 == nil,
               "a report without identity clears stale evidence to unknown")
        let legacy = try JSONDecoder().decode(MachineState.self, from: Data(#"{"machine":"legacy"}"#.utf8))
        expect(legacy.installedBuild == nil && legacy.installedExecutableSha256 == nil,
               "state written before identity fields existed still loads as unknown")
    } catch { expect(false, "installed identity bounds regression: \(error)") }
}