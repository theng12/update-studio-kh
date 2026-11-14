# What's new in Update Studio KH

The newest version is first. `khu publish` reads the top entry: `## <version> — <date>` and its "- " lines.




## 1.0.37 — 2026-11-14

- Includes Studio Launcher KH 0.1.35: a failed installer download resumes where it stopped instead of starting over, and an install that failed retries from the finished installer without downloading it again.
- Also in 0.1.35: a repaired app path is saved so the repair line appears once, a one-shot local install waits for the agent's run instead of being refused by its lock, and a hand-written `"app": true` Automatic switch in helper.json is honoured.

## 1.0.36 — 2026-11-13

- Includes Studio Launcher KH 0.1.34: a newly enrolled Mac registers the KH apps it already has once, with a one-line "adopted" note, instead of rediscovering them silently every cycle.

## 1.0.35 — 2026-11-13

- Includes Studio Launcher KH 0.1.33: the path-repair line appears for every repair, including one found during the startup check.

## 1.0.34 — 2026-11-13

- Your Mac's own Automatic switch now wins whenever the update page's value is not provably later, including a publisher default. Across this fleet that turns Hub and the Launcher back on for the machines whose records defaulted them off (56 of 63 records carried "hub/updater off" as a default); those Macs' own switches already said on.
- A configured app path that no longer exists (a renamed app) is repaired from the signed feed's own bundle name and said out loud once, rather than skipping the app silently.
- A Mac that has just been enrolled adopts every KH app it already has whose bundle ID is in the signed feed, by bundle ID, on its first run — so a Hub-only mini updates through the Launcher with no hand-edited config.
- Every skipped app says why in the log, with the rule's own origin, for example: hub: skipped — automatic is off (This Mac's default).
- The agent's log lines appear immediately (no more block-buffered silence) and the log rotates at 8 MB keeping three older copies.
- Includes Studio Launcher KH 0.1.32, which also repairs a saved app list that recorded an app as updating itself.

## 1.0.33 — 2026-11-13

- An app an older setup recorded as "updates itself" is adopted the moment the signed feed offers it: Update really runs, and the Mac keeps your Automatic choice.
- Includes Studio Launcher KH 0.1.31 with the same installer fixes.

## 1.0.32 — 2026-11-13

- Every app in the signed feed can now be installed or updated from its card on any Mac, including this publisher Mac: the feed's offers are what an install uses, never this Mac's feed-hosting role.
- Story Studio KH and Hub Studio KH are managed apps now: they install and update through the same safe route as every other app, which quits them safely, stops their services and reopens them in the background only when you asked.
- A first Install for an app this Mac was not configured for is adopted from the signed feed's own app name and identity, so it is no longer silently skipped.
- A click is acknowledged at once ("Receiving update…") and then reports downloading, installing and the result.
- An SSD or a saved app list can no longer mark an app as updating itself when the signed feed offers it as an installer; the feed decides, and a skipped app says why in the log.
- Studio Launcher KH is published as its own feed entry, so its window can update its own app; the helper entry is only the helper.
- Includes Studio Launcher KH 0.1.30 with the same installer fixes.

## 1.0.31 — 2026-11-13

- Re-pairing a Mac on the same tailnet no longer needs the six-digit code while the publisher's allow-a-Mac window is open: leave the code empty and press Pair again.
- Pair again now names the publisher address and exactly what did not match (address, key or clock), instead of saying the code is wrong or giving a generic mismatch.
- Includes Studio Launcher KH 0.1.29 with the same pairing fixes.

## 1.0.30 — 2026-11-13

- Re-pairing a Mac no longer needs a Remove on the publisher Mac: entering its pairing code replaces the older sign-in, and the previous token stops working.
- The Launcher's address field accepts the publisher's Tailscale name (ending in .ts.net) and says plainly why a numeric IP cannot be used.
- Includes Studio Launcher KH 0.1.28 with the same connection fixes.

## 1.0.29 — 2026-11-13

