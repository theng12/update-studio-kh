import Foundation

private final class AttachmentShell: Shell, @unchecked Sendable {
    var entities: [[String: String]]
    var detaches: [[String]] = []
    init(_ entities: [[String: String]]) { self.entities = entities }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ShellResult {
        guard executable == "/usr/bin/hdiutil" else { throw khuFail("unexpected fixture command") }
        if arguments.first == "attach" {
            let data = try PropertyListSerialization.data(fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
            return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        detaches.append(arguments)
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

func dmgAttachmentTests() {
    let mount = "/Volumes/KHU-fixture"
    for apfs in [false, true] {
        let device = apfs ? "/dev/disk10s1" : "/dev/disk9s1"
        var entities = [["dev-entry": "/dev/disk9"]]
        if apfs { entities += [["dev-entry": "/dev/disk9s1"], ["dev-entry": "/dev/disk10"]] }
        entities.append(["dev-entry": device, "mount-point": mount])
        let shell = AttachmentShell(entities)
        do {
            let attachment = try Recipe.attach(shell, "fixture.dmg")
            expect(attachment.mount == mount && attachment.device == device,
                   "DMG attachment selects the mounted device for \(apfs ? "APFS" : "HFS")")
            expect(Recipe.detach(shell, attachment.device).isEmpty && shell.detaches == [["detach", device]],
                   "DMG cleanup detaches only the captured mounted device for \(apfs ? "APFS" : "HFS")")
        } catch { expect(false, "DMG attachment accepts \(apfs ? "APFS" : "HFS"): \(error)") }
    }
    for apfs in [false, true] {
        let folder = tmpDir("dmg-meta-\(apfs)")
        _ = makeApp(folder.appendingPathComponent("Fixture.app"), version: "1.0.0", id: "com.example.dmg-fixture")
        let device = apfs ? "/dev/disk10s1" : "/dev/disk9s1"
        var entities = [["dev-entry": "/dev/disk9"]]
        if apfs { entities += [["dev-entry": "/dev/disk9s1"], ["dev-entry": "/dev/disk10"]] }
        entities.append(["dev-entry": device, "mount-point": folder.path])
        let shell = AttachmentShell(entities)
        do {
            let metadata = try AppMeta.read(dmg: "fixture.dmg", shell: shell)
            expect(metadata.version == "1.0.0" && metadata.bundleID == "com.example.dmg-fixture",
                   "DMG AppMeta reads the real fixture bundle for \(apfs ? "APFS" : "HFS")")
            expect(shell.detaches == [["detach", device]], "DMG AppMeta detaches its captured mounted device")
        } catch { expect(false, "DMG AppMeta accepts fixture: \(error)") }
    }
    let empty = tmpDir("dmg-meta-empty")
    let noApp = AttachmentShell([["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk10"], ["dev-entry": "/dev/disk10s1", "mount-point": empty.path]])
    expectThrows("DMG AppMeta refuses a missing app", contains: "expected exactly one") {
        _ = try AppMeta.read(dmg: "fixture.dmg", shell: noApp)
    }
    expect(noApp.detaches == [["detach", "/dev/disk10s1"]], "DMG AppMeta failure detaches the captured APFS device")
    for mounted in [
        [["mount-point": mount, "dev-entry": "/Volumes/KH-STUDIO-ATLAS"]],
        [["mount-point": mount]],
        [["mount-point": mount, "dev-entry": "/dev/disk9s1"], ["mount-point": "/Volumes/other", "dev-entry": "/dev/disk9s2"]]
    ] {
        let shell = AttachmentShell([["dev-entry": "/dev/disk9"]] + mounted)
        expectThrows("DMG ambiguous or invalid mounted device is refused", contains: "mount point and device") {
            _ = try Recipe.attach(shell, "fixture.dmg")
        }
        expect(shell.detaches == [["detach", "/dev/disk9"]], "DMG refusal cleans up only a captured whole-disk device")
    }
}
