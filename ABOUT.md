# Studio Launcher KH / KH Updater — what it is

Studio Launcher KH is the owner's macOS update tool. It builds signed releases,
serves them from one feed and runs a small agent on each Mac that installs them. The
Launcher is the menu-bar app; KH Updater is the publisher and agent behind it. It
never runs, routes or pauses production work.

## What it does

- Lets each Mac update by click, with an optional automatic switch per app per
  machine.
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
- Shows this Mac's apps in the Launcher window and the publisher's page in a Fleet
  window; the headless tools keep working without a menu bar.
- Names known apps absent from the last verified feed and shows drive scans separately
  from feed checks. The Launcher can use either the public signed feed or a paired publisher.

## How it is built

Swift 6.4 SwiftPM code (`Sources/KHUpdaterCore/`, `Sources/khu/`,
`Sources/KHUStub/`, `Sources/khu-stub/`), a test runner (`Tests/Runner/`), and
shell/Python packaging (`packaging/`, `build.sh`). There is no remote for this
repository.

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

1.0.42, from the newest `CHANGELOG.md` entry (2026-11-16). No manifest in this
repository holds a version: the number is passed to `packaging/build-launcher.sh`
when the Launcher DMG is built, so the manifest location is not established.
