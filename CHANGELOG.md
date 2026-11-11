# What's new in Update Studio KH

The newest version is first. `khu publish` reads the top entry: `## <version> — <date>` and its "- " lines.

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
