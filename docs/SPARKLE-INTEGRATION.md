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

## Why the link is deferred to 0.1.83, and the approved path: weak linking

`build/khu` is **one binary in three places**:

| where | who runs it | `@executable_path/../Frameworks` resolves to |
|---|---|---|
| `Studio Launcher KH.app/Contents/MacOS/` | the app | `Contents/Frameworks` (carries `Sparkle.framework`) |
| `~/Library/KHUpdater/base/versions/<v>/` | the running agent | `base/versions/Frameworks` (absent) |
| `~/Library/KHUpdater/base/bin/khu` | the CLI copy, refreshed on every switch (`Agent.swift` `refreshCLICopy`) | `base/Frameworks` (absent) |

A **strong** link (`-framework Sparkle` → `LC_LOAD_DYLIB`) would make dyld refuse to start
any copy whose framework is missing — including the agent on a remote Mac, which nobody can
hand-fix.

**Approved path for 0.1.83: weak-link `Sparkle.framework` into the single `build/khu` binary.**
No second executable, no fork of the sources, and no change to the pinned
`dist/libkhsparkle.a` (`2bce760e…`). Weak linking emits `LC_LOAD_WEAK_DYLIB` and
marks the shim's two Sparkle class imports (`_OBJC_CLASS_$_SPUUpdater`,
`_OBJC_CLASS_$_SUUpdatePermissionResponse`) as `[weak-import]`, so standalone copies (the
agent, `base/bin/khu`, and `test-cli`) launch cleanly without `Sparkle.framework` or
`DYLD_FRAMEWORK_PATH`, while the bundled `.app` loads `Contents/Frameworks/Sparkle.framework`
and runs the full hold-then-appcast path.

### Steps to land in 0.1.83

1. **`build.sh` (universal `swiftc` build of `build/khu`):** link the pinned static archive
   and weak-link `Sparkle.framework` on both `arm64` and `x86_64`:
   ```sh
   vendor/khsparkle/libkhsparkle.a \
     -F vendor/khsparkle \
     -Xlinker -weak_framework -Xlinker Sparkle \
     -Xlinker -rpath -Xlinker @executable_path/../Frameworks
   ```
   Keep one `build/khu` binary across the app, `base/versions/<v>/`, and `base/bin/khu`.
2. **`packaging/build-launcher.sh`:** copy `vendor/khsparkle/Sparkle.framework` into
   `Studio Launcher KH.app/Contents/Frameworks/Sparkle.framework` before the `codesign` step
   (current line 56), sign nested-first — `Versions/B/XPCServices/*.xpc`,
   `Versions/B/Autoupdate`, `Versions/B/Updater.app`, then `Sparkle.framework`, then the
   app — and prove it with `codesign --verify --deep --strict`. Use `Versions/Current`
   (`Current -> B`), never a `Versions/A` alias.
3. **Mandatory Launcher-side guard before calling `kh_sparkle_start()`:** call from the
   Launcher's own start path once `LauncherHold` is up (`main.swift:704` is where
   `LauncherHold` is constructed). **Before** calling `kh_sparkle_start()`, check:
   ```swift
   guard NSClassFromString("SPUUpdater") != nil else {
       // log a clear error naming the missing Sparkle.framework and return without calling kh_sparkle_start()
   }
   ```
   This guard is **mandatory, not optional**: with weak linking, a mispackaged `.app` missing
   `Contents/Frameworks/Sparkle.framework` still launches, and without this guard the current
   pinned shim would take the hold (`POST /api/maintenance/hold`) before `[SPUUpdater alloc]`
   returns `nil` and would leave the hold to expire via `dispatch_paused_s`. Checking
   `NSClassFromString("SPUUpdater") != nil` first eliminates that unreleased-hold wart
   immediately without rolling the shim pin. On a non-zero return from `kh_sparkle_start()`,
   log `kh_sparkle_last_error()` and never retry in a loop.
4. **Hardened runtime:** the Launcher signs without `--options runtime` today, so it needs
   **no** library-validation entitlement. If hardened runtime is ever added to the `.app`,
   `com.apple.security.cs.disable-library-validation` becomes mandatory — a self-signed app
   plus a self-signed framework have no Team ID, and dyld refuses that combination (Displays
   0.1.8 died this way one second after launch). Standalone weak-linked `build/khu` with
   `--options runtime` and no framework launches cleanly without the entitlement (measured).

