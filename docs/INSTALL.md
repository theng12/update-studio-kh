# Installing KH Updater

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
  --app gateway --version 0.2.196 --artifact dist/gateway-kh-0.2.196.dmg --kind app-dmg
~/Library/KHUpdater/bin/khu publish ... --app updater --version 1.0.1 --artifact build/khu --kind updater
```

A version not newer than the feed's is refused (`--allow-same` to re-publish the same one).

## 3. Each Mac — once, with the kit installer

`packaging/build-agent-kit.sh <updater-version> <new-output-directory>` packages the two
`./build.sh build` binaries, the existing agent plist, a config example and `install-agent.sh`.
The kit has no credentials. It contains the build Mac's architecture only; check the destination
architecture before copying it. No sudo, package receipt or system-wide daemon is needed.

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

### Enrolment — where the config's token comes from

On the publisher: `~/Library/KHUpdater/bin/khu enrol --state ~/Library/KHUpdater/state --machine <id>` prints the
Mac's token (only its sha256 is stored). Then that token goes in the Mac's config.

**Or let the Mac enrol itself**: open a window on the publisher's page
(`http://127.0.0.1:8790`) — or `~/Library/KHUpdater/bin/khu enrol-window --state ~/Library/KHUpdater/state --minutes 30`
— and the Mac's setup claims a token for itself while the window is open. Enrolment is closed the rest
of the time. Only a Mac the publisher does not already know can do this: an id that is already enrolled
is refused over the network, so a device on the tailnet can never take a real Mac's place. A Mac that
was reset is removed first — `Remove Mac` on the page, or
`khu remove --state ~/Library/KHUpdater/state --machine <id>` — and then enrols again through the next
window. The page lists every Mac that enrolled through a window, with the time, so the owner can see
who claimed one.

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
