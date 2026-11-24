import Foundation

func repairedPathTests() {
    // PR1/PR2: a path repair is written into the live config, so it is not repaired — or named —
    // again on every run. Everything else in the file is kept exactly as it was.
    do {
        let rig = Rig("repair-live")
        let installed = makeApp(rig.root.appendingPathComponent("Renamed.app"), version: "1.0.0", id: "com.example.renamed")
        try FeedPublisher.publish(feedDir: rig.feed, keyFile: rig.key, app: "renamed", version: "1.0.0",
                                  artifact: rig.artifact("renamed.dmg", "bytes"), kind: "app-dmg", allowSame: false, meta: { _ in AppMeta(name: "Renamed", bundleID: "com.example.renamed",
                                                       bundleName: "Renamed.app", version: "1.0.0", iconPNG: nil) }, url: "https://example.test/fixture.dmg")
        let token = try Enrolment.enrol(stateDir: rig.state, machine: "mac1")
        let configFile = rig.root.appendingPathComponent("config.json")
        let stateDir = rig.root.appendingPathComponent("agent").path
        let saved = """
        {"feedURL":"http://100.64.0.7/release.json","publicKey":"\(rig.pair.publicKeyBase64)","stateDir":"\(stateDir)",\
        "machine":"mac1","token":"\(token)","intervalMinutes":5,"once":true,"note":"kept",\
        "apps":{"renamed":{"bundlePath":"/nonexistent/Old Name.app","recipe":"app-dmg","automatic":false}}}
        """
        try saved.write(to: configFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        let cfg = try JSON.decode(AgentConfig.self, from: Data(contentsOf: configFile))
        let client = InProcessClient(server: rig.server)

        let first = try? Agent.runOnce(config: cfg, http: client, appFolders: [rig.root], configFile: configFile)
        let repairNote = first?.notes.contains { $0.contains("configured bundle path /nonexistent/Old Name.app") } ?? false
        let rewritten = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configFile))) as? [String: Any]
        let apps = rewritten?["apps"] as? [String: [String: Any]]
        let mode = (try? fm.attributesOfItem(atPath: configFile.path))?[.posixPermissions] as? NSNumber
        expect(repairNote && apps?["renamed"]?["bundlePath"] as? String == installed.path,
               "PR1 the repaired path is written into the live config, not only logged")
        expect(rewritten?["note"] as? String == "kept" && mode?.intValue == 0o600,
               "PR1 every other key and the file's own permissions are kept")

        let reloaded = try JSON.decode(AgentConfig.self, from: Data(contentsOf: configFile))
        let second = try? Agent.runOnce(config: reloaded, http: client, appFolders: [rig.root], configFile: configFile)
        expect(!(second?.notes.contains { $0.contains("configured bundle path") } ?? true),
               "PR2 the next run starts from the repaired path: the repair line is not repeated")
    } catch { expect(false, "PR repair: \(error)") }
}
