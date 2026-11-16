# What's new in Studio Launcher KH

The newest version is first. `khu publish` reads the top entry: `## <version> — <date>` and its "- " lines.




## 0.1.48 — 2026-11-17

- An owner's order can no longer become undrivable because one Mac never answered it. A new order for the same app on the same Mac now replaces an order older than 30 minutes instead of being silently swallowed, and a swallowed order is recorded in the publisher's own log, so a stuck order cannot sit invisible for an hour again.
- A download is no longer stopped by a flat ten-minute clock. The time allowed now comes from the size of the artifact, with the clock only as a hard backstop: a stalled small file still fails fast, and a large artifact on a slow link is allowed to finish.
- The publisher now records each order it hands to a Mac, with the order ids and the clock gap, so "the Mac is online and doing nothing" can be answered from the log.

## 0.1.47 — 2026-11-17

- No change in what the helper does: this release carries the same behaviour as 0.1.46, with the checks behind the unattended quit split so that a failing one names itself instead of hiding behind a single combined line.

## 0.1.46 — 2026-11-16

- An app whose build predates its update hold is now updated the way it was before holds existed: the Launcher quits it, swaps it and reopens it, so a Mac with an old build can be updated with nobody sitting at it. This is the owner's temporary order for this release, and it is removed once the fleet is past the hold: the app's idle check is now recorded rather than obeyed. A quit that the app does not complete within its own time limit fails that attempt with the reason, and nothing is replaced — an app is never killed.

- Hub's idle check now says why it refused, in the words the operator needs: "no database at …", "file is not a database", "database is locked" or "unable to open database file", instead of a bare "exited 1 (no output)" that made a missing database, a missing `sqlite3`, a moved data folder and a genuinely busy Hub all look the same. The check itself is unchanged, and it still fails closed.
- The check runs with the user's real home folder and a fixed `PATH` exported into it, and calls `/usr/bin/sqlite3` directly, so a launch agent's bare environment cannot change what it finds.

## 0.1.45 — 2026-11-16

- Hub's idle check comes with the helper, so no Mac has to be visited to arm it: it is Hub's own condition, and it fails closed — a missing, unreadable or corrupt Hub database answers "not idle", so that Mac waits rather than quitting a working Hub. A Mac can overrule it: `idleProbe` in that Mac's `apps.hub` settings replaces the built-in check, and an empty `idleProbe` turns the unattended quit off there. No other app is affected.
- Every unattended quit now says four things in that Mac's own log: what the idle check answered (its exit status, and the reason it gave when it refused), whether the app exited and how long it took or that its time limit was reached, whether its background services started, and whether it came back and as which version. So a Mac that stalls, refuses or half-restarts says which of the four failed, instead of looking like it worked.

## 0.1.44 — 2026-11-16

- When an app refuses or fails an automatic update, this Mac's own log now says which app, which version and why. Each reason is logged once, not every 5 minutes, and is logged again after the next successful update.
- The What's New dialog on the publisher page is bigger and shows more detail, the same as in the Update Studio KH window.
- An app build older than its update hold (for example Hub 0.6.235, where the hold first shipped in 0.6.240) is no longer reported as "refused the update hold (credential)". It now says it needs one normal install while the app is closed, naming both versions. The feed records the first version of each app's hold (`holdSince`); `khu publish --hold-since <version>` sets it for an app published before this field existed.
- An update for an app whose build has no update hold yet no longer fails once and is dropped. The owner's order stays pending and installs on the first run that finds the app closed, with nobody needed at the Mac. The Mac's row on the publisher page says "Waiting for <app> to close" and why. An order waits up to 14 days (`waitForCloseDays` in the agent config); after that it is refused with the reason, so the wait always ends.
- An owner's order can now finish on a Mac nobody is sitting at: for a build older than its update hold, the Launcher quits the app, swaps it and reopens the new one, the way updates worked before holds existed. This happens only when that app's own idle check answers that nothing is running or queued — one small command per app, `idleProbe` in the agent config, exit 0 = safe. No idle check configured, a non-zero answer, an unreadable answer or one that takes longer than 15 seconds all mean the app is **not** quit: the order keeps waiting for it to close and the log says in one line what the check saw. An app that will not quit within its own time limit is left exactly as it was and reported as a refusal with the reason.
- `quitOldBuilds` in the agent config turns this off for a Mac (`false` = never quit an old build; unset = on, for orders only — Automatic updates always wait).

