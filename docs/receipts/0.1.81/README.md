# 0.1.81 — Studio Launcher KH + Studio Launcher KH Helper

Receipt written 2026-11-24 before the publish; the feed readback and the repository screenshots are
completed after it. Both apps ship from this repository and the same release.

## Release
- version `0.1.81`, commit `a6e74c1` (main moved to it by fast-forward; branch `launcher/first-run-0181`)
- commit identity: `112568204+theng12@users.noreply.github.com`

## Gate
`gate-run.sh`, `GATE PASS launcher a6e74c1 2026-11-24T01:19:14Z`, evidence
`launcher-lead/gate-20261124-075203-86024`. Ten steps green:

| step | result |
|---|---|
| trash-link | ok |
| build | ok (universal khu + khu-stub) |
| snapshot | ok — page measured in this build, 12 measurements (2 screens × 2 schemes × 3 widths) |
| snapshot-check | ok — gap ≥6px, target ≥32px, contrast ≥4.5, no wrapped label, no image metadata |
| swift | ok — `TESTS: 2102 passed, 0 failed` |
| render | ok — page render suite |
| packaging | ok |
| idle | ok — one real check, then 600 s idle: 77→80 MB, 37→37 fds, 0→0 sockets |
| desktop-safety | ok |
| commit-identity | ok |

`idle-footprint: UNMEASURED` in the summary is the built-in `IDLE_PID` hook, which needs an app
running from this build; the `idle` step is that measurement, run headless with its own state dir.

Machine: the gate started with `ALLOW_BUSY=1` because swap was 93% used while 13.5 GB was available
and no process held more than 1 GB; the summary records `machine check skipped (ALLOW_BUSY=1)`.

## Artifacts
| row | bytes | sha256 |
|---|---|---|
| `launcher` 0.1.81 DMG | 7,656,260 | `8a248033da099d5ebf5b390c86b4133b4b8292175dd3cb9c44029fb91e67251b` |
| helper, sealed in the kit (`bin/khu`) | 8,712,752 | `41d08ecb9df7124c053135af11fb219ca7a9591c31f170db457e35bb267fe1ed` |

## Scan and preflight
- `scan-dmg.sh` on the exact DMG: exit 0, sha bound, 13 files, `UNKNOWN — none`. OWNER HITS: only the
  tailnet range literal, accepted. "Brand identifiers" hits (`macmini`, `terranash`) are the fleet-name
  parser and the reserved bundle domain, both already in this public source.
- `release-preflight.sh launcher 0.1.81 … --scan-receipt`: **PREFLIGHT PASS** (changelog heading,
  artifact sha/bytes, no existing 0.1.81 release, scan bound to the sha, feed serves 0.1.80).

## What changed in 0.1.81
First run is one press and one source; the Studio's controls live behind Advanced and a single-Mac
screen never shows fleet or publisher wording; the category tabs are 32px accent-filled controls;
Automatic updates have a visible switch that is on for a fresh Mac.

See `CHANGELOG-launcher.md`.

## Not yet done, and why
- **Publish and feed readback:** tag `0.1.81` is placed at `a6e74c1` and verified through
  `git/ref/tags/0.1.81`. The GitHub release was not created from this session: the tool layer
  refused it because the publish consent is in S001's relay rather than the user's own words here.
  The two assets are staged and named for the upload —
  `8a248033da09-Studio.Launcher.KH-0.1.81.dmg` and `41d08ecb9df7-khu` (the sealed helper, not a
  rebuild).
- **Screenshots:** done at `d283296` — four 1440×900 PNGs taken from the 0.1.81 DMG's own `khu page`
  with `packaging/screenshot-demo.json`, rendered headless, each under 150 KB with no metadata chunk,
  each opened and read before the commit; `README.md` embeds two with alt text.
- **Retention:** `dist/` holds 0.1.79, 0.1.80 and 0.1.81. 0.1.79 is retired to
  `~/Desktop/_trash/update-studio-kh/` only after 0.1.81 is served and verified.
- **Installed-build check:** the shipped-app click is the owner's walk; nothing here installs.
