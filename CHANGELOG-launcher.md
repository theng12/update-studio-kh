# What's new in Studio Launcher KH

The newest version is first; this file keeps the ten most recent, and older entries live in
`docs/changelog-archive.md`. An entry is for the person updating — `## <version> — <date>` and its "- "
lines. The **release body is not this file**: `packaging/release-push.sh --summary <file>` takes a
two-or-three-sentence summary, because the feed row is composed from the body and the Launcher card
shows it.

## 0.1.90 — 2026-11-27

- **The app list no longer waits for artwork.** Each check used to fetch every feed icon it did not already hold, one after another, before the window could draw its first row: on a cold network that is a minute per missing icon, which is how a fresh Mac sat on “Checking…” for minutes. The list is now drawn from what the Mac already has, and the missing icons are fetched afterwards, one at a time, each with its own short ceiling. A slow or dead network costs a placeholder, never the list.
- **An installed app always shows its own icon.** A remembered icon path from an unplugged drive, or one that no longer exists, was drawn as a blank tile even with the app sitting right there; the bundle that is really installed now comes first.
- **An icon that arrives late replaces its placeholder.** The window keeps the picture it drew only while the same file backs it, so a row that started blank redraws itself when its artwork is fetched.
- **Each app's update hold uses that app's own credential, and refuses plainly when it cannot.** Six apps keep their token in the file their own bundle names, and the Launcher used to rotate a different shared file on every start — so those apps refused every automatic update after one rotation. A plist that names no file keeps the shared credential; a plist that names one uses that file only; a named file that is missing or unusable makes no request and says which file, instead of sending a credential the app never asked for. The file is read only — never created, chmodded or followed through a symlink — and must contain exactly one 64-hex token. Storage 0.1.26 names no file and keeps the shared fallback.
- **Relay updates under the id the feed publishes.** A kit can register Relay as `relay` while the feed calls it `relay-studio`; the old id was folded only for drawing, not for the run, so the update saw the same bundle as two apps. The fold now happens before validation, and again from the signed feed once it is in hand — so a Mac whose saved cache was cold still selects the feed's id in the same run — dropping the old entry rather than adding a second, keeping the person's Automatic setting, and processing the app once.

## 0.1.89 — 2026-11-27

- **A tag is tied to the commit it was built from.** `khu feed` resolves each release's tag to its commit (peeling annotated tags), prints `<app> <tag> -> <commit>` every run, and refuses the whole publish when the release body's own `GATE PASS <app> <sha>` line names a different commit — a tag pointing anywhere else is a release whose bytes were never gated. A release target that is not in that commit's history is a printed warning, never a refusal.
- **A re-created release cannot move a row it already serves.** When the same version comes back with a new date, unchanged sha, size and asset name are a note (`release re-created at … , artifact unchanged`, and `(repo recreated)` when the repository itself is younger than the served release); a different artifact under a published version is refused, because one published version is one artifact.
- **`khu feed --pin <app>=<version>:<reason>`** builds one app's row from that exact published release for that run only. The reason is required and printed as `pinned: <app> <version> (<reason>)`, so a held row is explained rather than remembered. `--pin` is per run and never persisted; refusals name an unknown app, an invalid version, a missing `:reason` or a blank one, and a version the repo does not publish.
- **An edited release body on an unchanged version is reported.** The row keeps the notes it serves and the run says the new text reaches it at the next version; `--refresh-notes` remains the only replacement, and only over the tool's own placeholder.
- **`khu feed --help`** prints that command's own usage and exits 0, instead of the whole tool's list at exit 64.
- **`FeedPublisher.publish` no longer takes a `url`.** The production path cannot name a row's address, which `khu feed` produces; a caller that must state one is the separate, named `publishAddressed(…, url:)`. Both share one implementation.
- `OPEN-WORK.md` at the repository root: the open work for this repo, in the estate's shared shape, safe to publish.

## 0.1.88 — 2026-11-27