- The Launcher's Update/Install confirmation is an in-page dialog; the webview's built-in confirm() was a silent no-op.
- An unattended install no longer opens the app, and an already-installed equal version is not reinstalled.
- Includes Studio Launcher KH 0.1.26: an app replaced by an automatic update no longer opens in front of you; it stays closed for you to open.
- An update you asked for on this Mac reopens the app in the background, and a hidden or test run is replaced but never reopened as your app.
- A version already installed is left alone instead of being downloaded and installed again from an out-of-date report.

## 1.0.28 — 2026-11-12

- Includes Studio Launcher KH 0.1.25: on large fleets the menu lists only the apps that need action, so it stays short.
- A saved switch shows every app, and small fleets still list everything.

## 1.0.27 — 2026-11-12

- The helper always runs the version the update points at, and switches to a new one as soon as an update moves it, instead of keeping the old helper running.
- Every installed version carries its own named helper app, so a new version starts even when the older ones were never opened.
- A rollback records the same pointer the switch uses, so the launcher and the helper can no longer disagree about what is running.

## 1.0.26 — 2026-11-12

- An install repairs a LaunchAgent that still names a deleted bundle path, when the executable name is unchanged.
- Opening the Launcher re-reads the installed versions immediately instead of showing the last report.

## 1.0.25 — 2026-11-12

- Update and Install now ask before they run, naming the app and versions.
- The Launcher's own liveness probe answers, so a reachable feed no longer reads as "feed host is off".
- Installing retires a second copy of the same app, and the feed keeps three verified versions for rollback.

## 1.0.24 — 2026-11-12
- Settings → Appearance offers System, Light and Dark; a saved "Default" now reads as System.
- Publishing keeps a restorable previous release, so Roll back works on the publisher's own Mac.
- The helper and the Launcher reach the feed by its Tailscale name and nothing else.

## 1.0.23 — 2026-11-12
- The helper and the Launcher reach the feed by its Tailscale name, so a publisher whose address changes keeps working without touching every Mac.
- The feed now lives on the 1301 Mac; this app updates from there.
- A check that cannot read the feed says which publisher address it tried and why it failed, instead of showing an empty list.

## 1.0.22 — 2026-11-12
- Update Studio KH has a left sidebar: Connect a Mac, Macs, Apps & updates, Settings and Support this app, each with an icon.
- The version pill opens What's New, the round-arrow button checks for updates, and a small down-arrow appears only when an update is ready.
- Settings → Appearance offers System, Light, Dark and Default; System is the starting choice, and a saved choice is kept.
- Support this app explains the free one-time donation; nothing is locked behind it.
- The helper and publisher run from named bundles, "Update Studio KH Helper.app" and "Update Studio KH Publisher.app", so process lists show their names instead of a bare command.
- The named helper keeps reporting this Mac's apps and knows its own version, exactly as the bare command did.
- An app that renames its bundle (Hub Studio KH is next) is still found, updated and reported where it now lives, with your update choices kept.

## 1.0.21 — 2026-11-11
- Includes Studio Launcher KH 0.1.18 with orderly helper shutdown during saved-setup repair and responsive release notes.
- Keeps existing saved connections, app choices and pauses through the update.

## 1.0.20 — 2026-11-11
- Includes Studio Launcher KH 0.1.17 with separate new-Mac pairing and saved-setup repair.
- Launcher shows the current app and installer choices, why an SSD copy was refused and where each Automatic choice came from.
- Existing connections, app choices, pauses and signed-installer checks are preserved.

## 1.0.19 — 2026-11-11
- Includes Studio Launcher KH 0.1.16, which can install or update apps that normally update themselves when you choose them by hand, and keeps a running app untouched.
- Smaller updates reuse an exact verified installer already saved on this Mac, including one taken from the installer SSD; a missing or changed copy falls back to the full installer. No size saving is promised.
- A connected installer SSD is preferred only when its copy matches the signed offer, and an older copy stays a first-install choice.

