import Foundation

struct VendorPreferences: Codable {
    var retired: Set<String> = []
    var byteCap: Int64 = 4 * 1024 * 1024 * 1024
    static func url(_ state: URL) -> URL { state.appendingPathComponent("other-apps-settings.json") }
    static func load(_ state: URL) throws -> Self {
        try AtomicFile.readJSON(Self.self, from: url(state)) ?? Self()
    }
}

extension FeedServer {
    func vendorRequest(_ req: HTTPRequest) -> HTTPResponse {
        guard OwnerAccess.isSameSite(req.headers, port: port) else { return Self.text(403, "cross-site request refused") }
        let fields = OwnerAccess.fields(req)
        let response = transact { state in
            var catalog = try VendorCatalog.load(from: VendorCatalog.url(in: stateDir.path))
            var preferences = try VendorPreferences.load(stateDir)
            guard let id = fields["app"], let index = catalog.entries.firstIndex(where: { $0.id == id }) else {
                return Self.text(404, "no catalog app")
            }
            switch req.path {
            case "/api/vendor-edit":
                guard let source = fields["source"], let hosts = fields["hosts"], let team = fields["team"],
                      let bundle = fields["bundle"], let evidence = fields["evidence"], !evidence.isEmpty,
                      let cap = fields["byteCap"].flatMap(Int64.init), cap > 0,
                      source.utf8.count <= 4096, hosts.utf8.count <= 4096, team.count <= 64,
                      bundle.count <= 256, evidence.utf8.count <= 4096 else {
                    return Self.text(400, "send source, official hosts, signing Team ID, bundle ID, evidence and a positive download byte limit")
                }
                var entry = catalog.entries[index]
                entry.sourceURL = source
                guard let sourceKind = VendorEntry.SourceKind(rawValue: fields["sourceKind"] ?? entry.sourceKind.rawValue) else {
                    return Self.text(400, "choose a known source type")
                }
                entry.sourceKind = sourceKind
                entry.sourceMatch = fields["sourceMatch"] ?? entry.sourceMatch
                entry.officialHosts = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                entry.teamID = team; entry.bundleID = bundle; entry.teamIDEvidence = evidence
                entry.enabled = true
                do { try VendorOrder(entry: entry, kind: VendorOrder.kind(for: id), byteCap: cap).validate(app: "vendor-" + id) }
                catch { return Self.text(400, "\(error)") }
                entry.enabled = false
                catalog.entries[index] = entry
                try catalog.save(to: VendorCatalog.url(in: stateDir.path))
                preferences.byteCap = cap
                try AtomicFile.writeJSON(preferences, to: VendorPreferences.url(stateDir))
                // Refresh only waiting installs; editing a source never starts a new install.
                for machine in state.machines.keys {
                    var mac = state.machines[machine]!
                    mac.pending = mac.pending.map { command in
                        guard command.action == ServerCommand.vendorInstall, var payload = command.vendor else { return command }
                        if payload.entry.id == id { payload.entry = entry; payload.entry.enabled = true }
                        payload.byteCap = cap
                        guard payload != command.vendor else { return command }
                        return ServerCommand(machine: machine, app: command.app, action: command.action, vendor: payload)
                    }
                    state.machines[machine] = mac
                }
            case "/api/vendor-retire", "/api/vendor-restore":
                if req.path == "/api/vendor-retire" {
                    preferences.retired.insert(id)
                    for machine in state.machines.keys {
                        state.machines[machine]?.vendorAssignments?[id] = false
                        state.machines[machine]?.pending.removeAll { $0.action == ServerCommand.vendorInstall && $0.app == "vendor-" + id }
                    }
                } else {
                    preferences.retired.remove(id)
                }
                try AtomicFile.writeJSON(preferences, to: VendorPreferences.url(stateDir))
            case "/api/vendor-assign":
                guard !preferences.retired.contains(id) else { return Self.text(409, "restore this app before assigning it") }
                let machines = fields.filter { $0.key.hasPrefix("mac-") && $0.value == "on" }
                    .map { String($0.key.dropFirst(4)) }.sorted()
                guard !machines.isEmpty, machines.allSatisfy({ state.machines[$0]?.tokenHash != nil }) else {
                    return Self.text(400, "select enrolled Macs")
                }
                guard machines.count == 1 || fields["confirmed"] == "true" else {
                    return Self.text(400, "confirm installation on the selected Macs")
                }
                let on = fields["on"] == "true"
                var entry = catalog.entries[index]; entry.enabled = on
                let order = VendorOrder(entry: entry, kind: VendorOrder.kind(for: id), byteCap: preferences.byteCap)
                if on {
                    do { try order.validate(app: "vendor-" + id) }
                    catch { return Self.text(400, "\(error)") }
                }
                for machine in machines {
                    var mac = state.machines[machine]!
                    mac.vendorAssignments = (mac.vendorAssignments ?? [:]).merging([id: on]) { _, new in new }
                    mac.pending.removeAll { $0.action == ServerCommand.vendorInstall && $0.app == "vendor-" + id }
                    if on {
                        mac.pending.append(ServerCommand(machine: machine, app: "vendor-" + id,
                                                         action: ServerCommand.vendorInstall, vendor: order))
                    }
                    state.machines[machine] = mac
                }
            default: return Self.text(404, "not found")
            }
            return Self.ok
        }
        if response.status == 200, (req.headers["content-type"] ?? "").hasPrefix("application/x-www-form-urlencoded") {
            var back = HTTPResponse(303, "text/plain; charset=utf-8", "")
            back.headers = ["Location": "/#apps"]
            return back
        }
        return response
    }

