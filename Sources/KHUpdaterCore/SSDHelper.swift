import Foundation

/// A connected Mac can adopt the SSD's verified helper without changing its saved identity.
public enum SSDHelper {
    public static func refresh(launcher: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> RecipeResult {
        let fm = FileManager.default
        let base = home.appendingPathComponent("Library/KHUpdater/base")
        let file = base.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: file.path) else {
            return RecipeResult(status: "needs_connection", reason: "Launcher is installed. Open it to connect this Mac with your pairing code.")
        }
        let config = try JSON.decode(AgentConfig.self, from: Data(contentsOf: file))
        let state = home.appendingPathComponent("Library/KHUpdater/state")
        guard URL(fileURLWithPath: config.stateDir).standardizedFileURL == state.standardizedFileURL,
              config.stubBase.map({ URL(fileURLWithPath: $0).standardizedFileURL }) == base.standardizedFileURL else {
            throw khuFail("This Mac uses a different helper layout; its saved settings were left unchanged.")
        }
        return try FileLock.withExclusive(state.appendingPathComponent("agent.lock"), wait: false) {
            if HelperSettings.load(from: state).paused(at: Date()) {
                return RecipeResult(status: "paused", reason: "Helper updates are paused on this Mac. Its pause was kept.")
            }
            let kit = launcher.appendingPathComponent("Contents/Resources/khu-agent")
            let publisher = try Connect.publisher(kit: kit)
            // The saved trust must be this build's pin, and the kit must name that same key.
            try PinnedKey.require(config.publicKey)
            try PinnedKey.requireKit(publisher.publicKey)
            guard publisher.publicKey == PinnedKey.trusted(config.publicKey) else {
                throw khuFail("The SSD's helper belongs to a different publisher; this Mac's saved trust was kept.")
            }
            let version = try String(contentsOf: kit.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let layout = StubLayout(base: base)
            if let current = layout.currentBinary() {
                let installed = StubLayout.version(of: current)
                guard let order = VersionCompare.compare(version, installed) else { throw khuFail("The helper version could not be compared.") }
                if order < 0 { return RecipeResult(status: "current", reason: "This Mac already has a newer helper (\(installed)).") }
            }
            let binary = kit.appendingPathComponent("bin/khu")
            let pin = try Signing.sha256Hex(fileAt: binary)
            let entry = FeedApp(version: version, file: "khu", sha256: pin.hex, bytes: pin.bytes, kind: "updater")
            return try Agent.installUpdater(entry, artifact: binary, config: config)
        }
    }
}
