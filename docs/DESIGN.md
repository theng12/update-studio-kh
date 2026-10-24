# Design

Reviewed adversarially on 2026-10-24 (reliability: 35 findings; security: 11). Every finding is
fixed and has a regression test in `Tests/Runner/main.swift`, named R1–R35 / S1–S11.

## Feed

A directory holding `release.json` and `artifacts/<sha12>-<file>`. `release.json` is the feed
and its signature in ONE file, replaced by one rename, so a reader never sees a new feed with an
old signature: `{ "feed": "<base64 of the exact signed bytes>", "signature": "<base64 ed25519>" }`.

The feed (schema 1):

```
{ "schema": 1, "published_at": "<ISO8601>", "apps": { "<app_id>": { "version", "file", "sha256", "bytes", "kind", "notes?" } } }
```

Versions are dotted numbers only (`1.4.355`); anything else is refused, never compared as zero.

`khu keygen <dir>` creates `private.key` created with mode 0600 (never wider, even for an instant)
and prints the public key. It refuses to overwrite an existing key.
`khu publish --feed <dir> --key <keyfile> --app <id> --version <v> --artifact <path> [--kind <k>] [--allow-same]`
runs under `publish.lock`; verifies the existing release with the key's own public key before
touching it (a tampered or corrupt release is refused, never re-signed or treated as empty);
stores the artifact under its own hash, so two apps' files never collide; refuses a version not
newer than the feed's (`--allow-same` re-publishes the same one); and moves `published_at`
strictly forward.

## Server

`khu serve --feed <dir> --state <dir> --bind <ip> [--bind <ip>…] --port <p>`. Every address is
bound before any is served. Each connection runs on its own thread (at most 32 at once; more get
503) with a 15 s total read deadline and a 30 s send timeout, and artifacts stream from disk —
one slow or stalled Mac never holds up the others.

- `GET /release.json`, `GET /artifacts/<file>` (percent-decoded once; only names in the feed)
- `POST /status`, `GET /commands?machine=<id>`, `POST /commands/<id>/result` — per-Mac bearer
  token (stored as sha256 only). An order stays pending until its result arrives (the result is
  the acknowledgement).
- Owner-only: `GET /`, `POST /api/request-update`, `POST /api/automatic` — loopback peer, a Host of
  127.0.0.1/localhost/[::1] with this port (no DNS rebinding), and for changes an Origin or
  Referer from this page (neither is refused). The page sends CSP, `X-Frame-Options: DENY`,
  `Cache-Control: no-store`. It shows each Mac's effective Automatic setting (the owner's
  override, else what the Mac's own config says).

State is `state.json`; every change is one read-modify-write under `state.lock` (flock, shared
by all processes, `khu enrol` included). An unreadable state file is a 503 that says so and is
left untouched; a change that could not be saved is a 500, never a 200.

## Agent

`khu agent --config <file>`. One run at a time per Mac (`agent.lock`); a second refuses. Each run:

1. finish or undo any install a killed run left behind (the install journal);
2. fetch `release.json`, verify against the pinned key, require schema 1 and a real date; refuse
   a feed older than the newest seen, a different feed with the same date, or one dated more than
   a day ahead (which is then not remembered);
3. report installed versions, health and its own Automatic defaults;
4. re-send any result the server did not take last time; fetch orders.

An order runs once (by id; a redelivered one is re-reported, not re-run). An order for the
version already installed is `current`; for an older one, `refused` (no downgrade). Automatic
installs a newer version unless that exact artifact already failed here (an order retries it).
Artifacts stream to `downloads/<app>/`, refused past their signed size, then checked against
the signed size and SHA-256. The previous download moves to `_trash`.

`khu agent` writes a heartbeat every 30 s on its own thread (so a long install never silences
it), carrying the nonce the stub gave this child.

## Recipes

`app-dmg` and `gateway`, in this order:

1. recover any interrupted install for the app;
2. attach the DMG (plist output), require exactly one `.app`, the feed's exact version, the
   expected bundle identifier (`bundleID` in the config, else the installed app's), and a
   runnable executable; copy it with `ditto` into `.<name>.khu-staging` beside the installed
   app and check the copy — all before anything is stopped; detach;
3. write the install journal; quit the app and stop its service. A refusal relaunches what was
   running and changes nothing;
4. installed → rollback (the previous rollback to `_trash`), staging → installed, the journal
   moving forward at each step; any failure restores the previous bundle, relaunches it and says
   exactly what was restored — or, loudly, that it could not be;
5. relaunch only if it was running, and require it healthy as the new version;
6. otherwise quit and stop both again (else `rollback_blocked`, both bundles kept), put the
   previous bundle back, prove it is the previous version, and require it healthy as that.

A process belongs to an app only if its executable's real path is inside the bundle
(`proc_pidpath`, never a regex). Quitting passes the bundle id to `osascript` as an argument,
never inside the script. The Gateway is stopped by the PID its `/health` reports only when that
PID runs from inside this Gateway's bundle (SIGTERM only), and counts as stopped once the port
stays quiet; it is healthy when `/health` answers 200 from a process of this bundle, the bundle
on disk is the expected version, and the app runs.

`story`, `hub`: status only — those apps keep their own updaters. `updater`: self-update (below).

Helpers run with absolute paths and hard deadlines: both pipes are drained while they run; on a
deadline they get SIGTERM, then SIGKILL, and are reaped before the error is raised. No `sudo`.
Nothing is deleted: superseded files go to `_trash/`.

## Stub

`khu-stub` keeps `current` alive under `versions/<v>/khu`, `current` and `previous` symlinks.
Links change by renaming a fresh symlink over the old one (old one copied to `_trash`), so a
kill at any instant leaves whole versions; `previous` moves before `current`. Installing the
version already running is a no-op, and a version directory is never overwritten.

Every new target `current` resolves to — first start, self-update, rollback — starts a probation:
three non-zero exits within 5 minutes, or no heartbeat from THIS child (matching nonce and pid)
within 2 minutes, put `previous` back. A quiet window with a heartbeat settles it. A missing or
unrunnable `current` falls back to a usable `previous`; a dangling or identical `previous` is no
fallback, and with none the running child is left alone rather than killed for nothing.
Live waits use a monotonic clock.

## Limits (not fixed, stated)

- Persisted probation times are wall-clock; a clock jump during a probation can lengthen or
  shorten it once.
- `_trash` grows with each install (previous downloads and bundles) until the owner empties it.
- The status page has no CSRF token: it relies on loopback-only, Host and Origin/Referer checks.

## SwiftPM note

SwiftPM is broken on this Mac (CLT libPackageDescription link failure). Package.swift is retained for the future, but the build of record is `./build.sh` compiling with plain `swiftc` into `build/`: `khu`, `khu-stub`, `khu-tests`. Tests use a self-contained runner (Tests/Runner) with `expect` helper and `TESTS: N passed, M failed` summary; `./build.sh test` builds and runs it. No XCTest/swift-testing.
