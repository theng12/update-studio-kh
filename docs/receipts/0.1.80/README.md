# 0.1.80 — Studio Launcher KH + Studio Launcher KH Helper

Backfilled receipt (2026-11-23) for the release the feed serves. Both apps ship from this repository
and the same release, so they are recorded together; policy §5b wants the evidence committed beside
the code it describes.

## Release
- tag `0.1.80`, release published **2026-11-23T08:05:52Z**, commit `ae351be`
- commit identity: `112568204+theng12@users.noreply.github.com`

## Artifacts (as the signed feed serves them, read back 2026-11-23T15:07:48.277Z)
| row | bytes | sha256 | address |
|---|---|---|---|
| `launcher` 0.1.80 | 7,335,883 | `cc2763fd8bca78065962a423aad50cb069fbe425de396933b6aa0ff122f1e77b` | `https://github.com/theng12/update-studio-kh/releases/download/0.1.80/cc2763fd8bca-Studio.Launcher.KH-0.1.80.dmg` |
| `updater` 0.1.80 | 8,628,848 | `10e22658328f49473c13d5d329d702a64a89e334e3d923917ba4b40a265c8cac` | `https://github.com/theng12/update-studio-kh/releases/download/0.1.80/` (helper) |

The Launcher DMG was downloaded anonymously and hashed here on 2026-11-23 before it was installed
(7,335,883 B, sha `cc2763fd…` — exact match). The helper's sha is the sealed copy: the agent kit's
`MANIFEST.json` declares `10e22658…` and the shipped binary hashes to it (verified 2026-11-23).

## Feed readback
- `release.json` served from GitHub Pages, envelope signature verifies against the key installed
  clients pin (public half `057b6e66…`). That key's own location and backup are deliberately not
  recorded here: this file is served publicly by the Pages site.
- both rows present at `launcher`/`updater` 0.1.80, `type: system`

## What is proven, and what is not
- **Proven:** the artifacts download anonymously at the recorded bytes and sha; both rows are served
  and signed; the Launcher installs and runs on a Mac (installed and observed 2026-11-23).
- **Not proven — self-update:** the shipped bundles vendor a **pre-fix** Sparkle shim, whose
  `KHHoldTokenFile` does not expand `~`. Measured at wire level on three apps: `~/…` → refused,
  absolute path → authorised, no key → 401. So 0.1.80 is **released and installable, not
  self-updating**; that begins with a release vendoring the fixed shim
  (`818826a79d4e54885cbb5ad167f7425da8ba77436c6a5e277532f400aa1b4216`) plus a served appcast item.
- **Not proven — install on a second Mac:** only this Mac was observed.

## Scan
No keys, no tokens, no absolute home paths in this receipt; addresses are the public release URLs and
the feed's own values.
