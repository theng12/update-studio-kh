# Open work — update-studio-kh

Only open work for this repo. Update in the same commit whenever work starts, changes, or finishes.
Keep this file public-safe: no home paths, no hostnames or network addresses, no secrets.
History belongs in git log and receipts; failure patterns belong to the plugin's issue directory.

- [ ] **The app list says nothing about the last check** — a Mac on the public feed can fail every
  check and show nothing: the time, the outcome and the reason when it failed are not on the page,
  and a failed install path reads as silence. Show the last check per app from the app's own record,
  never from a publisher. **Next:** read the helper's last-run record into the page state and render
  one line per app with the time and, on failure, the reason.
- [ ] **The first paint still waits for the first check** — the window shows “Checking…” until a check
  finishes, and a check's own feed reads are bounded at a minute each across several sources, so a Mac
  whose feed cannot be reached still waits before any row appears. 0.1.90 removed the artwork from
  that wait, not the check itself. **Next:** draw the apps installed on this Mac from disk on the
  first paint, marked as not yet compared with the feed, and let the check's rows replace them.
- [ ] **Feed artwork is named but published nowhere** — measured 2026-11-27 on the live feed: 7 of 14
  rows name an `<sha>-icon.png` and the other 7 name none, and neither the rows' own release assets
  (a DMG and, for the Launcher, the helper binary) nor the feed repository carry any of those PNGs,
  so every icon address answers 404 and a fresh Mac draws a placeholder on every card. 0.1.90 stops
  the list waiting on them and draws an installed app from its own bundle; it cannot invent artwork.
  **Next:** the feed producer publishes the icons the rows name — either beside each release's own
  assets or beside the feed, which `Agent.feedIcon` now tries — and rows with no icon field get one
  from their app's bundle at publish time.
- [ ] **A rotate-then-hold readback on 1301 is still owed** — 0.1.90 reads each app's own
  `KHHoldTokenFile` and falls back to the shared file when it is missing, but this Mac's config keys
  only the updater, so nothing here proves the apps that keep their own credential still answer 200
  after the shared token rotates. **Next:** on the Gateway testing Mac, rotate the shared token and
  hold each of those apps with its own credential, then read back 200.
