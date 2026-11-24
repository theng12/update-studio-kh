# Sparkle 2 in the Launcher — prepared for 0.1.83 (2026-11-24)

Branch `launcher/sparkle-0.1.83` off `38b8a40`. **Nothing here is on `main`**: 0.1.82's gate
was queued behind four apps and the owner was waiting on the memory fix inside it.

## What this branch already does

- `Sources/khu/Launcher.swift` — `LauncherBundle.write` now writes the three keys the shim
  refuses to start without, beside the `KHHoldURL` it already wrote:
  `SUFeedURL`, `SUPublicEDKey` (the Launcher's own per-app EdDSA public half), and
  `KHHoldTokenFile` (`~/Library/KHUpdater/state/launcher-hold-token` — `LauncherHold.tokenName`,
  the hold's own 0600 file, never the agent's rotating token).
- `docs/appcast.xml` — the feed the key above points at, served by Pages from `main:/docs`.
  Empty until the first signed row lands, which reads as "no update" and is the truth.

Keys alone change nothing: without the shim linked and started, Sparkle is not in the app.

## What it deliberately does not do, and why

`build/khu` is **one binary in three places**:

| where | who runs it | `@executable_path/../Frameworks` would resolve to |
|---|---|---|
| `Studio Launcher KH.app/Contents/MacOS/` | the app | `Contents/Frameworks` |
| `~/Library/KHUpdater/base/versions/<v>/` | the running agent | `base/versions/Frameworks` |
| `~/Library/KHUpdater/base/bin/khu` | the CLI copy, refreshed on every switch (Agent.swift `refreshCLICopy`) | `base/Frameworks` |

Linking `libkhsparkle.a` into that binary adds an `LC_LOAD_DYLIB` for
`@rpath/Sparkle.framework/Versions/B/Sparkle` to **all three**. dyld then refuses to start any
copy whose framework is missing — and the agent is the one component nobody can hand-fix on a
remote Mac. `refreshCLICopy` copies a *binary*, not a bundle, so every self-update would have to
carry the framework too.

**Recommendation: give the app its own executable rather than link the shared one.**

1. `build.sh`: a second universal build, `build/khu-launcher` — the same `Sources/khu/*.swift`,
   plus `-F vendor/khsparkle -framework Sparkle -lkhsparkle` and
   `-Wl,-rpath,@executable_path/../Frameworks` (the shape proved in the shim's harness, assertion 7).
2. `main.swift` `launcher-bundle`: take `--exe <path>` instead of `CommandLine.arguments[0]`;
   `packaging/build-launcher.sh` passes `build/khu-launcher`. Everything else in the bundle is
   unchanged, and the agent's binary stays framework-free.
3. `packaging/build-launcher.sh`: copy `Sparkle.framework` to `Contents/Frameworks` before the
   `codesign` at the current line 56, sign nested-first — `Versions/B/XPCServices`,
   `Versions/B/Autoupdate`, `Versions/B/Updater.app`, then the framework, then the app — and prove
   it with `codesign --verify --deep --strict`. `Versions/Current`, never a `Versions/A` alias.
4. Call `kh_sparkle_start()` once the hold listener is up, from the Launcher's own start path
   (`main.swift:704` is where `LauncherHold` is constructed). A non-zero return is the shim's
   refusal — log `kh_sparkle_last_error()`, never retry in a loop.
5. The Launcher signs without `--options runtime` today, so it needs **no** library-validation
   entitlement. If hardened runtime is ever added, `com.apple.security.cs.disable-library-validation`
   becomes mandatory — a self-signed app plus a self-signed framework have no Team ID, and dyld
   refuses that combination (Displays 0.1.8 died this way, one second after launch).

## The version it rides

**0.1.83** — the cut after 0.1.82 is served, as agreed with System. Planning it into that cut from
the start is the point: the shim adds an executable, a framework copy and a signing step to the
build, and discovering those mid-gate is what this branch exists to prevent.

## Landing checklist for the Launcher lead

- [ ] the steps above, on this branch, compiled here
- [ ] `codesign --verify --deep --strict` on the built app, plus a real launch alive a second later
- [ ] the app's Info.plist carries all four keys, read back from the built bundle
- [ ] `appcast.xml` served 200 from Pages, and its first item signed with
      `~/.kh-sparkle/com.khupdater.launcher/private.key`
- [ ] a self-update proven with live work queued (the hold says `safe:false` naming the app)
