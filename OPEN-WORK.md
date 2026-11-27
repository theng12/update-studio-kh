# Open work — update-studio-kh

Only open work for this repo. Update in the same commit whenever work starts, changes, or finishes.
Keep this file public-safe: no home paths, no hostnames or network addresses, no secrets.
History belongs in git log and receipts; failure patterns belong to the plugin's issue directory.

- [ ] **The app list says nothing about the last check** — a Mac on the public feed can fail every
  check and show nothing: the time, the outcome and the reason when it failed are not on the page,
  and a failed install path reads as silence. Show the last check per app from the app's own record,
  never from a publisher. **Next:** read the helper's last-run record into the page state and render
  one line per app with the time and, on failure, the reason.
