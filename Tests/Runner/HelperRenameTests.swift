import Foundation

/// The client engine was renamed in 0.1.36. An older version directory still holds the old-named
/// bundle; a rollback into it must run from its plain binary instead of a path that does not exist,
/// and an install/self-update of that version must create the renamed bundle around it.
func helperRenameTests() {
    let base = tmpDir("helper-rename")
    let layout = StubLayout(base: base)

    func makeVersion(_ version: String, oldBundle: Bool, newBundle: Bool) -> URL {
        let binary = try! layout.binary(for: version)
        try! fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        chmod(binary.path, 0o755)
        func bundle(_ name: String) {
            let exe = base.appendingPathComponent("versions/\(version)/\(name).app/Contents/MacOS/Studio Launcher KH Helper")
            try! fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
            chmod(exe.path, 0o755)
        }
        if oldBundle { bundle("Update Studio KH Helper") }
        if newBundle { bundle("Studio Launcher KH Helper") }
        return binary
    }

    // HR1: a pre-rename version falls back to its bare binary; a renamed one runs from its bundle.
    let oldBinary = makeVersion("0.1.35", oldBundle: true, newBundle: false)
    expect(layout.runnable(for: oldBinary).path == oldBinary.path,
           "HR1 a pre-rename version with only the old bundle runs from its bare binary")
    let newBinary = makeVersion("0.1.36", oldBundle: false, newBundle: true)
    let newRun = layout.runnable(for: newBinary).path
    expect(newRun.hasSuffix("Studio Launcher KH Helper.app/Contents/MacOS/Studio Launcher KH Helper"),
           "HR1 a renamed version runs from Studio Launcher KH Helper.app")

    // HR2: rolling back into the pre-rename version still starts from a path that exists. The Mac
    // starts on 0.1.35 (as installed before the rename), then updates to 0.1.36 and rolls back.
    let switcher = StubSwitcher(layout: layout)
    try! fm.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/0.1.35/khu")
    _ = try? switcher.install(version: "0.1.36")
    let back = try? switcher.switchBack()
    let restored = layout.currentBinary().map { layout.runnable(for: $0).path }
    expect(back == "0.1.35" && restored == oldBinary.path,
           "HR2 a rollback into a pre-rename version starts from its bare binary (\(back ?? "nil"), \(restored ?? "nil"))")

    // HR3: installing that version again creates the renamed bundle around it and runs from it.
    _ = try? switcher.install(version: "0.1.35")
    let renamed = try! layout.helperBundle(for: "0.1.35").appendingPathComponent("Contents/MacOS/Studio Launcher KH Helper")
    expect(fm.isExecutableFile(atPath: renamed.path) && layout.runnable(for: oldBinary).path == renamed.path,
           "HR3 a version installed after the rename gets the renamed bundle and runs from it")

    // HR4: the old bundle is kept, never deleted.
    expect(fm.fileExists(atPath: base.appendingPathComponent("versions/0.1.35/Update Studio KH Helper.app").path),
           "HR4 the pre-rename bundle is left in place")
}
