# Design

## Feed

A directory containing `feed.json`, `feed.json.sig` (ed25519 detached signature over the
exact bytes of `feed.json`, via CryptoKit `Curve25519.Signing`) and `artifacts/<file>`.

`feed.json` schema v1:

```
{ "schema": 1, "published_at": "<ISO8601>", "apps": { "<app_id>": { "version", "file", "sha256", "bytes", "kind", "notes?" } } }
```

`khu keygen <dir>` creates `private.key` (0600) and prints the public key (base64).
`khu publish --feed <dir> --key <keyfile> --app <id> --version <v> --artifact <path> [--kind <k>] [--allow-same]`
copies the artifact in, hashes it, updates `feed.json` (other apps untouched), re-signs.
Refuses a version that is not newer than the current one for that app unless `--allow-same`.

## Server

`khu serve --feed <dir> --state <dir> --bind <ip> --port <p>` runs a minimal HTTP/1.1
server. Routes:

- `GET /feed.json`, `GET /feed.json.sig`, `GET /artifacts/<file>` (no path traversal; only names listed in the feed)
- `POST /status` (agent reports; authenticated by per-machine bearer token from enrolment)
- `GET /commands?machine=<id>` (agent fetches pending commands; same auth)
- `POST /commands/<id>/result`
- Owner-only (loopback 127.0.0.1/::1 only): `GET /` status page, `POST /api/request-update`, `POST /api/automatic`

State is persisted as JSON files written atomically (temp + fsync + rename).

## Agent

`khu agent --config <file>` loops every N minutes (default 5): fetch feed + sig, verify
signature against the pinned public key (reject unsigned/invalid/rollback-to-older feeds:
remember highest `published_at` seen), read installed versions from Info.plist paths given per
app in config, POST status, GET commands. An update runs when (a) a command asks for it, or
(b) automatic is on for that app and the feed is newer. Install = download artifact to a
private temp dir, verify bytes+sha256, then run the app's recipe. Never more than one install
at a time per machine.

## Recipes

- `app-dmg`: attach DMG read-only/nobrowse, find exactly one `.app`, verify
  `CFBundleShortVersionString` equals feed version, quit running app politely (bounded
  wait), move installed bundle to rollback dir (keep ONE previous), copy new bundle with
  `ditto`, detach, relaunch, health check within bounded time; on failure restore previous
  bundle + relaunch, report `rolled_back`.
- `gateway`: app-dmg plus stop the Gateway server process first (PID from
  `GET http://127.0.0.1:8787/health` → `pid`; SIGTERM, bounded wait, report+abort if it
  won't stop — never SIGKILL). Health = `/health` returns 200 within 120s after relaunch.
  Never delete any data directory.
- `story`, `hub`: status only. "Updated by its own updater." No install from KH Updater.
- `updater`: self-update via the stub (see below).

All shell-outs use absolute paths, bounded timeouts, captured output. No `sudo`.

## Stub

`khu-stub` layout under a base dir: `versions/<version>/khu`, `current` -> symlink,
`previous` -> symlink. The stub runs `current/khu agent ...` as a child. Self-update
(by the agent's `updater` recipe): place new binary in `versions/<v>/`, verify hash, point
`previous` at old, `current` at new, exit so stub restarts. Stub rolls back (`current := previous`)
when the new version exits non-zero 3 times within 5 minutes of a switch OR writes no heartbeat
within 2 minutes of a switch. Stub is small, has no network code, changes rarely.

## Threat notes

- Tailnet-only transport (no public exposure).
- Signed feed (ed25519 over exact bytes).
- Owner routes loopback-only (127.0.0.1/::1).
- Per-machine bearer tokens stored only as sha256 on the server.
- No sudo, no path traversal, artifacts only served when listed in the feed.
- Atomic state writes (temp + fsync + rename).
- Rollback preserved for one previous app bundle.

## SwiftPM note

SwiftPM is broken on this Mac (CLT libPackageDescription link failure). Package.swift is retained for the future, but the build of record is `./build.sh` compiling with plain `swiftc` into `build/`: `khu`, `khu-stub`, `khu-tests`. Tests use a self-contained runner (Tests/Runner) with `expect` helper and `TESTS: N passed, M failed` summary; `./build.sh test` builds and runs it. No XCTest/swift-testing.
