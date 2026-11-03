import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Read-only Mac inventory: collection bounds, the server's bounded read, and the state fields.
// Nothing here touches /Applications outside a temporary directory, launchd, or the network.

func invTmpDir(_ tag: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("khu-inv-\(tag)-\(UUID().uuidString.prefix(8))")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal .app bundle with an Info.plist. `id` nil omits CFBundleIdentifier on purpose.
func invMakeApp(_ url: URL, version: String?, id: String?, maker: String?) {
    let contents = url.appendingPathComponent("Contents")
    try! FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                             withIntermediateDirectories: true)
    var plist: [String: Any] = ["CFBundleName": url.deletingPathExtension().lastPathComponent]
    if let version { plist["CFBundleShortVersionString"] = version }
    if let id { plist["CFBundleIdentifier"] = id }
    if let maker { plist["CFBundleVendor"] = maker }
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
}

func inventoryTests() {
    // system_profiler JSON -> facts; a masked serial is not a serial.
    let sample = #"{"SPHardwareDataType":[{"machine_name":"Mac Studio","machine_model":"Mac14,13","#
        + #""chip_type":"Apple M2 Max","serial_number":"C02ABCDEF"}]}"#
    let facts = MacInventory.profilerFacts(sample)
    expect(facts.model_name == "Mac Studio" && facts.model_id == "Mac14,13"
           && facts.chip == "Apple M2 Max" && facts.serial == "C02ABCDEF",
           "INV1 system_profiler facts parse with their real key names")
    let masked = MacInventory.profilerFacts(
        #"{"SPHardwareDataType":[{"machine_name":"Mac","serial_number":"****************"}]}"#)
    expect(masked.serial == nil, "INV2 a masked serial is reported as absent, not as the mask")
    expect(MacInventory.profilerFacts("not json").model_name == nil,
           "INV3 an unreadable profile says nothing")
    let overlong = MacInventory.profilerFacts(
        #"{"SPHardwareDataType":[{"machine_name":""# + String(repeating: "x", count: 200) + #""}]}"#)
    expect(overlong.model_name == nil, "INV4 a profile value past the bound is dropped, never cut")

    // A snapshot collected without a real profiler fits every bound the publisher enforces.
    let snap = MacInventory.collect(shell: FakeShell())
    expect(snap.boundViolation() == nil, "INV5 a collected snapshot fits the report bounds")
    expect(snap.apps_truncated != nil, "INV6 every collection says whether its app listing is complete")
    expect(snap.model_id == nil || snap.model_id == MacInventory.sysctlString("hw.model"),
           "INV7 the model identifier is the hardware's own sysctl value")

    // The bounded app scan: nested folders are followed, bundles are not descended into.
    let root = invTmpDir("scan")
    invMakeApp(root.appendingPathComponent("Foo.app"), version: "1.2", id: "com.example.foo", maker: "Example Corp")
    invMakeApp(root.appendingPathComponent("Sub").appendingPathComponent("Bar.app"),
               version: "2.0", id: "com.example.bar", maker: nil)
    let scan = MacInventory.scanAppBundles(roots: [root])
    expect(scan.apps.count == 2 && !scan.truncated, "INV8 a small complete listing is not truncated")
    expect(scan.apps.first { $0.id == "com.example.foo" }?.maker == "Example Corp",
           "INV9 the maker comes from CFBundleVendor when the bundle has one")
    expect(scan.apps.first { $0.id == "com.example.bar" }?.maker == nil,
           "INV10 a bundle without a vendor reports no maker")
    // FileManager answers with /private prepended under the temporary directory's /var symlink;
    // compare with that one prefix folded away.
    func invFolded(_ path: String) -> String { path.hasPrefix("/private") ? String(path.dropFirst(8)) : path }
    expect(!scan.apps.isEmpty && scan.apps.allSatisfy { invFolded($0.path).hasPrefix(invFolded(root.path)) },
           "INV11 only bundles under the given roots are listed")

    // The cap says the listing is incomplete instead of implying a full one.
    let many = invTmpDir("cap")
    for n in 0..<3 { invMakeApp(many.appendingPathComponent("A\(n).app"), version: "1", id: "com.example.a\(n)", maker: nil) }
    let capped = MacInventory.scanAppBundles(roots: [many], maxApps: 2)
    expect(capped.apps.count == 2 && capped.truncated, "INV12 reaching the cap marks the listing incomplete")

    // A folder past maxDepth is not explored, and that too is reported as incomplete.
    let deep = invTmpDir("depth")
    invMakeApp(deep.appendingPathComponent("One").appendingPathComponent("Two").appendingPathComponent("Deep.app"),
               version: "1", id: "com.example.deep", maker: nil)
    let shallow = MacInventory.scanAppBundles(roots: [deep], maxDepth: 1)
    expect(shallow.apps.isEmpty && shallow.truncated, "INV13 a depth-limited listing says it is incomplete")

    // A bundle with no identifier cannot be recorded, so the listing says incomplete.
    let noId = invTmpDir("noid")
    invMakeApp(noId.appendingPathComponent("Anonymous.app"), version: "1", id: nil, maker: nil)
    let noIdScan = MacInventory.scanAppBundles(roots: [noId])
    expect(noIdScan.apps.isEmpty && noIdScan.truncated, "INV14 an unidentifiable bundle is dropped, not guessed")

    // Tailscale range classification: exactly 100.64.0.0/10.
    expect(MacInventory.isTailscaleIPv4("100.64.0.1") && MacInventory.isTailscaleIPv4("100.127.255.254"),
           "INV15 addresses inside the Tailscale range classify as Tailscale")
    expect(!MacInventory.isTailscaleIPv4("100.63.255.255") && !MacInventory.isTailscaleIPv4("100.128.0.1")
           && !MacInventory.isTailscaleIPv4("192.168.1.5") && !MacInventory.isTailscaleIPv4("100.64.1")
           && !MacInventory.isTailscaleIPv4("not-an-address"),
           "INV16 everything outside the Tailscale range stays out of it")

    // The server's bounded read: absent, accepted, refused.
    expect({ if case .absent = MacInventory.read(nil) { return true }; return false }(),
           "INV17 no inventory key reads as absent")
    let valid: [String: Any] = ["model_id": "Mac14,13", "memory_bytes": 8_589_934_592,
                                "apps": [], "local_addresses": [], "apps_truncated": false]
    guard case .accepted(let parsed) = MacInventory.read(valid) else {
        expect(false, "INV18 a bounded report is accepted")
        return
    }
    expect(parsed.model_id == "Mac14,13" && parsed.apps_truncated == false && parsed.apps.isEmpty,
           "INV18 a bounded report is accepted with its fields intact")
    guard case .accepted(let partial) = MacInventory.read(["chip": "Apple M1"]) else {
        expect(false, "INV19 a partial report decodes with empty collections")
        return
    }
    expect(partial.apps.isEmpty && partial.local_addresses.isEmpty,
           "INV19 a partial report decodes with empty collections")
    var huge: [String: Any] = [:]
    huge["apps"] = (0..<(ReportPolicy.maxInventoryApps + 1)).map {
        ["id": "com.example.\($0)", "name": "App\($0)", "path": "/Applications/App\($0).app"]
    }
    expect({ if case .refused = MacInventory.read(huge) { return true }; return false }(),
           "INV20 more apps than the bound is refused")
    let longPath: [String: Any] = ["apps": [["id": "com.example.x", "name": "X",
                                             "path": String(repeating: "p", count: ReportPolicy.maxInventoryAppPathCharacters + 1)]]]
    expect({ if case .refused = MacInventory.read(longPath) { return true }; return false }(),
           "INV21 a path past the bound is refused")
    let manyAddresses: [String: Any] = ["local_addresses": Array(repeating: "192.168.1.7",
                                                                 count: ReportPolicy.maxInventoryAddresses + 1)]
    expect({ if case .refused = MacInventory.read(manyAddresses) { return true }; return false }(),
           "INV22 more addresses than the bound is refused")
    expect({ if case .refused = MacInventory.read("just a string") { return true }; return false }(),
           "INV23 an inventory that is not an object is refused")
    let longText: [String: Any] = ["user": String(repeating: "u", count: ReportPolicy.maxInventoryStringCharacters + 1)]
    expect({ if case .refused = MacInventory.read(longText) { return true }; return false }(),
           "INV24 text past the bound is refused")
    expect({ if case .refused = MacInventory.read(["memory_bytes": -1]) { return true }; return false }(),
           "INV25 a byte count that cannot be one is refused")

    // The JSON the agent sends keeps the snake_case names the page reads.
    let object = MacInventory(model_id: "Mac14,13", apps_truncated: false).asJSONObject()
    expect(object?["model_id"] as? String == "Mac14,13" && object?["apps_truncated"] as? Bool == false,
           "INV26 asJSONObject carries the snake_case report keys")

    // MachineState: old state reads, new fields round-trip, nothing is required that was not before.
    let oldState = #"{"machine":"m1","installed":{"demo":"1.0"},"health":{"demo":"running"}}"#
    let old = try! JSON.decode(MachineState.self, from: Data(oldState.utf8))
    expect(old.inventory == nil && old.site == nil && old.tags == nil,
           "INV27 state written before inventory, site or tags still reads")
    var record = MachineState(machine: "m2")
    record.site = "Studio B"
    record.tags = ["sleep", "khmer"]
    record.inventory = MacInventory(model_id: "Mac14,13", model_name: "Mac Studio",
                                    local_addresses: ["192.168.1.9"], apps_truncated: false)
    let roundTrip = try! JSON.decode(MachineState.self, from: JSON.encode(record, pretty: false))
    expect(roundTrip.site == "Studio B" && roundTrip.tags == ["sleep", "khmer"]
           && roundTrip.inventory?.model_name == "Mac Studio" && roundTrip.inventory?.apps_truncated == false,
           "INV28 site, tags and inventory round-trip through state.json")
    expect(roundTrip.installed.isEmpty && roundTrip.machine == "m2",
           "INV29 the inventory never touches the installed managed-app map")

    // The bounds are the stated policy the page shows.
    expect(ReportPolicy.maxInventoryApps == 128 && ReportPolicy.maxInventoryAddresses == 16
           && ReportPolicy.maxInventoryStringCharacters == 128
           && ReportPolicy.maxInventoryAppPathCharacters == 512
           && ReportPolicy.maxInventoryAddressCharacters == 64,
           "INV30 the inventory bounds are the published policy numbers")
    expect(!MacInventory.isTailscaleIPv4("100.64..1") && !MacInventory.isTailscaleIPv4("100.64.999.1"),
           "INV31 incomplete and out-of-range IPv4 octets cannot identify a Tailscale address")
    expect({ if case .refused = MacInventory.read(["uptime_seconds": 1e100]) { return true }; return false }(),
           "INV32 an uptime that cannot render as whole seconds is refused instead of trapping")
    let unreadableRoot = invTmpDir("notdir").appendingPathComponent("file")
    try! Data("not a directory".utf8).write(to: unreadableRoot)
    expect(MacInventory.scanAppBundles(roots: [unreadableRoot]).truncated,
           "INV33 an existing scan root that cannot be listed reports an incomplete inventory")
    let incompleteHTML = PublisherInventory.apps(MacInventory(apps_truncated: true), ownBundleIDs: [], h: { $0 })
    expect(incompleteHTML.contains("Incomplete inventory") && incompleteHTML.contains("128 apps"),
           "INV34 incomplete inventory shows the enforced scan limit instead of claiming completeness")
}
