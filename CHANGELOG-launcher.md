# What's new in Studio Launcher KH

The newest version is first; this file keeps the ten most recent, and older entries live in
`docs/changelog-archive.md`. An entry is for the person updating — `## <version> — <date>` and its "- "
lines. The **release body is not this file**: `packaging/release-push.sh --summary <file>` takes a
two-or-three-sentence summary, because the feed row is composed from the body and the Launcher card
shows it.

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

## 0.1.79 — 2026-11-22

- The helper no longer restarts itself after a check that failed. A failed check leaves nothing to preserve, and on the Studio server every check was failing at its status report, so it restarted 1,605 times in a row — the app that kept appearing.
- It cannot restart twice with no successful check in between: the second attempt is refused, with one line in the log saying so, instead of another restart.
- The Dock icon added in 0.1.63 stays, and now appears at most once per genuine restart: the 1,605 appearances were one failing check restarting for ever, and that is what this release stops.
- The agent log begins each process with its transfer count and whether the last restart had a successful check, so "did it reset?" is answered by a line instead of a guess.
- The status report now has its own 15-second ceiling and a line naming the address and the reason when it fails, and the first check after a restart waits up to 30 seconds for the publisher's name before going ahead — a Mac that has just booted reaches its publisher instead of hanging on a name that is not answering yet.
- The Download-previous-version control is scheduled for 0.1.80: this release is the restart fix alone, so a fault fix is not hidden behind a feature.

## 0.1.78 — 2026-11-21

- **Check sources** names the Mac’s saved host and installer drives. The footer names the host that actually answered, even when the Launcher used a fallback.
- The app list shows the verified feed’s app count and publish time, names fleet apps that the feed does not carry, and marks new feed apps it does not recognise yet.
- Sort by **Type** in grid or list view. Publishers label apps Business, Entertainment, Media, System or Utility; older or unknown labels read **Unlabelled**.
- **Extensions and plugins** is separate from apps. Open it to check for published downloads. Verified Chrome extensions show Download, which saves the file to Downloads, then checks its published size and checksum before keeping it and refuses a mismatch; a plugin with no download says so instead of a dead button.

## 0.1.77 — 2026-11-21

- Settings' "Where updates come from" now shows which route is chosen: the selected one is a pressed segment, not three identical buttons.
- The footer's fleet button reads "Fleet" in full (it was cut to "Fleet…"); its tooltip keeps the full sentence.
- In Settings, "Where updates come from" has its own spacing, "Check connection" sits under the address it checks, and the Join note is one line — so the route picker and the Join controls are visible without scrolling at the default window size.
- Connecting from GitHub releases no longer fails on a Mac that has used Studio Launcher before: leftover updater state made the installer refuse a plain run ("KH Updater already exists"), and the app showed only "Local setup could not be completed". The app now asks for the installer's repair mode when anything is already there, and a real failure shows the installer's own last line.
- The custom-address field says plainly that a numeric IP can never work: macOS refuses plain http to an IP address, so only the publisher's private-network host name (or an https feed link) can be used.
- An app Studio Launcher knows but the feed it reads does not carry is now named in the list ("This feed does not carry …"), never a silent gap.
- The refresh control moved to the top right beside the view toggles and reads "Scan drives", so what it checks is on the button; the footer keeps "Drives scanned … · Server …" and says "Drives not scanned yet" before the first scan.
