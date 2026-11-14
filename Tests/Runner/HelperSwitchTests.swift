import Foundation

func helperSwitchTests() {
    // One temp state dir per load, removed as soon as the settings are read.
    func load(_ json: String) -> HelperSettings {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("khu-hs-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try! json.write(to: dir.appendingPathComponent("helper.json"), atomically: true, encoding: .utf8)
        return HelperSettings.load(from: dir)
    }

    // HS1: a bare boolean is a valid Mac switch with no time, and it beats the config default.
    let bare = load(#"{"automatic":{"hub":true}}"#)
    let hs1 = bare.automaticDecision("hub", page: nil, pageAt: nil, config: false)
    expect(bare.automatic["hub"]?.on == true, "HS1 a bare-bool automatic switch decodes")
    expect(hs1.on && hs1.origin == .mac, "HS1 a bare-bool Mac switch beats the config default")

    // HS2: with no page time the page cannot beat a timeless switch.
    let hs2 = bare.automaticDecision("hub", page: false, pageAt: nil, config: false)
    expect(hs2.on && hs2.origin == .mac, "HS2 a bare-bool Mac switch beats an untimed page value")

    // HS3: a timed switch keeps the later-wins rule.
    let now = ISO.string(Date())
    let timed = load("{\"automatic\":{\"hub\":{\"on\":true,\"at\":\"\(now)\"}}}")
    let tie = timed.automaticDecision("hub", page: false, pageAt: now, config: true)
    let older = timed.automaticDecision("hub", page: false,
                                        pageAt: ISO.string(Date(timeIntervalSince1970: 1_800_000_000)),
                                        config: true)
    let later = timed.automaticDecision("hub", page: false,
                                        pageAt: ISO.string(Date().addingTimeInterval(3600)), config: true)
    expect(tie.on && tie.origin == .mac, "HS3 a page value at the switch's own time is a tie the Mac keeps")
    expect(older.on && older.origin == .mac, "HS3 an older page value loses to the Mac's switch")
    expect(!later.on && later.origin == .page, "HS3 a strictly later page value wins")

    // HS4: an unparseable time does not drop the switch.
    let badTime = load(#"{"automatic":{"hub":{"on":false,"at":"not-a-date"}}}"#)
    let hs4 = badTime.automaticDecision("hub", page: true, pageAt: now, config: true)
    expect(badTime.automatic["hub"]?.on == false, "HS4 a switch with an unparseable time still loads")
    expect(!hs4.on && hs4.origin == .mac, "HS4 a switch with an unparseable time still wins")

    // HS5: checkManually and a bare-bool switch survive in the same file.
    let both = load(#"{"automatic":{"hub":true},"checkManually":true}"#)
    expect(!both.installsAutomatically && both.automatic["hub"]?.on == true,
           "HS5 checkManually and a bare-bool hub switch both survive the load")
}
