# Check for Updates: the shared feed contract

What a KH app does behind its version pill, its Check for Updates button and the
conditional tiny update button. This is a read-only check plus a hand-off to the
one updater that exists (Update Studio KH / Studio Launcher KH); an app never
downloads or installs itself, and never runs a second updater.

Every number, path and rule below is taken from the Updater's own code; the file
and symbol are named so a reviewer can check the claim instead of trusting it.

## Where the answer comes from

1. **`~/Library/KHUpdater/publisher.json`** — written on every Mac that was set up,
   readable by the signed-in user. Four fields only (`Sources/KHUpdaterCore/Connect.swift`,
   `Publisher`):

   | field | meaning |
   |---|---|
   | `feedURL` | `http://<tailnet-ip>:8790/release.json` — the signed feed |
   | `enrolURL` | `http://<tailnet-ip>:8790/enrol` — pairing, not for this check |
   | `publicKey` | the Ed25519 public key the feed is signed with, base64 |
   | `testAuthority` | `true` only on a throwaway test publisher |

   This file is **not** signed. The trust anchor is the key inside it, pinned when
   the Mac was set up; everything fetched afterwards must verify against it.
   Missing or unreadable file = this Mac is not connected. That is
   **"Not checked" with the reason**, never "Up to date".

2. **`GET <feedURL>`** — a JSON object with two base64 strings
   (`Sources/KHUpdaterCore/Feed.swift`, `Release`):

   ```json
   { "feed": "<base64 of the exact signed bytes>", "signature": "<base64 Ed25519 signature>" }
   ```

   Verify the signature over the **decoded `feed` bytes exactly as received**
   (Ed25519, `publicKey` from step 1). A body that does not verify, or whose
   schema is not `1`, is a failure — it is reported, never treated as empty and
   never re-signed (`Sources/KHUpdaterCore/Publish.swift`).

3. The verified feed is `{ "schema": 1, "published_at": "...", "apps": { "<id>": FeedApp, ... } }`.
   Find **your** entry by `apps[*].bundleID == your CFBundleIdentifier`, not by name
   and not by the id string, which is the Updater's internal key (`hub`, `story`,
   `media-studio`, …). No entry = this Update Studio does not offer your app:
   show **"Not offered by this Update Studio"**, not "Up to date".

4. `FeedApp` fields that matter here: `version`, `name`, `sha256`, `bytes`, `kind`,
   `notes` (What's New, plain text), `mainMacOnly`. The artifact itself is at
   `feedURL` with its last path component replaced by `artifacts/<file>` — your
   app does not need it; the updater downloads and verifies it.

## Comparing versions

`Sources/KHUpdaterCore/Crypto.swift`, `VersionCompare`:

- A version is 1–6 dot-separated parts, each 1–9 ASCII digits. Anything else is
  not a version (`isValid` false).
- Compare part by part numerically, missing parts as 0; `isNewer(feed, installed)`
  is true only when both sides parse **and** the feed is strictly greater.
- Installed version is your own `CFBundleShortVersionString`. Never compare
  strings, never trust a feed version that does not parse: report it as a feed
  problem.

**Update available** therefore means: your bundle's identifier was found in a
verified feed, both versions parse, and the feed's is strictly newer. Anything
looser (different key, unverified, unparsable, missing) is a failure state with
its reason, never "up to date".

## The five states (one compact status line)

| state | line | when |
|---|---|---|
| not checked | `Not checked` | no check has run yet in this launch |
| checking | `Checking…` | request in flight; the button is disabled until it answers |
| up to date | `Checked just now · up to date` | verified feed, your version is current |
| available | `Checked just now · <version> is available` | strictly newer offer |
| failed | `Check failed: <why>. Try again.` | any of: no `publisher.json`, feed unreachable, signature/ schema refused, your entry missing, version unparsable |

Rules:
- One line, it replaces itself; never stack two messages, never show a spinner
  and an old line together.
- A failure never silently reads as "up to date"; a missing answer never reads as
  "no update".
- The line is polite to assistive tech: `role=status`, `aria-live=polite`
  (Updater: `#check-status`; Launcher: `#checked` / `#err`).
- The check is a *read*: it may run on launch and on demand, and it changes
  nothing on disk.

## The tiny update button

- Appears **only** in the available state, next to the icon-only Check button;
  hidden otherwise. Its accessible name names the version (`Update to 1.4.392`).
- It does not download anything. It brings the existing updater forward — open
  Studio Launcher KH (or Update Studio KH on the host) and let the person pick
  your app there. The install, hash check, journal, rollback and relaunch all
  stay inside that updater, exactly as today (`Sources/khu/LauncherWindow.swift`,
  the update order path). Selecting your row from the button is **not wired
  yet**; opening the updater is the contract, deep-linking is a later addition.
- Never a second updater, never an app-owned download, never a silent install.

## Two platform facts this session paid for

- **ATS:** a bundled app doing plain HTTP to a numeric tailnet address is blocked
  on macOS 14+ unless its `Info.plist` carries
  `NSAppTransportSecurity → NSExceptionDomains → "100.64.0.0/10" →
  NSExceptionAllowsInsecureHTTPLoads = true`. A bare command-line tool is not
  subject to this; a `.app` is. Copy the block from the Launcher's plist
  (`Sources/khu/Launcher.swift`, `FrontDoor` bundle writer).
- **Read it yourself, do not ask the helper for the answer:** the helper may be
  busy or its window may never appear (a slow mounted volume can hold it), so a
  check that depends on the helper answering can hang or lie. `publisher.json`
  plus a direct verified feed read is the whole contract.

## What this file is not

Not an install path, not a pairing path, not a way to get the artifact. Those
belong to Update Studio KH alone. If a surface needs more than a check and a
hand-off, it is a change to this contract, not a private exception.
