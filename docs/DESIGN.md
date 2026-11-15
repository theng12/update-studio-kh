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

The 2026-11-05 SSD/helper-retirement review found two checksum races: mounting the original SSD path after hashing it, and rereading an index changed after Launcher verification. Both are fixed: installers use private reverified copies, and the bootstrap passes the original index hash into the native single-read decoder. `SSDUpdateTests.swift` and `test_ssd_entry.py` cover both substitutions. The final adversarial pass found no remaining confirmed issue in those paths.

## Feed

A directory holding `release.json` and `artifacts/<sha12>-<file>`. `release.json` is the feed
and its signature in ONE file, replaced by one rename, so a reader never sees a new feed with an
old signature: `{ "feed": "<base64 of the exact signed bytes>", "signature": "<base64 ed25519>" }`.

The feed (schema 1):

```
{ "schema": 1, "published_at": "<ISO8601>", "apps": { "<app_id>": { "version", "file", "sha256", "bytes", "kind", "notes?" } } }
```

Versions are dotted numbers only (`1.4.355`); anything else is refused, never compared as zero.

Unreleased incremental delivery: an optional `delta` on a signed app entry names `file`, `sha256`,
`bytes`, `baseSHA256` and `baseBytes`. The publisher builds a bounded copy/literal `KHUD1` patch
from the exact displaced full installer and publishes it only when it is smaller than the target.
A successful SSD install keeps its verified installer in the normal download cache for the next
server update. Cache failure reports that the next update may need a full download and does not
misreport an already successful installation as failed. The client uses only an exact
hash-and-size-verified cached installer as its base, verifies the
patch, reconstructs privately and verifies the full target hash and size before installation.
Missing, modified or unusable bases/patches use the full signed installer; cancellation stops
instead of starting another transfer. Invalid optional descriptor values are ignored while full
installer, signature, schema and freshness validation still apply. Mirrors retain verified patches
when available; a missing optional patch cannot block the full installer. Older clients ignore
`delta` and use the full installer. Compressed DMGs may have no reusable blocks: the measured
Launcher 0.1.12→0.1.14 patch is 4,658,823 bytes versus 4,658,788 full bytes, so it is omitted.
Transfer progress labels patch versus full fallback and uses the current transfer's actual bytes.

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

Unreleased distributor change (not in helper 0.1.12): optional signed `previous` entries name one
older installer per app. The publisher adopts the existing `artifact-retention.json` pins after
checking their bytes, then updates only the published app's fallback. Mirrors download both sets
on a fresh start and protect those per-app pins across unrelated publications. Dropped distributor
artifacts go to native macOS Trash; stage/recovery material still uses `_trash`. After all pins
are verified, the new signed release and its recovery copy are published before predecessor
retirement. A Trash failure remains an error to retry but cannot remove a live signed pin.
Tests substitute a temporary Trash destination. The owner enables Finder's 30-day removal on 1301 only; this Mac's
Trash settings and stable application payloads are not changed by this operation.

Optional `network` settings inside those signed bytes contain ordered `feedURLs` and `hosts`,
keyed by enrolled machine ID. Host roles start off; enabled roles name an existing tailnet bind
address and port. `khu network --feed <dir> --key <keyfile> --config <network.json>` verifies the
existing feed, validates these settings and signs the next publication under `publish.lock`.
Ordinary app publications preserve them. The private key stays with the original publisher.

An enabled host mirrors the original publisher's exact signed release, verifies each artifact's
signed size and hash and each signed icon hash, then publishes the release atomically. A failed
sync keeps the last working release. Current and previous artifact sets stay; older copies move
to `_trash`. Its per-user `com.khupdater.feed-host` LaunchAgent runs `khu serve --feed-only`;
that server exposes only release and artifact downloads, with no enrolment or control routes.
Disabling the role stops only that job and retires its plist. No SSH, network configuration or
firewall changes are part of this role; a macOS permission request needs the owner's decision.

## Server