## 0.1.43 — 2026-11-16

- Gateway's real hold route, `/admin/api/maintenance/drain`, is now a trusted endpoint: the exact path only, on loopback with an explicit port. Any other `/admin/…` path, a longer path, a query string or a fragment is rejected, both when the feed is validated and when the hold is taken.

## 0.1.42 — 2026-11-16

- Apps whose update-hold route is gated now get the Launcher's own credential: a 0600 file at `~/Library/KHUpdater/state/hold-token`, reissued atomically every time the background engine starts, presented only on the loopback hold request. The Launcher never reads an app's own credential file.
- The recorded reason now says exactly which step stopped an update: the installed build has no hold endpoint (one normal install while the app is closed will fix it), the app refused the credential, the feed's address does not match the build, or the endpoint answered another status. A failed download stays a separate reason.
- Held → paused → updating → resumed is unchanged, and the reply's in-flight work is still named.

## 0.1.41 — 2026-11-15

- Updating a running app now pauses its work first: the Launcher asks the app for an update gap inside one 30-second window (a silent app fails the request instead of stalling it), updates in that gap, and the app resumes by itself. Queued work is kept and the result says how much was held.
- The app is checked again immediately before the swap: one opened while the installer downloads is held then, or refused if it offers no gap; one that has closed is never quit. A missing or unreadable replacement is refused before anything is stopped, so a failed update can never leave the Mac with no app.
- An app that cannot offer a gap is left untouched and the update says why; quit it by hand and it updates normally. The updater's own engine and this Launcher are exempt — they hold no work queue.
- A rollback and a local SSD update follow the same rule: a running app is held first or refused.
- Fixed a defect that could retire the app that had just been installed: the duplicate-app sweep now resolves links before comparing, never treats the installed app as a candidate, and retires nothing when it cannot read the installed app.

## 0.1.40 — 2026-11-15

- Updating a running app now pauses its work first: the Launcher asks the app for an update gap (it waits up to 20 seconds; work already running gets up to 30 to settle), updates in that gap, then the app resumes by itself. Queued work is kept, and the result says how much work was held.
- An app that cannot offer such a gap is left untouched: the update is refused with a plain reason instead of quitting it under its work. Quit it by hand and it updates normally. The updater's own engine and this Launcher are exempt — they hold no work queue.
- An app whose gap expires while its installer downloads is asked again just before the swap; if it can no longer settle, the swap is refused and the app is resumed.

## 0.1.39 — 2026-11-15

- A failure now shows its own words whole: the job name and exit code are no longer cut off at the first full stop, and the next step stays readable.
- The in-page confirmation is a real dialog: it takes the keyboard focus, Escape cancels, Tab stays on its two buttons, and a click outside cancels. Closing it returns focus to where you were; if a status refresh replaced that control, focus goes to Settings instead of nowhere.
- One limit is stated plainly: if an app's helper runs as a child of the app itself rather than as a launchd job, the app can still refuse to quit. The update says so and keeps the app; quitting that app by hand then lets the update run.

## 0.1.37 — 2026-11-15

- An app whose own background helper keeps it running no longer blocks its update with "the app did not quit": the updater stops such a helper the way macOS expects (unloads its launchd job), swaps the app, and loads the job again. If the helper cannot be put back, the update says so and the next run retries it instead of reporting success.
- The Launcher's own background engine is now named **Studio Launcher KH Helper** everywhere you see it (menu, Update Studio page, process lists), instead of "Update Studio KH Helper". It is the same engine, with the same identity and the same one launchd job; a Mac upgraded from the older name keeps its old bundle in the installer's trash and is pointed at the new one the next time setup is repaired or installed.

## 0.1.35 — 2026-11-14

- A download that fails now resumes where it stopped instead of starting over: the partial installer is kept, only the missing part is fetched, and the signature is checked once the file is complete. An install that failed (an app that would not quit) retries from the finished installer without downloading it again.
- A repaired app path is saved in this Mac's own config, so the "configured bundle path … is missing; using …" line appears once instead of on every run.
- A one-shot local install waits for the agent's current run to finish instead of being refused while another run holds its lock.
- An Automatic switch written by hand in helper.json as `"hub": true` is honoured, and this Mac's switch wins unless the update page's value is provably later.

## 0.1.34 — 2026-11-13

- A Mac that has just been enrolled keeps the apps it found: each installed KH app the signed feed names is registered once, with a one-line "adopted this Mac's installed app" note, instead of being rediscovered silently on every cycle.

