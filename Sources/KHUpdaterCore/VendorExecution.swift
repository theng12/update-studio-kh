import Foundation

struct VendorReceipt: Codable {
    var order: VendorOrder
    var destination: String
    var installerPath: String?
    var status: String
    var reason: String?
    static func file(_ state: URL, _ id: String) -> URL {
        state.appendingPathComponent("vendor-receipts").appendingPathComponent(id + ".json")
    }
}

extension Agent {
    static func installVendor(_ command: ServerCommand, config: AgentConfig, stateDir: URL,
                              http: HTTPClient, shell: Shell, control: (String, AppConfig) -> AppControl) throws -> RecipeResult {
        guard let order = command.vendor else { throw khuFail("vendor order has no signed catalog entry") }
        try order.validate(app: command.app)
        let names = ["tailscale": "Tailscale", "chrome": "Google Chrome", "telegram": "Telegram",
                     "yam-display": "Yam Display", "word": "Microsoft Word", "excel": "Microsoft Excel"]
        guard let name = names[order.entry.id] else { throw khuFail("unknown vendor app; refused") }
        let cfg = config.apps[command.app] ?? AppConfig(bundlePath: "/Applications/\(name).app", bundleID: order.entry.bundleID)
        let registration = stateDir.appendingPathComponent("vendor-apps.json")
        var apps = try AtomicFile.readJSON([String: AppConfig].self, from: registration) ?? [:]
        apps[command.app] = cfg
        try AtomicFile.writeJSON(apps, to: registration)
        var client: HTTPClient = http
        if var live = http as? URLSessionHTTPClient {
            live.officialHosts = order.entry.officialHosts
            client = live
        }
        let source = try VendorSource.resolve(order.entry, http: client)
        let outcome = VendorInstaller.install(entry: order.entry, kind: order.kind, sourceURL: source,
            stateDir: stateDir.path, destination: cfg.bundlePath, http: client, shell: shell,
            control: control(command.app, cfg), byteCap: order.byteCap)
        let receipt = VendorReceipt(order: order, destination: cfg.bundlePath, installerPath: outcome.installerPath,
                                    status: outcome.status, reason: outcome.reason)
        do { try AtomicFile.writeJSON(receipt, to: VendorReceipt.file(stateDir, order.entry.id)) }
        catch {
            return RecipeResult(status: outcome.status,
                reason: (outcome.reason.map { $0 + "; " } ?? "") + "the receipt could not be saved (\(error))",
                version: outcome.version)
        }
        return RecipeResult(status: outcome.status, reason: outcome.reason, version: outcome.version)
    }

    static func vendorRows(stateDir: URL) -> [HelperApp] {
        let folder = stateDir.appendingPathComponent("vendor-receipts")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { file in
            guard file.pathExtension == "json", let receipt = try? AtomicFile.readJSON(VendorReceipt.self, from: file) else { return nil }
            let version = (try? BundleInfo.read(receipt.destination)).flatMap { $0.identifier == receipt.order.entry.bundleID ? $0.version : nil }
            var row = HelperApp(app: "vendor-" + receipt.order.entry.id, installed: version, available: nil,
                statusOnly: true, automatic: false,
                status: receipt.status.replacingOccurrences(of: "_", with: " "), reason: receipt.reason)
            row.name = receipt.order.entry.name
            row.source = "Official vendor"
            row.bundlePath = version == nil ? nil : receipt.destination
            row.bytes = receipt.order.byteCap
            row.setupFolder = receipt.installerPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            return row
        }.sorted { $0.name < $1.name }
    }
}
