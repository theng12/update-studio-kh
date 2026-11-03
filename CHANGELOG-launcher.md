# What's new in Studio Launcher KH

The newest version is first. `khu publish` reads the top entry: `## <version> — <date>` and its "- " lines.

## 0.1.5 — 2026-11-03
- Mac names follow Hub’s current human label after matching its controller ID to the existing connection; renaming keeps the connection and sign-in intact.
- A new Mac connects through a native Connect to Update Studio screen with its publisher, Mac name, pairing code and connection result.
- Settings explain the current connection and offer a connection check without enrolling the Mac again or changing its Automatic choices.
- Pair again is an explicit, confirmed recovery for a removed connection: it requires the pairing code, keeps this Mac’s pinned key and app choices, and preserves the old sign-in in _trash.
- A different publisher needs its trusted Launcher connection package; an unverified address or pairing code cannot replace the existing trust.

## 0.1.4 — 2026-11-03
- Update Studio follows this Mac’s Hub Machine ID or computer name while keeping its enrolment connected.
- A label set on the Update Studio page stays until the Mac’s own name changes again.

## 0.1.3 — 2026-11-02
- Studio Launcher KH is a real app in Applications: Spotlight finds it, and opening it shows one window with every app for this Mac.
- The list comes from the feed and any plugged-in SSD. Each app shows its own icon, what is installed, the newest version and where it comes from, with Install, Update or Open.
- An SSD copy is checked against its checksum before it is installed, and installs the same way as a download, with rollback. When the feed and the SSD have the same version, the SSD copy is used.
- Story Studio KH, Hub Studio KH and Gateway Studio KH show their version and Open Setup Folder, since they update themselves.
- An app installed by hand is found and kept up to date too.
- On a Mac with no helper yet, opening Studio Launcher KH asks for the pairing code once and sets everything up.
- The menu has Open Studio Launcher.

## 0.1.2 — 2026-11-02
- Studio Launcher KH has a small icon in the menu bar on each Mac. It has no Dock icon and no window.
- The menu lists each app with its version and state: Up to date, Update available, Updating or Failed with the reason.
- Update now, Check for Updates Now, an Automatic switch per app, and Pause Automatic Updates for 24 Hours.
- Story Studio and Studio Hub update themselves, so they show their state and no switch.
- A Mac set up from now on has Automatic on.

## 0.1.1 — 2026-10-27
- Installing the agent from an SSD kit or Studio Hub also starts it, so a Mac starts reporting as soon as it enrols.