The publisher window follows Studio Launcher KH’s system typography, green accent, semantic status
pills, compact buttons and light/dark surface tokens. Its primary views are Macs, Apps & updates,
and Settings; Connect a Mac remains a distinct primary action. Connection setup places a short
ordered checklist beside a large selectable pairing code and explicit copy actions. At narrow
widths the code appears first and the checklist follows. Copy feedback is announced through a
live status region; denied clipboard access offers manual copying instead of claiming success.
Settings describes the actual listener, pairing lock state and existing per-Mac Automatic choices.
It does not pretend to edit a running listener or introduce a global default that overwrites Macs.
All owner action forms, confirmation boundaries and report semantics remain unchanged.
The Macs list defaults to 25 per page, with a page-size choice including All. Search, status,
site and tag filters, grouping and the current page survive refresh. Site and tags are owner
metadata (128-character site, at most 20 tags of 64 characters) saved under the same loopback,
Host and same-origin checks as existing owner actions. No site is inferred from a machine name.
Mac details use a native HTML dialog with focus return and Escape; the original details/forms
remain the no-script fallback. Refresh pauses while details are open, including a fetch that
started before opening, to preserve edits. Hardware and icons follow actual reported values,
never the connection name. Missing inventory reads Not reported. App inventory is read-only.

`khu serve --feed <dir> --state <dir> --bind <ip|auto|host> [--bind …] --port <p>`. `auto` takes
this Mac's tailnet address at start and a host name is resolved then; anything that resolves to no
tailnet address stops the server with the reason, so a renumbered Mac never serves where nobody can
reach it. Every address is bound before any is served. Each connection runs on its own thread (at
most 32 at once; more get 503) with a 15 s total read deadline and a 30 s send timeout, and
artifacts stream from disk —
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
- `vendor-install` orders are delivered only to agents advertising `vendor-install-v1`. Other unknown actions retain the existing rollback-capable agent refusal path; legacy agents receive neither. The signed order carries the vendor entry, signature pins, payload kind and visible byte cap. Vendor IDs use `vendor-<id>` to keep results separate from KH releases.
- Other apps adds owner-only `POST /api/vendor-edit`, `/api/vendor-assign`, `/api/vendor-retire` and `/api/vendor-restore`, under the same loopback/Host/Origin checks. The six catalog entries and all per-Mac assignments start off. Bulk assignment requires explicit confirmation. Turning off cancels waiting installs, preserving installed apps; retirement keeps the entry/history, turns assignments off and cancels pending installs. Restore leaves assignments off. Editing sources refreshes only waiting vendor orders, including the shared download limit; it never creates a new install. Catalog source type, page-link match, official hosts, Team ID/evidence and bundle ID are editable; every editable field, the page-link match included, is capped at 4096 bytes before it can enter the catalog or a signed order. A refused owner form answers as a styled page carrying the reason and a link back, never as bare text.
- `/status` may also report optional `installed_build` and `installed_executable_sha256` maps. Each has the same app/name/value bounds as `installed`; builds are nonempty single lines and executable hashes are exactly 64 lowercase hexadecimal characters. The publisher retains only the latest maps for readback; a later report without them clears previous identity to unknown. These are reported installed-bundle bytes, not proof of a release archive, and older state files remain readable.
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
- An id that already has a record is refused **409** only when the claim carries neither the
  publisher's valid pairing code nor an **open enrolment window**. Either one **replaces** the record
  (owner, 2026-11-13: re-pairing must not need a Remove on the publisher Mac, and a same-tailnet Mac
  should not need six digits typed): a new token is issued, the stored hash is overwritten so the
  previous token stops working, and a `paired again` line is kept on the Mac's page. The code is
  rate-limited per address, locks after the configured wrong tries, and the owner can replace it
  with New code; the window is the owner's deliberate allow-a-Mac action, bounded by its end time
  and cap, and a replacement spends no window slot. Re-enrolment on the publisher itself
  (`khu enrol`) and through Remove Mac remain available.
  **The other exception is the same claim arriving twice:** a window-enrolled record that has never
  reported (`/status` once), resent with the **same nonce**, is answered with a freshly signed reply
  carrying a new token instead of a 409. The token it was sent the first time may have died with a
  reply that never arrived, and a permanent 409 would strand that Mac until the owner removed it by
  hand. The nonce is what makes it the same claim — a different nonce without the code is still 409,
  a record that has reported is still 409, and a closed window mints nothing — and the resend spends
  no second slot of the window's cap. The stored hash is replaced, so the token from the lost reply
  stops working.
- Closed window: **403**. No `--key`: **403** (it could not sign a reply, and an unsigned reply is
  one the Mac must refuse). Past the window's cap of `EnrolPolicy.maxPerWindow`: **429**. `/enrol`
  attempts are rate-limited per client address (`EnrolPolicy.attemptsPerMinute`, in memory) so the
  attempts a window's cap does not count cannot be made for free. **Every refusal leaves the state
  byte for byte as it was**; the numbers the page shows are the numbers the server enforces.
