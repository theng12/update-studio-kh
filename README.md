# KH Updater

A light macOS tool that updates apps on each Mac and shows status. It never runs or
routes production work, never pauses/resumes jobs, and never changes app settings.
Updates default to click-to-update; an "automatic" switch per app per machine can be
turned on.

## Roles

- **Publisher** (dev Mac): `khu keygen`, `khu publish`, `khu enrol`, `khu serve`
- **Agent** (each Mac): `khu agent --config <file>`
- **Stub**: `khu-stub --base <dir>` (kept alive by launchd)

## Build

```
./build.sh build
./build.sh test
```

(Requires the Swift 6.4 command-line tools; XCTest is not used — tests use the
`Testing` framework.)

## The app

`packaging/build-app.sh <version>` builds `build/KH Updater.app` and its DMG: a window onto the
publisher's page (http://127.0.0.1:8790/). Nothing else; the publisher runs without it.

## Subcommands

See `docs/DESIGN.md`.
