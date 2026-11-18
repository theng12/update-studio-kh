# Installing KH Updater

## Connect another Mac with Studio Launcher KH

On the controller Mac, 1301, open Studio Launcher KH → **Fleet…** (menu bar, or the footer of the Launcher window) → Connect a Mac. Use **Save Launcher copy…** to save a ZIP of the signed Launcher app with its verified connection kit, or use the newly packaged Launcher installer on an install SSD. A Launcher packaged from the current release carries controller 1301's address (`http://100.82.91.102:8790/release.json`) and the existing pinned key; an older shared Launcher copy still names the old address and is not the one to hand out. Transfer it to the new Mac; a path on the controller Mac’s Desktop is not an address the new Mac can use.

On the new Mac, install Tailscale and sign in to a network that permits reaching controller 1301. Put Studio Launcher KH in Applications, open it, and use **Connect to Update Studio**. The Update Studio address starts with the trusted package’s saved address (controller 1301's `http://100.82.91.102:8790/release.json` in the current package) and can be edited to another Tailscale IPv4 address; the package’s publisher key stays pinned. Confirm the Mac name, enter the code from Update Studio, and click **Connect**. The app shows connecting, success or the reason it could not connect. It never discovers or trusts an arbitrary publisher from a code alone.

The installed Launcher app stays exactly as packaged when the raw helper updates. Target Macs never regenerate or sign its bundle and need no private app-signing key. A missing or damaged Launcher requires the signed Launcher installer; the raw helper keeps running and reports that requirement. Opening any Launcher copy first asks this user's running helper to open the main window. An existing installation starts its saved helper if needed and waits for its window instead of showing the pairing form. The main window checks its saved connection; a refused sign-in opens Settings with Pair again, while an unreachable publisher keeps the saved connection. First-run connection opens as a centred normal window, leaving other windows usable.

Helper automatic updates start enabled, matching the existing setup default. After signed pairing, setup first requests the pinned publisher’s signed helper release and checks the download’s size and SHA-256. An unavailable feed or interrupted download uses the verified kit inside this Launcher; an invalid signature, checksum or refused request stops setup. Pairing itself still needs the controller. A newer kit is never downgraded by an older network release. Connecting does not silently install other apps. Settings show the current connection and let you check it without enrolling the Mac again. Changing publisher trust requires its trusted connection package; a failed connection check does not replace credentials.

If Connect finds leftover installation files without saved connection settings, it repairs the incomplete setup while keeping the Mac’s app data and previous versions. Keep the same name and enter the current pairing code. If local setup fails, try Connect again; Launcher keeps the same pairing attempt. If setup finishes but the helper cannot start, close the window and reopen Launcher to retry starting it.

If Update Studio no longer recognises this Mac’s sign-in, remove its old enrolment on the publisher, then choose **Pair again** in Launcher’s connection settings. Confirm the recovery and enter the pairing code. Recovery keeps this Mac’s existing publisher key and connection ID, preserves its app and Automatic choices, and saves the previous config under `~/Library/KHUpdater/_trash` for restoration. A wrong code or different publisher key leaves the current config intact. Launcher never pairs again automatically.

The pairing code has no time expiry. **New code** replaces it for future connections; existing Macs remain connected. Five wrong codes lock pairing for five minutes. The existing code-free enrolment window remains an explicit owner action for Hub bootstrap. No trust, enrolment, network or code-lifecycle policy changes as part of this interface.

## Update or repair installed apps from an SSD

Open **Update installed apps.command** at the install SSD’s root. It checks the Launcher installer’s SHA-256 and app signature before opening the local results window. No publisher connection is needed for the app repair pass.

The action installs Studio Launcher KH if it is missing, then checks the KH apps already in this user’s Applications folders against `apps.json`. Each installer must match its SHA-256 and contain the expected signed app and version. Newer installed versions are kept. The same version may be installed again to repair damaged app files; missing optional apps are skipped. An app that is paused, busy, unreadable or unsafe to replace gets a plain reason in the results instead of a forced installation. Saved connections, grants and pause settings are not changed.

On a connected Mac, the verified Launcher kit can also promote the helper through its existing current/previous rollback layout. On a never-connected Mac, open the installed Launcher and use the normal pairing code once; the SSD action never creates or replaces a connection identity.

Helper version cleanup is on by default after sustained healthy reports. It keeps the current version and the previous fallback, moves older versions to the helper’s `_trash`, and can be switched off in Launcher Settings. The SSDs remain mounted when the action finishes.

## Publisher operation and manual recovery

The commands below document publisher administration and the kit’s underlying install procedure. Normal new-Mac setup uses the Launcher app above.

Everything lives in the user's own `~/Library/KHUpdater` — no `sudo`, nothing in `/usr/local`.
Build once on the dev Mac: `./build.sh` (gives `build/khu` and `build/khu-stub`), `./build.sh test`.

Placeholders in `packaging/*.plist` and `examples/agent-config.json`: `__HOME__` (the Mac user's home),
`__TAILSCALE_IP__` (this Mac's Tailscale IPv4, `tailscale ip -4`), `__PUBLISHER_TAILSCALE_IP__`,
`__PUBLIC_KEY_BASE64__`, `__MACHINE_ID__`, `__TOKEN_FROM_ENROL__`.

## 1. Publisher (the dev Mac) — once

```bash
K="$HOME/Library/KHUpdater"; mkdir -p "$K/bin" "$K/feed" "$K/state" ~/Library/Logs ~/Library/LaunchAgents
cp build/khu build/khu-stub "$K/bin/"     # from this repository's ./build.sh
"$K/bin/khu" keygen "$K/keys"      # prints the PUBLIC key; private.key stays here, mode 0600
# The publisher plist must pass `--key "$K/keys/private.key"` to `khu serve`: orders are
# signed with it, and the Macs refuse an unsigned or unverifiable order. Without it the
# publisher can still publish and serve the feed, but it cannot command anything.
sed -e "s#__HOME__#$HOME#g" -e "s#__TAILSCALE_IP__#$(tailscale ip -4)#g" \
    packaging/com.khupdater.publisher.plist > ~/Library/LaunchAgents/com.khupdater.publisher.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.khupdater.publisher.plist
open http://127.0.0.1:8790/        # the status page (loopback only)
```

## 2. Publish a release (any time)

```bash
~/Library/KHUpdater/bin/khu publish --feed ~/Library/KHUpdater/feed --key ~/Library/KHUpdater/keys/private.key \
  --app gateway --version 0.2.196 --artifact dist/gateway-kh-0.2.196.dmg --kind app-dmg --changelog /path/to/gateway/CHANGELOG.md
~/Library/KHUpdater/bin/khu publish ... --app updater --version 1.0.1 --artifact build/khu --kind updater --changelog CHANGELOG-launcher.md
```

Every KH app release includes a four-SSD refresh before closeout: refresh KH-STUDIO-ATLAS, KH-STUDIO-NOVA and KH-STUDIO-UGREEN from the released artifacts, and KH-STUDIO-TERRA too whenever it is attached (a detached TERRA is reported as not refreshed, not as a release failure). TERRA is a full install drive (previously hand-maintained); its Hub `model-library/`, `optional-models/`, `voices/` and `Extras/` folders are model content, not installers — the release refresh must never rotate, delete or re-hash them, only the app DMGs, the helper/app bundle and the index; update each SSD’s `apps.json`, installer checksums, version notes and setup helpers; read back and hash every copied installer and helper; keep the current and one previous version, moving older material to restorable `_trash`; leave all four SSDs mounted. A missing drive or failed copy is an unfinished release step and must be reported. ORICO is the owner's Time Machine drive and is never used for a release refresh or accessed by agents. Update Studio owns serialized SSD writes across app releases.

The one-click SSD action reads the current `apps.json` each time it starts. App identities, versions, installer paths, sizes and checksums come from that refreshed index, rather than a fixed version list in Launcher. The same click therefore handles future released app versions after the SSD refresh. It still keeps newer installed versions, preserves pauses and never installs absent optional apps.

Publishing commits the signed current and previous installer references before retiring unreferenced artifacts and icons to macOS Trash. The feed keeps two verified versions of each app by default — the current one and its previous — and that count is a setting beside the feed: `khu publish --keep N` saves it for the publishes that follow, values below 2 are refused, and the publisher's Settings page shows the count in use. Existing `artifact-retention.json` recovery pins also remain protected: an older recovery copy is still referenced until that ledger is safely refreshed. The next normal publication retries retirement after those references are released or a Trash failure is resolved. This can temporarily retain more than the kept count while legacy recovery is required; publication does not silently drop those recovery references.

Those version numbers are examples: use the app’s new version and exact installer path. A version not newer than the feed's is refused (`--allow-same` exists, but never use it to replace an accepted installer with different application bytes).

After the normal release is installed, launched and verified on its intended Mac, retain its accepted installers with the shared portfolio helper. Before this step, check that no active job or dependency uses an installer that would leave the retained pair. Write the helper's trusted schema-1 pins with the single GUI app entry, `Studio Launcher KH`, naming the canonical project directory and its latest plus previous accepted DMG, exact version, absolute source, SHA-256, byte count and installed-acceptance evidence. (`Update Studio KH` was folded into it in 0.1.53 and takes no new pin.) One version is allowed only when the app has shipped once. The shared contract is documented in `Shared Tools/portfolio/README.md` → Release dist retention.

```bash
sh packaging/retain-release.sh /absolute/path/to/accepted-installer-pins.json
```

This post-acceptance hook delegates to `~/Developer/Shared Tools/portfolio/tools/release-dist.py`; `KHU_RELEASE_DIST_TOOL` can select the same shared helper at another location. It does not build, sign, publish, install or infer acceptance. The helper copies exact pins into canonical `dist/<App Name>-<version>.dmg` and records provenance in `dist/.release-dist.json`; only unchanged obsolete files it previously managed can retire to project `_trash/dist/`. Both apps keep their own pair (four DMGs total). Preserve previous working installers until the replacement is verified. A failed or pending candidate must not enter the pins.

Launcher feed entries of kind `updater` are helper binaries, not Launcher DMGs: select its verified packaging DMG independently. Publishing continues to name an explicit `--artifact` and `--version`, so retained sibling DMGs do not affect selection. Never choose a newest glob or modification time. Builders still produce candidates under `build/`; they must not call this hook before installed acceptance. The focused caller proof is `python3 -I Tests/test_release_dist_hook.py` with `TMPDIR` set to an existing directory in the local task folder.

There is no Add App form in Update Studio. **Apps & updates** lists published versions, sizes and What's New and can request updates on connected Macs. To add a normal app DMG, publish it with a stable `--app` ID, its version, `--artifact` and a `--changelog` whose top entry matches. The publisher checks the DMG’s version and reads its bundle identity and icon, stores the installer by SHA-256 and signs the release with the existing publisher key. A new installation mechanism needs a supported recipe; a catalog record alone does not implement one.

Use `--name` for its shown name, `--description` for the Launcher details description, and optional `--tagline` / `--feature` for other app words. Description is separate from What's New. Keep the same description in each SSD’s `apps.json` app record; indexing preserves those words. Metadata changes do not require rebuilding an unchanged app. Publishing or distributing still follows the release approval and gate.

## 3. Each Mac — once, with the kit installer

`packaging/build-agent-kit.sh <updater-version> <new-output-directory>` packages the two
`./build.sh build` binaries, the existing agent plist, a config example and `install-agent.sh`.
The kit has no credentials. Its helper and supervisor must each contain both arm64 and x86_64
slices; the kit builder refuses thin inputs. No sudo, package receipt or system-wide daemon is needed.

On the destination, as the signed-in user, run:

```bash
bash /path/to/kit/install-agent.sh /path/to/filled-config.json "$HOME"
```

**`install-agent.sh` is the one per-Mac procedure, and it installs and starts the agent.** A Mac
that already has Studio Hub gets the same agent from the Hub's own installer, which takes the same
path; whichever runs first installs, and the other reports that it is already there.

In order, it:

1. validates the config — every required field filled in, a real `apps` dictionary, a valid kit
   version — before writing anything to the destination;
2. refuses if `~/Library/KHUpdater` or the agent's LaunchAgent plist already exists, so an existing
   install is preserved and its upgrade/repair procedure is used instead of an overwrite;
3. stages the per-user layout in `~/Library/.KHUpdater-install.*`, sets `stateDir` and `stubBase`
   to this home, forces `once: false`, and writes a mode-0600 config plus the LaunchAgent plist;
   it preserves the configured app choices and Automatic settings — use the `story`/`hub` recipes
   for those apps, always status-only in v1;
4. promotes the staged files into place;
5. **starts the agent** (owner, 2026-10-26). It probes
   `launchctl print gui/$(id -u)/com.khupdater.agent` and bootstraps the plist only when that job is
   not loaded, so an already-loaded agent is left alone and a second copy is never created. Studio
   Hub's `khu_agent` does exactly the same.

A failed *staging* attempt moves into `~/Library/_trash/`; no file is deleted. A failed *start* does
not: the install is complete by then and stays exactly where it is, the script prints launchctl's
own reason and the one command that starts it later, and exits non-zero.

```bash
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.khupdater.agent.plist"
```

The usual cause is a shell with no GUI session (over SSH); run that command in that Mac's own
Terminal, or log in and run the installer again.

The local smoke check is `python3 -I Tests/test_packaging.py` after `./build.sh build`; it uses only
temporary homes and a stand-in `launchctl` first on `PATH`, and never opens an app.

Release checks use the Developer-owned `~/Developer/portfolio/bin/testctl` policy for `kh-updater`.
Use `testctl plan kh-updater` before the coordinated gate and `testctl run kh-updater <lane>` for
the chosen configured lane. The policy must point at the exact release checkout; the supported
`--config` option can select a temporary copy with only that checkout path changed (resolve the
shared receipts/tmp paths to their original absolute locations). The `full` lane already includes
the fast lane's tests; do not repeat the fast lane to collect duplicate evidence. After the gate,
`python3 -B -I packaging/release-proof.py --config <candidate-policy> --lane full --started-at <gate-start-UTC> --out <new-proof.json>`
collects that lane's matching receipt and independently rehashes its log. Older matching results are
labelled `skipped-unchanged` and retain the source on which they ran. The collector runs no tests,
defines no lanes, and refuses receipts for another checkout or a changed log. Packaged launch,
update/rollback and intended-machine evidence remain separate required release checks; a test
receipt never claims those passed. `Tests/test_release_proof.py` checks the collector itself.

Shared UI release inputs are versioned under `packaging/shared-ui` so the scoped test receipt covers them and isolated builds need no Developer-folder path. At release preparation, compare those three files with `~/Developer/Shared Tools/kh-shared-ui` and refresh any changed inputs before the gate. `packaging/generate-ui.py` compiles the shared notes and layout values into the helper; both screens consume that compiled data.

Both native app packagers use `KHU_SIGN_IDENTITY`, defaulting to the existing
`KH Studio Local Signing` identity. A missing identity fails packaging; ad-hoc signing is refused.
The private app-signing key stays on the build Mac. Compare designated requirements across two
differing packaged versions, verify signatures and kit hashes after the final outer seal, and
run the isolated packaged launch check before distribution. Target Macs preserve the signed app.

### Enrolment — where the config's token comes from

On the publisher: `~/Library/KHUpdater/bin/khu enrol --state ~/Library/KHUpdater/state --machine <id>` prints the
Mac's token (only its sha256 is stored). Then that token goes in the Mac's config.

**Or let the Mac enrol itself**: the Connect kit asks for the pairing code shown on the publisher's page
(`http://127.0.0.1:8790`) and claims a token with it, at any time. Five wrong codes lock it for five
minutes, and New code on the page replaces it. Hub's bootstrap sends no code, so it needs an open window:
`~/Library/KHUpdater/bin/khu enrol-window --state ~/Library/KHUpdater/state --minutes 30`. Only a Mac the publisher does not already know can do this: an id that is already enrolled
is refused over the network, so a device on the tailnet can never take a real Mac's place. A Mac that
was reset is removed first — `Remove Mac` on the page, or
`khu remove --state ~/Library/KHUpdater/state --machine <id>` — and then enrols again the same way. The page lists every Mac with the time it connected, so the owner
can see who claimed one.

### Optional feed hosting

Hosting starts off. The original publisher keeps the signing key, enrolment, status and orders.
An agent may host verified downloads when its exact enrolled machine ID has an enabled role in
signed `network` settings. Publish those settings with `khu network --feed <feed-dir> --key
<existing-key-file> --config <network.json>` on the original publisher only. The JSON has ordered
`feedURLs` and a `hosts` dictionary; each host role has `enabled`, `bind` and `port`. Use the chosen
Mac's existing tailnet address; client URLs end in `/release.json`, with the original publisher
last. Publish the host role first, verify that its mirror serves the signed feed and artifacts,
then publish the preferred client URLs. Do not guess a machine ID from its display name.

The agent mirrors every signed artifact and icon before publishing its local feed, then manages
only `com.khupdater.feed-host` in its user's LaunchAgents. It runs `khu serve --feed-only`; the
mirror has no sign-in or command routes and receives no signing key or enrolment token. Disable
that machine's role to stop its job; mirror files stay restorable. No SSH, firewall changes or
network reconfiguration are required. If macOS requests network or firewall permission, stop
and tell the owner instead of granting it or finding a workaround.

Clients keep `feedURL` pointing at the original publisher for control traffic. Signed mirror
settings change download sources only. Once learned, those settings let explicit local requests
use a verified mirror during publisher downtime; Automatic and remote orders wait. A refused
sign-in remains an error. `khu agent --config <file> --install <app-id>` runs a local request once.

### What the agent does on each Mac

The stub runs the binary `current` links to (`agent --config base/config.json`), keeps it alive, and puts
`previous` back if a new version exits non-zero 3 times within 5 minutes of a switch or writes no heartbeat
of its own within 2 minutes. `feedURL` ends in `/release.json`. Set `bundleID` for each app (e.g. the
Gateway's `CFBundleIdentifier`) so a DMG holding any other app is refused.

In the config, list only the apps that Mac has. Recipes: `gateway` (stops its server by the PID `/health`
reports, SIGTERM only), `app-dmg` (any ordinary app), `updater` (self-update through the stub), and `story` /
`hub`, which are **status only**: those apps keep their own updaters, which let running work finish first.

`_trash` folders (in `state/`, `feed/` and `base/`) collect superseded downloads, bundles and links;
nothing is ever deleted, so empty them yourself from time to time.

First installs with no previous bundle are launched and health-checked. If unhealthy, their
install journal stays and later runs retry health rather than report `current`. Recovery and
rollback failures also keep the journal; do not discard it to silence an unresolved result.
Gateway stop and health require the PID in `/health` to own the listening socket as well as
run from the configured bundle; an unrelated listener blocks installation.

## Recovery appendix: install by hand

Only when the kit installer cannot be used — a refused kit, a Mac whose installer never ran, or a
deliberately hand-built layout. It does what `install-agent.sh` does, without its checks: fill
`examples/agent-config.json` yourself, and do not run it over an existing installation.

```bash
K="$HOME/Library/KHUpdater"; mkdir -p "$K/bin" "$K/state" "$K/base/versions/1.0.0" ~/Library/Logs ~/Library/LaunchAgents
# khu and khu-stub are this repository's build/ outputs, copied to the Mac
cp khu-stub "$K/bin/"; cp khu "$K/base/versions/1.0.0/khu"; chmod 755 "$K/bin/khu-stub" "$K/base/versions/1.0.0/khu"
ln -s "$K/base/versions/1.0.0/khu" "$K/base/current"
# examples/agent-config.json with the placeholders filled -> "$K/base/config.json"
sed "s#__HOME__#$HOME#g" packaging/com.khupdater.agent.plist > ~/Library/LaunchAgents/com.khupdater.agent.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.khupdater.agent.plist
```

## Removing it

`launchctl bootout gui/$(id -u)/com.khupdater.agent` (or `.publisher`), then move `~/Library/KHUpdater` and the
plist to the project `_trash/`. Installed apps are untouched.
