# Design

Reviewed adversarially on 2026-10-24 (reliability: 35 findings; security: 11) and again on 2026-10-25
(reliability: 20 findings). Reproduced findings are fixed and covered in
`Tests/Runner/main.swift`, named R1–R35 / S1–S11 for round 1 and R2-1–R2-20 for round 2.
Round-2 finding 20 was already safe in the reviewed base; its explicit derived-name budget
and boundary coverage are documented below. A monotonic-clock test for round 1's R28 is also present.

Owner-ordered rollback was added on 2026-10-25 and reviewed the same day, adversarially, against
every way it could leave a Mac with no working app or run an unsigned or foreign bundle: 32 checks,
named R6-1–R6-12 (`ownerRollbackTests`). Each of them fails against the reviewed base `a216932`
(27 fail; the 5 that pass there are the paired post-conditions and guards a base satisfies anyway —
the `capabilities` gate is read off the wire and the journal is written as JSON so the same file
builds against both) — the base has no `ServerCommand.action`, no journal order/intent, no
`/api/request-rollback` and no owner swap at all.

Network enrolment windows and Mac removal were added on 2026-10-25 (owner) and are covered by E1–E26
in `Tests/Runner/main.swift` (`enrolWindowTests`): a closed window, a window's expiry, the minted
reply as Studio Hub's client verifies it, an already-enrolled id, bad ids and nonces and oversize
bodies, the window's cap, the per-address rate limit, `/enrol` without `--key` and on a bind no Mac
can reach, the owner route's loopback/Host/Origin checks, the CLI, the page, and removal with its
re-enrolment and its concurrency (E1–E17); then the 2026-10-26 adversarial review's findings
(E18–E24): a state file written before `removed` existed still decoding, the bounded report routes,
`/enrol` refused to a web page, abandoned window enrolments pruned and a lost reply re-minted,
`/enrol`'s generic refusals, and the single window constructor with the Tailscale-only bind; and the
same day's re-review (E25 and E26, with E18 and E21 extended): the prune running only when a NEW
window opens and only past the abandonment age, `machines` required of a state file, `GET /commands`
bounded and probe-safe, and a page's refusal not spending the Mac's allowance.

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
- `POST /status`, `GET /commands?machine=<id>[&capabilities=<a,b>]`, `POST /commands/<id>/result` — per-Mac bearer
  token (stored as sha256 only). `GET /commands` answers with `SignedReply` (the reply and its
  Ed25519 signature in ONE body), signed with `--key`, naming the Mac and the moment it was made;
  the agent refuses one it cannot verify, one for another Mac, or one not fresh. A result
  acknowledges an order by id only when it is pending for this Mac and the body's app matches.
  Unknown IDs return 404 without changing state; the agent treats this as an already absent order.
  Automatic results use `POST /automatic/auto-<id>/result`, which never clears pending orders.
  Every report a Mac can write is bounded, because one Mac — possibly one that claimed a token
  through a window and has never been inspected — must not grow `state.json` without limit, and
  every change is a whole-file rewrite under the one lock every other Mac waits on:
  `installed`, `health` and `automatic_default` carry at most `ReportPolicy.maxApps` entries with
  bounded names and values; a result keeps its order id, `status` and `reason` within their own
  bounds, at most one result per app (the map is keyed by app) and at most `maxApps` apps — a Mac
  that keeps naming new ones evicts the oldest, so what one Mac can write never depends on how long
  it runs. `/commands` is bounded too: the `capabilities` names an agent advertises are at most
  `ReportPolicy.maxCapabilities` short names and `maxCapabilitiesQueryBytes` in all, refused above
  that instead of stored, and a request that names **no** `capabilities` parameter at all changes
  nothing on the record — the Hub asks this route with a stored token to learn whether the publisher
  still honours it, and a probe must not edit the record it is asking about (nor refresh `lastSeen`,
  which would make a removed Mac look alive). `/status`, `/commands` and both result routes share one
  per-machine rate limit (`ReportPolicy.perMachinePerMinute`), counted only after the Mac's token is
  checked — a limit keyed on a name the body chooses, before the token, would let anything on the
  tailnet silence a Mac's reports by sending them with its id — and set far above any real agent's
  rate.
  A **rollback** order is handed out only to an agent that names `owner-rollback-v1` in
  `capabilities`: an agent built before `ServerCommand.action` existed would read the same order as
  an update and install the feed's version — the opposite of what the owner asked. `action` itself
  defaults to `update` when absent, so an order signed before the field existed decodes unchanged
  and still means what it meant when the owner gave it.