## 0.1.33 — 2026-11-13

- The one-line path repair now appears for every repair, including one found during the startup check, so a renamed app's old path is always named in the log.

## 0.1.32 — 2026-11-13

- Your Mac's own Automatic switch now wins whenever the update page's value is not provably later, including a publisher default. Across this fleet that turns Hub and the Launcher back on for the machines whose records defaulted them off (56 of 63 records carried "hub/updater off" as a default) — the switches themselves already said on.
- A configured app path that no longer exists (a renamed app) is repaired from the signed feed's own bundle name and said out loud once, instead of the app being skipped in silence.
- A Mac that has just been enrolled adopts every KH app it already has whose bundle ID is in the signed feed, by bundle ID, on its first run — a Hub-only mini updates through the Launcher with no hand-edited config.
- Every skipped app now says why in the log, with the rule's own origin, for example: hub: skipped — automatic is off (This Mac's default).
- The agent's log lines appear immediately instead of waiting in a buffer, and the log rotates at 8 MB keeping three older copies, so a quiet log can no longer hide a working agent.
- The saved app list is repaired as well: an app an older setup recorded as updating itself does not fall back to that after it is moved or replaced.

## 0.1.31 — 2026-11-13

- An app an older setup recorded as "updates itself" is adopted the moment the signed feed offers it: its Update button now updates it, and the Mac keeps your Automatic choice.
- Includes every installer fix from 0.1.30 below.

## 0.1.30 — 2026-11-13

- Every app in the signed feed can now be installed or updated from its card on any Mac, including the publisher's own Mac: a first Install no longer does nothing, and Storage Studio KH, Media, Music, Library, Printer and Relay all install from the feed.
- Story Studio KH and Hub Studio KH update through Studio Launcher like every other app: it quits them safely, stops their services, replaces them, and reopens them in the background only when you asked for the update here.
- A click now says "Receiving update…" at once, then shows the download and install, and finally the result.
- The log says why an app was left alone ("marked as updating itself") instead of only reporting that nothing happened.
- An SSD or a saved list can no longer keep an app marked as updating itself when the signed feed offers it as an installer; the feed decides.
- Studio Launcher KH is in the feed as its own app, so its window can update its own app.

## 0.1.29 — 2026-11-13

- Pair again works with no code typed while the publisher's allow-a-Mac window is open; the older sign-in is replaced and the old token stops working.
- A failed pairing names the publisher address and the exact mismatch (address, key or clock) instead of saying the code is wrong.

## 0.1.28 — 2026-11-13

- Re-pairing works from this Mac: entering the pairing code replaces the older sign-in, no Remove on the publisher Mac needed, and the old token stops working.
- The address field accepts the publisher's Tailscale name (ending in .ts.net); a numeric IP is refused with the reason macOS gives.
- A refused sign-in still offers Pair again, and pairing reconnects without a step on the publisher Mac.

## 0.1.26 — 2026-11-13

- Update and Install work again: the confirmation is a real in-page dialog, because the packaged webview's confirm() silently did nothing.
- An automatic update no longer opens the app in front of you: it stays closed for you to open.
- An update you asked for on this Mac reopens the app in the background, and a hidden or test copy is replaced but never reopened as your app.
- A version already installed is left alone instead of being downloaded and installed again from an out-of-date report.

## 0.1.25 — 2026-11-12

- On large fleets the menu lists only the apps that need action, so it stays short; a saved switch shows every app.
- Small fleets still list everything, and the choice is remembered.

## 0.1.24 — 2026-11-12

- The helper switches to the version an update points at, even when the update came from somewhere else, so the running helper always matches the version shown.
- Each installed version carries its own named helper app, so a newly switched version starts without needing an older one.

## 0.1.23 — 2026-11-12

- Opening the window re-reads the installed versions right away.

## 0.1.22 — 2026-11-12

- Update, Install and Reinstall ask for confirmation first, then show progress and the result.
- The feed's liveness probe answers, and the app raises its own file-descriptor limit before installing.

## 0.1.21 — 2026-11-12
- The helper reaches the feed by its Tailscale name, so a publisher whose address changes keeps working.
- Settings → Appearance offers System, Light and Dark; a saved "Default" now reads as System.
- Quit Studio Launcher KH sits in the app menu and in the menu-bar menu.

