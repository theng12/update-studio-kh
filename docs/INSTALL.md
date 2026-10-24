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

## 3. Each Mac — once

On the publisher: `~/Library/KHUpdater/bin/khu enrol --state ~/Library/KHUpdater/state --machine <id>` prints the
Mac's token (only its sha256 is stored). Then on the Mac:

```bash
K="$HOME/Library/KHUpdater"; mkdir -p "$K/bin" "$K/state" "$K/base/versions/1.0.0" ~/Library/Logs ~/Library/LaunchAgents
# khu and khu-stub are this repository's build/ outputs, copied to the Mac
cp khu-stub "$K/bin/"; cp khu "$K/base/versions/1.0.0/khu"; chmod 755 "$K/bin/khu-stub" "$K/base/versions/1.0.0/khu"
ln -s "$K/base/versions/1.0.0/khu" "$K/base/current"
# examples/agent-config.json with the placeholders filled -> "$K/base/config.json"
sed "s#__HOME__#$HOME#g" packaging/com.khupdater.agent.plist > ~/Library/LaunchAgents/com.khupdater.agent.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.khupdater.agent.plist
```

The stub runs the binary `current` links to (`agent --config base/config.json`), keeps it alive, and puts
`previous` back if a new version exits non-zero 3 times within 5 minutes of a switch or writes no heartbeat
of its own within 2 minutes. `feedURL` ends in `/release.json`. Set `bundleID` for each app (e.g. the
Gateway's `CFBundleIdentifier`) so a DMG holding any other app is refused.

In the config, list only the apps that Mac has. Recipes: `gateway` (stops its server by the PID `/health`
reports, SIGTERM only), `app-dmg` (any ordinary app), `updater` (self-update through the stub), and `story` /
`hub`, which are **status only**: those apps keep their own updaters, which let running work finish first.

`_trash` folders (in `state/`, `feed/` and `base/`) collect superseded downloads, bundles and links;
nothing is ever deleted, so empty them yourself from time to time.

## Removing it

`launchctl bootout gui/$(id -u)/com.khupdater.agent` (or `.publisher`), then move `~/Library/KHUpdater` and the
plist to the project `_trash/`. Installed apps are untouched.
