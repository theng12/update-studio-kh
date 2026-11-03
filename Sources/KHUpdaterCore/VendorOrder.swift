import Foundation

/// Vendor pins and limits travel inside the machine-bound signed order, never in an unsigned fetch.
public struct VendorOrder: Codable, Sendable, Equatable {
    public var entry: VendorEntry
    public var kind: VendorInstaller.Kind
    public var byteCap: Int64
    public init(entry: VendorEntry, kind: VendorInstaller.Kind, byteCap: Int64) {
        self.entry = entry; self.kind = kind; self.byteCap = byteCap
    }

    static func kind(for id: String) -> VendorInstaller.Kind {
        ["tailscale", "word", "excel"].contains(id) ? .pkg : .dmg
    }

    public func validate(app: String) throws {
        guard app == "vendor-" + entry.id, (try? SafeName.component(entry.id, what: "vendor id")) != nil,
              entry.enabled, entry.sourceKind != .unresolved,
              (entry.sourceKind != .pageLink || entry.sourceMatch?.isEmpty == false),
              byteCap > 0, let team = entry.teamID, !team.isEmpty,
              entry.teamIDEvidence?.isEmpty == false, entry.bundleID?.isEmpty == false,
              let source = URL(string: entry.sourceURL),
              URLSessionHTTPClient.officialURL(source, hosts: entry.officialHosts) else {
            throw khuFail("vendor order is disabled, has no signature pin, or has an invalid official source or download limit")
        }
    }
}