- The background helper now restarts itself on a Mac that reads the public feed, which it had never done. It is meant to start a fresh process after 150 checks — each check costs a little memory the system never gives back — but the rule also required a check to have reached a publisher, and a public feed has no publisher to reach, so the rule could never fire here. Measured on this Mac: 255 checks in one process, 21 hours old, and no restart ever.
- A check that could not read the feed still does not count, and neither does one that ran from a drive while offline, so the 1,605-restarts-in-a-row failure stays fixed. What changed is only that a public-feed check which did read its feed is no longer treated as a failure.
- After this install, a Mac with a long history behind it restarts its helper once, on the first check. That is the limit working for the first time: same process and same job, one line in the log, and nothing in flight is interrupted.

## 0.1.87 — 2026-11-25

- The Extension tab now reads like every other tab: the same card, the same grid, the same detail window. A card carries the extension's icon, a picture of it, its name, version and what it does, a status and a Download button, and opens a window with the description, the size, the checksum and the Chrome steps.
- The status is what this Mac can see rather than what we hope: **Downloaded 1.3.32** when the zip is in your Downloads folder, **Not downloaded** when it is not. The Launcher cannot add an extension to Chrome — Chrome has no way to do that without you — so the button stays Download, the window says so in one sentence, and nothing anywhere reads "Installed".
- Size and checksum come from the published list. A release date is not published for extensions, and the window says "Not published" instead of showing an empty line as if it were a date.

## 0.1.86 — 2026-11-25

- The app list has a Show control: All, Installed, or Not installed. Installed keeps what this Mac already has — including an app that exists here but never came from the feed, which gets its own "Installed on this Mac" group rather than a category it was never given. Not installed shows only what this Mac is still missing, and the choice is remembered the next time the window opens.
- A filter that hides everything says so and says how to get back: "Nothing from this feed is installed on this Mac yet. Choose All to see the feed." or "Every app on this feed is already installed here. Choose Installed to see them." — never a blank panel.

## 0.1.85 — 2026-11-25

- Studio Launcher KH can install its own updates again. Opening the app hands its window to the background helper and the app closes straight away, and the updater read that as "the new version did not start" — so every install of the Launcher failed, was put back and retried on every check. The updater now judges the installed Launcher by what is on disk: its version, its executable and its signature.
- An install that could not finish says one plain sentence — "An earlier install of Studio Launcher KH did not finish. It will be tried again on the next check." — and the card's Update button tries again, instead of printing a file path and instructions meant for whoever maintains the Mac.
- Displays Studio KH and Relay Studio KH are named correctly again. Both were shown as "Unrecognised" or listed as not on the feed, because the Launcher's built-in list of app names still used the apps' former ids.

## 0.1.84 — 2026-11-25

- Studio Launcher KH can now update itself directly through its signed Sparkle 2 appcast channel without interrupting an install. The helper keeps its own bundle free of Sparkle and schedules headless checks on the verified packaged `Studio Launcher KH.app`, pausing new agent work while Sparkle holds port 8792 and deferring whenever another app is installing.
- A background self-update relaunches silently: a short-lived relaunch marker clears the hold so queued work resumes right away and exits with zero visible windows, while opening the app yourself still opens the window as before.
- Feed rows take their words from each app's own tagged metadata, and Wire's fallback words are retired from the registry now that its tag carries them.

## 0.1.83 — 2026-11-25

- The Launcher's own updates now pause it instead of interrupting it. Its feed row carries the hold it already serves on 8792, so an update asks it to stop taking new work, waits for the job in hand to slide into a gap, installs and relaunches, and the app carries on by itself. Queued work stays queued and nothing in flight is cancelled.
- The background helper is deliberately left out of that: it opens no window, serves nothing over the network and replaces itself between runs, so there is nothing to pause.
- The Launcher now carries its own update feed address and public key and serves an empty appcast channel from this repo's Pages site — the groundwork for updating itself without a Studio. An empty channel means "no update", so it changes nothing until the release after this one writes its first row.

