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

    // AP3/AP4 a kill inside the swap window. The child performs one exchange and is killed either
    // just before or just after the rename — the window an interrupted install occupies. Either way
    // the app at the installed path is whole and still launches: it is the old one or the new one,
    // never neither, which is the failure this fix exists to remove.
    func fixture(_ dir: URL, _ text: String) throws {
        try fm.createDirectory(at: dir.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("marker"))
        let run = dir.appendingPathComponent("Contents/MacOS/App")
        try Data("#!/bin/sh\necho \(text)\n".utf8).write(to: run)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
    }
    func child(staged: URL, installed: URL, kill: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "build/khu")
        var env = ProcessInfo.processInfo.environment
        env["KHU_EXCHANGE_FIXTURE"] = staged.path + "|" + installed.path
        env["KHU_TEST_EXCHANGE_KILL"] = kill
        p.environment = env
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
    func launches(_ dir: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [dir.appendingPathComponent("Contents/MacOS/App").path]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && !(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
    for killPoint in ["before", "after"] {
        do {
            let root = tmpDir("atomic-kill-\(killPoint)")
            let staged = root.appendingPathComponent("Staged.app")
            let installed = root.appendingPathComponent("Applications/Target.app")
            try fixture(staged, "new"); try fixture(installed, "old")
            let status = child(staged: staged, installed: installed, kill: killPoint)
            let installedText = (try? String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8)) ?? "gone"
            expect(status != 0, "AP3 the child died at the \(killPoint) edge of the swap (status \(status))")
            expect((installedText == "old" || installedText == "new") && launches(installed),
                   "AP3 killed \(killPoint) the exchange: the app is whole and launches, and it is the \(installedText) one")
            let stagedText = (try? String(contentsOf: staged.appendingPathComponent("marker"), encoding: .utf8)) ?? "gone"
            expect(killPoint == "before" ? stagedText == "new" : stagedText == "old",
                   "AP3 killed \(killPoint): the other copy is still on disk (\(stagedText))")
        } catch { expect(false, "AP3 \(killPoint) fixture: \(error)") }
    }
}