- `/status` may report a bounded `display_name`. The helper reads the installed Hub’s current Machine ID, else the macOS computer name. The publisher stores the last reported name separately: a manual label survives unchanged reports, and the next actual Mac name change follows automatically. Older helpers omit the field and leave the label alone.
- A Mac has a separate optional display label. Renaming changes that label and adds one history entry; the enrolment ID, token hash, pending orders and enrolment date stay unchanged. Duplicate labels remain separate records and show “same name” on the page.
- Owner-only: `GET /`, `POST /api/rename-machine`, `POST /api/request-update`, `POST /api/request-rollback`, `POST /api/automatic`,
  `POST /api/enrol-window`, `POST /api/remove-machine` — loopback peer, a Host of
  127.0.0.1/localhost/[::1] with this port (no DNS rebinding), and for changes an Origin or
  Referer from this page (neither is refused). The page sends CSP, `X-Frame-Options: DENY`,
  `Cache-Control: no-store`. It shows each Mac's effective Automatic setting (the owner's
  override, else what the Mac's own config says). Each row with an app of its own has an Update
  button, a Roll back button and its Automatic toggle; the rollback route needs no feed entry
  for that app, because it puts back a version the Mac already keeps.

**Enrolment is closed until the owner opens a window.** `POST /enrol` is the one route with no
token, and it is the only way a Mac gets a token without the owner touching the publisher:

- Body `{"machine": <id>, "nonce": <64 hex>}`, answer `SignedReply` of
  `{machine, nonce, feedURL, publicKey, issuedAt, token}`. The `X-Hub-Token` header the Hub sends is
  **ignored**: nothing on the publisher can verify it, so it is not part of any decision here.
- A request that carries **Origin or Referer is refused (403)** before its body is parsed, and before
  it counts against the address's allowance — a page the owner visits must not be able to spend the
  attempts a Mac needs. `/enrol` is the one route with no token, and a `text/plain` POST is a "simple
  request" a browser sends cross-site without a preflight, so a page the owner happened to visit could
  otherwise spend the window they opened. A Mac's own agent sends neither header (it is an `httpx`
  POST with no browser in front of it), so the refusal can never reach the Mac it is meant to enrol.
- The **window** is opened from the page (`POST /api/enrol-window`, `minutes` 0 to close, 1–240 to
  open) or with `khu enrol-window --state <dir> --minutes N`. Its end time is stored in state.json
  under state.lock and is the **only** thing that decides: there is no second flag that can disagree
  with it, and an end time that cannot be read is closed, never open. Opening a window resets its
  count, and both callers build it with the one `EnrolWindow.starting(minutes:now:)` — two copies of
  that arithmetic are two chances for the window the page shows and the server enforces to disagree.
  The page shows the state, how much of the window's allowance is used, how many Macs enrolled
  through a window, and a per-second countdown — the page's one script, allowed by a per-response CSP
  nonce rather than `'unsafe-inline'`.
- While it is open, a machine id this publisher has **no record of at all** is minted a token exactly
  as `Enrolment.enrol` mints one — the sha256 is stored, never the token — and the reply is signed
  with the `--key` key, after the reply is signed and only then written to state. The machine id goes
  through `SafeName`, the nonce must be exactly 64 hexadecimal characters, and a body over 4 KiB is
  refused before it is parsed.
- An id that already has a record is refused **409**, whatever else is true: a device on the tailnet
  can never rotate a real Mac's token out from under it. Re-enrolment stays on the publisher
  (`khu enrol`), and a Mac the owner removed has no record, so it enrols again through a window.
  **One exception, and it is the same claim arriving twice:** a window-enrolled record that has never
  reported (`/status` once), resent with the **same nonce**, is answered with a freshly signed reply
  carrying a new token instead of a 409. The token it was sent the first time may have died with a
  reply that never arrived, and a permanent 409 would strand that Mac until the owner removed it by
  hand. The nonce is what makes it the same claim — a different nonce is still 409, a record that has
  reported is still 409, and a closed window mints nothing — and the resend spends no second slot of
  the window's cap. The stored hash is replaced, so the token from the lost reply stops working.
