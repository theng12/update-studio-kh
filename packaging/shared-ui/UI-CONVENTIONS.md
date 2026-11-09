# KH app UI conventions (v1, owner-approved 2026-11-08)

One look and behaviour across the KH apps. Each app builds these in its own toolkit; there is no shared code package. Brand colours, fonts and app icons stay per app (owner 2026-11-08: no icon changes for now). Adopt in each app's next normal release, no separate release. Full audit with file paths: `_orchestra/developer-handoff/shared-ui-audit-20261108.md`.

Numbers (spacing, radii, text sizes, status names, toast limits): `design-tokens.json`. Use them as CSS variables or Swift constants; don't invent new values.

## Version
- Read from the app's own bundle/package, never typed by hand.
- Shown at the bottom of the sidebar (or Settings → About where there is no sidebar), as `v1.4.388`, plus `· built 2026-11-08` where a build stamp exists.
- Clicking the version opens What's New.

## What's New
- Data: `whats-new.json` made at release by `whats-new.py` from `CHANGELOG.md` (`## x.y.z — date`, then `- ` bullets, plain words).
- Look: title "What's New", current version beside it, newest release first, current release marked, bullets at body size, one Done/Close.
- Modal or page are both fine. Show it once after an upgrade, never on a first-ever run.

## Sidebar
- 220 wide, group headers, one line icon per row, active row tinted with the app's accent.
- Version + What's New at the bottom. Collapses on narrow windows.
- Apps without a sidebar (Update Studio launcher, menu-bar only views) put version + What's New in Settings/About.

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

## Settings
- Sidebar row → Settings page. Sections as cards: this app / this Mac first, About last (version + What's New).
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