## Required gate checks for 0.1.83

Because weak linking degrades a missing framework from a launch crash to a runtime `nil`,
both checks below are required in the release gate:

1. **Weak-link check on `build/khu` and `base/versions/<v>` (both slices):**
   `otool -arch arm64 -l` and `otool -arch x86_64 -l` must show `LC_LOAD_WEAK_DYLIB` for
   `@rpath/Sparkle.framework/Versions/B/Sparkle` and **zero** strong `LC_LOAD_DYLIB`
   references to Sparkle. This catches any build change that accidentally drops
   `-weak_framework`.
2. **Bundle packaging and signature check on `Studio Launcher KH.app`:**
   verify `Contents/Frameworks/Sparkle.framework` is present in the built bundle, signed
   nested-first (`XPCServices/*.xpc` → `Autoupdate` → `Updater.app` → `Sparkle.framework` →
   app), and that `codesign --verify --deep --strict` passes.

## Measurement evidence and verification boundary

Measured 2026-11-24 against the pinned `dist/libkhsparkle.a` (`2bce760e…`) and
`vendor/Sparkle.framework` (2.10.1) using a universal `swiftc` binary matching `app/build.sh`
flags and signed with `KH Studio Local Signing`:

- **Mach-O / imports (`arm64` + `x86_64`):** `otool -l` shows `LC_LOAD_WEAK_DYLIB` only;
  `dyld_info -imports` shows only `_OBJC_CLASS_$_SPUUpdater` and
  `_OBJC_CLASS_$_SUUpdatePermissionResponse`, both `[weak-import]`. Binary size delta on
  `arm64`: `+28,968` bytes.
- **Standalone (`arm64`, no framework):** passes `codesign --verify --strict` (plain and
  `--options runtime`), launches cleanly (`rc=0`, `SPUUpdater=nil`). Calling
  `kh_sparkle_start()` without a bundle plist returns `rc=2` (`Info.plist is missing
  SUFeedURL`), state `0`, zero network requests.
- **Bundled `.app` (`arm64`, with `Sparkle.framework`):** passes
  `codesign --verify --deep --strict`, `SPUUpdater=loaded`, `kh_sparkle_start()` returns `0`,
  sends `POST /api/maintenance/hold` with Bearer token, starts `SPUUpdater`, and fetches
  `GET /appcast.xml`.
- **Verification boundary — stated plainly:** **`arm64` was verified live at runtime;
  `x86_64` was verified at the Mach-O and imports level only** (Rosetta is not installed on
  this host, so `arch -x86_64` cannot execute here).

## Queued shim-side cleanup (next shim revision — do not roll the pin now)

The current pinned `dist/libkhsparkle.a` (`2bce760e…`) is untouched. When the shim
next cuts a revision, add a 4-line defensive guard inside `kh_sparkle_start()` before taking
the hold (`if (!NSClassFromString(@"SPUUpdater")) { set_error(@"Sparkle.framework is not loaded"); return 4; }`)
and call `release_hold()` on the `!updater` fallback path so even a caller that forgets the
app-side guard never leaves a hold dangling.

## The version it rides

**0.1.83** — the cut after 0.1.82 is served, as agreed with System. Planning it into that cut
from the start is the point: weak linking keeps one `build/khu` binary while the framework
copy, nested signing, app-side guard, and two gate checks are scheduled into the cut cleanly.

## Landing checklist for the Launcher lead

- [ ] the steps above, on this branch, compiled here with `vendor/khsparkle/libkhsparkle.a` matching the pinned sha
- [ ] gate check 1: `otool -l` on `build/khu` and `base/versions/<v>` proves `LC_LOAD_WEAK_DYLIB` and zero strong `LC_LOAD_DYLIB` for Sparkle on both `arm64` and `x86_64`
- [ ] gate check 2: `Contents/Frameworks/Sparkle.framework` present in `Studio Launcher KH.app`, signed nested-first, `codesign --verify --deep --strict` passes, plus a real launch alive a second later
- [ ] mandatory `NSClassFromString("SPUUpdater") != nil` guard in place before `kh_sparkle_start()`
- [ ] the app's Info.plist carries all four keys, read back from the built bundle
- [ ] `appcast.xml` served 200 from Pages, and its first item signed with
      `~/.kh-sparkle/com.khupdater.launcher/private.key`
- [ ] a self-update proven with live work queued (the hold says `safe:false` naming the app)
