import Foundation

/// Owner, 2026-11-24: Story's 1.4.419 row carried 29,955 characters of notes and the Launcher
/// rendered all of them. An ordinary release must read whole; a huge one must be honestly cut and
/// say what it left in the release.
func notesClampTests() {
    // NC1 an ordinary changelog is shown whole, bullets stripped and blank lines dropped.
    let ordinary = "- Opens What's New once per version.\n\n- Keeps your settings.\n- Fixes the buttons."
    expect(NotesClamp.lines(ordinary) == ["Opens What's New once per version.", "Keeps your settings.",
                                          "Fixes the buttons."],
           "NC1 an ordinary release reads whole (\(NotesClamp.lines(ordinary)))")

    // NC2 the 30 KB body: well under the cap plus one notice, and the notice names the rest.
    let huge = (1...400).map { "Line \($0) of a very long release body." }.joined(separator: "\n")
    let clamped = NotesClamp.lines(huge)
    let shown = clamped.dropLast().joined(separator: "\n").count
    expect(shown <= NotesClamp.limit,
           "NC2 a 30 KB body is cut at the cap (\(shown) of \(huge.count) characters)")
    expect(clamped.last?.contains("more line") == true,
           "NC2 and the last line says what was left in the release (\(clamped.last ?? "none"))")
    expect(clamped.count < 401, "NC2 far fewer lines are rendered than the body carries (\(clamped.count))")

    // NC3 a single line longer than the cap is shown cut, never dropped.
    let oneLine = String(repeating: "x", count: NotesClamp.limit * 3)
    let cut = NotesClamp.lines(oneLine)
    expect(cut.first?.count == NotesClamp.limit,
           "NC3 one enormous line is shown up to the cap, not dropped (\(cut.first?.count ?? 0))")

    // NC4 nothing, and a zero cap, are empty rather than a crash or a stray notice.
    expect(NotesClamp.lines(nil).isEmpty && NotesClamp.lines("").isEmpty, "NC4 no notes, no lines")
    expect(NotesClamp.lines("a\nb", limit: 0).isEmpty, "NC4 a zero cap renders nothing")
}