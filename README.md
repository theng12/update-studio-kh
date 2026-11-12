# KH Updater

A light macOS tool that updates apps on each Mac and shows status. It never runs or
routes production work, never pauses/resumes jobs, and never changes app settings.
Updates default to click-to-update; an "automatic" switch per app per machine can be
turned on.

## Roles

- **Publisher** (dev Mac): `khu keygen`, `khu publish`, `khu enrol`, `khu serve`
- **Agent** (each Mac): `khu agent --config <file>`
- **Stub**: `khu-stub --base <dir>` (kept alive by launchd)

## Release path (owner, 2026-11-12)

This Mac builds, signs and tests. The release host, 1301, is the **only** feed writer, and every
Mac pulls from it. A publish run on this Mac reaches nobody.

1. Build and sign here: `packaging/build-app.sh <version>`, `packaging/build-launcher.sh <version> <publisher.json>`.
   Each writes its DMG into `dist/` — no separate copy step.
2. Once the release is accepted, `packaging/record-dist.sh rotate <app> <version>` keeps the
   latest two installers and retires the rest to `_trash`.
3. `packaging/release-push.sh <feed-app-id> <version> <dmg> <changelog>` copies the DMG and its
   changelog to the host's staging folder, publishes there with the host's own key, and reads the
   served feed back to prove the version it now offers.
4. Macs pull from `http://100.82.91.102:8790/release.json`.

Test installs on this Mac are expected and harmless: they prove download and update, they are not
the release source.

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