    func vendorHTML(_ state: ServerState) -> String {
        func h(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        do {
            let catalog = try VendorCatalog.load(from: VendorCatalog.url(in: stateDir.path))
            let prefs = try VendorPreferences.load(stateDir)
            let rows = catalog.entries.map { entry -> String in
                let id = h(entry.id), retired = prefs.retired.contains(entry.id)
                let macs = state.machines.values.filter { $0.tokenHash != nil }.sorted { $0.name < $1.name }.map { mac -> String in
                    let assigned = mac.vendorAssignments?[entry.id] == true
                    let pending = mac.pending.contains { $0.action == ServerCommand.vendorInstall && $0.app == "vendor-" + entry.id }
                    let result = mac.lastResults?["vendor-" + entry.id]
                    let message = pending ? (mac.capabilities?.contains(AgentCapability.vendorInstall) == true ? "Install requested" : "Waiting for compatible Launcher")
                        : result.map { $0.status.replacingOccurrences(of: "_", with: " ") + ($0.reason.map { ": " + $0 } ?? "") } ?? (assigned ? "Assigned; no result yet" : "Off")
                    return "<label class=setting><span><input type=checkbox name=\"mac-\(h(mac.machine))\"\(assigned ? " checked" : "")> \(h(mac.name))</span><span class=sub>\(h(message))</span></label>"
                }.joined()
                func input(_ name: String, _ label: String, _ value: String) -> String {
                    "<label>\(label)<input name=\"\(name)\" value=\"\(h(value))\" required></label>"
                }
                let sourceTypes: [(VendorEntry.SourceKind, String)] = [(.direct, "Direct file"), (.latestAlias, "Current-version alias"), (.pageLink, "Link on vendor page"), (.unresolved, "Not available")]
                let sourceOptions = sourceTypes.map { kind, label in
                    "<option value=\"\(kind.rawValue)\"\(kind == entry.sourceKind ? " selected" : "")>\(label)</option>"
                }.joined()
                let sourceControl = "<label>Source type<select name=sourceKind>\(sourceOptions)</select></label><label>Page link must contain<input name=sourceMatch value=\"\(h(entry.sourceMatch ?? ""))\"></label>"
                let edit = "<details class=notes><summary>Official source and identity</summary><form method=post action=/api/vendor-edit><input type=hidden name=app value=\"\(id)\">"
                    + sourceControl + input("source", "Official source URL", entry.sourceURL)
                    + input("hosts", "Official hosts (comma separated)", entry.officialHosts.joined(separator: ", "))
                    + input("team", "Signing Team ID", entry.teamID ?? "") + input("bundle", "Bundle ID", entry.bundleID ?? "")
                    + input("evidence", "Identity evidence", entry.teamIDEvidence ?? "")
                    + input("byteCap", "Download limit in bytes (for all other apps)", String(prefs.byteCap)) + "<button>Save source</button></form></details>"
                let retire = "<form method=post action=/api/vendor-\(retired ? "restore" : "retire") data-confirm=\"\(retired ? "Restore this app? Assignments stay off." : "Retire this app and cancel its waiting installs?")\"><input type=hidden name=app value=\"\(id)\"><button>\(retired ? "Restore" : "Retire")</button></form>"
                let assign = retired ? "<p class=sub>Retired. Source and history are kept; restore to assign again.</p>" : entry.sourceKind == .unresolved ? "<p role=alert>Installer source is not available. \(h(entry.notes ?? "Set a verified official source before assigning."))</p>" : "<details class=notes><summary>Choose Macs</summary><form method=post action=/api/vendor-assign data-confirm=\"Apply this choice to the selected Macs?\"><input type=hidden name=app value=\"\(id)\">\(macs.isEmpty ? "<p>No Macs enrolled.</p>" : macs)<label><input type=checkbox name=confirmed value=true required> Confirm this choice for the selected Macs</label><button name=on value=true>Assign and install</button><button name=on value=false>Turn off</button></form></details>"
                return "<div class=setting><div><h3>\(h(entry.name))</h3><p class=sub>\(VendorOrder.kind(for: entry.id) == .pkg ? "Package signature is checked before an administrator finishes installation on the Mac." : "App signature is checked before installation; existing app identity must match.")</p>\(retire)</div><div>\(assign)\(edit)</div></div>"
            }.joined()
            return "<h2>Other apps</h2><p class=sub>Off until assigned. Downloads use official sources and verified vendor signatures. Accounts and licences stay yours. Turning off cancels waiting installs and keeps installed apps. Download limit: \(prefs.byteCap) bytes.</p><div class=settingslist>\(rows)</div>"
        } catch {
            return "<h2>Other apps</h2><p role=alert>Catalog could not be read: \(h("\(error)")). Existing files were kept.</p>"
        }
    }
}
