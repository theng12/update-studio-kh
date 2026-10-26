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
- **Never re-run `packaging/publisher-init.sh`, and never copy or create the signing key.** It ran
  on 2026-10-26 on the Mac Studio: the key is `~/Library/KHUpdater/keys/private.key` (mode 0600) and
  the owner keeps plain backups on the kit SSDs himself. A new key orphans every enrolled Mac — the
  script refuses to overwrite one, and so must you. Its own refusals (`--backup-to` off this Mac's
  disk, an existing key, an existing plist) are the rule, not an obstacle.
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
  the branch commit and the kit built from it are the release.
- **Roll out through Studio Hub, all Macs at once** (owner, 2026-10-25). The agent ships inside the
  Hub release and installs per user on launch; the Hub's own site-by-site rollout is the only
  pacing. No SSH, no per-Mac AirDrop, no staged pilot.
- **Quality bar: adversarial review before any Mac runs this.** Every confirmed review finding is
  fixed with a regression test that fails against the reviewed base — the `R`/`S`/`E` names in
  `docs/DESIGN.md`'s opening are that record. Never install a build with open findings. Prove it on
  this Mac (publisher plus one agent, a real update and a real rollback) before the fleet.
- **No `sudo`, nothing outside `~/Library`.** The agent and the publisher run as the signed-in user;
  `~/Library/KHUpdater` and `~/Library/LaunchAgents` are the whole footprint.
- **One endpoint, one key, no secrets on a drive.** Macs trust the pinned `publicKey` in the config
  and refuse anything unsigned or unverifiable; only the publisher holds the private key, and a kit
  or `.sspack` never carries one.

## Tests

Run all three; a release needs the whole set, unfiltered:

```bash
./build.sh test                        # Swift core + CLI: Tests/Runner, prints "TESTS: N passed, M failed"
python3 -I Tests/test_packaging.py     # kit builder and install-agent.sh
./Tests/test_publisher_init.sh         # publisher setup against a temporary home and "drive"
```

The two packaging suites must stay inside temporary homes and a stand-in `launchctl` first on
`PATH`: never the real `~/Library/LaunchAgents`, never the real `gui` launchd domain, never a real
key in the owner's home. Every change to an installer, the stub, the agent or the publisher needs a
regression test that fails against the code before it.
