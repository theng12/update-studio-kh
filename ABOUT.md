# Studio Launcher KH / KH Updater — what it is

Studio Launcher KH is the owner's macOS update tool. It builds signed releases,
serves them from one feed and runs a small agent on each Mac that installs them. The
Launcher is the menu-bar app; KH Updater is the publisher and agent behind it. It
never runs, routes or pauses production work.

## What it does

- Sets a Mac up in one press: the copy already knows its one update source, so first
  run asks no question and names a failure with Retry when the feed cannot be read.
- Lets each Mac update by click, with Automatic on for a fresh Mac, a visible switch on
  the main screen, and a per-app switch in each app's own menu.
- Publishes signed releases with `khu keygen`, `khu publish`, `khu enrol` and `khu
  serve`; the 1301 host is the only feed writer and Macs pull from it.
- Runs a headless `khu` agent with a one-run lock, outbox, re-send, ordered
  rollback and feed freshness checks.
- Runs a `khu-stub` supervisor that keeps `current`/`previous` app versions with
  probation and a heartbeat.
- Installs and rolls back app recipes (`app-dmg`, `gateway`), reports only for
  `story` and `hub`, and self-updates the updater.
- Holds an app's queue before a byte moves, leaves queued work queued, and resumes
  by itself after the gap; the hold is in-memory or expiring.
- Keeps the latest two DMGs and retires older ones recoverably;
  `packaging/release-push.sh` publishes and reads the served feed back.
- Syncs an accepted release to the public page only when its SHA-256 matches the
  feed.
- Shows this Mac's apps in the Launcher window; the publisher's page opens from the
  Studio section of Settings (and the menu bar's Fleet item) only on a Mac that runs a
  Studio or has joined one. A single-Mac screen shows no fleet or Studio wording. The
  headless tools keep working without a menu bar.
- Shows the last verified feed’s app count and publication time, names roster apps it does
  not carry, and marks unfamiliar apps. The kit’s roster is updated at release.
- Checks the saved feed and scans installer drives, in those plain words; no screen
  names the service behind the feed. Apps can be sorted by the publisher’s type label.
- Shows verified extension and plugin downloads in their own section when published: each tile
  carries the published icon and a screenshot, and one that cannot be read or is over 2,048 pixels
  a side keeps a placeholder and says why. Chrome downloads install by hand; a plugin without a
  download is listed only.

## How it is built

Swift 6.4 SwiftPM code (`Sources/KHUpdaterCore/`, `Sources/khu/`,
`Sources/KHUStub/`, `Sources/khu-stub/`), a test runner (`Tests/Runner/`), and
shell/Python packaging (`packaging/`, `build.sh`). The repository's remote is
`https://github.com/theng12/update-studio-kh.git`; releases are built in a worktree
off `main` and merged back.

Build the tools with:

    ./build.sh build

The GUI DMG is built separately with `packaging/build-launcher.sh <version>
<publisher.json>`.

## Where it fits

It is shared update infrastructure, not another production app. The agent ships
inside the Studio Hub kit and every Mac pulls from the signed feed on 1301. The
Launcher is now the only GUI: the old Update Studio KH.app is retired. No app being
updated needs its own updater for the feed path.

## Current version

0.1.78, from the top entry of `CHANGELOG-launcher.md`, served by the signed feed on
GitHub Pages (read back 2026-11-21T19:03:05Z; 1301 is retired as a feed host). No
manifest in this repository holds a version:
the number is passed to `packaging/build-launcher.sh` when the Launcher DMG is
built.
