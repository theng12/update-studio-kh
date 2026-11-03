import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One `.app` bundle the bounded scan found. `maker` is the bundle's own `CFBundleVendor` when its
/// Info.plist carries one; absent means Not reported — a bundle identifier is never a maker.
public struct InventoryApp: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String?
    public var maker: String?
    public var path: String
    public init(id: String, name: String, version: String? = nil, maker: String? = nil, path: String) {
        self.id = id; self.name = name; self.version = version; self.maker = maker; self.path = path
    }
}

/// A read-only snapshot one Mac reports about itself on `/status`: real hardware facts (never
/// inferred from the machine's name), its addresses, and the `.app` bundles under `/Applications`
/// and `~/Applications`. Every collection is bounded by `ReportPolicy`; a field that could not be
/// read here is absent, which the page shows as Not reported — never as a guess.
public struct MacInventory: Codable, Sendable, Equatable {
    /// `sysctl hw.model`, e.g. `Mac14,13`. The actual hardware identifier.
    public var model_id: String?
    /// Marketing name from `system_profiler` (e.g. `Mac Studio`). Never the computer name.
    public var model_name: String?
    /// Chip from `system_profiler`, else `machdep.cpu.brand_string`.
    public var chip: String?
    public var memory_bytes: UInt64?
    public var storage_total_bytes: UInt64?
    public var storage_free_bytes: UInt64?
    public var os_version: String?
    /// Seconds since boot, measured from `kern.boottime`.
    public var uptime_seconds: Double?
    /// The signed-in user this agent runs as. Absent only if the system would not say.
    public var user: String?
    /// Hardware serial from `system_profiler`, only when it reads plainly and no new permission
    /// is needed; masked or missing means absent.
    public var serial: String?
    /// First IPv4 inside `100.64.0.0/10` on this Mac's interfaces (the Tailscale range).
    public var tailscale_ipv4: String?
    /// The interface that address sits on (e.g. `utun4`). Not a connection or host name.
    public var tailscale_interface: String?
    /// Tailscale's own DNS name. Never derived from the local hostname; absent until it can be
    /// read safely, which today's collection does not attempt.
    public var tailscale_name: String?
    /// Non-loopback IPv4 addresses outside the Tailscale range, sorted, deduplicated.
    public var local_addresses: [String]
    /// Bounded `.app` scan of `/Applications` and `~/Applications`.
    public var apps: [InventoryApp]
    /// True when the app listing is incomplete: the enforced cap was reached, a deeper folder was
    /// not explored, or an entry could not be recorded. The page must say so and name the maximum.
    public var apps_truncated: Bool?

    public init(model_id: String? = nil, model_name: String? = nil, chip: String? = nil,
                memory_bytes: UInt64? = nil, storage_total_bytes: UInt64? = nil, storage_free_bytes: UInt64? = nil,
                os_version: String? = nil, uptime_seconds: Double? = nil, user: String? = nil, serial: String? = nil,
                tailscale_ipv4: String? = nil, tailscale_interface: String? = nil, tailscale_name: String? = nil,
                local_addresses: [String] = [], apps: [InventoryApp] = [], apps_truncated: Bool? = nil) {
        self.model_id = model_id; self.model_name = model_name; self.chip = chip
        self.memory_bytes = memory_bytes; self.storage_total_bytes = storage_total_bytes
        self.storage_free_bytes = storage_free_bytes; self.os_version = os_version
        self.uptime_seconds = uptime_seconds; self.user = user; self.serial = serial
        self.tailscale_ipv4 = tailscale_ipv4; self.tailscale_interface = tailscale_interface
        self.tailscale_name = tailscale_name; self.local_addresses = local_addresses
        self.apps = apps; self.apps_truncated = apps_truncated
    }

