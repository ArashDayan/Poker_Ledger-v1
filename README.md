# Poker Ledger

**Track Every Chip. Trust Every Session.**
Professional poker cash-game accounting for hosts — not a poker game.

## v1.1 — Brand, Rake Slots, Signatures & Sound

This pass focused on making the app look and feel like a professional
piece of card-room equipment, without touching the accounting core or
speeding the flow up at the cost of proof.

### 1. New brand mark & home screen

The logo is a premium green-felt-and-gold casino chip: eight gold edge
inlays, a gold text band carrying **POKER LEDGER** set circularly
(POKER over the top, LEDGER under the bottom, meeting gold diamonds at
3 and 9 o'clock), and a centre medallion holding a fanned **Ace of
Spades over a King of Clubs**.

It is drawn in code — `lib/widgets/poker_chip_logo.dart`, a
`CustomPainter` — rather than shipped as an SVG. `flutter_svg` does not
implement `<text>` / `<textPath>`, so an SVG version of this mark would
have silently dropped the circular brand text at runtime, which is the
whole point of it. Painting it also means it stays crisp at 26 px in the
session AppBar and at 210 px on the home screen, from one source of
truth. `tool/generate_logo.py` renders the identical geometry to PNG for
the Android/iOS launcher icons so the raster and painted marks never
drift apart.

The home screen was rebuilt around it: a felt vignette hero with the
mark at real size, a gold-gradient wordmark, and three headline stats
(Active / Sessions / Total Rake). Session rows are now cards with a
coloured status spine, status/table/seated pills, and the rake figure
called out in gold. Total Rake deliberately shows `—` when past sessions
mix currencies, rather than adding Toman to dollars.

### 2. Five configurable quick-rake slots

Quick rake is now **exactly five banker-defined slots**, not an
open-ended add/remove list. A fixed five means the Collect Rake sheet
shows the same buttons in the same positions all night, which is what
makes them fast — muscle memory beats flexibility at a live table.

* Set them **when creating the session** (New Session → House Rules →
  Quick Rake Buttons), pre-seeded with a ladder that matches the chosen
  currency, and re-seeded if you switch currency.
* **Edit them any time** from House Rules on a running session.
* A blank slot simply doesn't render as a button — a room that only uses
  three amounts leaves two empty and the layout doesn't shift.
* **Slot order is preserved, never sorted**, so the buttons stay where
  you put them.
* The **custom amount** path (with pot-size-driven rake suggestion) is
  untouched and still sits underneath the quick buttons.

Shared UI lives in `lib/widgets/quick_rake_slots_editor.dart` so the
create-session and edit-rules screens are guaranteed identical.

### 3. Signatures — still mandatory, now verifiable

Signatures remain **required on every money transaction** (buy-in,
rebuy, cash-out). Nothing was relaxed.

What's new is the **specimen**: when you seat a player you can capture a
one-off *sample signature* from that player, stored on their record with
the date it was taken. Later, tapping **verify signature** on any of that
player's rows in the Timeline opens a side-by-side comparison — their
sample on file above, the signature captured on that specific
transaction below — plus flags for anything the app already knows
(signed while marked absent, edited after the fact, no sample on file).

The sample is deliberately **optional and non-authorising**: a regular
you trust can be seated without one, and the app never blocks on its
absence. Poker Ledger also **never scores or "matches" the two marks** —
automated signature matching would give false certainty about someone's
money. It puts both in front of the banker at the same size and lets a
human decide, exactly as a real card room does.

### 4. Poker chip sounds — selectable variations

The banker supplies one long recording containing several different chip
gestures performed back to back with pauses between them, shipped as
**`assets/sounds/Chip_sound.wav`**.

`tool/split_chip_sounds.py` splits it automatically:

1. Builds a 30 ms amplitude envelope of the mono sum.
2. Measures the recording's own noise floor and derives the open/close
   thresholds from it, so re-recording at a different level still works.
3. Walks the envelope with **hysteresis** — a high threshold to open a
   region, a much lower one to close it. This matters: a single threshold
   chatters during the quiet tail of a pour and shatters one gesture into
   a dozen fragments.
4. Merges regions closer than 250 ms, because the small gaps *inside* a
   pour are not gesture boundaries.
5. Drops anything too short to be a real gesture.

From the 20 gestures it finds, it picks a spread of genuinely different
ones — bucketed by length and strike count, so the options are a pour, a
cascade, a riffle and single drops rather than six near-identical hits.
Each is trimmed to its onset, given 2 ms/30 ms fades so it can never
click, and peak-normalised. **No synthesis, no EQ, no layering** — these
are the banker's own chips, just isolated.

The result is six options, shortest first:

| Option | Length | Character |
|---|---|---|
| Single Chip | 0.27 s | One clean chip set down |
| Chip Drop | 0.36 s | A handful of chips dropped |
| Chip Drop 2 | 0.41 s | A crisper handful, brighter tail |
| Chip Cascade | 0.65 s | A shorter pour, chips settling |
| Chip Pour | 0.83 s | A long cascade onto the felt |
| Chip Pour 2 | 1.04 s | The fullest pour, longest tail |

**Settings → Table Sounds** lists all six; tapping one selects it *and*
plays it, so choosing and auditioning are the same gesture. The choice is
persisted and used for every chip action — buy-in, rebuy, cash-out, rake,
add player and cash drop. The on/off toggle is unchanged.

Playback is built to be harmless: audio is fire-and-forget and fully
guarded, so a missing asset, a device with no audio route or a platform
with no plugin can never throw into a money path — **the ledger always
wins**. It mixes with other audio rather than seizing the session, and
rotates a small player pool so nine rapid buy-ins overlap naturally
instead of cutting each other off.

## Brand logo — how to install the real asset

The app renders the brand mark from a single file:

    assets/images/logo.png

`lib/widgets/poker_chip_logo.dart` loads that asset everywhere — home
hero, session AppBar, splash screen and the centre of the poker table —
so replacing the file updates the whole app. A painted chip remains in
the widget purely as a fallback if the asset is missing or fails to
decode; it is never used when the real file is present.

To install the designed logo, run:

```bash
pip install pillow numpy
python3 tool/install_logo.py path/to/your-logo.png
dart run flutter_launcher_icons     # rebuilds platform launcher icons
```

That one command generates all four required variants from your file:

| Output | Purpose |
|---|---|
| `logo.png` | in-app mark, transparent background |
| `splash_logo.png` | splash screen mark |
| `app_icon.png` | launcher icon source, opaque dark background |
| `app_icon_foreground.png` | Android adaptive foreground, with safe-zone padding |

**Why it processes rather than copies.** A supplied render usually sits
on a dark photographic backdrop. Copied in as-is, that backdrop would
show as a dark rectangle behind the chip on every screen — most visibly
in the centre of the green felt table. The script flood-fills the
backdrop away from the border (so dark detail *inside* the chip is
kept), trims to the chip, squares the canvas, and adds the safe-zone
padding Android adaptive icons need or the gold rim gets cropped by the
launcher's mask.

## V2 — Player History, Multi-Table, Privacy Mode

### Player history across sessions

A dedicated **Players** directory (people icon on the home screen) lists
everyone the host has ever seated, searchable and sortable by recent /
name / sessions / lifetime profit. Tapping one opens their full record:
sessions played, lifetime profit or loss, W/L and win rate, totals for
buy-in / rebuy / cash-out, averages, biggest win and loss, first and last
played, and every session they appeared in — tap any of those to jump
straight to it. Also reachable from a player's detail screen and from the
history button on their card during a live game.

**How players are linked across sessions.** A `Player` row belongs to
exactly one session and there is no global player registry, so a career
is assembled by grouping rows on a **normalised name** (case- and
whitespace-insensitive). This is a deliberate trade-off: two different
people sharing a name are treated as one, and someone entered as "Ali"
one week and "Ali K" the next shows as two. The alternative — fuzzy
matching — risks silently merging two people's money history, which is
far worse than a split record the banker can see and fix by renaming.

The whole feature is a **read-only aggregation** of transactions that
already exist. It cannot alter the ledger. Lifetime totals are suppressed
(shown as `—`) for anyone with sessions in more than one currency, since
adding Toman to dollars would be meaningless.

### Multi-table support

A session can now run several tables. **More → Tables** adds, renames,
resizes (6/8/9/10 seats) and removes them; a table switcher appears above
the Table and Players views once a second table exists, and the dashboard
gains a per-table breakdown. Players can be moved between tables with the
swap icon on their card, which picks the next free seat.

**Tables organise seating only — all money stays session-wide.** A host
running three tables settles one bank at the end of the night, not three,
so buy-ins, rebuys, rake and the balance check remain exactly as they
were. Moving a player between tables changes their seat and nothing else;
their transactions are untouched. This is what keeps the settlement
engine completely unaffected by the feature.

**Existing sessions are safe.** Sessions saved before this change have no
table list and their players have no `tableId`. The app synthesises a
single table from the session's existing table-number/seat-count/dealer
fields and treats a null `tableId` as "the first table", so an old
session opens as an ordinary one-table game and the multi-table UI only
appears if the host actually adds a second table. Seat numbers are unique
*per table*, so Table 1 Seat 3 and Table 2 Seat 3 are different people.

### Privacy Mode

An eye icon in the session AppBar and on the home screen (also in
**Settings → Privacy**) instantly replaces every money amount on screen
with `••••`.

It is implemented at the single choke point every amount already passes
through — `CurrencyFormatter.format` — rather than screen by screen,
because a per-screen implementation would inevitably miss one and the one
it missed would be the one on show when a player leans over the phone.
Toggling it re-keys the widget tree so even tabs parked in an
`IndexedStack` repaint immediately instead of keeping a stale frame with
visible figures.

It is a **display mask only**. The ledger, the balance engine, and
exported PDFs/CSVs are untouched — exports deliberately use `formatRaw`,
because a report the banker explicitly generates must always contain real
numbers. Amount-entry fields and the quick-rake buttons also stay
readable, since masking the number you are about to type or tap would be
actively dangerous. The mask is fixed-width so turning it on never
reflows the layout under the banker's thumb mid-tap.

### Unchanged on purpose

Per the brief: tap counts were **not** aggressively reduced, Table View
behaviour is **unchanged** (tapping a player still opens the actions
sheet), and the settlement/balance engine is **untouched** — session
level only, `buy-ins + rebuys` vs `cash-outs + rake`, a $0 cash-out
still valid, a winner's cash-out never capped by their buy-in.

### Regenerating the assets

```bash
pip install pillow numpy
python3 tool/generate_logo.py         # launcher icons + logo.png
```

The chip sounds are cut from a supplied recording, not synthesised.
Replace `assets/sounds/Chip_sound.wav` and re-run:

```bash
python3 tool/split_chip_sounds.py    # re-splits the selectable samples
```

Then update `kChipSamples` in `lib/services/sound_service.dart` to match
the printed manifest. `test/chip_samples_test.dart` fails if the two
drift apart.

## License / Activation

The app ships with an offline license-activation layer: a copied APK
installed on another phone requires its own activation key. Licenses are
RSA-2048 signed by the owner and verified on-device with an embedded
public key, so they cannot be forged by editing the APK.

Signed with the **production** key pair, whose private half is held by the
owner outside this repository (`~/.pokerledger/signing/`) and is therefore
never committed, never in a build, and never in a project archive.
Architecture and stated limitations: **[LICENSE_SYSTEM.md](LICENSE_SYSTEM.md)**.

There are two license types: an **Owner License** (your permanent master
key, covering several of your own devices, never expires) and **Customer
Licenses** (`standard` / `full` / `trial` / `club`, each with its own
device limit and optional expiry).

```bash
python3 tool/issue_license.py --owner                            # your master key
python3 tool/issue_license.py --customer "Reza" --id PL-2026-0001
```

The license layer is strictly additive — it gates the UI at launch and
touches no session, player, transaction or settlement code.

## App Lock (device authentication)

An optional second layer, independent of licensing: when enabled, Poker
Ledger asks the operating system to confirm the user's identity before
the ledger is shown — fingerprint, face, or the device PIN/pattern/
password as fallback.

**The app never sees biometric data.** It calls the OS authentication API
(`local_auth`) and receives only a yes/no answer. Fingerprint and face
templates never leave the device's secure hardware, and the app is never
given the PIN, pattern or password. The only things stored are two
preferences: whether App Lock is on, and the auto-lock timeout.

Configure in **Settings → App Lock**: enable/disable, and auto-lock
immediately / after 1, 5 or 15 minutes in the background.

Platform requirements already wired up: `USE_BIOMETRIC` permission,
`FlutterFragmentActivity` (required for Android's BiometricPrompt), and
`NSFaceIDUsageDescription` on iOS.

## Building the APK

This repository has no `android/` folder checked in (it was never
`flutter create`d). To produce an installable APK:

```bash
flutter pub get
flutter create --platforms=android .   # generates android/ once
dart run flutter_launcher_icons        # bakes the new chip icon
flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk
```

Requires Flutter 3.24+ and a JDK 17 Android toolchain.

---

## Version 2 status

This pass focused on live-table speed, editability, and configurability,
on top of the Version 1 foundation below. Nothing from Version 1 was
removed.

1. **Faster workflow (highest priority).** Adding a player and recording
   their opening buy-in is now ONE action
   (`SessionProvider.addPlayerWithBuyIn`, surfaced in
   `PlayersTab.showAddPlayerSheet`) — no more create-player-then-navigate.
   Every buy-in/rebuy/cash-out amount pre-fills with the last amount used
   for that player (`SessionService.lastAmountForPlayer`), or the
   session's default entry fee, via the new `showQuickTransactionSheet`
   — a compact amount + signature sheet used everywhere for 2–4 tap entry
   instead of a full screen. The detailed `PlayerActionScreen` is still
   there when more context is useful (tap a player card).
2. **Transactions are now editable.** Every recorded transaction — buy-in,
   rebuy, cash-out, rake — can be edited (`SessionService.updateTransaction`,
   re-stamps `isEdited`/`editedAt` and requires a fresh signature when the
   type normally needs one), voided or restored
   (`voidTransaction`/`unvoidTransaction`, from the History tab's per-row
   menu, not just "undo the last one"), or permanently deleted with
   confirmation (`deleteTransactionPermanently`). Nothing is ever lost
   without an explicit confirm — destructive actions are PIN-gated when a
   PIN is set (`confirmSensitiveAction`).
3. **Cash-out = 0 is valid.** A player busting out with no chips left is
   normal poker, not an error — `SessionService.recordTransaction` and
   `Validators.cashOutAmount` explicitly allow 0 for cash-outs (every
   other transaction type still requires a positive amount). The
   session-level "never cashed out" advisory now checks whether a
   cash-out was *recorded at all* (`hasCashedOut`), not whether its total
   is above a threshold — so a $0 cash-out correctly counts as settled.
4. **House Rules are always accessible and editable.** A dedicated
   `HouseRulesScreen` (reachable from the Dashboard tab's gavel icon, the
   session AppBar, and directly from any house-rule warning via a new
   "View Rule" button) shows and edits the session's entry fee, buy-in
   cap, rebuy level cutoff, and rake configuration. These are genuinely
   per-session fields on `PokerSession` now (`rebuyLastLevel`,
   `buyInCapAmount`, etc.), not fixed constants — `HouseRules` in
   `core/house_rules.dart` now provides *defaults* for new sessions, and
   every rule check takes the session's own values. Warnings still never
   hard-block — "Proceed Anyway" is always available alongside "View Rule".
5. **Rake system overhauled.** Sessions pick a `RakeMode` — percentage
   (original behavior), fixed amount, or fully configurable tiered
   thresholds (`core/rake_calculator.dart`'s `RakeTierRule` +
   `RakeCalculator.suggestForSession`). The Transactions tab's Collect
   Rake dialog adapts to whichever mode is set, and the tiered thresholds/
   amounts/max-rake/no-rake-cutoff are all editable from House Rules.
6. **Navigation restructured.** The old single-screen dashboard is now
   `SessionShellScreen` — a bottom `NavigationBar` with five fast
   destinations: **Dashboard** (status/timer/level/settlement numbers —
   this also covers "Live Session", which was the same view under a
   different name in the request), **Players** (seat + fast per-player
   actions), **Actions** (table-level quick actions: rake, cash drop, and
   player transactions via a player picker), **History** (full audit log,
   now with edit/void/delete), **Reports** (export). Settings and House
   Rules live in the AppBar since they're not per-tab actions.
7. **UI polish.** A real hero header on the home screen (84×84 logo, not
   a cramped AppBar icon), an "N active sessions" chip, restyled session
   and stat cards (gradient surfaces, `FittedBox`-protected large numbers
   so long Toman figures never overflow), tappable full-card session
   tiles.

### A note on validation (Version 2)

Same caveat as Version 1: this sandbox has no Flutter/Dart SDK, so
`flutter analyze`/`flutter build web` were not run here. Every changed
and new file was manually checked for: balanced braces/parens, every
relative import resolving to a real file, every package import backed by
a `pubspec.yaml` entry, and no leftover references to renamed/removed
symbols (`SessionDashboardScreen`, `playerStack`, `playersStillActive`)
anywhere in `lib/`. Please run `flutter analyze` and `flutter pub get`
locally as the real gate before shipping.

## Version 1 status

This is a continuation/refactor pass on the existing codebase. Nothing was
regenerated from scratch. Highlights of this pass:

1. **Fixed the settlement engine bug** — cash-out was being capped by that
   player's own buy-in + rebuy total. It no longer is. A player can buy in
   for 2,000, win, and cash out for 5,000; the app accepts it.
2. **Settlement validation moved to session level only**
   (`SessionService.checkBalance`):
   - `Money In  = Total Buy-ins + Total Rebuys`
   - `Money Out = Total Cash-outs + Total Rake`
   - The difference must be ~0 for `isBalanced` to be true. No individual
     player's numbers are ever used to gate a transaction.
3. **Dashboard rebuilt** around that model: explicit Money In / Money Out /
   Difference / Current Pot cards, a session status chip (Active / On
   Break / Ended), a blind-level tracker with a "Next Level" action, and a
   Recent Transactions preview.
4. **Session & Player models extended**: `PokerSession` gained
   `currentLevel`, `buyInCapAmount`, and `defaultBuyInAmount`. `Player`
   activity (`isActive`) is now an explicit host action
   (`SessionService.markPlayerSettled` / `SessionProvider.toggleSettled`)
   instead of being inferred from a stack reaching zero — there is no such
   thing as a meaningful zero-stack signal once cash-out isn't capped.
5. **House rules encoded as configurable, advisory checks**, not hard
   blocks: buy-in cap per player (`assertWithinBuyInCap`), rebuy
   eligibility by level (`canRebuy`), and the level-5/6 catch-up rebuy
   bundle (`eligibleForCatchUpRebuy`) — see `lib/core/house_rules.dart`.
   A tiered rake suggestion for Toman games lives in
   `lib/core/rake_calculator.dart` and is surfaced in the dashboard's
   Collect Rake dialog, always editable before confirming.
6. **Refactor/cleanup**: removed dead fields (`_undoStack`,
   `_overrideHouseRule`), renamed the misleading "current stack" concept
   to explicit Total-In / Net-Result figures everywhere it's shown, and
   consolidated per-player totals into named `SessionService` methods
   (`playerTotalIn`, `playerTotalCashOut`, `playerProfitLoss`) used
   consistently across the dashboard, player-action screen, reports, and
   PDF/CSV export.
7. **Brand pass**: app name, tagline, and a hand-authored SVG logo
   (`assets/images/logo.svg` — emerald chip, gold ring, circular
   "POKER LEDGER" text, white ledger + green check medallion, faint A♠/K♣
   behind it) now show in the home screen header. The same SVG is a
   reasonable source to export a square PNG from for the Android launcher
   icon (see "Generating the Android app icon" below).
8. **Add/edit players completed** — editing a player's name, seat, and
   tags after creation was previously missing; `PlayerCard` now has an
   edit action wired to a shared add/edit sheet
   (`SessionDashboardScreen._playerFormDialog`).
9. **Backup & Restore actually implemented**, replacing the earlier
   placeholder SnackBar. `lib/services/backup_service.dart` exports every
   session/player/transaction to a single JSON file
   (`BackupService.exportBackup`) and restores/merges from one
   (`BackupService.importBackup`, idempotent by record id). Wired into
   Settings with real file share/pick dialogs (`share_plus` +
   `file_picker`).
10. **Subtle animation polish**: a gentle fade/scale page-transition
    theme (`AppTheme` → `_FadeThroughTransitionsBuilder`) replaces the
    default abrupt platform transition app-wide, the balance banner
    animates between its balanced/discrepancy colors
    (`AnimatedContainer`), and the dashboard's status chip cross-fades on
    change (`AnimatedSwitcher`).

## A note on validation

This sandbox has no Flutter/Dart SDK installed, so `flutter analyze` /
`flutter build web` were **not** actually run here. Every changed file was
manually re-checked for: matching braces/parens, every relative import
resolving to a real file, every call site of a changed
constructor/method updated to match its new signature, and no leftover
references to removed APIs (`playerStack`, `playersStillActive`,
`moneyInBox`) anywhere in `lib/`. Please run `flutter analyze` and
`flutter build web` locally as the real check before shipping.

## Getting started

```bash
flutter pub get

# Models use hand-written Hive TypeAdapters (lib/models/*.g.dart) so the
# app builds without running codegen. If you change a model's @HiveField
# layout, regenerate instead of hand-editing:
flutter pub run build_runner build --delete-conflicting-outputs

flutter run -d chrome   # Flutter Web
flutter run              # Android/iOS
```

Minimum Flutter SDK: 3.19 / Dart 3.3.

### Generating the Android app icon

`assets/images/logo.svg` is designed to work as a square icon. To produce
Android launcher icons: render it to a 1024×1024 PNG (e.g. via
`flutter pub run flutter_svg_to_png` or any vector tool/Inkscape/Figma
export), save as `assets/images/app_icon.png`, add the
`flutter_launcher_icons` dev dependency, and run it — this step needs an
actual image-rendering tool and wasn't run in this text-only sandbox.

## Architecture

```
lib/
  core/
    theme/               Dark "felt" theme, brand colors
    utils/                Currency formatting, form validators
    localization/          Lightweight EN/FA string tables (no codegen)
    house_rules.dart        Configurable house-rule defaults (entry fee, buy-in cap, rebuy levels)
    rake_calculator.dart     Tiered rake suggestion by pot size
  models/                  Hive data models: Session, Player, Transaction, enums
  services/
    hive_service.dart        Owns all local storage boxes (offline-first)
    session_service.dart     Core accounting logic + SESSION-LEVEL balance check
    export_service.dart      PDF/CSV report generation
  providers/                ChangeNotifier state for the active session & settings
  screens/                   New Session, Dashboard, Player Action, History, Reports, Settings, PIN lock
  widgets/                   Signature pad, stat cards, player cards, balance banner
```

### The accounting model (read this before touching `session_service.dart`)

Every dollar (or toman) is one of five transaction types:
`buyIn`, `rebuy`, `cashOut`, `rakeCollection`, `cashDrop`.

```
Money In  = Total Buy-ins + Total Rebuys
Money Out = Total Cash-outs + Total Rake
```

`SessionService.checkBalance()` compares the two **at the session level
only**. A single player's cash-out is never compared against their own
buy-in/rebuy — `SessionService.playerTotalIn` /
`playerTotalCashOut` / `playerProfitLoss` are informational/reporting
figures, never constraints. If Money In ≠ Money Out, the app shows the
exact difference and a ranked list of likely causes (missing cash-out,
unlogged rebuy, double payout, double-counted rake, etc.).

`cashDrop` (money moved to the safe/owner) is tracked and shown, but is
intentionally **not** part of the balancing equation — it's an internal
transfer of cash the house already has, not a payout or a source of new
money.

Buy-ins, rebuys and cash-outs **require** a captured host signature
(`LedgerTransaction.requiresSignature`) before
`SessionService.recordTransaction` will commit them. Rake collection and
cash drops are host-only, table-level actions and don't need one. Nothing
is ever hard-deleted: Undo voids a transaction (`isVoided = true`), Redo
un-voids it, so the audit log stays intact.

### House rules (advisory, never a silent hard block)

`lib/core/house_rules.dart` centralizes the configurable numbers:
- Default entry fee (20,000,000 Toman) — pre-fills the amount field for a
  fresh buy-in/rebuy on a Toman session, editable per session in
  New Session → House Rules.
- Buy-in cap per player (50,000,000 Toman default) —
  `SessionService.assertWithinBuyInCap` throws `HouseRuleViolation`,
  which the UI catches and turns into a "Proceed Anyway?" confirmation,
  never a hard stop.
- Rebuys offered through level 6, one extra rebuy unlocked every two
  levels (`HouseRules.maxRebuysAllowedAtLevel`), plus a "catch-up" bundle
  of 3 rebuys at levels 5–6 for anyone who hasn't rebought yet
  (`SessionService.eligibleForCatchUpRebuy`).
- Rake suggestion table (`RakeCalculator.suggestRake`) for Toman pots:
  no rake under 10M, 1M/1.5M/2M/2.5M through the 30M band, capped at 3M,
  and no rake once the pot reaches 50M. Always a suggestion the host can
  overwrite in the Collect Rake dialog.

### Moving to Firebase later

`HiveService` is the only place that talks to local storage. To go online,
swap its box-backed reads/writes for Firestore calls (or a repository
interface with two implementations) — `SessionService`, the providers, and
every screen call `HiveService`/`SessionService` and don't know or care
where the data physically lives. This pass didn't touch that boundary.

## Currency & language

- USD and Iranian Toman, switchable per-session and as a global default
  (Settings → Default Currency).
- English and Persian/Farsi, switchable in Settings; the app auto-flips to
  RTL layout when Farsi is selected.

## Security

- Optional PIN lock on app launch (`PinLockScreen`), PIN stored as a SHA-256
  hash, never in plaintext.
- Every buy-in/rebuy/cash-out is signed by the host before it's committed.

## Not yet wired (left as clearly-marked extension points)

- Voice notes: `LedgerTransaction.voiceNotePath` already exists as a data
  field. To implement, add the `record`/`audioplayers` packages back to
  `pubspec.yaml` and hook up a recorder button in `PlayerActionScreen`
  (left out of the default dependency set for now to keep `pub get`
  resolution lean).
- Biometric unlock: add `local_auth` to `pubspec.yaml` for a
  fingerprint/Face ID option alongside the PIN.
- Firebase/cloud sync: architecture is prepared (see above) but not
  implemented, per the current requirement to stay offline-first.

## Future roadmap (intentionally not implemented)

Per explicit request, these are postponed — the data model and services
are kept generic enough not to block them later, but none of the
following exist yet: chip inventory, chip color/value management,
automatic chip distribution, chip reconciliation, or advanced casino
inventory features.
