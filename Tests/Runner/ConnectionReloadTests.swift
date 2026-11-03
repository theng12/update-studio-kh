import Foundation

private final class ConnectionReloadHTTP: HTTPClient, @unchecked Sendable {
    var requests: [(URL, [String: String])] = []
    func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
        requests.append((url, headers)); return (Data(), 503)
    }
    func post(_ url: URL, headers: [String: String], body: Data) throws -> (Data, Int) {
        requests.append((url, headers)); return (Data(), 503)
    }
    func download(_ url: URL, headers: [String: String], to file: URL, limit: Int64) throws -> Int { 503 }
}

func connectionReloadTests() {
    let root = tmpDir("connection-reload"), file = root.appendingPathComponent("config.json")
    let original = AgentConfig(feedURL: "http://100.64.0.1:8790/release.json", publicKey: "original-pin",
        stateDir: root.appendingPathComponent("state").path, machine: "same-mac", token: "old-token",
        apps: ["updater": AppConfig(bundlePath: "", recipe: "updater", automatic: false)], intervalMinutes: 60)
    var saved = original
    saved.feedURL = "http://100.64.0.2:8790/release.json"; saved.token = "repaired-token"
    saved.apps["updater"]?.automatic = true
    try! JSON.encode(saved).write(to: file)
    let current = try! original.reloadingConnection(from: file)
    let http = ConnectionReloadHTTP()
    _ = try? Agent.runOnce(config: current, http: http, appFolders: [])
    expect(!http.requests.isEmpty && http.requests.allSatisfy { $0.0.host == "100.64.0.2" }
           && http.requests.contains { $0.1["Authorization"] == "Bearer repaired-token" },
           "CR1 the next real agent run sends requests to the saved address with the repaired token")
    expect(current.apps == original.apps && current.machine == original.machine && current.publicKey == original.publicKey
           && current.intervalMinutes == original.intervalMinutes,
           "CR2 reloading connection leaves automation, identity, pin and pacing unchanged")
    for field in ["publicKey", "machine", "stateDir", "stubBase"] {
        var values = try! JSONSerialization.jsonObject(with: JSON.encode(saved)) as! [String: Any]
        values[field] = "different"
        try! JSONSerialization.data(withJSONObject: values).write(to: file)
        do { _ = try original.reloadingConnection(from: file); expect(false, "CR3 refuse a changed \(field)") }
        catch { expect(true, "CR3 refuse a changed \(field)") }
    }
    try! Data("unreadable".utf8).write(to: file)
    do { _ = try original.reloadingConnection(from: file); expect(false, "CR4 unreadable saved connection is a loud failure") }
    catch { expect(true, "CR4 unreadable saved connection is a loud failure") }
}
