import Foundation

/// The menu-bar line is a summary of an error, never a truncated copy of it. The defect that made
/// this test: a Mac stuck on a bare-IP feed showed "…which macOS refuses for an unencrypted feed; use
/// the publi…" in the menu, cutting the one instruction it gave.
func menuTextTests() {
    let stuck = "the saved address 100.82.91.102 is a bare IP, which macOS refuses for an unencrypted feed; use the publisher's host name instead"
    let line = MenuText.short(stuck)
    let kept = String(line.dropLast())          // without its ellipsis
    expect(line.count <= 90 && line.hasSuffix("…"),
           "MT1 a long sentence is shortened to one menu line (\(line.count) characters)")
    expect(stuck.hasPrefix(kept) && stuck.dropFirst(kept.count).first == " ",
           "MT1 the cut lands on the space after a whole word, never inside one (\(line))")
    expect(line == "the saved address 100.82.91.102 is a bare IP, which macOS refuses for an unencrypted…",
           "MT1 that exact sentence shortens to that exact line (\(line))")
    expect(MenuText.short("Update Studio could not be reached at 100.82.91.102") == "Update Studio could not be reached at 100.82.91.102",
           "MT2 a short sentence is shown whole")
    let oneWord = String(repeating: "x", count: 200)
    expect(MenuText.short(oneWord).count == 90 && MenuText.short(oneWord).hasSuffix("…"),
           "MT3 a single long word still fits the line instead of being dropped")

    // MT4 the other half: a 200-character operator sentence reaches the menu intact — the line is
    // shortened, and the item's tooltip carries every character, so nothing is lost.
    let long = stuck + " " + String(repeating: "and nothing is lost ", count: 9)
    let item = MenuText.item(long)
    expect(long.count >= 200, "MT4 the fixture sentence is at least 200 characters (\(long.count))")
    expect(item.title.hasSuffix("…") && long.hasPrefix(String(item.title.dropLast())),
           "MT4 a 200-character sentence is shortened to one whole-word line (\(item.title))")
    expect(item.tooltip == long, "MT4 the item carries the whole sentence, character for character")
    expect(MenuText.item("short enough").tooltip == nil, "MT4 a line that fits needs no tooltip")
}
