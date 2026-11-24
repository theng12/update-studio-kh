import Foundation

/// Owner, 2026-11-24: one Launcher offered a drive's 0.1.75 as the update on a 0.1.81 Mac, and
/// another did not mention a newer 0.6.257 after 0.6.255 had been installed from the drive. Both
/// are the same question answered in two places; these pin the one place that answers it.
func appSourcesTests() {
    let drive = { (v: String) in AppSources.Source(name: "ATLAS", version: v) }
    let feed = { (v: String) in AppSources.Source(name: "the saved feed", version: v, isFeed: true) }

    // AS1 installed from a drive that carries a newer copy: the newer one is the offer, named.
    let c = AppSources(installed: "0.6.255", sources: [drive("0.6.256")])
    expect(c.order(drive("0.6.256")) == .newer && c.offer == "0.6.256",
           "AS1 a newer drive copy is offered (offer \(c.offer ?? "nil"))")
    expect(c.text == "This Mac has 0.6.255; ATLAS carries 0.6.256, newer.", "AS1 and is named (\(c.text ?? "nil"))")

    // AS2 installed newer than the drive's copy: older, and never the upgrade.
    let d = AppSources(installed: "0.6.256", sources: [drive("0.6.255")])
    expect(d.order(drive("0.6.255")) == .older && d.offer == "0.6.256",
           "AS2 an older drive copy is not the offer (\(d.offer ?? "nil"))")
    expect(d.text == "This Mac has 0.6.256; ATLAS carries 0.6.255, older.", "AS2 and is named older (\(d.text ?? "nil"))")

    // AS3 nothing installed: the feed's version is the reference, the drive is compared with it.
    let a = AppSources(installed: nil, sources: [feed("0.1.81"), drive("0.1.75")])
    expect(a.order(drive("0.1.75")) == .older && a.offer == "0.1.81", "AS3 the feed is the offer")
    expect(a.text == "This Mac has no copy yet; ATLAS carries 0.1.75, older.", "AS3 and both are named (\(a.text ?? "nil"))")

    // AS4 the drive is newer than a stale feed: it is the offer.
    let b = AppSources(installed: nil, sources: [feed("1.0"), drive("1.2")])
    expect(b.offer == "1.2" && b.text?.contains("NOVA") == false, "AS4 a newer drive copy is the offer")

    // AS5 nothing installed and no feed: the drive's copy is all there is.
    let e = AppSources(installed: nil, sources: [drive("1.2")])
    expect(e.offer == "1.2", "AS5 the drive's own copy is the offer (\(e.offer ?? "nil"))")

    // AS6 a copy whose version cannot be read is unknown, never current.
    let u = AppSources(installed: "0.6.255", sources: [drive("bad"), feed("0.6.255")])
    expect(u.order(drive("bad")) == .unknown && u.unknown.count == 1, "AS6 an unreadable copy is unknown")
    expect(u.text?.contains("cannot be compared") == true, "AS6 and the sentence says so (\(u.text ?? "nil"))")
    expect(u.offer == "0.6.255", "AS6 nothing is offered on an unknown comparison")

    // AS7 the feed alone, newer than what is here: the card's own version line already says it.
    let f = AppSources(installed: "1.0", sources: [feed("1.1")])
    expect(f.offer == "1.1" && f.text == nil, "AS7 a plain feed update needs no extra sentence")

    // AS8 an app that names its own version, with nothing else: that is a source too.
    let selfUpdating = AppSources(installed: "0.6.255", sources: [AppSources.Source(name: "its own updater", version: "0.6.257")])
    expect(selfUpdating.offer == "0.6.257" && selfUpdating.text?.contains("its own updater carries 0.6.257, newer") == true,
           "AS8 the app's own updater is named (\(selfUpdating.text ?? "nil"))")

    // AS9 installed, and no other copy known: said plainly rather than left to look current. With
    // nothing to compare, nothing is offered either — the row says "not in the feed", not current.
    let lonely = AppSources(installed: "0.6.255", sources: [])
    expect(lonely.text == "This Mac has 0.6.255; no other copy is known.", "AS9 nothing else is named (\(lonely.text ?? "nil"))")
    expect(lonely.offer == nil, "AS9 and no offer is invented (\(lonely.offer ?? "nil"))")
}
