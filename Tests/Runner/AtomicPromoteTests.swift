import Foundation

/// The promote is an exchange, not two moves. Measured 2026-11-23: the old order moved the installed
/// bundle to the rollback path and then moved the staged one in; when that second move did not
/// happen, this Mac had no Launcher in /Applications and nothing put it back. These pin the property
/// the fix rests on — after a promote both bundles still exist, and a refused promote changes nothing.
func atomicPromoteTests() {
    let fm = FileManager.default
    // AP1 an exchange swaps the two directories and keeps both of them on disk.
    do {
        let root = tmpDir("atomic-promote")
        let staged = root.appendingPathComponent("staged/New.app")
        let installed = root.appendingPathComponent("apps/Installed.app")
        for (dir, text) in [(staged, "new"), (installed, "old")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("marker"))
        }
        expect(Recipe.exchange(staged.path, installed.path), "AP1 an exchange on one volume succeeds")
        let atInstalled = (try? String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8)) ?? ""
        let atStaged = (try? String(contentsOf: staged.appendingPathComponent("marker"), encoding: .utf8)) ?? ""
        expect(atInstalled == "new", "AP1 the installed path holds the new bundle (\(atInstalled))")
        expect(atStaged == "old", "AP1 the previous bundle survives where the staged one was, so it can become the fallback (\(atStaged))")
    } catch { expect(false, "AP1 fixture: \(error)") }

    // AP2 an exchange against a path that is not there is refused, and the existing bundle is untouched.
    do {
        let root = tmpDir("atomic-missing")
        let only = root.appendingPathComponent("Only.app")
        try fm.createDirectory(at: only, withIntermediateDirectories: true)
        try Data("only".utf8).write(to: only.appendingPathComponent("marker"))
        expect(!Recipe.exchange(only.path, root.appendingPathComponent("Missing.app").path),
               "AP2 an exchange with a missing partner is refused")
        let still = (try? String(contentsOf: only.appendingPathComponent("marker"), encoding: .utf8)) ?? ""
        expect(still == "only", "AP2 a refused exchange leaves the existing bundle exactly as it was (\(still))")
    } catch { expect(false, "AP2 fixture: \(error)") }
}
