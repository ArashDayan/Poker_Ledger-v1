# Poker Ledger — Banker's Field Review (live cash game simulation)

**Reviewer role:** the guy actually running the box at a 9-handed $1/$2 home game.
**Method:** walked every screen/code path as a real session — create session, seat 9
players, opening buy-ins, 6 rebuys, rake collections, cash-outs, close and verify.
**No code changed.** This is the pre-work report.

---

## 1. The simulated session

| Step | What I did | Screens touched |
|---|---|---|
| 1 | New Session: "Friday Night Game", location, blinds 1/2, table 1, rake 5%, USD, opened House Rules panel to set entry fee 200 / cap 600 | New Session |
| 2 | Seated 9 players (Ari, Sam, Kian, Dana, Reza, Mo, Nina, Jack, Ben), seats 1–9, each with a 200 opening buy-in + signature | Players tab → Add sheet → Quick sheet ×9 |
| 3 | 6 rebuys across 4 players, two of them after the rebuy-level cutoff (warning fired, "Proceed Anyway") | Players tab or Actions tab |
| 4 | 7 rake collections (quick chips + 2 custom pot-based) | Actions tab |
| 5 | Cash-outs: 3 winners (one at 1,150 — triggered the outlier prompt), 4 losers, 2 busted at 0 | Players / Actions |
| 6 | End Session → balance banner → confirm → Report | Dashboard → sheet → Reports |

**Verdict on the math:** the accounting core is sound. Session-level balance
(`buy-in + rebuy` vs `cash-out + rake`) reconciled to zero, $0 cash-outs counted as
settled, a winner cashing out far above their buy-in was never blocked. Void/edit
keeps the audit trail. That part I'd trust with real money.

**Verdict on the speed:** it is not fast enough for a live table. The ledger is
right; the *interaction cost* is wrong.

---

## 2. Click/tap counts (measured, best case, nothing mistyped)

| Action | Taps today | Detail | Target |
|---|---|---|---|
| Create session | **9–14** | name, location, 2 blinds, table no., rake, currency, expand house rules, entry fee, cap, rake mode, submit | 2 (template/"repeat last game") |
| Seat one player + buy-in | **6–9** | open sheet, type name (keyboard), pick seat chip, accept amount, Continue, **draw signature**, Confirm | 3 |
| Seat 9 players | **~60 taps + 9 signatures + 9 name typings** | ≈4–6 min of table time | <90 s |
| Rebuy (from Players tab) | **4** (+1 if warning fires) | Rebuy chip → amount prefilled → **signature** → Confirm | 2 |
| Rebuy (from Actions tab) | **5–6** | extra player-picker step | — |
| Rake, quick chip | **3** | Actions tab → Collect Rake → chip | 1 |
| Rake, pot-based | **5–6** | + pot typing | 2 |
| Cash-out | **4** | + signature | 2 |
| Bust-out (0) | **4** | same as a full cash-out — no dedicated "busted" button | 1 |
| End + verify | **5** | End Session → read banner → Confirm → PIN → report | fine |

**Headline:** a 9-player, 6-rebuy, 7-rake, 9-cash-out night = **~130 taps and 24
signature draws**. That's the real cost, and almost all of it lands during hands.

---

## 3. Where the banker makes mistakes

Ranked by how likely I am to actually do it at 2 a.m.:

1. **Signature fatigue → the pad becomes theatre.** 24 signatures a night means
   I start scribbling them myself to keep the game moving. The moment that happens
   the whole signature feature is worthless *and* misleading in a dispute. It's
   labelled "host signature", captured on my phone, and required even for a $0
   bust-out. Requiring it everywhere is what destroys its evidentiary value.
2. **Wrong player, right amount.** In the Actions tab the player picker is a plain
   list of "Seat N · Name" with no amounts, no active/settled state, no visual
   grouping. Tapping Reza instead of Rez... is a one-pixel mistake that produces a
   silently wrong ledger. Nothing downstream catches it because the table still
   balances.
3. **Rebuy logged as buy-in.** The two chips sit side by side, identical styling,
   and the prefilled amount is the same. The totals still reconcile, so the error
   only surfaces in the report as a wrong buy-in/rebuy split — often after payout.
4. **Double-charging a rebuy.** The Confirm button disables on tap (good), but if
   I get interrupted mid-sheet and re-open it, the amount is prefilled and nothing
   tells me "Reza already rebought 40 seconds ago." No recent-duplicate guard.
5. **Rake drift.** Rake is a *manual* action with no prompt, no per-hand or
   per-level target, and no "you haven't raked in 22 minutes" nudge. In a real
   session I forget 2–4 drops an hour. This is the single biggest real money leak
   and the app is silent about it.
6. **Cap/level warnings become noise.** The rebuy-level dialog fired repeatedly in
   my run and "Proceed Anyway" is the fast path. By hand 60 I'm tapping through it
   without reading — so a genuine cap breach also gets waved through.
7. **Settled toggle hidden on the avatar.** Marking someone settled is an
   undiscoverable tap on their photo circle. I found it by reading source, not by
   using the app. It also affects `signedWhileAbsent` stamping, so it silently
   changes audit data.
8. **No cash-box reconciliation.** The app verifies its own arithmetic, never
   "does the drawer hold what the app says." Cash Drop exists but is outside the
   balance equation and only shown as a footnote line.

---

## 4. Screens that slow the game down

- **New Session.** 12 fields to start a Tuesday game that is identical to last
  Tuesday's. Blocking validation on Location and Table Number for a home game is
  pure friction. There is no template, no duplicate, no default host.