- `feedURL` is **the address the Mac's own request used**, when that is this listener's tailnet
  address or this publisher's Tailscale DNS name (`*.ts.net`); otherwise the bound tailnet address,
  written the one way `publisher.json` writes it (`http://<host>:<port>/release.json`). A kit that
  names the tailnet host therefore gets a reply it agrees with, and a foreign `Host` is never
  echoed. Only the **Tailscale range the Hub itself accepts** (`100.64.0.0/10`) or the tailnet's own
  DNS suffix is such an address: the Hub's `publisher_config` refuses any other one, so a publisher
  bound to a LAN address would enrol a Mac and then hand it a feed URL its own Hub refuses to adopt.
  Loopback, wildcard, link-local, multicast and ordinary LAN binds are all refused (403) instead of
  guessed at — fail closed, and the launch agent binds the Tailscale address.
- The Launcher's typed address accepts the publisher's **Tailscale name** and refuses a numeric IP
  with the reason: the app's ATS exception allows plain http only to `*.ts.net`, so an IP would be
  blocked inside the app before any request left it (the fleet defect fixed 2026-11-13).

Launcher connection attempts are serialized per home. A pending claim keeps its machine, address,
publisher key and nonce in a private local file until installation succeeds; a failed local install
can resend that same claim without creating another duplicate-name refusal. A home with installer
remnants but no `base/config.json` selects the installer's explicit `--repair` mode after verifying
the signed pairing reply. Saved state and earlier versions are kept. A complete installation still
uses the confirmed Pair again flow, preserving its saved trust and app choices. Reopening Launcher
starts its saved LaunchAgent only when launchd does not already have that job loaded.
Only `print` exit 113 permits the absent-job path. The helper remains disabled when macOS
reports it disabled; unknown, malformed, ambiguous or refused disabled-state queries never
authorize startup. A valid saved plist and executable are required before one bootstrap.
A refused bootstrap permits one read-only `print` for a registration race, not another start.
Static refusal messages identify the failed phase/exit or missing file class without relaying
arbitrary subprocess output, addresses or credentials. Saved configuration, pairing, trust,
Automatic choices and helper files are preserved; reopening never resets or re-enrols them.
An already configured installation can use this reopening path without Connect or auto-enable.
The 18 actual-method mock scenarios run from the existing `build.sh test` entry and retain
parse, compile and test logs. Runner CF18 additionally checks exact executable, complete argv,
current GUI UID, saved plist path, timeouts and absence of extra calls. These fixtures do not
verify the unidentified powered-off affected Mac or replace full-module/native release checks.

**Removing a Mac revokes it; a valid pairing code is also enough to re-pair it** (owner, 2026-11-13).
`POST /api/remove-machine` (`Remove Mac` on the page) or `khu remove --state <dir> --machine <id>`
drops the live record — its token hash and its
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

Vendor installs share the same run lock, machine-bound signed-order validation, durable done/outbox and replay protection. An explicit signed vendor order is required; Automatic never installs an optional app. Source pages use the bounded HTTP client; initial requests and every redirect stay on the catalog's official HTTPS hosts. A local vendor receipt records the outcome and supplies Launcher rows; the verified-installer folder handoff is shown only while a person must act (`needs_admin`/`needs_person`), a `needs_admin` receipt resolves to installed once the matching bundle exists, and vendor apps report in the publisher's Other apps section only — never as a duplicate per-Mac feed row. Receipt-save errors preserve the actual install outcome and are reported separately. Accounts, sign-ins and licences are never read or changed.

`khu agent --config <file>`. One run at a time per Mac (`agent.lock`); a second refuses. Between runs, the long-lived helper re-reads only its saved address and token so an explicit address change or confirmed Pair again takes effect on the next check. A changed pinned key, machine ID or runtime path is refused; other running settings remain intact. Each run:

1. finish or undo any install a killed run left behind (the install journal);
2. read installed versions, health and its own Automatic defaults;
3. `POST /status` with this Mac's Automatic defaults, so the page shows what will really happen;
4. re-send results the server did not take last time, before fetching the feed; if the publisher
   is unreachable, keep those results in the outbox without retrying every one against it;
