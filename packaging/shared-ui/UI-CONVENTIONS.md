# KH app UI conventions (v2, owner-approved 2026-11-08; bottom-left group, sidebar, appearance and support added 2026-11-12)

One look and behaviour across the KH apps. Each app builds these in its own toolkit; there is no shared code package. Brand colours, fonts and app icons stay per app (owner 2026-11-08: no icon changes for now). Adopt in each app's next normal release, no separate release. Full audit with file paths: `_orchestra/developer-handoff/shared-ui-audit-20261108.md`.

Numbers (spacing, radii, text sizes, status names, toast limits): `design-tokens.json`. Use them as CSS variables or Swift constants; don't invent new values.

## Version + What's New pill
- Read the version from the app's own bundle/package, never typed by hand.
- One pill in the bottom-left — sidebar footer, menu-bar apps at the bottom of the dropdown, no sidebar: Settings → About — showing the app name and installed version, e.g. `Studio Launcher KH 0.1.20`.
- The whole pill opens What's New. No separate version text or What's New link remains anywhere.
- Immediately to its right: a Check for Updates icon button (tooltip and accessible name "Check for updates"). When the signed feed offers a newer version, a tiny update button appears beside it and starts that update.
- That band holds only Support this app, the pill and those two buttons, plus at most one compact status line. Machine names, counts, badges and build details belong in the page (Overview or Settings), never in the footer.

## What's New
- Data: `whats-new.json` made at release by `whats-new.py` from `CHANGELOG.md` (`## x.y.z — date`, then `- ` bullets, plain words).
- Look: title "What's New", current version beside it, newest release first, current release marked, bullets at body size, one Done/Close.
- Modal or page are both fine. Show it once after an upgrade, never on a first-ever run.

## Sidebar
- 248 wide (never under 240 — the footer group needs the room), background = panel, one right border. Collapses on narrow windows.
- One navigation list with few group headers, one order, no destination repeated elsewhere. Every navigation and footer entry has a leading 16 px icon from one consistent set, its text label and an accessible name — no text-only lists.
- The set itself: `glyphs.json` beside this file (plus, macs, apps, settings, heart, check, update), and the footer's exact numbers in `design-tokens.json` → `footer`.
- Primary task destinations first; Connect/Add actions at the top of the same list; Settings last. Active row tinted with the app's accent or panel highlight.
- Footer holds Support this app (heart) just above the version + What's New pill, then Check for Updates and the conditional tiny update button. Nothing else.
- Apps without a sidebar put the same group at the bottom of the menu-bar dropdown, or Settings → About for utilities with neither.

## Modals and dialogs
- Use the toolkit's own dialog (sheet, `<dialog>`, NSAlert, Modal component).
- Esc closes the topmost one only. Backdrop click closes, except for destructive confirms. Focus stays inside while open. Radius `sheet` (12).
- Title, body, footer; one primary button on the right. System file/print/permission panels stay native.

## Pop-up messages (toasts)
- Bottom-right, at most 3 at once, newest on top.
- Success: 5–8 s. Errors stay until read or dismissed and say the real reason.
- One optional action: Undo, Retry or Open. Announced to screen readers (`role="status"` / live region).
- Background events in menu-bar apps may use the system notification instead.

## Confirm before delete
- The confirm button says what it does ("Delete 3 videos"); the safe button says "Keep".
- Red only on the destructive button. Backdrop never confirms or dismisses.
- Enter confirms unless "Keep" has focus. Type-to-confirm for the most serious actions.
- Prefer moving to trash/retired over deleting for good.

## Appearance
- Settings → Appearance (menu-bar apps: the app's Settings/preferences), never in the footer group.
- Four choices: **System** (default), Light, Dark, Default. Default means the app's designed look.
- Every app starts on System; a saved explicit choice is kept. An app that shipped only its old default migrates that default to System once.
- Apply live across the app and keep text and controls legible in every mode.

## Support this app
- Sidebar footer entry with a heart icon, just above the version pill; opens the app's Support page.
- The app is free with every feature unlocked. Offer a one-time donation through the shared public page `https://nowpayments.io/donation/studiokh`, opened in the user's browser through the app's allow-listed external opener.
- Optional and non-blocking: never required, never nagging, no repeat reminders.
- Every app gains Check for Updates and the conditional tiny update button on the same shared feed contract, including apps that never had an in-app updater. Never add a second updater.

## Settings
- Sidebar row → Settings page. Sections as cards: this app / this Mac first, Appearance and About after (About carries version + What's New where there is no pill).
- Searchable when there are many settings.

## Empty, loading and error
- Same shape for all three: quiet icon, one-line title, one-line detail, one action.
- Loading adds a spinner. Error shows the real reason and Retry.
- "Not checked" never looks like "passed"; "no data" never looks like 0.

## Update prompt
- Say what will stop before installing. Show the new version and what changes.
- One Install button plus Dismiss. A release that fails verification shows no Install. Never nag.

## Keyboard
- Cmd+, Settings · Esc closes topmost overlay · Enter confirms · Cmd+Z undoes the last undoable action · Cmd+K search (where the app has search) · Space/arrows in players.

## Icons (rules only, no changes now)
- 1024×1024 from SVG/code, rounded square with the macOS margin, no text, one strong shape, readable at 16 px.
