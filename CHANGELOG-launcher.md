# What's new in Studio Launcher KH

The newest version is first. `khu publish` reads the top entry: `## <version> — <date>` and its "- " lines.

## 0.1.12 — 2026-11-05
- Download apps from a preferred signed-feed host, with fallback to the original publisher when needed. Every feed and installer still has to match the pinned signature and checksum.
- Local install requests can continue from a verified mirror while the original publisher is unavailable; remote orders and Automatic wait safely.
- A chosen Mac can host verified app downloads through an optional role that starts off. The signing key stays with the original publisher.

## 0.1.11 — 2026-11-05
- The install SSD offers Update installed apps: install Launcher and update or repair the KH apps already on this Mac, with a result for each app.
- SSD installers are checked against their checksums; newer installed apps, existing pauses and saved connections are preserved. Apps that cannot be updated safely say why.
- Launcher keeps its app list and connection setup together; a new Mac can install Launcher before connecting.
- After repeated healthy reports, older helper versions move to the restorable _trash folder. The current and previous versions stay, and Settings can switch this cleanup off.
- The SSD action supports the released Story installer’s normal packaging. Installer cleanup uses the mounted device ID, supports APFS images, and refuses SSD volume paths.
- Pause-download tests clean up their temporary files after success or failure.

## 0.1.10 — 2026-11-04
- Opening a Launcher copy uses this Mac's running helper before asking to connect, and gives a starting helper time to open the main window.
- A refused saved sign-in opens connection settings with Pair again; existing app choices and saved data stay in place.
- The connection window opens in the centre and behaves like a normal window, so other windows remain usable.
- Includes incomplete-setup repair and safe connection retries from 0.1.9.

## 0.1.9 — 2026-11-04
- Connect repairs an incomplete local setup while keeping saved app data and earlier versions.
- A connection interrupted during local setup can be retried without removing the Mac again.
- Reopening Launcher retries starting a helper that could not start after setup.

## 0.1.8 — 2026-11-03
- Accept explicitly assigned Other apps from Update Studio, using official HTTPS downloads and verified vendor signatures.
- App installs preserve rollback protection and refuse an existing app with a different identity.
- Packages need an administrator to finish in the vendor’s Installer. Launcher shows the result and opens the setup folder; it never asks for account or licence details.
- Other apps stay off until assigned. Turning off a waiting assignment leaves installed apps in place.

## 0.1.7 — 2026-11-03
- Connect to Update Studio works over Tailscale HTTP on current macOS, with the exception limited to Tailscale addresses.
- The first-run Update Studio address is editable and starts with the kit’s saved address; the publisher’s pinned key is still required.

## 0.1.6 — 2026-11-03
- Update Studio receives this Mac’s reported hardware, connection details and installed-app inventory without asking for new macOS permissions.
- Missing details remain unreported; app inventory is read-only and does not install or remove other makers’ apps.

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