- **Add Player sheet → then a second Quick Transaction sheet.** Two sheets,
  a keyboard, a seat grid and a signature pad to seat one person. Done nine times
  in a row while people are standing over you with cash, this is the worst moment
  in the app.
- **Actions tab.** It's a second, slower route to actions that already exist on the
  Players tab, with an extra player-pick step. It is the tab whose big grid buttons
  *look* like the fast path but are the slow one. Only Rake and Cash Drop genuinely
  need to live there.
- **Signature pad, everywhere.** 160 px of drawing surface inside every money
  sheet. It's the single largest per-transaction time cost.
- **Table View.** Beautiful, and the right mental model (I think in seats, not in
  an alphabetical list), but it's a *view* — tapping a seat opens a menu rather
  than firing the action. It's decoration where it could be the primary console.
- **5 tabs + a "More" menu.** Dashboard, Table, Players, Actions, Timeline. During
  live play I only ever used Table/Players and Actions-for-rake. Dashboard is a
  glance screen occupying prime tab real estate.

---

## 5. Information missing during live play

Things I needed and could not see without leaving the screen:

1. **Cash box / drawer total right now** — "the box should contain X." Not shown
   anywhere. This is the number a banker checks constantly.
2. **Per-player "owes / is owed" at a glance** in the seat map. The card shows
   buy-in/rebuy/out; the table view doesn't show money at all.
3. **Time since last rake** and rake-per-hour vs. expected.
4. **Who is still un-cashed-out** — surfaced only at End Session, when it's too
   late and someone has gone home. Needs to be a live count in the header.
5. **Rebuys remaining for this player under the cap** — I only learn on rejection.
6. **Chips issued vs. chips on the table** — no chip-denomination tracking at all,
   so a chip-race or a colour-up is invisible to the ledger.
7. **Undo affordance.** `undo()` exists but is buried; there's no persistent "last
   action: Reza rebuy 200 — undo" strip, which is the #1 error-recovery tool.
8. **Player history across sessions.** Every session starts from an empty roster;
   the same nine people show up every week and I retype nine names.

---

## 6. What I'd redesign (priority order)

**P0 — kill the taps that happen 100× a night**

1. **Make Table View the home screen of a live session.** Tap an occupied seat →
   radial/inline action bar right on the seat: `Rebuy · Cash-out · Rake`. Money
   shown on the seat chip. Target: rebuy in 2 taps, zero navigation.
2. **Signature policy, not signature everywhere.** Make it configurable per session
   with a sane default: signature required on **cash-outs above a threshold** and
   on **edits/voids** only; buy-ins and rebuys record with a timestamp + host
   identity. Add a "signature off" mode for private home games. This is the single
   biggest speed win and it *increases* the credibility of the signatures that
   remain.
3. **Long-press = repeat last amount, no sheet.** Long-press Rebuy on a player →
   instantly logs their standard rebuy with an undo snackbar. 1 tap.
4. **Persistent undo strip** at the bottom of the live screen showing the last
   action with a one-tap undo (5–10 s window) — replaces most "let me go find it
   in Timeline and void it".

**P1 — stop the money leaks**

5. **Rake reminder + rake pacing.** Header chip: "Rake: $340 · last 8 min ago".
   Optional nudge per N minutes or per level. Quick-rake chips promoted to the live
   header so raking is 1 tap from anywhere.
6. **Cash box widget.** `Expected drawer = buy-ins + rebuys − cash-outs − drops`,
   pinned in the header next to the clock, with a one-tap "count the box" reconcile
   that logs a variance instead of hiding it.
7. **Duplicate-transaction guard.** Same player, same type, same amount, <2 min →
   "Reza already rebought $200 a minute ago. Log another?"
8. **Distinct buy-in vs rebuy affordances.** Different colour and icon weight; and
   auto-infer: a player who already has a buy-in gets **Rebuy** as their primary
   button, buy-in demoted to the overflow.

**P2 — the setup and close**

9. **Session templates / "Start same game as last time."** One tap from the session
   list, everything pre-filled, only date changes. Drop the hard requirement on
   Location and Table Number.
10. **Persistent player roster (regulars).** Names, default buy-in, usual seat,
    private tags carried across sessions. Seating a regular becomes: tap seat →
    tap name → done. That alone removes nine keyboard sessions per night.
11. **Bulk seating mode.** One sheet, add nine names in a row with a shared default
    buy-in, one confirmation at the end.
12. **Live "un-cashed-out" counter** in the AppBar, and at End Session a
    settlement sheet that says *who pays whom* — not just whether the totals
    reconcile. Right now the report tells me the table balanced but not that Jack
    hands Nina $420.
13. **"Bust out" as its own 1-tap action** on the seat, recording a $0 cash-out and
    marking the player settled in one move. It's the most common way a player
    leaves and today it costs 4 taps.

**P3 — polish**

14. Make "settled" an explicit labelled control, not a tap on the avatar.
15. Downgrade the rebuy-level dialog to a non-blocking inline warning on the seat
    (a coloured ring) so real cap breaches still get a modal and stay meaningful.
16. Add chip-denomination tracking as an optional module if you want to serve
    rooms that colour up.

---

## 7. One-line summary

The ledger math is professional-grade and I'd trust it with the night's cash — but
the app currently costs ~130 taps and 24 signatures a session, which is where a
real banker starts cutting corners. **Make the table map the console, make the
signature conditional, add a live cash-box and a rake pacing reminder, and give me
a saved roster** — those five changes cut roughly 60% of the taps and close every
error path that today produces a *silently wrong but perfectly balanced* ledger.

---

*Next step: say the word and I'll implement P0 (items 1–4) first — they're
self-contained and don't touch the accounting core.*
