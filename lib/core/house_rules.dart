/// Configurable house rules. These are *defaults* the host can override
/// per-session (see [PokerSession] fields) — nothing here is hardcoded
/// into the accounting logic itself, so a different house can run
/// different numbers without a code change.
class HouseRules {
  /// Suggested entry fee for a fresh buy-in (Toman house default).
  static const double defaultEntryFeeToman = 20000000;

  /// Typical table size, shown as a hint only — never enforced as a hard cap.
  static const int typicalMinPlayers = 8;
  static const int typicalMaxPlayers = 9;

  /// A player's total money in (buy-in + all rebuys) should not exceed
  /// this without an explicit host override. 0/null on the session means
  /// "no cap".
  static const double defaultBuyInCapToman = 50000000;

  /// Rebuys are only offered up to and including this blind level, by
  /// default. Editable per session via PokerSession.rebuyLastLevel.
  static const int lastRebuyLevel = 6;

  /// One additional rebuy is unlocked every two levels
  /// (level 2 -> 1 rebuy, level 4 -> 2, level 6 -> 3), relative to
  /// whatever [lastLevel] the session is configured with.
  static int maxRebuysAllowedAtLevel(int level, {int lastLevel = lastRebuyLevel}) {
    if (level <= 0) return 0;
    final capped = level > lastLevel ? lastLevel : level;
    return capped ~/ 2;
  }

  /// How many one-tap rake buttons the banker configures. Fixed at five
  /// so the Collect Rake sheet has a stable, memorisable layout all night
  /// — the positions never move, which is what makes them fast.
  static const int quickRakeSlotCount = 5;

  /// Default one-tap rake amounts (Toman-scale house game). Every session
  /// gets these as a starting point and the banker overwrites them with
  /// their own five values at session creation or in House Rules
  /// (PokerSession.quickRakeAmounts).
  static const List<double> defaultQuickRakeAmounts = [
    200000,
    500000,
    1000000,
    2000000,
    3000000,
  ];

  /// Sensible starting ladder for a USD table, so a banker creating a USD
  /// session doesn't see Toman-scale numbers pre-filled.
  static const List<double> defaultQuickRakeAmountsUsd = [5, 10, 15, 20, 25];
}