5. try the configured signed download addresses, with the original publisher as fallback;
   fetch `release.json`, verify against the pinned key, require schema 1 and a real date; refuse
   a feed older than the newest seen, a different feed with the same date, or one dated more than
   a day ahead (which is then not remembered). A self-update the stub rolled back is marked
   rejected by its remembered installed SHA; those bytes are not installed again until the
   artifact changes or an explicit order arrives;
6. fetch `SignedReply` of orders, verify the signature and freshness, refuse one for another Mac.

After the feed is verified, before any order runs, the config is reconciled with what is really on
disk. A configured app whose bundle path is gone (a renamed app, a hand-written config) is repaired
from the signed feed's own `bundleName`, else from the app's bundle ID in the usual Applications
folders, and one line says so (`hub: configured bundle path … is missing; using …`) instead of the
app being skipped in silence. A Mac whose config is empty apart from the helper adopts every app
the signed feed names and this Mac already has, by bundle ID — the first-run path for a Hub-only
node. Every feed app left behind by Automatic logs the rule that stopped it, with that rule's own
origin (`hub: skipped — automatic is off (This Mac's default)`). Stdout is line-buffered so those
lines land immediately, and the agent's log rotates at 8 MB, keeping three older copies in
`~/Library/Logs/_trash`.

Feed-host status is re-observed through `launchctl print` before each status report and saved
with its check time. A loaded job or successful bootstrap alone never claims a running process;
only a running state with a positive PID does. Compact observed status fits the existing 64-byte
health limit, including when replacing an older oversized status file. Setup errors remain in
that file and add a bounded failure marker to publisher health until reconciliation succeeds.
The supervised host resolves and validates `StubLayout.currentLink`, which points at the
executable itself, not a directory containing `khu`. A missing or unusable current target falls
back to the running executable if it is an executable regular file; otherwise hosting refuses.

Verified signed network settings are remembered for later runs. Download sources receive no
bearer token; status, results and signed orders keep using the saved `feedURL` endpoint.
An optional signed `network.controller` handoff names exact `from` and `to` feed addresses.
Only an agent still using `from` considers it, after completing that run's existing work.
It re-verifies the signed handoff against its freshness history, requires the destination to
serve the exact same envelope without credentials, then checks its existing token through a
fresh, machine-bound signed commands reply. Only then does it atomically save the new address;
identity, token, pin, app settings and unknown fields stay intact. Concurrent local edits refuse
the move. A 0600 rollback config is retained under the config directory's `_trash`; no pairing
or install order is dispatched. A newly signed reverse handoff supports an operator-led rollback.
The CLI supplies the actual config path; library calls without one never rewrite settings.
Authenticated HTTP requests refuse redirects. Public feed redirects retain their existing
behavior and vendor redirects remain restricted to official HTTPS hosts. Older clients ignore
this optional field and require a helper update or a deliberate local address change.
This is a connection handoff, not a state-export or cutover command: operators must first stage
the same signer and enrollment state at the destination and keep a single authoritative writer.
A host refreshes from that original publisher, never its own mirror. If the publisher has a
transport failure and mirror settings are already known, explicit local install requests may
continue from a verified mirror. Remote orders and Automatic wait; HTTP refusals and invalid
signed replies remain errors. Artifact transfers can retry other configured sources, checking
the same signed size and hash on every attempt.

