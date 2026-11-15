import Foundation

private struct SSDSignatureShell: Shell {
    let base: RecordingShell
    let diagnostic: String
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/usr/bin/codesign" {
            return ShellResult(exitCode: 1, stdout: "", stderr: "\(arguments.last!): \(diagnostic)\n")
        }
        return try base.run(executable, arguments: arguments, timeout: timeout)
    }
}

func ssdUpdateTests() {
    for (diagnostic, accepted) in [("code has no resources but signature indicates they must be present", true),
                                    ("code object is not signed at all", false),
                                    ("code has no resources but signature indicates they must be present\nbad resource seal", false)] {
        let rig = RecipeRig("ssd-signature")
        defer { try? fm.removeItem(at: rig.root) }
        do {
            let image = rig.root.appendingPathComponent("image.dmg")
            try Data("private DMG fixture".utf8).write(to: image)
            let app = SSDApp(id: "foo", name: "Foo", version: "1.2.3", bundleID: "com.example.foo",
                             bundleName: "Foo.app", file: image.lastPathComponent, sha256: try Signing.sha256Hex(fileAt: image).hex)
            let fake = FakeApp(installed: rig.installed, running: false, healthy: ["1.2.3"])
            let rows = try SSDUpdate.run(source: SSDSource(volume: "Fixture", root: rig.root, index: SSDIndex(apps: [app])),
                stateDir: rig.state, folders: [rig.apps], shell: SSDSignatureShell(base: rig.shell, diagnostic: diagnostic),
                control: { _, _ in fake.control })
            expect(rows.first?.status == (accepted ? "updated" : "refused"), "SSD accepts only the exact released unsealed signature verdict")
            expect(marker(rig.installed) == (accepted ? "1.2.3" : "1.0.0"), "SSD signature refusal preserves the installed bundle")
        } catch { expect(false, "SSD signature regression: \(error)") }
    }
    let root = tmpDir("ssd-update")
    defer { try? fm.removeItem(at: root) }
    let drive = root.appendingPathComponent("SSD"), folder = root.appendingPathComponent("Applications")
    let state = root.appendingPathComponent("state")
    do {
        for dir in [drive, folder, state] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let image = drive.appendingPathComponent("installer.dmg")
        try Data("SSD image fixture".utf8).write(to: image)
        let hash = try Signing.sha256Hex(fileAt: image)
        func app(_ id: String, version: String = "2.0") -> SSDApp {
            SSDApp(id: id, name: id, version: version, bundleID: "com.fixture." + id,
                   bundleName: id + ".app", file: "installer.dmg", sha256: hash.hex)
        }
        let foo = app("foo"), optional = app("optional")
        var launcher = app("updater")
        launcher.bundleID = "com.khupdater.launcher"
        _ = makeApp(folder.appendingPathComponent("foo.app"), version: "1.0", id: foo.bundleID)
        let stopped: (SSDApp, String) -> AppControl = { _, _ in
            AppControl(isRunning: { false }, quit: { true }, launch: {}, healthy: { _ in true })
        }
        var calls: [String] = []
        let install: (SSDApp, String, String, AppControl) throws -> RecipeResult = { app, _, artifact, _ in
            calls.append(app.id)
            expect(artifact != image.path && (try? Signing.sha256Hex(fileAt: URL(fileURLWithPath: artifact)).hex) == hash.hex,
                   "SSD installer receives a private checksum-verified copy")
            return RecipeResult(status: "updated")
        }
        func run(_ entries: [SSDApp], apps: [String: AppConfig] = [:], ctl: ((SSDApp, String) -> AppControl)? = nil) throws -> [SSDUpdateRow] {
            try SSDUpdate.run(source: SSDSource(volume: "Fixture", root: drive, index: SSDIndex(apps: entries)),
                              stateDir: state, folders: [folder, root.appendingPathComponent("missing-folder")], apps: apps,
                              control: ctl ?? stopped, install: install)
        }
        let indexFile = drive.appendingPathComponent(SSDIndex.fileName)
        try AtomicFile.writeJSON(SSDIndex(apps: [foo]), to: indexFile)
        let selectedIndexHash = try Signing.sha256Hex(fileAt: indexFile).hex
        expect(try SSDUpdate.index(at: drive, sha256: selectedIndexHash).apps == [foo], "SSD consumes the selected index snapshot")
        try AtomicFile.writeJSON(SSDIndex(apps: [optional]), to: indexFile)
        expectThrows("SSD refuses index replacement after Launcher verification") { _ = try SSDUpdate.index(at: drive, sha256: selectedIndexHash) }
        let batch = try run([foo, optional, launcher])
        expect(batch.map(\.status) == ["updated", "not_installed", "updated"] && calls == ["foo", "updater"],
               "SSD updates installed apps, skips absent optional apps, and installs missing Launcher")
        calls = []
        let newer = app("foo", version: "0.5")
        expect(try run([newer])[0].status == "current" && calls.isEmpty, "SSD keeps newer installed versions")
        expect(try run([app("foo", version: "1.0")])[0].status == "updated", "SSD permits same-version repair")
        var settings = HelperSettings()
        settings.pausedUntil = ISO.string(Date().addingTimeInterval(3600))
        try settings.save(to: state)
        let pause = try Data(contentsOf: HelperSettings.file(in: state))
        calls = []
        expect(try run([foo, launcher]).allSatisfy { $0.status == "paused" } && calls.isEmpty, "SSD preserves a pause for every install including Launcher")
        expect(try Data(contentsOf: HelperSettings.file(in: state)) == pause, "SSD action leaves pause bytes unchanged")
        settings.pausedUntil = nil; try settings.save(to: state)
        let hub = app("hub")
        _ = makeApp(folder.appendingPathComponent("hub.app"), version: "1.0", id: hub.bundleID)
        let running: (SSDApp, String) -> AppControl = { _, _ in AppControl(isRunning: { true }, quit: { false }, launch: {}, healthy: { _ in true }) }
        calls = []
        expect(try run([hub], ctl: running)[0].status == "busy" && calls.isEmpty, "SSD refuses running production apps without a quiet point")
        // No hardcoded app list: any running app is refused, not only hub/story/gateway.
        let media = app("media-studio")
        _ = makeApp(folder.appendingPathComponent("media-studio.app"), version: "1.0", id: media.bundleID)
        calls = []
        expect(try run([media], ctl: running)[0].status == "busy" && calls.isEmpty,
               "SSD refuses any running app, not a hardcoded list")
        // The updater's own Launcher is the one exception: it holds no queue and runs this action.
        calls = []
        expect(try run([launcher], ctl: running)[0].status == "updated" && calls == ["updater"],
               "SSD still installs the Launcher while it runs this action")
        calls = []
        var corrupt = foo; corrupt.sha256 = String(repeating: "0", count: 64)
        expect(try run([corrupt])[0].status == "refused" && calls.isEmpty, "SSD refuses checksum mismatch before install")
        expectThrows("SSD refuses duplicate identities before any install") { _ = try run([foo, foo]) }
        var escaped = foo; escaped.file = "../outside.dmg"
        expect(try run([escaped])[0].status == "refused", "SSD refuses installer path escape")
        let damaged = folder.appendingPathComponent("Damaged.app")
        try fm.createDirectory(at: damaged, withIntermediateDirectories: true)
        let configured = AppConfig(bundlePath: damaged.path, bundleID: optional.bundleID)
        expect(try run([optional], apps: [optional.id: configured])[0].status == "updated", "SSD repairs a damaged bundle identified by saved configuration")
        let privateResult = try SSDUpdate.run(source: SSDSource(volume: "Fixture", root: drive, index: SSDIndex(apps: [foo])),
            stateDir: state, folders: [folder], control: stopped, install: { _, _, local, _ in
                try Data("changed after private verification".utf8).write(to: image)
                expect(try Signing.sha256Hex(fileAt: URL(fileURLWithPath: local)).hex == hash.hex, "SSD mutation after verification cannot change installed bytes")
                return RecipeResult(status: "updated")
            })
        expect(privateResult[0].status == "updated", "SSD uses the private verified image for installation")
    } catch { expect(false, "SSD batch regression: \(error)") }
}
