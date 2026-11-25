import Foundation

/// The Launcher's own update hold, measured over its real socket: no token is refused, a GET is
/// named as not a hold request, and an install in progress makes `safe:false` name the app — the
/// refusal Sparkle's shim reads rather than a boolean it guesses.
func launcherHoldTests() {
    final class Busy: @unchecked Sendable {
        private let lock = NSLock()
        private var apps: [String] = []
        func set(_ next: [String]) { lock.lock(); apps = next; lock.unlock() }
        func get() -> [String] { lock.lock(); defer { lock.unlock() }; return apps }
    }
    struct Reply { var code = 0; var body: [String: Any] = [:]; var allow: String? }

    func call(_ port: UInt16, _ method: String, token: String? = nil) -> Reply {
        var reply = Reply()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(LauncherHold.path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.code = (response as? HTTPURLResponse)?.statusCode ?? -1
            reply.allow = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Allow")
            reply.body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return reply
    }

    let busy = Busy()
    let hold = LauncherHold(token: "fixture-token", busy: { busy.get() })
    do { try hold.start(port: nil) } catch { expect(false, "HH1 fixture: \(error)"); return }
    var waited = 0.0
    while hold.boundPort == nil && waited < 3 { Thread.sleep(forTimeInterval: 0.05); waited += 0.05 }
    guard let port = hold.boundPort else { expect(false, "HH1 the hold port never opened"); return }
    defer { hold.stop() }

    // HH1 no token, and a wrong one, are refused with the reason.
    do {
        let anonymous = call(port, "POST"), wrong = call(port, "POST", token: "not-it")
        expect(anonymous.code == 401 && wrong.code == 401,
               "HH1 a hold without the Launcher's token is refused (401/\(anonymous.code), \(wrong.code))")
    }

    // HH2 a GET is not a hold request, and the answer says what is.
    do {
        let got = call(port, "GET", token: "fixture-token")
        expect(got.code == 405 && got.allow?.contains("POST") == true,
               "HH2 GET answers 405 and names POST/DELETE (\(got.code), Allow \(got.allow ?? "none"))")
    }

    // HH3 mid-install: the answer refuses and names the app.
    do {
        busy.set(["displays-studio"])
        let held = call(port, "POST", token: "fixture-token")
        let unsettled = held.body["unsettled"] as? [String] ?? []
        expect(held.code == 200 && held.body["safe"] as? Bool == false && unsettled == ["displays-studio"],
               "HH3 an install in progress is safe:false naming the app (\(held.body))")
        expect(held.body["in_flight"] as? Int == 1 && held.body["dispatch_paused_s"] as? Int == 120,
               "HH3 the reply carries the contract's five keys")
    }

    // HH4 idle: safe to replace.
    do {
        busy.set([])
        let idle = call(port, "POST", token: "fixture-token")
        expect(idle.code == 200 && idle.body["safe"] as? Bool == true
               && (idle.body["unsettled"] as? [String])?.isEmpty == true,
               "HH4 with nothing installing the Launcher is safe to replace (\(idle.body))")
    }

    // HH5 DELETE resumes: still safe, and it is accepted as a hold request.
    do {
        let resumed = call(port, "DELETE", token: "fixture-token")
        expect(resumed.code == 200 && resumed.body["safe"] as? Bool == true,
               "HH5 DELETE answers like a resume (\(resumed.code))")
    }

    // HH6 the token file is the Launcher's own: 0600, and reading it twice gives the same value.
    do {
        let dir = tmpDir("launcher-hold-token")
        let first = try? LauncherHold.token(in: dir)
        let second = try? LauncherHold.token(in: dir)
        let mode = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(LauncherHold.tokenName).path))?[.posixPermissions] as? NSNumber
        expect(first != nil && first == second && (first?.count ?? 0) == 64,
               "HH6 the token is created once and stays the same")
        expect(mode?.intValue == 0o600, "HH6 the token file is 0600 (\(mode?.intValue ?? -1))")
        expect(LauncherHold.url == "http://127.0.0.1:8792/api/maintenance/hold",
               "HH6 the fixed URL matches the contract's port table")
    }

    // HH7 pause/resume primitives: waitUntilBound, POST pauses and waitForResume blocks until
    // DELETE wakes it promptly, release() clears a pause, and the pause expires past pauseSeconds.
    do {
        final class LogBox: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let log = LogBox()
        let gated = LauncherHold(token: "fixture-token", busy: { [] }, log: { log.append($0) })
        do { try gated.start(port: nil) } catch { expect(false, "HH7 fixture: \(error)"); return }
        defer { gated.stop() }
        let bound = gated.waitUntilBound(timeout: 3)
        expect(bound && gated.boundPort != nil, "HH7 waitUntilBound observes the bound port")
        guard let gport = gated.boundPort else { return }

        expect(!gated.paused(), "HH7 unpaused before POST")
        _ = call(gport, "POST", token: "fixture-token")
        expect(gated.paused(), "HH7 POST puts the hold in paused state")
        expect(!gated.paused(at: Date().addingTimeInterval(Double(LauncherHold.pauseSeconds + 1))),
               "HH7 pause expires past pauseSeconds without a latch")

        let resumedInTime = DispatchSemaphore(value: 0)
        final class WaitResult: @unchecked Sendable { var stillPaused = true; var elapsed = 99.0 }
        let waited = WaitResult()
        let started = Date()
        DispatchQueue.global().async {
            waited.stillPaused = gated.waitForResume(limit: 5)
            waited.elapsed = Date().timeIntervalSince(started)
            resumedInTime.signal()
        }
        Thread.sleep(forTimeInterval: 0.15)
        _ = call(gport, "DELETE", token: "fixture-token")
        let signaled = resumedInTime.wait(timeout: .now() + 3) == .success
        expect(signaled && !waited.stillPaused && waited.elapsed < 2.0,
               "HH7 DELETE wakes waitForResume promptly (signaled=\(signaled), paused=\(waited.stillPaused), elapsed=\(waited.elapsed))")

        _ = call(gport, "POST", token: "fixture-token")
        expect(gated.paused(), "HH7 second POST pauses again")
        gated.release()
        expect(!gated.paused(), "HH7 release() clears pause immediately")
        let lines = log.all()
        expect(lines.contains(where: { $0.contains("held; new work paused") }) && lines.last == "resumed",
               "HH7 log records held and resumed (\(lines))")
    }

    // HH8 cross-app Sparkle install-in-progress marker contract (khsparkle.m:65-85).
    do {
        let fakeHome = tmpDir("sparkle-install-marker")
        let defaultURL = SparkleInstallMarker.fileURL(home: fakeHome, environment: [:])
        expect(defaultURL.path == fakeHome.appendingPathComponent("Library/Application Support/kh-sparkle/install-in-progress").path,
               "HH8 default marker path matches khsparkle.m (\(defaultURL.path))")

        let overridePath = fakeHome.appendingPathComponent("custom/marker").path
        let overrideURL = SparkleInstallMarker.fileURL(home: fakeHome, environment: ["KH_SPARKLE_INSTALL_MARKER": overridePath])
        expect(overrideURL.path == overridePath, "HH8 KH_SPARKLE_INSTALL_MARKER overrides default path")

        SparkleInstallMarker.set("story", home: fakeHome, environment: [:])
        let content = try? String(contentsOf: defaultURL, encoding: .utf8)
        let mode = (try? fm.attributesOfItem(atPath: defaultURL.path))?[.posixPermissions] as? NSNumber
        expect(content == "story\n" && mode?.intValue == 0o600,
               "HH8 set(app) writes mode 0600 marker naming the app (\(content ?? "nil"), \(mode?.intValue ?? -1))")

        SparkleInstallMarker.set(nil, home: fakeHome, environment: [:])
        expect(!fm.fileExists(atPath: defaultURL.path), "HH8 set(nil) removes the marker cleanly")
    }
}