- Closed window: **403**. No `--key`: **403** (it could not sign a reply, and an unsigned reply is
  one the Mac must refuse). Past the window's cap of `EnrolPolicy.maxPerWindow`: **429**. `/enrol`
  attempts are rate-limited per client address (`EnrolPolicy.attemptsPerMinute`, in memory) so the
  attempts a window's cap does not count cannot be made for free. **Every refusal leaves the state
  byte for byte as it was**; the numbers the page shows are the numbers the server enforces.
- `feedURL` is the address **this listener was bound to**, written the one way `publisher.json`
  writes it (`http://<bind>:<port>/release.json`). That is the address the Mac just reached the
  publisher at, so it cannot drift from what the Mac's kit says. Only the **Tailscale range the Hub
  itself accepts** (`100.64.0.0/10`) is such an address: the Hub's `publisher_config` refuses any
  other one, so a publisher bound to a LAN address would enrol a Mac and then hand it a feed URL its
  own Hub refuses to adopt. Loopback, wildcard, link-local, multicast and ordinary LAN binds are all
  refused (403) instead of guessed at — fail closed, and the launch agent binds the Tailscale
  address.

**Removing a Mac is what makes re-enrolment possible.** `POST /api/remove-machine` (`Remove Mac` on
the page) or `khu remove --state <dir> --machine <id>` drops the live record — its token hash and its
waiting orders with it, so the old token cannot report or fetch orders — and appends
`{machine, removedAt, installed, health, lastSeen, enrolledAt, enrolmentSource, droppedOrders}` to
`state.removed`, newest last. One read-modify-write under state.lock, like every other change, so
removals and enrolments from different processes never lose each other. A removed id is **not** barred
from enrolling: that day of resetting Macs and enrolling them afresh is exactly what removing is for.
The removal stays in the list as history, and the page says whether that Mac is enrolled again since.
**Removing a Mac and enrolling it again drops everything the record held**, including the owner's
per-app Automatic overrides (`state.machines[<id>].automatic`): the fresh record starts with none, so
the Mac's own config decides again until the owner sets them. The history in `state.removed` keeps
what the Mac had reported, but not those overrides — the removed record is the one that had them.
**Removal changes this publisher's state and nothing else.** The dead config the Hub archived when it
re-enrolled (`<home>/Library/KHUpdater/_trash/<id>/config.json`) still holds the token the publisher
has just stopped honouring, and an older `state.json` restored from a backup brings the removed
record — and that token with it — back to life. A restored publisher state is a state the owner is
choosing to run with; removal is not a revocation that lives anywhere else.

**A window is not left full of claims nobody made good on, but only time may say so.** A record that
enrolled through a window, never reported, and is older than
`EnrolPolicy.abandonedAfterSeconds` (15 minutes) is dropped when a NEW window opens. Such a record is
an id a device claimed and abandoned, and it holds one of the window's cap slots and would 409 the
real Mac that wants that id. **Closing a window drops nothing**, and neither does one that is only
seconds old on opening a new one: the Mac has the token the moment the reply reaches it and may not
run its agent for a few minutes, so deleting its record would leave it answering 401 with a token the
publisher legitimately gave it — the age is the only evidence that separates a Mac that has not
reported *yet* from one that never will. A record whose `enrolledAt` cannot be read is kept, not
guessed at, and a record that has reported (`lastSeen`) is never dropped this way — only Remove Mac
does that.

State is `state.json`; every change is one read-modify-write under `state.lock` (flock, shared
by all processes, `khu enrol` included). An unreadable state file is a 503 that says so and is
left untouched; a change that could not be saved is a 500, never a 200. **`machines` is required;
the fields added later are optional when they are read.** A file with no `machines` key is an error,
never an empty fleet — serving an empty fleet would silently orphan every Mac that believes it is
enrolled — while `removed` and `enrolWindow` are absent in everything written up to `2eaae0c`, and a
decoder that throws on a missing one of them turns every route into a permanent 503 for the whole
fleet. The same rule holds inside each record: every field it has ever had reads as optional with the
value it had when it was absent.

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
installs a newer version unless that exact artifact already failed here (an update order retries it).

