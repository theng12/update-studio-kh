# What's new in Studio Launcher KH

The newest version is first; this file keeps the ten most recent, and older entries live in
`docs/changelog-archive.md`. An entry is for the person updating — `## <version> — <date>` and its "- "
lines. The **release body is not this file**: `packaging/release-push.sh --summary <file>` takes a
two-or-three-sentence summary, because the feed row is composed from the body and the Launcher card
shows it.

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

## 0.1.75 — 2026-11-21

- A Mac can now leave a fleet from Studio Launcher itself. Settings shows "Leave this fleet" only while this Mac is enrolled to a publisher — a saved Update Studio address and its sign-in. A GitHub-only Mac never sees it.
- One in-page confirmation: this Mac keeps every app, every model and every setting. It stops taking orders from Update Studio and updates from the GitHub feed instead.
- Leaving needs no network at all, so it works with Update Studio off or this Mac offline. The pinned key stays and still verifies every update. The saved sign-in is cleared and this Mac gets a fresh local id, so the old controller's record can never be used against it. The previous settings are kept in ~/Library/KHUpdater/_trash, and the page says where.
- Afterwards Settings shows the GitHub address as the one in use, says this Mac no longer reports to or takes orders from a Studio, and the GitHub switch button disappears — one action, not two. Re-joining with a pairing code from a controller works exactly as before, and removing a Mac from Update Studio is still done there.
- "Repair this Mac's setup" can no longer be a dead end. When the saved address is one macOS refuses — a bare IP over plain http — the window says why and offers one press, "Use GitHub releases instead": the public feed is verified against this Mac's own pinned key, the address is saved, the old sign-in is cleared, and the helper is then repaired from this app's own kit. Apps, settings and the pinned key stay.
- The updater never sits unable to update. When every saved address is one macOS refuses, it reads the built-in GitHub feed and says so in one line ("the saved address is a bare IP, so this Mac is updating from GitHub releases instead") instead of retrying an address macOS can never allow. A Mac with a working publisher address is untouched.
- Automatic updates now depend on the feed, not on a publisher. A Mac on the GitHub feed updates its apps and itself automatically, exactly like a Mac on a publisher's feed, and still reports to nobody and takes no orders. Its per-app Automatic switches, pause and backoff work as before.
- Settings offers the same three-way "Where updates come from" as first run: GitHub releases, This Mac's Update Studio, or a custom address. A Mac on the GitHub feed can join Update Studio again by typing that Mac's address and a pairing code — no reinstall — and a wrong code changes nothing.
- On a GitHub-fed Mac the self-update switch is on and usable, driven by the feed instead of a publisher, and one line says this Mac updates from the signed feed, reports to nobody, and needs a pairing code to join Update Studio again.

## 0.1.74 — 2026-11-21

- First run now asks where updates come from, as a drop-down: GitHub releases, a custom address, or — when this copy came from a publisher's kit — that Mac's own Update Studio. GitHub is the default on a copy downloaded for anyone, so setting up a Mac no longer starts at one particular publisher's address.
- Choosing GitHub releases needs no pairing code and shows the public feed link, read-only, with one line saying this Mac installs only what that feed signs and reports nothing to anyone.
- A custom address accepts an https feed link (no pairing code) or the publisher's private-network host name (the code from its Update Studio window). A numeric IP is still refused — macOS blocks plain http to one — and the sentence says to use the name shown on the publisher's window.
- A Mac set up from a publisher's kit opens on that Mac's own Update Studio, prefilled with its address and the pairing code, exactly as before. Pair again and Repair keep their saved connection and show no picker.
- GitHub releases is now the built-in starting address when nothing is saved — it keeps working when Update Studio is off. A saved or typed address always wins over it, and Settings shows the address actually in use, marked as the default when it is that one.
- An already-paired Mac can move to the public feed in one click: Settings has "Use GitHub releases instead". The mirror is checked against this Mac's own pinned key before it is saved; the saved sign-in is kept, so switching back is one address away. After the switch Settings says this Mac no longer reports to or takes orders from Update Studio.
- The failure sentence names the real cause instead of a generic "could not be reached": a numeric IP says macOS blocks plain http to an IP; https typed for a publisher says it serves plain http on its own port; a tailnet name that does not resolve says Tailscale's DNS is not answering on this Mac. Each offers GitHub releases as the way out.

## 0.1.73 — 2026-11-20

- The version check now answers while transfers are running. The feed index sat in the same fixed slot count as a 1.48 GB download, so 46–65 Macs checking during a rollout were told the publisher was busy for about 18 seconds and then retried together. The index and the page are now served outside the transfer slots; a transfer started while every slot is full is still refused as busy, exactly as before.
- Hub rollouts are staggered from now on, and the choice is made on each Mac, not at the publisher. A Mac starts a large pull at its own minute inside a 60-minute window, worked out from its own name and the version, so 65 Macs never pull 1.48 GB at once and a Mac that retries after a "busy" answer cannot re-form the stampede. It needs nothing from the publisher, and a Mac that has been offline for a day simply waits its own minute from when it sees the release. The window and the size it applies to are settings; 0 turns it off.
- A security update never waits for a slot. An entry the publisher marks as a security update is pulled immediately, which is what a Mac that has been offline and is far behind needs; an app this Mac does not have yet is never staggered either.
- A switch turned on in Update Studio now takes effect on a Mac that has no Hub too. The check that ends an already-queued update when Automatic is off read this Mac's own switch and stopped there, so a page switch set later was ignored and the Mac said "set on this Mac" about a switch set in the page. It now follows the same rule the automatic sweep uses, and the sentence names the switch that actually decided.
- An automatic pull held for its slot says so in one line: which minute of the window it is waiting for and that nothing else is waiting on it.

## 0.1.72 — 2026-11-20

- A refused update hold no longer locks a Mac out of that version for ever. When an app does not pause in time, the failure is remembered separately with its reason and time, retried after 15 minutes, and after three attempts tells you to quit or restart the app once — the update is already downloaded and installs as soon as the app closes, without waiting for another backoff.
- A real artifact failure still stops after one automatic attempt and now expires after seven days instead of stranding a Mac permanently. An identical repeated failure does not refresh its own clock.
- A Mac whose earlier build recorded a refused update hold as a bad artifact clears that memory automatically on its next run and tries the version again.
- Connecting to the public GitHub feed works again. The setup file a public feed writes carries no token on purpose, and the installer refused it as unfilled, so every public-feed connect failed. A public https feed now needs no token; a publisher's feed still does.
- Update installed apps on the SSD no longer asks to install the Command Line Tools first. It is now a plain shell script using the Mac's own tools, with the same checksum, private-copy, identity and signature checks as before, so it runs on a Mac that has never had any developer tools.
