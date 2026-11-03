import Foundation

/// Rendering is deliberately read-only; missing values never become inferred hardware facts.
enum PublisherInventory {
    static func facts(_ inventory: MacInventory?, lastSeen: String?, h: (String) -> String) -> String {
        func field(_ label: String, _ value: String?) -> String {
            let value = value.flatMap { $0.isEmpty ? nil : $0 }
            return "<dt>\(h(label))</dt><dd>" + (value.map { "<span>\(h($0))</span><button type=button class=small data-copy=\"\(h($0))\">Copy \(h(label.lowercased()))</button>" } ?? "<span class=sub>Not reported</span>") + "</dd>"
        }
        func bytes(_ value: UInt64?) -> String? {
            value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) }
        }
        var result = field("Last reachable report", lastSeen)
        result += field("Tailscale address", inventory?.tailscale_ipv4)
        result += field("Tailscale name", inventory?.tailscale_name)
        result += field("Local network addresses", (inventory?.local_addresses).flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") })
        result += field("macOS", inventory?.os_version)
        result += field("Model", inventory?.model_name)
        result += field("Model identifier", inventory?.model_id)
        result += field("Chip", inventory?.chip)
        result += field("Memory", bytes(inventory?.memory_bytes))
        result += field("Storage free", bytes(inventory?.storage_free_bytes))
        result += field("Storage total", bytes(inventory?.storage_total_bytes))
        result += field("Uptime", inventory?.uptime_seconds.map { "\(Int($0) / 86400) days, \((Int($0) % 86400) / 3600) hours, \((Int($0) % 3600) / 60) minutes" })
        result += field("Logged-in user", inventory?.user)
        result += field("Serial number", inventory?.serial)
        return "<dl class=identity>\(result)</dl><p class=inventorynote>Reported by this Mac’s Launcher. Last reachable means its last received report, not a new network probe. Unavailable values stay Not reported.</p>"
    }

    static func apps(_ inventory: MacInventory?, ownBundleIDs: Set<String>, h: (String) -> String) -> String {
        guard let inventory else { return "<h3>Installed app inventory</h3><p class=sub>Not reported by this Launcher yet.</p>" }
        let ownNames = Set(AppNames.names.values)
        func own(_ app: InventoryApp) -> Bool { ownBundleIDs.contains(app.id) || ownNames.contains(app.name) }
        let apps = inventory.apps.sorted { a, b in
            if own(a) != own(b) { return own(a) }
            return (a.name.localizedLowercase, a.path) < (b.name.localizedLowercase, b.path)
        }
        let rows = apps.map { app in
            "<tr><td class=name>\(h(app.name))\(own(app) ? " <span class=\"chip muted\">Our app</span>" : "")<div class=sub>\(h(app.id))</div></td><td class=num>\(h(app.version ?? "Not reported"))</td><td class=sub>\(h(app.maker ?? "Not reported"))</td><td><code>\(h(app.path))</code><button type=button class=small data-copy=\"\(h(app.path))\">Copy path</button></td></tr>"
        }.joined()
        return "<h3>Installed app inventory</h3><p class=inventorynote>Read-only inventory from /Applications and ~/Applications. Our apps appear first. No apps are installed or removed from this list.</p>"
            + "<p class=inventorynote>Scan limit: \(ReportPolicy.maxInventoryApps) apps, up to 4 folder levels.</p>"
            + (inventory.apps_truncated == true ? "<p class=warntext>Incomplete inventory: a scan limit was reached or some entries could not be read.</p>" : "")
            + (rows.isEmpty ? "<p class=sub>No apps reported.</p>" : "<div class=tablewrap><table class=inventorytable><thead><tr><th>App</th><th>Version</th><th>Maker</th><th>Location</th></tr></thead>\(rows)</table></div>")
    }
}