**Ordered rollback.** An order whose `action` is `rollback` puts this app's kept previous version
back (see Recipes). Anything else than `update` or `rollback` is `refused` and nothing is touched.
It runs under the same one-run-at-a-time lock and the same outbox as an install, so its result
survives a lost report and a redelivered order is answered, never carried out twice. It is refused
for an app this Mac does not run, for `story`/`hub` (their own updaters) and for `updater` itself:
the stub only restores a version it watched fail, so there is no order to give it here. After a
successful rollback the version rolled back FROM is marked rejected by the SHA the feed names for
that same version — Automatic will not put it straight back, and a new artifact or an update order
clears that, exactly as for a version that failed here. When the feed does not name that version,
nothing is marked: an invented SHA would suppress an artifact nobody identified. An owner swap a
killed run left in the journal is finished or undone by the next run's recovery, which then answers
that order by id from what is on disk (`rolled_back_by_owner`, or `rollback_failed` when the swap
did not land) instead of running it again; while it cannot be settled the order stays unanswered and
the next run tries again.

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

**The menu-bar icon (0.1.2).** In a logged-in session the agent shows a menu-bar icon from its own
process (no Dock icon, no second app): each app's version and state, Update now, Check for Updates
Now, an Automatic switch per app and a 24-hour pause, stored in `state/helper.json`. Each switch has
its time; the agent reports them on `/status` and the publisher keeps whichever change, the Mac's or
the page's, is later. The signed `/commands` reply carries `automaticAt` so the agent applies the
same rule. A pause holds Automatic only: the owner's orders and Update now still run. Story and Hub
stay status-only and get no switch. `KHU_NO_MENU` turns the icon off.

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

**An owner-ordered rollback is the same swap from the other side.** The source is the bundle this
Mac kept at `rollback-<app>/<name>.app`, not a DMG, and what has to come up healthy is the OLDER
version. Before anything running is touched it is proven: a readable bundle whose identifier is the
configured one (else the installed app's), the kept version strictly older than the installed one
by `VersionCompare` (equal or newer is refused), a real runnable executable inside the bundle, and
the same code-signed app as the one installed — `codesign --verify --strict` must pass on both and
their `Identifier|TeamIdentifier` must match, so an unsigned, altered or foreign bundle is never
what a rollback runs. The verified bundle is then copied into the usual staging path **with its
signature re-checked on the copy**, and only then does the install's own journaled path take over:
quit, stop the service, promote, launch, and require the older version healthy through the same
settle window. The version it displaced is the fallback, so an unhealthy rollback puts this Mac's
current version back and health-checks it — reported as `rollback_failed`, since what the owner
asked for did not come up. The journal records the order id and `intent: owner_rollback`, so
recovery answers that order instead of running it again, and it keeps the journal whenever the
swap could not be settled. `RecipeResult.version` carries the version the app moved away from, so
the agent can reject exactly that artifact. The owner's rollback needs no feed entry, and a version
that is already installed, has no kept bundle, or is not older is refused in one sentence.

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
- The signature check tells one signed app from another, not who published it: two bundles can be
  ad-hoc signed locally under the same identifier, so it proves "this is the same app this Mac is
  running, unaltered", which is the question a rollback has to answer. The feed's own signed SHA-256
  remains the only statement about which bytes a version is.
- An owner rollback that is interrupted in the instant between freeing the rollback slot and moving
  the displaced bundle into it leaves the kept bundle in state `_trash/` (moved, never deleted) with
  the app itself untouched on the version it was running; a later rollback order then refuses until
  a new install keeps a bundle again.
- The status page has no CSRF token: it relies on loopback-only, Host and Origin/Referer checks.
- **An open enrolment window is not a proof of identity, and this is what it does not protect
  against:** any device that can reach the tailnet address while a window is open can claim a *new*
  machine id and get a token. It cannot take an existing Mac's id (409), cannot rotate a real Mac's
  token, cannot reopen the window, and cannot reach the owner's route from off this Mac. What bounds
  it is the window's own end time (240 minutes at most, opened deliberately, closed by hand or by the
  clock), the `EnrolPolicy.maxPerWindow` cap on new ids per window, the page listing every Mac that
  enrolled through a window with its time, and Remove Mac dropping any of them in one click.