## 0.1.20 — 2026-11-12
- The footer now holds a version pill that opens What's New, an icon-only Check for Updates, and a small update button that appears only when a newer Launcher is ready.
- Support this app sits in the footer and in the menu bar's menu; it explains the free one-time donation.
- Settings → Appearance offers System, Light, Dark and Default, with System as the starting choice.
- The status line stays on one line; a failed check replaces it, so the footer never stacks messages.

## 0.1.19 — 2026-11-11
- What's New is a simple pop-up inside Launcher instead of a separate system window: the title, this version and the notes, with one Done button. Esc or a click outside closes it.
- Opening What's New from the menu bar shows the same pop-up in the Launcher window.

## 0.1.18 — 2026-11-11
- Stopping the helper's supervisor also stops the helper it started, so a saved-setup repair does not leave the previous helper running.
- What's New opens as a sheet in Launcher, keeping the helper responsive when Launcher is opened during an upgrade.
- Saved-setup repair brings its confirmation forward before asking you to continue.

## 0.1.17 — 2026-11-11
- Choose whether to pair a new Mac with a code or repair this Mac's saved setup. Repair keeps the existing connection, app choices and pauses instead of enrolling the Mac again.
- Install or update available apps by hand using the current signed app list, the installed versions and checked copies on your installer SSD.
- See which installer source is selected and why an SSD copy could not be used.
- Each Automatic switch says whether its current choice came from this Mac, Update Studio or this Mac's default. A reported copy of this Mac's own choice keeps the correct label.
- Settings explains what this Mac reports, where its files stay and the actual download limits.

## 0.1.16 — 2026-11-11
- On a Mac that only has the publisher connection, you can now install or update Story, Hub and other apps that normally update themselves by choosing them in Launcher. A running app is kept as it is: nothing is quit, stopped or replaced.
- These hand installs get the same signed-installer checks as any other: signature, exact checksum, size and app identity. A first install is opened and health-checked; an existing app that was stopped stays stopped, without a live health check. Automatic updates and remote orders still leave these apps alone.
- Launcher still prefers an installer on a connected SSD when it is the signed offer. An older SSD copy is offered for a first install only, never as an update.
- A smaller update uses only an exact verified full installer already saved on this Mac, including one taken from the installer SSD. That file is kept when another download source fails; a missing or changed copy means the normal full installer is used. No download size saving is promised.
- Reopening a saved Launcher starts its helper only when macOS reports no job already loaded. A disabled, unclear or refused answer never starts one, and saved connections and app choices are kept.

## 0.1.15 — 2026-11-09
- Shows actual download amounts and separates preparation, download checking and installation.
- Queued apps keep their own status until their installation starts.
- New connections prefer the trusted publisher's download, with a checked copy inside Launcher available when that download is unavailable.
- Includes a helper for Intel and Apple silicon Macs running macOS 13 or later.
- Helper updates preserve the installed signed Launcher app.
- Uses the shared layout sizes, opens What's New from its version link, and saves view choices correctly.
- The window no longer redraws itself while only the download numbers are moving, so it stops flickering and an open app or Settings dialog keeps its place, its focus and what you had typed.
- An update you cancelled says it is stopping instead of going on showing "Installing…", and when an app is being tried again an earlier failure is labelled as the previous attempt rather than reading as a new one.

## 0.1.14 — 2026-11-07
- Connection setup and Pair again now say "the controller Mac" instead of "the Mac Studio", matching whichever Mac runs Update Studio KH.

## 0.1.13 — 2026-11-06
- A signed controller move can keep this Mac's existing connection and app choices. It checks the destination's matching signed feed and existing sign-in before saving, and keeps a private rollback copy.
- Authenticated updater requests refuse redirects, so a connection token stays with its explicitly chosen controller.
- Feed-host health reports fit the publisher's existing limits, so a failed host no longer blocks this Mac's reports or signed-feed refresh.
- A supervised feed host starts through the actual current executable link. Its status reflects the observed launchd process or exit, instead of treating an accepted start request as success.
- A distributor can download the current and one older installer for each app from the publisher's existing verified retention records, including on its first start.
- Publishing a new app version updates that app's fallback automatically without changing the other apps' versions.
- Replaced distributor installers go to macOS Trash. A Trash failure stays visible and can be retried without breaking the signed downloads or their recovery copy.
- Empty retention records keep older-feed compatibility; stale records recover from their verified older current version instead of blocking an unrelated publication.

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