Unreleased standalone Launcher installs eligible feed apps without a hard-coded app registry.
The existing verified embedded kit and chosen owned-Mac address supply setup; the bundled helper
is internal. First-install app paths and bundle identities are saved in `state/launcher-apps.json`
before staging so recovery can find an interrupted first install. Existing configured apps take
precedence; conflicting saved registrations are skipped with a note. Ambiguous copies, different
bundle identities and unwritable app folders produce per-app refusals without aborting other apps.
The normal action selects the newest eligible SSD/server offer and prefers matching current SSD
bytes. An explicit older-SSD first-install choice is available only while the app is absent; the
newer server remains available afterwards, and existing Automatic settings are preserved. No
install or forced repair downgrades. SSD bytes are copied into private staging, checked against
the index's hash and declared size, and the staged app's signature is verified before replacement.
A transport-only feed outage permits explicit SSD installs and local rollback, records results in
the durable outbox and marks server versions unknown; Automatic and remote orders wait. An offline
rollback remembers its displaced version and reconciles it against the next signed feed before
Automatic runs, preventing immediate reinstallation. Successful status posts and recovery notes
survive a later feed outage. HTTP refusals, TLS/cancellation errors and invalid signed feeds never
grant offline permission. Uninstall turns that app's Automatic setting off. Installed, server and SSD versions remain separate
facts; the installed executable hash is not the installer hash. Existing status-only and main-Mac
policies remain in force, with one addition: an app that updates itself may be installed or updated
by hand when the person at this Mac chooses it in the Launcher, and only then — Automatic and a
remote order leave it alone, and a running one is kept until its work is finished. Native Edit
shortcuts and text-input focus use normal responder behavior.
A signed `status` feed kind keeps that policy even on a fresh Mac with no SSD history; discovery
records it as status-only, with Automatic off, and an installed copy can always be opened for its
own updater. A feed entry of any other kind is installable: the feed's kind decides, and a stale
self-updating flag in a drive index or the remembered cache cannot override it — `Catalog.remember`
corrects the cached entry and the SSD indexer rewrites the flag at the next index. The freshness timestamp advances only after a successful
server check; a failed attempt keeps it and reports its own attempt time beside the error.
Ordinary settings save synchronously with visible saved/failed feedback, and a failed write keeps
the Automatic and appearance choice shown before it. An address draft survives a refused check;
typing never pairs, changes the controller or installs.

An order runs once (by id; a redelivered one is re-reported, not re-run). Done records are not
trimmed before fetching orders, and IDs in the latest reply are protected from trimming. An order for the
version already installed is `current`; for an older one, `refused` (no downgrade). Automatic
installs a newer version unless that exact artifact already failed here (an update order retries it).

**Ordered rollback.** An order whose `action` is `rollback` puts this app's kept previous version
back (see Recipes). Anything else than `update` or `rollback` is `refused` and nothing is touched.
It runs under the same one-run-at-a-time lock and the same outbox as an install, so its result
survives a lost report and a redelivered order is answered, never carried out twice. It is refused
for an app this Mac does not run, for an app the live sources mark as updating itself, and for
`updater` itself:
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
the signed size and SHA-256. A transfer that fails keeps its `.part`, and the next attempt resumes
it with `Range: bytes=<have>-` (a publisher that answers 200 restarts it at zero instead); only
Cancel gives a partial up. A finished artifact is reused by a retried install, so an app that did
not quit costs no second download, and a superseded version's bytes move to `_trash`. Transport
failures (no data, connection reset, deadline exceeded) are NOT artifact rejections — they retry
next run and resume. Bytes
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
same rule: a page value wins only by being provably later — a value stamped with this Mac's own
switch time (the echo of a report, or a tie) is not later, so the switch at the Mac decides, and a
publisher default never acts as a page value. A pause holds Automatic only: the owner's orders and
Update now still run. `KHU_NO_MENU` turns the icon off.

**What the Launcher says about a policy, a source and its own data (unreleased).** A display never works
out a policy of its own: `HelperSettings.automaticDecision` returns the value the agent follows and
which of the three inputs (`mac` switch, `page` value, `config` default) it came from, and the row's
value and the origin caption are that one answer in `AutomaticOrigin.words`. A controller value
stamped with this Mac's own switch time — the echo of a report, or a tie — retains this Mac's origin
and value; only a provably later controller change wins. The menu-bar submenu,
the page's More menu and the Settings sheet repeat it, they never resolve it again. There is still no
reset-to-inherited control, and the reason is concrete rather than a choice of ours: a report merges
each switch it carries into the controller's record per key and never drops one it did not carry, so
clearing a switch here would leave whatever the controller last recorded ruling the next run — which
is often this Mac's own switch echoed back, not a page setting — and no contract says that is what
"reset to inherited" means; the origin caption is what the existing contract supports. `Catalog.ssdCopy`'s `refused(String)` is
carried on the row as `ssdNote` and shown verbatim, only for a drive whose copy is not the offer, and
the SSD fact reads `Not used` when no copy is in play — no line claims a saving, a download being
avoided, or readiness, none of which a refusal reason proves. Settings states the real report (this
Mac's name, installed apps with versions and builds, health, its Automatic switches and pause, and the
read-only inventory), the real locality of this Mac's own files (settings, rollback copy, icons and
`downloads/`, with replaced files moving to the restorable `_trash`) and the bounds the updater already
enforces (`smallLimit` per reply, each artifact refused past its signed size, one install at a time):
there is no storage quota, cache budget or resource claim, because none exists to show. Opening a
dialog or reading any of this still submits nothing — no install, no pairing, no controller move.

