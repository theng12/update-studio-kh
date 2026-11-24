import Foundation

/// A `ditto` whose exit code lies, exactly as measured on the fleet (2026-11-19): 27.0.1 returns 1
/// for a complete copy, and a copy can stop partway. Every call is recorded.
private final class LyingDittoShell: Shell, @unchecked Sendable {
    /// One behaviour per copy, in order; the last one repeats.
    enum Behaviour {
        case complete(exit: Int32, stderr: [String])
        case partial(files: Int, stderr: Int)
        case unreadable(String)
    }
    var behaviours: [Behaviour]
    var copies = 0
    let mount: URL
    init(mount: URL, behaviours: [Behaviour]) { self.mount = mount; self.behaviours = behaviours }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        if executable == "/usr/bin/hdiutil" {
            if arguments.first == "attach" {
                let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"],
                                                                ["dev-entry": "/dev/disk9s1", "mount-point": mount.path]]]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: "")
        }
        guard executable == "/usr/bin/ditto" else { throw khuFail("unexpected fixture command \(executable)") }
        copies += 1
        let behaviour = behaviours.count > 1 ? behaviours.removeFirst() : behaviours[0]
        let source = arguments[0], destination = arguments[1]
        switch behaviour {
        case .complete(let exit, let stderr):
            _ = try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            return ShellResult(exitCode: exit, stdout: "", stderr: stderr.joined(separator: "\n"))
        case .partial(let files, let stderrLines):
            _ = try? FileManager.default.removeItem(atPath: destination)
            try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            // Copy only part of the tree, the way the measured 62,104-of-67,233 copy looked.
            let entries = LyingDittoShell.entries(source).prefix(files)
            for entry in entries {
                let relative = String(entry.path.dropFirst(source.count)).drop { $0 == "/" }
                let target = destination + "/" + relative
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                } else if let data = try? Data(contentsOf: entry) {
                    try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                             withIntermediateDirectories: true)
                    try? data.write(to: URL(fileURLWithPath: target))
                }
            }
            return ShellResult(exitCode: 0, stdout: "", stderr: (0..<stderrLines).map { "ditto: line \($0)" }.joined(separator: "\n"))
        case .unreadable(let said):
            _ = try? FileManager.default.removeItem(atPath: destination)
            return ShellResult(exitCode: 1, stdout: "", stderr: said)
        }
    }

    static func entries(_ path: String) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                                        options: [], errorHandler: { _, _ in true }) else { return [] }
        return Array(walk.compactMap { $0 as? URL })
    }
}

private func copyFixture(_ tag: String) -> (rig: RecipeRig, source: String) {
    let rig = RecipeRig(tag)
    return (rig, rig.mount.appendingPathComponent("Foo.app").path)
}

