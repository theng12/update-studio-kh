# Design

Reviewed adversarially on 2026-10-24 (reliability: 35 findings; security: 11) and again on 2026-10-25
(reliability: 20 findings). Reproduced findings are fixed and covered in
`Tests/Runner/main.swift`, named R1–R35 / S1–S11 for round 1 and R2-1–R2-20 for round 2.
Round-2 finding 20 was already safe in the reviewed base; its explicit derived-name budget
and boundary coverage are documented below. A monotonic-clock test for round 1's R28 is also present.

## Feed

A directory holding `release.json` and `artifacts/<sha12>-<file>`. `release.json` is the feed
and its signature in ONE file, replaced by one rename, so a reader never sees a new feed with an
old signature: `{ "feed": "<base64 of the exact signed bytes>", "signature": "<base64 ed25519>" }`.

The feed (schema 1):

```
{ "schema": 1, "published_at": "<ISO8601>", "apps": { "<app_id>": { "version", "file", "sha256", "bytes", "kind", "notes?" } } }
```

Versions are dotted numbers only (`1.4.355`); anything else is refused, never compared as zero.

`khu keygen <dir>` creates `private.key` with mode 0600 (never wider, even for an instant) via a
temp file published by `link(2)`, which is atomic and fails with `EEXIST`: two `keygen`s running
at once can leave only one key stored, and it is the one whose public key was printed. It refuses
to overwrite an existing key.
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

- `GET /release.json`, `GET /artifacts/<file>` (percent-decoded once; any `SafeName` file stored
  under `artifacts/` is served, so a Mac already downloading a verified release is never cut off
  by the next publish; the agent checks signed size and SHA-256 before using a byte).
- `POST /status`, `GET /commands?machine=<id>`, `POST /commands/<id>/result` — per-Mac bearer
  token (stored as sha256 only). `GET /commands` answers with `SignedReply` (the reply and its
  Ed25519 signature in ONE body), signed with `--key`, naming the Mac and the moment it was made;
  the agent refuses one it cannot verify, one for another Mac, or one not fresh. A result
  acknowledges an order by id only when it is pending for this Mac and the body's app matches.
  Unknown IDs return 404 without changing state; the agent treats this as an already absent order.
  Automatic results use `POST /automatic/auto-<id>/result`, which never clears pending orders.
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
2. read installed versions, health and its own Automatic defaults;
3. re-send any result the server did not take last time (before the feed, so a publisher that
   cannot be reached for one is still told what happened here);
4. `POST /status` with this Mac's Automatic defaults, so the page shows what will really happen;
5. fetch `release.json`, verify against the pinned key, require schema 1 and a real date; refuse
   a feed older than the newest seen, a different feed with the same date, or one dated more than
   a day ahead (which is then not remembered). A self-update the stub rolled back is marked
   rejected by its remembered installed SHA; those bytes are not installed again until the
   artifact changes or an explicit order arrives;
6. fetch `SignedReply` of orders, verify the signature and freshness, refuse one for another Mac.

An order runs once (by id; a redelivered one is re-reported, not re-run). Done records are not
trimmed before fetching orders, and IDs in the latest reply are protected from trimming. An order for the
version already installed is `current`; for an older one, `refused` (no downgrade). Automatic
installs a newer version unless that exact artifact already failed here (an order retries it).
Artifacts stream to `downloads/<app>/`, refused past their signed size, then checked against
the signed size and SHA-256. The previous download moves to `_trash`. Transport failures (no
data, connection reset, deadline exceeded) are NOT artifact rejections — they retry next run. Bytes
that arrive but do not match the signed size or SHA (oversize, truncated, corrupt) are a delivery
mismatch: retried on the next run, and rejected only after `Agent.maxDeliveryMismatches` (3) in a
row for the same signed SHA, which bounds re-downloads when the server's copy itself is bad (a
re-publish of identical bytes keeps the same SHA and would not clear a rejection). Only
artifact-intrinsic failures (wrong version, wrong bundle id, health check failure, rollback, a
repeated delivery mismatch) mark the artifact rejected in `agent-memory.json`. Operational install failures
such as a copy timeout are `install_failed` and remain retryable. The installed status says
`unresolved install` while an install journal remains. A legacy stub rollback without recorded
artifact SHA uses the matching signed feed version conservatively, then consumes that rollback
counter once.

`khu agent` writes a heartbeat every 30 s on its own thread (so a long install never silences
it), carrying the nonce the stub gave this child.

## Recipes

`app-dmg` and `gateway`, in this order:

1. recover any interrupted install for the app;
2. attach the DMG (plist output), require exactly one `.app`, the feed's exact version, the
   expected bundle identifier (`bundleID` in the config, else the installed app's), and a
   runnable executable; copy it with `ditto` into `.<name>.khu-staging` beside the installed
   app and check the copy — all before anything is stopped; detach;
3. write the install journal (naming both paths AND the target version, so recovery can prove
   which side it found); quit the app and stop its service. A refusal relaunches what was
   running and changes nothing;
4. installed → rollback (the earlier rollback moves to `_trash`), staging → installed, the
   journal moving forward at each step. Any failure restores
   the previous bundle, relaunches it and says exactly what was restored — or, loudly, that it
   could not be, **and keeps the journal** so the next run retries instead of reporting a Mac
   whose app is merely the new version as settled;
5. relaunch if it was running and require it healthy as the new version. A first install with
   no previous bundle is always launched and checked, even if nothing was running before;
6. otherwise quit and stop both again (else `rollback_blocked`, both bundles kept and journal
   kept), copy and verify the previous bundle into a sibling on the installed volume, move the
   unhealthy bundle to another sibling, and rename the prepared previous bundle into place.
   The original rollback stays available; a failed rename attempts to put the unhealthy sibling
   back and keeps the journal regardless, so failure of that repair is still recoverable.
   Only after the previous bundle is installed does the unhealthy copy move to `_trash`.
   The journal records rollback intent before these moves, so interruption retries rollback.
   A rollback that cannot be finished or is unhealthy keeps the journal so the next run retries.
   An unhealthy first install with no fallback remains `unresolved`, never `current`, until a
   later health check succeeds. Recovery uses the journal's own paths and a control bound to
   that path, verifies each bundle's version and executable, and keeps unrecognized state.
   A legacy journal without a target version needs a readable staged bundle to prove its new
   version; otherwise it stays unresolved instead of guessing from an installed path.

A process belongs to an app only if its executable's real path (`realpath(3)`, never
Foundation's `resolvingSymlinksInPath`) is inside the bundle's real path. Config validation
uses real paths and folds case on case-insensitive volumes to reject duplicate bundle entries.
Staged executables must be real files — a symlinked one runs as its target, so `proc_pidpath` would report a path outside the bundle. Quitting passes the bundle id
to `osascript` as an argument, never inside the script. The Gateway is stopped by the PID its
`/health` reports only when that PID runs from inside this Gateway's bundle AND owns the
listening socket on the port (`lsof -nP -iTCP:<port> -sTCP:LISTEN`); an unrelated server naming
a pid of this bundle is refused, never signalled. It counts as stopped once the port stays
quiet; health requires the same listener ownership check, the expected on-disk version,
and a running bundle process.

`story`, `hub`: status only — those apps keep their own updaters. `updater`: self-update (below).

Helpers run with absolute paths and hard deadlines: both pipes are drained while they run; on a
deadline they get SIGTERM, then SIGKILL, and are reaped before the error is raised. The HTTP
client has BOTH an inactivity timeout (`timeout`) and a total transfer deadline (`totalTimeout`)
— an inactivity deadline alone lets a stalled or malicious peer hold a run open for ever. No
`sudo`. Nothing is deleted: superseded files go to `_trash/`. `SafeName` caps components at 196
bytes so the longest derived name (`.<sha12-><name>.khu-tmp-<uuid>`) fits inside 255.
The reviewed base `6c47e36` already restricted names to 128 ASCII characters; the round-2
claim that it accepted overflowing names could not be reproduced. The explicit 196-byte
budget documents the derived-name bound and safely permits longer components.

## Stub

`khu-stub` keeps `current` alive under `versions/<v>/khu`, `current` and `previous` symlinks.
Links change by renaming a fresh symlink over the old one (old one copied to `_trash`), so a
kill at any instant leaves whole versions; `previous` moves before `current`. Installing the
version already running is a no-op, and a version directory is never overwritten.

Every new target `current` resolves to — first start, self-update, rollback — starts a probation:
three non-zero exits within 5 minutes, or no heartbeat from THIS child (matching nonce and pid)
within 2 minutes, put `previous` back. A quiet window with a heartbeat settles it. A missing or
unrunnable `current` falls back to a usable `previous`; a dangling or identical `previous` (by
resolved real path, not link path) is no fallback, and with none the running child is left
alone rather than killed for nothing. A stub start with an open probation restarts the window
(fresh `switched_at`) so time that passed with no child running is not counted against this
version. A rollback records the version rolled back FROM in `stub-state.json`, which the agent reads
to mark the SHA remembered at installation rejected. Each rollback counter is consumed once;
a replacement artifact or explicit order can retry without the old rollback record rejecting it
again. Each spawn and exit clears the previous child's heartbeat. Live waits use a monotonic clock.

## Limits (not fixed, stated)

- Persisted timestamps use wall-clock time, but each stub process restarts an open probation
  and measures live deadlines with a monotonic clock. Crash timestamps remain wall-clock
  records, so a wall-clock jump can affect which exits belong to the crash window.
- `_trash` grows with each install (previous downloads and bundles) until the owner empties it.
- The status page has no CSRF token: it relies on loopback-only, Host and Origin/Referer checks.

## SwiftPM note

SwiftPM is broken on this Mac (CLT libPackageDescription link failure). Package.swift is retained for the future, but the build of record is `./build.sh` compiling with plain `swiftc` into `build/`: `khu`, `khu-stub`, `khu-tests`. Tests use a self-contained runner (Tests/Runner) with `expect` helper and `TESTS: N passed, M failed` summary; `./build.sh test` builds and runs it. No XCTest/swift-testing. The test command also compiles `build/khu`, so the CLI argument and
keygen regressions exercise the matching source. `R2_ONLY=<n> ./build.sh test` is a focused
proof run only; the completion check is always the unfiltered `./build.sh test`. Test bundle
executables are ad-hoc signed before spawn, and desktop launch/quit helpers are intercepted.