## Recipes

Other apps require a pinned Apple Team ID with evidence and a valid vendor signature/notarization before install; a published checksum is auxiliary and cannot authorize installation. DMGs reuse the journal/staging/rollback app recipe, verify the staged copy's vendor signature before promotion or execution, and refuse an existing app with a different bundle identity. Vendor destinations are registered in agent-owned `vendor-apps.json` before any install and merged into every run's recovery pass; journal and rollback keys consistently use `vendor-<id>`. Settled automatic rollbacks retain the recipe's actual outcome. Auxiliary checksums hash the downloaded installer, while vendor signatures verify the mounted and staged app. Packages are verified and kept in the agent's owned download folder; they return `needs_admin` with their path and are never executed by the agent. Launcher opens the setup folder so the person can run the vendor's own Installer; refused, blocked or failed payloads are never offered back as something to open, and every vendor refusal or handoff status counts as a failure wherever the publisher styles results. No credential collection, sudo or new privilege mechanism is added. Optional app bundles use the signed-in user's existing configured path or the standard Applications name; lack of write access never triggers privilege escalation.

`app-dmg` and `gateway`, in this order:

1. recover any interrupted install for the app;
2. attach the DMG (plist output), require exactly one `.app`, the feed's exact version, the
   expected bundle identifier (`bundleID` in the config, else the installed app's), and a
   runnable executable; copy it with `ditto` into `.<name>.khu-staging` beside the installed
   app and check the copy — all before anything is stopped; detach by the device ID captured from that attach, never a volume path;
3. write the install journal (naming both paths, the target version and any active owned service
   labels, so recovery can prove which side it found); quit the app and stop its service, in that
   order. A refusal keeps the installed bundle and requests restart of what was stopped;
4. installed → rollback (the earlier rollback moves to `_trash`), staging → installed, the
   journal moving forward at each step. Any failure restores
   the previous bundle, relaunches it and says exactly what was restored — or, loudly, that it
   could not be, **and keeps the journal** so the next run retries instead of reporting a Mac
   whose app is merely the new version as settled;
5. relaunch only when the install was asked for here at this Mac (attended), and then require
   it healthy as the new version; the relaunch is background and hidden (`open -g -j`) and a
   running test/hidden instance is never relaunched. An unattended install (Automatic or a
   remote order) never opens the app: it is left stopped and reported as such, so an install can
   never take the owner's desktop; a first install with no previous bundle is checked the same
   way when attended, and left stopped when not;
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

Generic app hosts are discovered from the user's existing LaunchAgent metadata: the declared
executable must be inside this bundle and match the live PID, and its policy must be one of two:
`KeepAlive: {SuccessfulExit:false}` (restart on failure; SIGTERM stops it and `kickstart`
brings it back) or `KeepAlive: true` (restart on any exit, so a signal is not a stop:
`launchctl bootout` unloads it and `launchctl bootstrap` from its own plist puts it back). Scheduled
or socket activation and any other policy are refused, never guessed at. The journal captures active
labels before desktop quit; service stop handles only those labels, re-proves ownership immediately
before acting, and requires both an empty bundle process set and the jobs' stopped states. A job that
was unloaded is put back on every exit path — after the swap, after a rollback, after an abandoned
stop, and in recovery (an interrupted run's saved labels are bootstrapped from their plists) — with
health requiring those hosts running again. Unsupported or newly appearing processes block
replacement. Gateway keeps its separate PID/port protocol.

`app-dmg` (also the legacy `story`/`hub` recipe names older kits wrote): the journaled install and
rollback route. `status`: observed only — the app keeps its own updater. `updater`: self-update (below).

An app that updates itself may still be installed or updated by hand, from the Launcher. The choice is
local and explicit: Automatic and a remote order never install one, and the app keeps its own policy
afterwards (it is registered under the `status` recipe, so no Automatic switch and no rollback are
offered for it). The installer is the SSD copy when the drive carries one and the signed feed artifact
otherwise, checked with the same containment, checksum, size, bundle-identity, staged-signature and
health rules as any other install. An older SSD copy is an explicit first-install choice only, as
elsewhere. A running app is kept — this route proves no Production quiet point — and the refusal says
so plainly; nothing is downloaded and nothing is touched.

Two details decide this route, and both read live data rather than one flag. The policy comes from the
catalog as well as the recipe: a Mac configured by an earlier kit may carry the app's own recipe name
(`story`, `hub`) — those are ordinary installable recipes now — while an app the signed feed does not
list and an SSD marks as updating itself stays hand-only. The same journaled path installs it, and the
same recovery loop finishes or undoes a killed run for it. The running check is made at the door, before anything is downloaded, and once more at the shared
promotion point, where the swap would stop the app: the read taken there is the one that decides, so an
app that came up in between is kept too. Its staged copy goes to `_trash`, nothing is quit, stopped,
started or replaced, and no journal is left for recovery to find.
The page offers Install or Update only on the agent's own comparison, so a newer or incomparable installed
build stays *Updates itself* instead of carrying a button that could only be refused.

The explicit SSD `ssd-update --volume` action updates or repairs installed KH bundles, including equal versions, and installs only Launcher when absent. It keeps newer versions, checks the SSD index identities and SHA-256, copies each installer privately and verifies those bytes again before mounting, and verifies the staged app signature through the existing journal/rollback recipe. A local pause holds this action. Running Hub, Story or Gateway is kept because this action has no Production quiet-point proof. The selected SSD index/checksum is the offline authority; it is not an authenticated online feed. The staged signature check accepts the exact exit-1 “code has no resources but signature indicates they must be present” verdict of accepted normal unsealed KH releases (Story 1.4.381); any other diagnostic or additional error still refuses. This does not change vendor signature/notarization checks or owner-rollback verification. Per-app refusals are shown and make the final result nonzero. Saved connections, grants and pauses are never rewritten.

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

`current` decides what runs: every start uses it whenever it resolves to an executable, and the
recorded `target` in `stub-state.json` is only the fallback when the link is missing or cannot
run. Each launch logs which was chosen and why. A switch made by another process (an update, a
hand switch) is noticed within the poll interval: the running child is stopped without counting
as a crash and the new `current` starts. The switcher records `current` and `target` together,
with a fresh probation window, so the two never persistently disagree. Every version directory
carries its `Studio Launcher KH Helper.app` built from that version's binary (the executable is a
hard link to it), and a switch never promotes a version whose bundle cannot run.

After a status report is accepted, optional helper retirement observes fresh heartbeats from the settled current child. It defaults on, waits 300 seconds across repeated reports, and resets on a restart, rollback, stale heartbeat or missed report interval. Its setting can disable cleanup or change the healthy duration. Only real older version directories move to restorable `_trash`; current and previous stay protected under `switch.lock`. A cleanup failure is a note and does not block updates.

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

- Other-app latest aliases and vendor-page links resolve live, so their versions are not pinned by the KH release feed. Vendor Team ID, bundle identity and notarization are the trust gate; a vendor may change or remove its download and then the install fails loudly. Page-link parsing accepts the vendor's published double-quoted hrefs; a changed page needs a catalog/source update. Chrome currently requires plain codesign verification plus Gatekeeper notarization because its official bundle has resource-fork detritus rejected by `--strict`.
- A vendor source edit, retirement or assignment-off cancels/replaces orders still waiting at the publisher; it cannot recall an order already fetched and being executed by a Mac. Orders remain machine-bound and freshness-limited. Package completion by the person is not claimed as an installed result by the agent.

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
  machine id and get a token. It cannot reopen the window and cannot reach the owner's route from
  off this Mac. A claim carrying the current **pairing code** or arriving while the owner has an
  **open window** can replace an existing Mac's enrolment by design (owner, 2026-11-13); what bounds
  that is the code's own secrecy (per-address attempt rate and lockout, replaceable with New code),
  and the window's end time (240 minutes at most, opened deliberately, closed by hand or by the
  clock). The `EnrolPolicy.maxPerWindow` cap counts new ids only; the page lists every Mac enrolled
  through a window with its time, and Remove Mac drops any of them in one click.
- During an open window a device on the tailnet can learn **whether a given machine id is already
  enrolled**: an id with a record answers 409 (without the pairing code) and one without is enrolled.
  The fleet's names are not secret from the tailnet; nothing else about an enrolled Mac — its token,
  its apps, its orders — is answered to anything but that Mac's own token. The one record that can
  be re-minted over the network without the code is one that has never reported, and only by
  repeating the nonce it enrolled with; with the current pairing code any record can be replaced.
  That Mac
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