## 1.0.18 — 2026-11-10
- Includes Studio Launcher KH 0.1.15 with clearer download progress and setup for Intel and Apple silicon Macs.
- Separates an app's desktop window from its verified background host during updates, and refuses replacement until both have stopped safely.
- Keeps the latest reported build details so matching version numbers are not mistaken for identical installed copies.
- Keeps the current and previous installers, moving older unreferenced copies to the Trash after a release is published.
- Shares layout sizes and What's New data with the other KH apps.

## 1.0.17 — 2026-11-07
- Includes Studio Launcher KH 0.1.14, whose connection setup and Pair again instructions say "the controller Mac" instead of "the Mac Studio".
- Existing connections, paused apps and signed releases are unchanged.

## 1.0.16 — 2026-11-06
- Includes Studio Launcher KH 0.1.13 with observed feed-host health, corrected supervised-host startup and verified current/fallback installer retention.
- Signed controller handoffs let prepared Macs keep their existing enrollment and app settings when moving to the same trusted publisher at a new address. No move happens unless it is explicitly published and the destination passes its checks.
- Authenticated requests do not follow redirects. Existing sign-ins, pauses and app choices remain in place.

## 1.0.15 — 2026-11-05
- An optional feed-host role keeps verified copies of the signed app feed and installers on a chosen Mac. It starts off and needs no signing key on that Mac.
- Signed settings can give clients a preferred download host and fallback addresses while keeping sign-in and remote orders with the original publisher.
- Local install requests can use a verified mirror when the publisher is unavailable. Remote orders and Automatic wait for the publisher; refused sign-ins still fail clearly.
- Includes Studio Launcher KH 0.1.12. Existing connections, pauses and app choices stay in place.

## 1.0.14 — 2026-11-05
- Includes Studio Launcher KH 0.1.11 with the SSD Update installed apps action and plain per-app results.
- SSD repair keeps newer installed versions, saved connections and pauses, and checks installer hashes before use.
- Installer cleanup supports APFS disk images and uses their mounted device IDs; SSD volumes are never detached.
- Older helper versions move to restorable storage after healthy reports; the current and previous versions are kept.
- Fixes large temporary pause-test downloads being left behind.

## 1.0.13 — 2026-11-04
- Studio Launcher 0.1.10 opens an existing helper before offering pairing, checks saved connections, and offers Pair again when a saved sign-in is refused.
- Launcher's connection window opens centred and leaves other windows usable.
- Includes incomplete connection repair, safe retries and plain name-in-use recovery instructions.

## 1.0.12 — 2026-11-04
- Studio Launcher 0.1.9 repairs incomplete connections without discarding saved app data, and lets interrupted setup be retried.
- When a reset Mac cannot reconnect because its name is already in use, the message explains how to remove the old entry in Update Studio and connect again.

## 1.0.11 — 2026-11-03
- Other apps lists Tailscale, Chrome, Telegram, Yam Display, Word and Excel, with official sources and vendor signature checks.
- Choose individual Macs or confirm a group assignment. Assignments start off; turning off cancels waiting installs and keeps installed apps.
- Official sources and vendor identities are editable. Retirement keeps each app’s source and history so it can be restored with assignments off.
- Waiting installs follow edited sources and the visible shared download limit. Older Launchers wait for a compatible version.
- Packages stay verified and ready for an administrator to finish on the Mac. Accounts, sign-ins and licences stay yours.

## 1.0.10 — 2026-11-03
- A Launcher-matched header, spacing and controls bring Macs, Apps & updates and connection setup into one consistent window.
- Connect a Mac uses a short checklist and a large pairing code, with separate Copy code and Copy address actions.
- Macs has page-size choices, search, status/site/tag filters and grouping, with editable location and tags.
- Mac details open in a focused pop-up with the existing app actions, reported hardware and connection details, installed-app inventory and recent results. Older Launchers show unreported fields honestly.
- Settings shows this publisher’s Tailscale address, pairing lock state and how each Mac’s automatic update choices work.
- Copy actions announce success or explain when manual copying is needed. Existing connections, update choices and confirmation steps stay intact.