    private enum CodingKeys: String, CodingKey {
        case model_id, model_name, chip, memory_bytes, storage_total_bytes, storage_free_bytes,
             os_version, uptime_seconds, user, serial, tailscale_ipv4, tailscale_interface,
             tailscale_name, local_addresses, apps, apps_truncated
    }
    /// Every field a report may omit decodes as absent: a partial report must still read, and the
    /// page shows what is missing rather than refusing the whole snapshot.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model_id = try c.decodeIfPresent(String.self, forKey: .model_id)
        model_name = try c.decodeIfPresent(String.self, forKey: .model_name)
        chip = try c.decodeIfPresent(String.self, forKey: .chip)
        memory_bytes = try c.decodeIfPresent(UInt64.self, forKey: .memory_bytes)
        storage_total_bytes = try c.decodeIfPresent(UInt64.self, forKey: .storage_total_bytes)
        storage_free_bytes = try c.decodeIfPresent(UInt64.self, forKey: .storage_free_bytes)
        os_version = try c.decodeIfPresent(String.self, forKey: .os_version)
        uptime_seconds = try c.decodeIfPresent(Double.self, forKey: .uptime_seconds)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        tailscale_ipv4 = try c.decodeIfPresent(String.self, forKey: .tailscale_ipv4)
        tailscale_interface = try c.decodeIfPresent(String.self, forKey: .tailscale_interface)
        tailscale_name = try c.decodeIfPresent(String.self, forKey: .tailscale_name)
        local_addresses = try c.decodeIfPresent([String].self, forKey: .local_addresses) ?? []
        apps = try c.decodeIfPresent([InventoryApp].self, forKey: .apps) ?? []
        apps_truncated = try c.decodeIfPresent(Bool.self, forKey: .apps_truncated)
    }

    /// The server's own words when a report does not fit `ReportPolicy`; nil means it fits.
    /// Refusal, never silent truncation: a bound the publisher enforces is a bound it shows.
    public func boundViolation() -> String? {
        let p = ReportPolicy.self
        let textFields = [model_id, model_name, chip, os_version, user, serial, tailscale_name]
        let networkFields = [tailscale_ipv4, tailscale_interface]
        var tooLong = textFields.compactMap { $0 }.contains { $0.utf8.count > p.maxInventoryStringCharacters }
            || networkFields.compactMap { $0 }.contains { $0.utf8.count > p.maxInventoryAddressCharacters }
        if let uptime_seconds, !uptime_seconds.isFinite || uptime_seconds < 0 || uptime_seconds >= Double(Int.max) { tooLong = true }
        let addressesBad = local_addresses.count > p.maxInventoryAddresses
            || local_addresses.contains { $0.isEmpty || $0.utf8.count > p.maxInventoryAddressCharacters }
        var appsBad = apps.count > p.maxInventoryApps
        for app in apps {
            if app.id.isEmpty || app.id.utf8.count > p.maxNameCharacters
                || app.name.isEmpty || app.name.utf8.count > p.maxNameCharacters
                || app.path.isEmpty || app.path.utf8.count > p.maxInventoryAppPathCharacters
                || (app.version?.utf8.count ?? 0) > p.maxVersionCharacters
                || (app.maker?.utf8.count ?? 0) > p.maxInventoryStringCharacters {
                appsBad = true
            }
        }
        guard tooLong || addressesBad || appsBad else { return nil }
        return "that Mac reported inventory outside the bounds this publisher accepts (at most "
            + "\(p.maxInventoryApps) apps, \(p.maxNameCharacters) characters for an app name or id, "
            + "\(p.maxVersionCharacters) for a version, \(p.maxInventoryAppPathCharacters) for a path, "
            + "\(p.maxInventoryStringCharacters) characters for any other text, "
            + "\(p.maxInventoryAddresses) addresses of \(p.maxInventoryAddressCharacters) characters)"
    }

    /// How the publisher reads the `inventory` value of a `/status` body: absent (an older agent
    /// that never sent one — the record is left as it was), accepted, or refused with a sentence.
    public enum InventoryRead: Sendable, Equatable {
        case absent
        case accepted(MacInventory)
        case refused(String)
    }
    public static func read(_ raw: Any?) -> InventoryRead {
        guard let raw else { return .absent }
        guard raw is [String: Any] else { return .refused("that Mac's inventory is not a JSON object") }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return .refused("that Mac's inventory could not be read as JSON")
        }
        let inventory: MacInventory
        do { inventory = try JSONDecoder().decode(MacInventory.self, from: data) }
        catch { return .refused("that Mac's inventory is not in a form this publisher accepts") }
        if let bad = inventory.boundViolation() { return .refused(bad) }
        return .accepted(inventory)
    }

    /// This snapshot as the JSON object the agent puts in its `/status` report.
    public func asJSONObject() -> [String: Any]? {
        let data = JSON.encode(self, pretty: false)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Collection (read-only, no new permissions, no external network)

    /// `system_profiler SPHardwareDataType` facts, parsed from its JSON. Each field is absent when
    /// the profile could not be read or did not say — never filled from anywhere else.
    public struct ProfilerFacts: Sendable, Equatable {
        public var model_name: String?
        public var model_id: String?
        public var chip: String?
        public var serial: String?
        public init(model_name: String? = nil, model_id: String? = nil, chip: String? = nil, serial: String? = nil) {
            self.model_name = model_name; self.model_id = model_id; self.chip = chip; self.serial = serial
        }
    }

    /// Parse the JSON `system_profiler SPHardwareDataType -json` prints. Bounded before it is
    /// parsed; a value longer than the report accepts is dropped rather than cut.
    public static func profilerFacts(_ json: String) -> ProfilerFacts {
        let limit = ReportPolicy.maxInventoryStringCharacters
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["SPHardwareDataType"] as? [[String: Any]],
              let row = rows.first else { return ProfilerFacts() }
        func text(_ key: String) -> String? {
            guard let value = row[key] as? String, !value.isEmpty, value.utf8.count <= limit else { return nil }
            return value
        }
        // A serial the system masks (or one it will not say) is not a serial to report.
        let serial = text("serial_number").map { value in
            value.allSatisfy { $0 == "*" } ? nil : value
        } ?? nil
        return ProfilerFacts(model_name: text("machine_name"), model_id: text("machine_model"),
                             chip: text("chip_type"), serial: serial)
    }

    static let profileJSONLimit = 64 << 10
    static let profileTimeout: TimeInterval = 15

    /// Collect this Mac's snapshot. Total, never throwing: anything unreadable stays absent.
    /// `shell` runs only the one constant `system_profiler` command (fixed arguments, no shell,
    /// hard deadline); everything else is sysctl, getifaddrs, filesystem reads.
    public static func collect(now: Date = Date(), shell: Shell = SystemShell()) -> MacInventory {
        var facts = ProfilerFacts()
        if let profile = try? shell.run("/usr/sbin/system_profiler", arguments: ["SPHardwareDataType", "-json"],
                                        timeout: profileTimeout), profile.exitCode == 0 {
            // Output of this one data type is a couple of kilobytes; the prefix keeps a runaway
            // answer from being parsed as a whole.
            let bounded = String(decoding: profile.stdout.utf8.prefix(profileJSONLimit), as: UTF8.self)
            facts = profilerFacts(bounded)
        }
        let addresses = interfaceAddresses()
        var inventory = MacInventory(
            model_id: facts.model_id ?? sysctlString("hw.model"),
            model_name: facts.model_name,
            chip: facts.chip ?? sysctlString("machdep.cpu.brand_string"),
            memory_bytes: sysctlUInt64("hw.memsize"),
            os_version: ProcessInfo.processInfo.operatingSystemVersionString,
            uptime_seconds: uptime(now: now),
            user: { let name = NSUserName(); return name.isEmpty ? nil : name }(),
            serial: facts.serial,
            tailscale_ipv4: addresses.tailscaleIPv4,
            tailscale_interface: addresses.tailscaleInterface,
            tailscale_name: nil,  // only Tailscale's own DNS name counts; never the local host name
            local_addresses: addresses.local)
        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            inventory.storage_total_bytes = values.volumeTotalCapacity.map { UInt64(clamping: $0) }
            inventory.storage_free_bytes = values.volumeAvailableCapacity.map { UInt64(clamping: $0) }
        }
        let roots = [URL(fileURLWithPath: "/Applications"),
                     URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")]
        let scan = scanAppBundles(roots: roots)
        inventory.apps = scan.apps
        inventory.apps_truncated = scan.truncated
        return inventory
    }

    /// The bounded `.app` walk. Never descends into a bundle; a plain folder is followed while it
    /// is within `maxDepth`. `truncated` says the listing is incomplete (cap, depth, or an entry
    /// that could not be recorded), so the page can say so instead of implying a full list.
    public static func scanAppBundles(roots: [URL], maxApps: Int = ReportPolicy.maxInventoryApps,
                                      maxDepth: Int = 4) -> (apps: [InventoryApp], truncated: Bool) {
        let fm = FileManager.default
        var apps: [InventoryApp] = []
        var truncated = false
        var stack: [(URL, Int)] = roots.map { ($0, 0) }
        while let (dir, depth) = stack.popLast() {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else {
                if fm.fileExists(atPath: dir.path) { truncated = true }
                continue
            }
            for item in items.sorted(by: { $0.lastPathComponent.localizedLowercase < $1.lastPathComponent.localizedLowercase }) {
                if apps.count >= maxApps { truncated = true; stack = []; break }
                if item.pathExtension.lowercased() == "app" {
                    if let app = appRecord(item) { apps.append(app) } else { truncated = true }
                    continue
                }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if depth + 1 <= maxDepth { stack.append((item, depth + 1)) } else { truncated = true }
            }
        }
        apps.sort { $0.path < $1.path }
        return (apps, truncated)
    }

    /// One bundle's own metadata, read straight from its Info.plist — no process per app. An
    /// entry whose id or path will not fit the bounds is dropped (and the scan says truncated).
    static func appRecord(_ url: URL) -> InventoryApp? {
        let p = ReportPolicy.self
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = readBounded(plistURL, limit: plistReadLimit),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fallbackName
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
        let maker = plist["CFBundleVendor"] as? String
        let path = url.path
        guard !name.isEmpty, name.utf8.count <= p.maxNameCharacters,
              id.utf8.count <= p.maxNameCharacters,
              path.utf8.count <= p.maxInventoryAppPathCharacters,
              (version?.utf8.count ?? 0) <= p.maxVersionCharacters,
              (maker?.utf8.count ?? 0) <= p.maxInventoryStringCharacters else { return nil }
        return InventoryApp(id: id, name: name, version: version, maker: maker, path: path)
    }

    static let plistReadLimit = 256 << 10

    static func readBounded(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? nil
    }

    /// `100.64.0.0/10` — the range Tailscale itself uses, the same one the publisher's feed URL
    /// rule accepts. Classification only; nothing here decides trust.
    public static func isTailscaleIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              let c = Int(parts[2]), let d = Int(parts[3]),
              (0...255).contains(a), (0...255).contains(b),
              (0...255).contains(c), (0...255).contains(d) else { return false }
        return a == 100 && (64...127).contains(b)
    }

    /// Every up, non-loopback IPv4: the Tailscale one (first, sorted) and the local rest.
    public static func interfaceAddresses() -> (tailscaleIPv4: String?, tailscaleInterface: String?, local: [String]) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (nil, nil, []) }
        defer { freeifaddrs(ifaddr) }
        var tailscale: [(String, String)] = []
        var local: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, ip.utf8.count <= ReportPolicy.maxInventoryAddressCharacters else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if isTailscaleIPv4(ip) { tailscale.append((ip, name)) }
            else if !local.contains(ip) && local.count < ReportPolicy.maxInventoryAddresses { local.append(ip) }
        }
        let best = tailscale.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.first
        local.sort()
        return (best?.0, best?.1, local)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty || value.utf8.count > ReportPolicy.maxInventoryStringCharacters ? nil : value
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }

    static func uptime(now: Date) -> Double? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        let seconds = now.timeIntervalSince1970 - TimeInterval(boot.tv_sec)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}
