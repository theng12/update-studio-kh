# Working in KH Updater

Rules for this repository. Each one is imperative and in force. The design authority is
[`docs/DESIGN.md`](docs/DESIGN.md): read the section named here before changing that area.

## Where the design lives

| Area | `docs/DESIGN.md` | Read it for |
| --- | --- | --- |
| Signed releases | `## Feed` | the feed directory, `release.json`, signed size and SHA-256, `_trash` |
| Publisher | `## Server` | routes, order signing, the enrolment window, Remove Mac, report bounds |
| Each agent run | `## Agent` | the one-run lock, the outbox, re-sending results, feed freshness, orders, ordered rollback, delivery mismatches |
| Apps on a Mac | `## Recipes` | `app-dmg`/`gateway` install and rollback, owner rollback proofs, `story`/`hub` status-only, `updater` self-update |
| The supervisor | `## Stub` | `current`/`previous`, probation, the heartbeat the stub requires |
| Accepted weaknesses | `## Limits (not fixed, stated)` | what this tool deliberately does not protect against — do not "fix" one of these by accident |
| Building and tests | `## SwiftPM note` | `./build.sh` is the build of record; `./build.sh test` runs `Tests/Runner` |

`docs/INSTALL.md` is the operating procedure: publisher once, releases any time, and the
credential-free agent kit per Mac.

## House rules

- **Never delete anything with `rm`.** A file you remove — one the owner named, or one you decided
  was clutter — moves into the repository's `_trash/`, keeping its sub-structure, and you say where
  it went. The running tool follows the same rule for its own files: superseded downloads, bundles
  and version links go to `_trash/` folders, never away (`## Recipes`, `## Stub`). `_trash/` is the
  owner's to empty; never tidy inside it.
  Owner exception, 2026-11-06: superseded distributor installers on 1301 go to native macOS Trash,
  and Finder's 30-day Trash removal is enabled there only. This Mac's Trash stays untouched;
  tests inject a fake Trash destination. Other runtime and repository `_trash` rules remain.
- **Never re-run `packaging/publisher-init.sh`; agents never read, print, copy, hold or create production signing-key bytes.**
  Owner exception, 2026-11-06: the owner authorized moving the EXISTING signer to 1301, preserving
  every Mac's pinned public key. Only the owner runs the SSD export/import commands; agents may
  prepare and syntax-check them, never execute them. The imported key is 0600 in a 0700 directory;
  verification prints only the public-key fingerprint and its match result. After verified import,
  the owner-run command moves the SSD transfer copy into that SSD's restorable `_trash`.
  This Mac keeps its signer until at least 2026-12-07 and until every enrolled Mac has updated or
  moved to 1301, whichever is later; only then may it be retired into restorable `_trash` with a
  separate owner OK. No key operation happens before then. A new key would orphan enrolled Macs.
  The original setup ran on 2026-10-26; its overwrite refusals remain in force.
- **The kit installer activates the agent** (owner, 2026-10-26: "sure switch it on").
  `packaging/install-agent.sh` installs *and* loads the LaunchAgent, matching Studio Hub's
  `components/hub/backend/khu_agent.py` (`Bootstrap.activate`): probe
  `launchctl print gui/$(id -u)/com.khupdater.agent`, bootstrap the plist only when that job is not
  loaded, so an already-loaded agent is left alone and never doubled. A failed start keeps the
  finished install where it is, prints launchctl's reason and the command that retries it, and
  exits non-zero. Do not reintroduce an "installed but not started" state.
- **Whole-cycle release.** A change is not finished until, in order: `./build.sh build`, the
  unfiltered test set below, a commit on its own branch, and an agent kit rebuilt from that same
  commit (`packaging/build-agent-kit.sh`) for the Studio Hub kit to carry. KH Updater has no remote;
  the branch commit and the kit built from it are the release. Before closeout, refresh the three
  active install SSD kits (ATLAS, NOVA and UGREEN; never ORICO, now the NAS data drive) and
  hash-check the copies as specified in `docs/INSTALL.md` → Publish a release.
  This is a standard step for every KH app release; Updater serializes the SSD writes.
- **Roll out through Studio Hub, all Macs at once** (owner, 2026-10-25). The agent ships inside the
  Hub release and installs per user on launch; the Hub's own site-by-site rollout is the only
  pacing. No SSH, no per-Mac AirDrop, no staged pilot.
- **Quality bar: adversarial review before any Mac runs this.** Every confirmed review finding is
  fixed with a regression test that fails against the reviewed base — the `R`/`S`/`E` names in
  `docs/DESIGN.md`'s opening are that record. Never install a build with open findings. Prove it on
  this Mac (publisher plus one agent, a real update and a real rollback) before the fleet.
- **No `sudo`, nothing outside `~/Library`.** The agent and the publisher run as the signed-in user;
  `~/Library/KHUpdater` and `~/Library/LaunchAgents` are the whole footprint.
- **One signer and control endpoint, no secrets on a drive.** Macs trust the pinned `publicKey`
  and refuse anything unsigned or unverifiable. Signed feed settings may name download mirrors;
  sign-in, status and orders stay with the saved controller unless an explicit same-signer signed
  controller handoff is verified. Only the publisher holds the production private key; mirrors,
  app kits and `.sspack` files never carry one. The owner's SSD key-transfer exception above is
  separate from app kits. A feed-host role and controller handoff both start off.

## Tests

Run all four; a release needs the whole set, unfiltered:

```bash
./build.sh test                        # Swift core + CLI: Tests/Runner, prints "TESTS: N passed, M failed"
python3 -I Tests/test_packaging.py     # kit builder and install-agent.sh
./Tests/test_publisher_init.sh         # publisher setup against a temporary home and "drive"
python3 -B -I Tests/test_ssd_entry.py   # SSD bootstrap checksums, private copy and index pin
```

The two packaging suites must stay inside temporary homes and a stand-in `launchctl` first on
`PATH`: never the real `~/Library/LaunchAgents`, never the real `gui` launchd domain, never a real
key in the owner's home. Every change to an installer, the stub, the agent or the publisher needs a
regression test that fails against the code before it.
