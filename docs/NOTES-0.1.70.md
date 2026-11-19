# 0.1.70 — the fleet's recovery path had no exit

The defect is not the predicate. The predicate is the mechanism; the defect is that **a Mac
excluded by it could never leave the exclusion state on its own.**

## The loop

`/api/update-all` ("Update N Macs") is the fleet's only way to place an order. It sends to exactly
the Macs `updateAvailable` names. That predicate, as it stood, excluded:

* any Mac holding a pending order for the app, **whatever its age**; and
* any Mac whose newest result for the app was a failure, **whatever its age**.

Nothing else places an order (the single-Mac button goes through the same predicate), and the only
thing that clears a failure is a later result, which needs an order. So:

    failure hides the Mac → no order → no new result → the failure stands for ever

`queueOrder` had already been given a 30-minute staleness rule after 39 Macs held a dead order on
2026-11-16. The predicate in front of it was never given the same rule, so the single-Mac button
never got far enough for that rule to matter, and the bulk route never reached it either.

## The fix

`orderRetryWindow` (30 minutes) now bounds both exclusions:

* a pending order younger than the window still holds the Mac back (it is working);
* a failure younger than the window still holds the Mac back (the owner has not read it yet);
* past the window neither counts, so the next "Update N Macs" places a fresh order.

The page uses the same rule (`failureToLookAt`) for the chip, so a Mac that has become eligible
reads "Update available · last try failed <when>" instead of a bare "Failed" that contradicted the
button. The failure itself stays in the Mac's history — placing an order does not rewrite what
happened — and the "Copy error report" block still shows it.

## What limits the retry loop

A genuinely broken Mac is retried once per press of "Update N Macs", and that is bounded at both
ends:

* **The route is owner-driven, never timed.** `/api/update-all` is a POST from the page's own form
  and is refused unless it arrives same-site from the owner typist's page. Nothing on the publisher
  posts it on a schedule, so an unattended publisher cannot spin (BU5: three presses leave one order).
* **The Mac stops re-trying a bad artifact.** The agent keeps `memory.rejected[app] = sha256` once
  an update for that artifact reaches `failed`/`rolled_back`, and Automatic skips it until the feed
  names a different artifact. An explicit owner order clears that memo on purpose — the owner asking
  again is a new attempt, not a loop.

## The second cause, kept separate

`1602` carried a 628 MB `.part` from 17 November that never completed and installed cleanly once it
had a whole file. That is **not** this defect, and folding it in would hide it.

The `.part` is now gone (the successful install cleaned it), so the transfer path cannot be
autopsied. What survives is `stub.log`: on 12 November, six entries reading
`cannot run …/versions/0.1.21/khu: Exec format error` (POSIX 8), then nothing until 19 November when
the install completed. **An exec failure is not a transfer failure.** That is a third cause:
a `khu` built for the wrong architecture. `build-agent-kit.sh` refuses to build a thin binary,
which is why no kit we hand out carries one — but a Mac that already carries a single-arch helper
has no way to say so, and nothing checks at install time or at first run.

Three defects, three rows:
* **this one** — the exclusion loop (fixed here, 0.1.70);
* **the transfer** — a `.part` that never resumed; needs a Mac still holding one to prove it;
* **the architecture** — an exec failure the stub reports (`cannot run …: Exec format error`) but
  no installer checks for.

## What this version does not prove

It cannot be proven on a Mac that is currently excluded, because there is no such Mac in this
checkout — the proof is the route run against a fixture (BU1–BU5), where a stale order and a stale
failure both now produce an order and the recent forms both still do not. The real proof is a Mac
receiving an order it was previously excluded from, on the next release cycle.
