# Working in KH Updater

Rules for this repository. Each one is imperative and in force. The design authority is
[`docs/DESIGN.md`](docs/DESIGN.md): read the section named here before changing that area.

## Efficient delegation and parallel work (owner, 2026-11-10)

Canonical: [_orchestra/developer-handoff/LEAD-RULES.md](../../../../_orchestra/developer-handoff/LEAD-RULES.md) → "Efficient delegation and parallel work", with "Who does what", "Every task, at all cost" and "Hard limits"; that file wins. Use the global efficient-orchestration skill; app-specific commands and holds stay here.

- Delegate complete deliverables: a useful, inexpensive, suitable worker owns one bounded, non-overlapping deliverable (named files/worktree/base commit), its implementation and routine fix loop; the lead plans, checks the actual work, integrates and accepts. Developer keeps portfolio priorities, cross-app/protected decisions and final release/live acceptance; app leads accept worker results within their brief. Existing model routing stays unchanged.
- Independent app leads work in parallel; never park one app's independent work for another app's schedule. Serialize only real conflicts: a shared writer/worktree, or shared heavy tests and target actions. Shared heavy tests use the existing KHApps `testctl` schedule; device, security, paid/public, Production and quiet-point holds remain.
- Give workers realistic fixtures and early permitted read-only checks; verify a small result before handoff. Reuse source-bound unchanged passing results; rerun changed or failed checks and affected callers, using a full gate when reach requires it. This section adds no approval gate: existing release gates and holds still apply.

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
- **Never re-run `packaging/publisher-init.sh` or handle production signing-key bytes.**
  Only the owner transfers the existing signer to 1301, preserving pinned public keys and
  0600 key / 0700 directory permissions. Agents may prepare and syntax-check transfer commands,
  never execute them; verify only public fingerprints. Keys never enter app kits.
- **Retain This Mac’s signer until both 2026-12-07 and every enrolled Mac has updated or moved
  to 1301.** Retire it only afterward, recoverably into `_trash`, with separate owner approval.
- **The kit installer activates the agent** (owner, 2026-10-26: "sure switch it on").
  `packaging/install-agent.sh` installs *and* loads the LaunchAgent, matching Studio Hub's
  `components/hub/backend/khu_agent.py` (`Bootstrap.activate`): probe
  `launchctl print gui/$(id -u)/com.khupdater.agent`, bootstrap the plist only when that job is not
  loaded, so an already-loaded agent is left alone and never doubled. A failed start keeps the
  finished install where it is, prints launchctl's reason and the command that retries it, and
  exits non-zero. Do not reintroduce an "installed but not started" state.
- **One GUI app: Studio Launcher KH** (owner, 2026-11-17). The publisher's fleet view is the
  Launcher's own Fleet window (`Sources/khu/FleetWindow.swift`), reached from the menu bar or the
  page footer; `Update Studio KH.app` and `packaging/build-app.sh` are retired and must not come
  back. `packaging/build-launcher.sh` is the one GUI release; the headless `khu` agent and
  `khu-stub` supervisor stay separate inside it, for Macs with no menu bar. The publisher page
  itself is server-side (`Sources/KHUpdaterCore/Server.swift`) and is what the Fleet window shows.
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

## SwiftPM note

**The test suite is `./build.sh test`; there is no SwiftPM test target.** `swift test` does not run
this project's tests and never has: the target that used to be declared had no `path:`, so SwiftPM
read the root `Tests/` (Python, Objective-C and JS together) and died with "mixed language source
files" before running anything — and the package does not build under SwiftPM at all
(`Sources/khu-stub` cannot see `KHUStub`'s types). Rows 20261123-123 and 20261123-126. A target that
cannot run is worse than no target; making SwiftPM build this package is a task of its own, not a
prerequisite for a release.