## 0.1.82 — 2026-11-24

- Every copy of an app is compared once, both ways, and the card says what it found in one plain sentence: "This Mac has 0.6.255; ATLAS carries 0.6.256, newer." A newer copy on a drive is offered as the update, an older one is named as older and never offered as one, and a copy whose version cannot be read is named unknown rather than left looking current.
- An app installed from a drive is no longer left behind: after installing it, the Launcher compares the drive and the feed with what is installed and offers the newer copy by name.
- An app installed on this Mac by hand and absent from the feed is listed under its own heading, "Installed on this Mac", with the version read from the app itself. It is never "No category yet" — that sentence is for a feed entry whose author forgot a label.
- Published extensions and plugins show their own icon and a screenshot of them working; a picture that cannot be read, or is larger than 2,048 pixels a side, keeps the placeholder and says why in one line.
- A long release's notes no longer fill the card: they stop at 4,000 characters on whole lines, and the last line says how many more lines are in the release.
- The folder and Disk Image carry a "Read Me First.txt": the exact command to run once, in Terminal, for a browser download that macOS quarantined.
- The helper no longer holds on to memory it is done with on the paths measured here — serving a large installer, and the reading loops a check runs: serving a 400 MB installer used to leave 600 MB in the process (measured 2026-11-24, three serves took the footprint from 2.7 MB to 600 MB, with only 224 bytes actually leaked) and a run used to leave about 94 MB behind. Both loops now read into one buffer: the same three serves take 2.7 MB → 5.0 MB, and a run now leaves about a third of a megabyte — the five-check series in the line below is that measurement.
- The helper now restarts itself after 150 checks as well as after 500 transfers. A Mac with nothing to install makes no transfers, so the transfer limit never fired while each check still cost a little memory; the log line says which limit restarted it. Five checks in one process measured 2026-11-24: 20.7 → 21.6 → 21.4 → 21.9 → 22.4 MB.
- The helper runs at most once per interval whatever woke it, so a settings change can no longer make it check in a tight loop.
- The Launcher's helper is not a feed app: the app list carries one Launcher row, and a helper left behind reports the version it actually runs.
- A first install is launched and health-checked before it is called done, and a rollback swaps the bundles rather than moving one out first.

## 0.1.81 — 2026-11-24

- Setting up a Mac is one press. The copy already knows where its updates come from, so there is no source to choose, no address to type and no pairing code before the first try; a copy shared from a Studio uses that Studio, and every other copy uses the signed public feed.
- A first run that cannot reach the feed says what was tried and what failed, in one sentence, and offers Retry. A Studio that wants a code asks for it after that refusal, not before.
- The everyday screen no longer names the service behind the feed: the footer says "the saved feed", and the word GitHub is gone from the app.
- The Studio — the fleet, the address, pairing, joining and leaving — is now its own Settings section, and it appears only on a Mac that runs a Studio or has joined one. A Mac with neither shows none of it: one list of apps, Install/Update, and the Automatic switch.
- The fleet view opens from the Studio section (and its menu item is offered on the same Macs), never from the everyday footer.
- Automatic updates have a visible switch on the main screen. It is on for a fresh Mac, it shows what the helper will really do — checking by hand shows it off — and a choice already saved on this Mac is never overwritten.
- The category tabs are proper controls: 6px apart, 32px tall, and the selected one is filled with the accent instead of underlined, so it reads at a glance and in greyscale. The accent still means "primary action" everywhere else.
- Settings is one screen: a line saying where updates come from, Check now, and the updates, appearance, background and log switches. The address and a Studio's own controls sit behind Advanced, which only appears when an address other than the saved feed is in use.

## 0.1.80 — 2026-11-22

- Publisher diagnostics report free and total disk space, the exact served feed fingerprint and timestamp, and the two installed updater fingerprints. Unavailable values are reported as unknown without interrupting feed service.