func rollbackRetirementTests() {
    // RR1. A rollback copy for an app this Mac neither manages nor has is retired into this Mac's
    // own trash; one for an app it manages, or with an unresolved install, is left alone.
    do {
        let rig = Rig("rollback-retire")
        let managed = makeApp(rig.root.appendingPathComponent("Managed.app"), version: "1.0.0", id: "com.example.managed")
        let token = try! Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let stateDir = URL(fileURLWithPath: rig.root.appendingPathComponent("agent").path)
        let keptHub = stateDir.appendingPathComponent("rollback-hub/Hub Studio KH.app")
        let keptMine = stateDir.appendingPathComponent("rollback-managed/Managed.app")
        for folder in [keptHub, keptMine] {
            try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try! "x".write(to: folder.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        try! rig.publish("managed", "1.0.0", rig.artifact("managed.zip", "managed"), kind: "fake-for-tests")
        // Hub is offered by the feed (with its identity, as a real publish has) but is not
        // installed here: its rollback copy buys nothing.
        try! FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "hub", version: "0.6.246",
                                   artifact: rig.artifact("hub.dmg", "hub"), kind: "app-dmg", allowSame: false, meta: { _ in AppMeta(name: "Hub Studio KH", bundleID: "com.example.hub",
                                                        bundleName: "Hub Studio KH.app", version: "0.6.246") }, url: "https://example.test/hub.dmg")
        let cfg = agentConfig(rig, token: token, apps: ["managed": AppConfig(bundlePath: managed.path, recipe: "fake-for-tests")])
        let run = try? Agent.runOnce(config: cfg, http: InProcessClient(server: rig.server))
        expect(run != nil && !fm.fileExists(atPath: keptHub.path) && fm.fileExists(atPath: keptMine.path),
               "RR1 a rollback copy of an app this Mac does not run is retired; a managed app's is kept (run \(run == nil ? "failed" : "ok"))")
        let trashed = (try? fm.subpathsOfDirectory(atPath: stateDir.appendingPathComponent("_trash").path)) ?? []
        expect(trashed.contains { $0.contains("rollback-hub") },
               "RR1 the retired copy is recoverable in this Mac's own trash")
    }
}

func copyCompletenessTests() {
    // CC1. A complete copy is accepted whatever the exit code says — 0 and 1 both mean "the copy
    // finished" on different macOS versions (measured 2026-11-19).
    for exit in [Int32(0), 1] {
        let (rig, source) = copyFixture("cc1-exit\(exit)")
        let info = try! BundleInfo.read(source)
        let shell = LyingDittoShell(mount: rig.mount,
                                    behaviours: [.complete(exit: exit, stderr: Array(repeating: "ditto: Permission denied", count: exit == 0 ? 9 : 0))])
        let paths = Recipe.Paths(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo")
        do {
            try Recipe.stage(paths, from: source, info: info, shell: shell, fileManager: .default)
            expect(shell.copies == 1 && FileManager.default.fileExists(atPath: paths.staged.path),
                   "CC1 a complete copy is accepted with ditto exit \(exit)")
        } catch { expect(false, "CC1 complete copy with exit \(exit) was refused: \(error)") }
        _ = Space.remove(paths.staged, shell: shell, fileManager: .default)
    }

    // CC2. A partial copy is cleared and retried once; the retry's complete copy is accepted.
    do {
        let (rig, source) = copyFixture("cc2-retry")
        let info = try! BundleInfo.read(source)
        let shell = LyingDittoShell(mount: rig.mount, behaviours: [.partial(files: 1, stderr: 39), .complete(exit: 1, stderr: [])])
        let paths = Recipe.Paths(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo")
        do {
            try Recipe.stage(paths, from: source, info: info, shell: shell, fileManager: .default)
            expect(shell.copies == 2 && (try? BundleInfo.read(paths.staged.path)) == info,
                   "CC2 an incomplete copy is cleared and retried once, and the second copy is kept")
        } catch { expect(false, "CC2 retry: \(error)") }
        _ = Space.remove(paths.staged, shell: shell, fileManager: .default)
    }

    // CC3. Two incomplete copies are a refusal, and the reason carries the count and stderr lines.
    do {
        let (rig, source) = copyFixture("cc3-twice")
        let info = try! BundleInfo.read(source)
        let shell = LyingDittoShell(mount: rig.mount, behaviours: [.partial(files: 1, stderr: 39), .partial(files: 2, stderr: 39)])
        let paths = Recipe.Paths(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo")
        var said = ""
        do { try Recipe.stage(paths, from: source, info: info, shell: shell, fileManager: .default) }
        catch { said = "\(error)" }
        expect(said.contains("failed twice") && said.contains("stderr") && !FileManager.default.fileExists(atPath: paths.staged.path),
               "CC3 a copy that stays incomplete after one retry is refused, with what was measured")
    }

    // CC4. An unreadable source is fatal on the first attempt: no retry, no second copy.
    for (tag, said) in [("notdir", "ditto: transformers/foo: Not a directory"),
                        ("nosuch", "ditto: x: No such file or directory"),
                        ("ioerr", "ditto: y: Input/output error") ] {
        let (rig, source) = copyFixture("cc4-\(tag)")
        let info = try! BundleInfo.read(source)
        let shell = LyingDittoShell(mount: rig.mount, behaviours: [.unreadable(said), .complete(exit: 0, stderr: [])])
        let paths = Recipe.Paths(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo")
        expectThrows("CC4 \(said) is fatal on the first attempt, never retried") {
            try Recipe.stage(paths, from: source, info: info, shell: shell, fileManager: .default)
        }
        expect(shell.copies == 1, "CC4 an unreadable source is copied once, not twice")
    }

    // CC5. A copy that starts with nothing at the source re-attaches the image once and copies
    // again from the new mount.
    do {
        let (rig, _) = copyFixture("cc5-reattach")
        let secondMount = tmpDir("cc5-second-mount")
        makeApp(secondMount.appendingPathComponent("Foo.app"), version: "1.2.3")
        let info = try! BundleInfo.read(secondMount.appendingPathComponent("Foo.app").path)
        let shell = LyingDittoShell(mount: rig.mount,
                                    behaviours: [.partial(files: 0, stderr: 0), .complete(exit: 0, stderr: [])])
        let paths = Recipe.Paths(installedPath: rig.installed.path, stateDir: rig.state.path, app: "foo")
        var reattached = 0
        do {
            try Recipe.stage(paths, from: rig.mount.appendingPathComponent("Foo.app").path, info: info,
                             shell: shell, fileManager: .default, reattach: {
                                 reattached += 1
                                 return secondMount.appendingPathComponent("Foo.app").path
                             })
            expect(reattached == 1 && shell.copies == 2, "CC5 an empty first copy re-attaches the image once and copies again")
        } catch { expect(false, "CC5 re-attach: \(error)") }
        _ = Space.remove(paths.staged, shell: shell, fileManager: .default)
    }
}
