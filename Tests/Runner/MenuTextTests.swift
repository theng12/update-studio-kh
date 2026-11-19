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
}
