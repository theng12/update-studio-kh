import Foundation

/// Hand-installed copies of this fleet's apps that the Launcher has not registered.
///
/// An offer names the copy's *existing* path: that is what the person is asked to approve, and
/// the only thing adoption records. Nothing here moves, renames or reinstalls over the copy, and
/// recording its own path means adoption never creates a second copy beside it.
public enum Adoption {
    public struct Offer: Equatable, Sendable {
        public var appID: String
        public var bundleID: String
        public var version: String
        public var existingPath: String
    }

    /// A pure read of the Applications folders: no file writes, prompts, moves or installs.
    /// `known` is the fleet's bundle-ID map from `Catalog.knownBundles`/`Catalog.known` (feed and
    /// SSDs), `managed` is `config.apps`, and `dismissed` is the caller's per-app decline set,
    /// keyed by app id (a bundle id is accepted too).
    public static func offers(known: [String: (id: String, updatesItself: Bool)],
                              managed: [String: AppConfig],
                              dismissed: Set<String> = [],
                              folders: [URL] = Catalog.applicationFolders) -> [Offer] {
        let managedPaths = Set(managed.values.map { LiveControl.realPath($0.bundlePath) })
        let managedBundles = Set(managed.values.compactMap(\.bundleID))
        var found: [String: Offer] = [:]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".app") {
                let path = folder.appendingPathComponent(name).path
                guard let info = try? BundleInfo.read(path), let hit = known[info.identifier],
                      !dismissed.contains(hit.id), !dismissed.contains(info.identifier),
                      managed[hit.id] == nil, !managedBundles.contains(info.identifier),
                      !managedPaths.contains(LiveControl.realPath(path)), found[hit.id] == nil else { continue }
                found[hit.id] = Offer(appID: hit.id, bundleID: info.identifier,
                                      version: info.version, existingPath: path)
            }
        }
        return found.values.sorted { $0.appID < $1.appID }
    }
}