- During an open window a device on the tailnet can learn **whether a given machine id is already
  enrolled**: an id with a record answers 409 and one without is enrolled. The fleet's names are not
  secret from the tailnet; nothing else about an enrolled Mac — its token, its apps, its orders — is
  answered to anything but that Mac's own token. The one record that can be re-minted over the
  network is one that has never reported, and only by repeating the nonce it enrolled with. That Mac
  may still be holding the token it was sent — its agent has not run yet — so the honest statement is
  that a re-mint displaces **no token the publisher has evidence was used**: a Mac that has reported
  is never re-minted, whatever nonce it sends, and neither is one whose record was minted for a
  different nonce.
- `/enrol` is the one route anything on the tailnet may reach, so its refusals are sentences and
  never diagnostics: no state path, no decoder text, no bind, no port. The detail of a state file
  that cannot be read or saved goes to the publisher's stderr and to the owner's page, which is
  where the owner can act on it.
- The report bounds are policy, not measurements: 64 apps and their names and values, a
  128-character order id, a 64-character status, a 400-character reason, 16 capability names of 64
  characters (512 bytes of query in all), and 60 report posts a minute per Mac. A real agent stays far
  under all of them; a Mac that somehow exceeds one is refused with a 400 or a 429 and its own agent
  reports the failure, rather than the publisher silently truncating what it was told. The one silent
  action is the oldest-result eviction at 64 apps, because a result the owner can no longer see beside
  its app has no reader.

- The reply crosses the tailnet with the token inside it, signed but not encrypted: the signature
  proves *who* answered, Tailscale's own transport encryption is the confidentiality there. A token
  read off the wire by something that can already see a Mac's tailnet traffic would be usable.
- The window's end time is wall-clock, and the rate limits live in memory in each `serve` process:
  a clock jump can close or extend a window early, and restarting `serve` clears them (the window's
  per-window cap, the 409 for an enrolled id and the report bounds do not depend on either). The
  `/enrol` limit is per client address, so several addresses each get their own allowance, and the
  report limit covers `/status`, `/commands` and both result routes per machine id; the cap on new
  enrolments per window is the bound that does not depend on anyone's address.
- A flood inside an open window can therefore use up that window's allowance of new ids — a Mac part
  way through enrolling may get 429 until the owner opens a new window or removes what a device
  claimed. It cannot touch a Mac that is already enrolled, cannot stop the owner opening a new
  window, and is visible on the page as it happens.
- A record abandoned by a device on the tailnet is freed fifteen minutes after it was minted, when
  the owner next opens a window — not at the moment the window closes. Until then that id answers 409
  to anything else, which is the price of never deleting a record a real Mac may be holding.
- `state.removed` grows by one record per removal and nothing trims it. Only the owner can add to it,
  and only from this Mac.
- A body larger than 4 KiB is refused with 413 once read; the transport's own 1 MiB cap is what stops
  a larger one, which is refused as a bad request instead.
- Removing a Mac abandons any order it had not answered, and its agent will report 401 until it is
  enrolled again: the owner's intent in removing it is that it stops being served.

## SwiftPM note

SwiftPM is broken on this Mac (CLT libPackageDescription link failure). Package.swift is retained for the future, but the build of record is `./build.sh` compiling with plain `swiftc` into `build/`: `khu`, `khu-stub`, `khu-tests`. Tests use a self-contained runner (Tests/Runner) with `expect` helper and `TESTS: N passed, M failed` summary; `./build.sh test` builds and runs it. No XCTest/swift-testing. The test command also compiles `build/khu`, so the CLI argument and
keygen regressions exercise the matching source. `R2_ONLY=<n> ./build.sh test` is a focused
proof run only; the completion check is always the unfiltered `./build.sh test`. Test bundle
executables are ad-hoc signed before spawn, and desktop launch/quit helpers are intercepted.