## 1.0.9 — 2026-11-03
- The Update Studio app package supports both Apple silicon and Intel Macs, with macOS 13 as its minimum.
- Mac filters sit at the front of the list, with a wider search field and a Refresh button that fetches the latest saved fleet and app reports.
- Refresh keeps your view, search and expanded Macs, and shows when fetching fails.
- Update requests awaiting a result stay in Needs update; a queued request no longer claims an installation is running.
- The publisher log records which page action created update orders and how many it created, without recording sign-in details.
- Mac details distinguish the fixed connection ID from the last reported name and show when hardware text was read from a name rather than a probe.
- Connect a Mac points to Studio Launcher KH’s connection screen and can save a signed Launcher copy for another Mac without publishing a local Desktop path.

## 1.0.8 — 2026-11-03
- Installers keep their declared macOS 13 minimum instead of requiring the build Mac’s newer OS.
- Mac names follow the Hub Machine ID, or the computer name when Hub is not installed, while keeping their enrolment.
- A label set on this page stays until the Mac’s own name changes again.
- Mac labels support names in every language, up to the limit shown beside Rename.

## 1.0.7 — 2026-11-03
- A Mac’s label can be renamed on its expanded row without changing its connection or enrolment.
- Macs with the same name stay separate and show a same name warning.
- A name change appears once in the Mac’s recent results.

## 1.0.6 — 2026-11-02
- Publishing reads What's New from the app's CHANGELOG, and refuses a CHANGELOG or installer on a different version
- The SSD's What's New now matches the feed's
- Update Studio KH and Studio Launcher KH each have their own CHANGELOG

## 1.0.5 — 2026-11-02
- Publishing an app records its own name, bundle ID and icon in the feed, so Studio Launcher KH lists a new app with no code change. A DMG that holds a different version than the one named is refused.
- `khu ssd-index` writes each SSD's apps.json from the installers in "1 Install Apps".

## 1.0.4 — 2026-11-02
- When someone changes Automatic from a Mac's menu-bar icon, that Mac shows "changed on this Mac" on the page. The later change wins, whether it was made on the page or on the Mac.
- A Mac whose Automatic updates are paused from its menu says so, and until when.
- New names: this window is Update Studio KH, and the helper on each Mac is Studio Launcher KH. The apps read Hub Studio KH, Story Studio KH, Gateway Studio KH, Printer Studio KH and Media Studio KH.
- The Connect a Mac steps point to the kit folder "Studio Launcher KH - Connect a Mac".
- Apps & updates also lists Story Studio KH, Hub Studio KH and Gateway Studio KH, with the newest version on any Mac. They show "Updates itself" instead of an Update button.

## 1.0.3 — 2026-11-02
- A new Mac connects with a pairing code shown in KH Updater, at any time. You no longer open a window first.
- New code replaces the code after asking; Macs already connected stay connected.
- Five wrong codes lock pairing for five minutes, and the page says so.
- The Connect kit asks for the code once and shows the publisher's own reason if it is refused.

## 1.0.2 — 2026-11-02
- A new look for the page and the app, in light and dark, with a new app icon.
- One compact row per Mac: its apps and versions, one overall state and when it was last seen. Problems come first, and All, Needs update, Failed and Offline filter the list. Type part of a name to find a Mac.
- Click a Mac to see each app's state (Up to date, Update available, Updating, Failed or Not checked), its last 10 install results, and Update, Roll back and Remove Mac.
- A Mac not heard from for 10 minutes shows "Offline since" that time, never its old state.
- A failed install shows the Mac's own reason, when it happened and the version it is back on, with a Copy error report button.
- The Feed lists what's new in each published app, and "Update N Macs" updates every connected Mac that is behind, after asking.
- "Connect a new Mac" shows the three steps, what is needed first and where the kit is; while the window is open, new Macs appear as they join.
- A release's notes can be added to the feed when it is published.
- KH Updater's own agent and app show their What's New from this changelog.
- The page refreshes without jumping to the top or closing open Macs, and Roll back asks first.

## 1.0.1 — 2026-11-02
- The status page shows KH Updater's version and what's new in it.

## 1.0.0 — 2026-11-02
- KH Updater is an app you can open: KH Updater.app shows the status page in its own window.
