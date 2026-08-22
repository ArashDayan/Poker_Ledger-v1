import 'package:hive/hive.dart';

part 'enums.g.dart';

/// Tags a host can assign to a player for quick identification at the table.
@HiveType(typeId: 0)
enum PlayerTag {
  @HiveField(0)
  vip,
  @HiveField(1)
  regular,
  @HiveField(2)
  problemPlayer,
  @HiveField(3)
  tilt,
}

/// Every type of money movement the ledger can record.
/// Kept explicit (rather than free-text) so balance math is always reliable.
@HiveType(typeId: 1)
enum TransactionType {
  @HiveField(0)
  buyIn,
  @HiveField(1)
  rebuy,
  @HiveField(2)
  cashOut,
  @HiveField(3)
  rakeCollection,
  @HiveField(4)
  cashDrop, // money moved from the table float to the safe/owner

  /// Money physically carried OUT of a table when a player moves to
  /// another table. Paired with a [transferIn] of the same amount.
  ///
  /// WHY THESE ARE THEIR OWN TYPES AND NOT A CASH-OUT + BUY-IN
  /// Recording a table move as a cash-out at the source and a buy-in at
  /// the destination would be catastrophic: it would inflate the
  /// session's totalBuyIn and totalCashOut, corrupt every player's
  /// profit/loss, and make `hasCashedOut` believe the player had left.
  /// A transfer is not revenue and not a settlement — it is the same
  /// physical money changing seats.
  ///
  /// Being distinct types is also what makes them SESSION-NEUTRAL for
  /// free: every session-level total (`totalBuyIn`, `totalCashOut`,
  /// `totalRake`, `checkBalance`, `moneyStillInPlay`, `playerProfitLoss`)
  /// filters on one explicit type, so none of them can ever see these.
  @HiveField(5)
  transferOut,

  /// Money physically carried INTO a table by an arriving player.
  /// Always the mirror of a [transferOut] of the same amount.
  @HiveField(6)
  transferIn,

  /// Chips taken off a table as a tip for the dealer.
  ///
  /// A REAL money-out flow, but NOT house income.
  /// Like rake, these chips physically leave the table and go back to
  /// the Bank, so the table's pot must fall by the amount. Unlike rake,
  /// the money is owed to the dealer rather than kept by the host — so
  /// it is deliberately its own type, never folded into
  /// `rakeCollection` (nor into house wins). `hostProfit` (rake +
  /// house wins, Phase 7) therefore never includes tips.
  @HiveField(7)
  dealerTips,

  /// TABLE CASH-OUT (Phase 7): the player leaves the table carrying
  /// the counted chips — the participation closes and the seat is
  /// freed, but the chips stay the PERSON's physical holding (no chip
  /// movement, no bank leg, no cashier cash, no financial event).
  ///
  /// This is a session-money OUT (the chips leave table play), stamped
  /// to the open participation and closing it (reason tableCashOut).
  /// It is NOT the final cage redemption: the person can carry the
  /// chips to another table (see [reentry]) or redeem them at the cage
  /// later — the cage redemption is the person-level financial
  /// operation (`cashOutForChips` / `cashOutUnbacked`), and only IT
  /// moves the person's chips back to the bank.
  @HiveField(8)
  tableCashOut,

  /// RE-ENTRY (Phase 7): the player is committed to a table using chips
  /// they ALREADY hold in their person-scoped chip holding — the same
  /// physical chips they bought earlier (this session or a previous
  /// one) and left the last table carrying.
  ///
  /// THIS IS NOT A PURCHASE.
  ///   * It is NOT a [buyIn]: no new money enters the session, the
  ///     original purchase is never counted again, and [totalBuyIn]
  ///     stays untouched.
  ///   * It is NOT a cash-in: no Financial Ledger event is written
  ///     (no cashInForChips, no frontMoneyOut, no wallet draw).
  ///   * It is NOT a chip issuance: no chip movement is recorded. The
  ///     chips already sit in the person's holding and travel with
  ///     them; re-entry only moves the COMMITMENT into the new table
  ///     context (it opens the new [TableParticipation]).
  ///
  /// It IS session money IN: the chips re-enter table play, exactly
  /// balancing the [tableCashOut] that took them off the previous
  /// table. A first-time sit-down with cashier-issued (wallet) chips
  /// is recorded the same way — the commitment of existing chips.
  @HiveField(9)
  reentry,

  /// HOUSE WIN (Phase 7): the house banked a win from a player at a
  /// house-banked game (e.g. roulette). The player's chips become
  /// CASINO-OWNED (chip movement holder -> bank, reason houseWin).
  ///
  /// HOUSE-GAME REVENUE — NEVER MERGED WITH RAKE.
  /// Poker rake is the house's fee on player-vs-player pots; a house
  /// win is the house playing against the player and winning the
  /// player's chips. The two are different economic sources and every
  /// report keeps them on separate lines ([totalRake] vs
  /// [totalHouseWin]). [hostProfit] is their sum — the house's total
  /// earned — with both components always visible.
  ///
  /// Session money OUT, player-attributed (the player's commitment
  /// at that game is settled).
  @HiveField(10)
  houseWin,
}

@HiveType(typeId: 2)
enum SessionStatus {
  @HiveField(0)
  active,
  @HiveField(1)
  onBreak,
  @HiveField(2)
  ended,
}

@HiveType(typeId: 3)
enum AppCurrency {
  @HiveField(0)
  usd,
  @HiveField(1)
  toman,
}

/// How a session collects rake. Percentage keeps the original behavior
/// (rakePercentage x pot). Fixed always suggests one flat amount. Tiered
/// uses a configurable pot-size table (see PokerSession.tieredRakeRules).
@HiveType(typeId: 7)
enum RakeMode {
  @HiveField(0)
  percentage,
  @HiveField(1)
  fixed,
  @HiveField(2)
  tiered,
}

extension RakeModeX on RakeMode {
  String get label {
    switch (this) {
      case RakeMode.percentage:
        return 'Percentage';
      case RakeMode.fixed:
        return 'Fixed Amount';
      case RakeMode.tiered:
        return 'Tiered (by pot size)';
    }
  }
}

extension PlayerTagX on PlayerTag {
  String get label {
    switch (this) {
      case PlayerTag.vip:
        return 'VIP';
      case PlayerTag.regular:
        return 'Regular';
      case PlayerTag.problemPlayer:
        return 'Problem Player';
      case PlayerTag.tilt:
        return 'Tilt';
    }
  }
}

extension TransactionTypeX on TransactionType {
  String get label {
    switch (this) {
      case TransactionType.buyIn:
        return 'Buy-in';
      case TransactionType.rebuy:
        return 'Rebuy';
      case TransactionType.cashOut:
        return 'Cash-out';
      case TransactionType.rakeCollection:
        return 'Rake Collected';
      case TransactionType.cashDrop:
        return 'Cash Drop';
      case TransactionType.transferOut:
        return 'Transfer Out';
      case TransactionType.transferIn:
        return 'Transfer In';
      case TransactionType.dealerTips:
        return 'Dealer Tips';
      case TransactionType.tableCashOut:
        return 'Table Cash-out';
      case TransactionType.reentry:
        return 'Re-entry (carried chips)';
      case TransactionType.houseWin:
        return 'House Win';
    }
  }

  /// Money moving INTO the host's box/table float.
  ///
  /// [transferIn] counts as an inflow for DISPLAY only (it decides the
  /// +/- sign and colour in the timeline). No money calculation reads
  /// this getter — verified across the codebase — so including the
  /// transfer types here cannot affect any total.
  bool get isInflow =>
      this == TransactionType.buyIn ||
      this == TransactionType.rebuy ||
      this == TransactionType.rakeCollection ||
      this == TransactionType.transferIn ||
      // Re-entry is a real inflow to the session's table play (the
      // carried chips re-enter the books) — unlike a table move's
      // transfer legs, which stay session-neutral.
      this == TransactionType.reentry;

  /// Money moving OUT of the host's box/table float.
  bool get isOutflow =>
      this == TransactionType.cashOut ||
      this == TransactionType.tableCashOut ||
      this == TransactionType.cashDrop ||
      this == TransactionType.transferOut ||
      this == TransactionType.dealerTips ||
      // House wins leave the player's table play for the house.
      this == TransactionType.houseWin;

  /// True for the two legs of a table-to-table move.
  ///
  /// These are internal movements of money that is already in the
  /// session, so they must never be counted as session revenue or as a
  /// player settling up.
  bool get isTableTransfer =>
      this == TransactionType.transferOut ||
      this == TransactionType.transferIn;
}

/// Whether a session is a cash game or a tournament.
///
/// These are deliberately separate modes rather than one blended screen:
/// a cash game settles continuously (buy in, cash out, walk away) while a
/// tournament pays a fixed prize pool at the end. Mixing them would make
/// both harder to run, so the app switches wholesale between the two and
/// the cash-game settlement engine is never touched by tournament code.
@HiveType(typeId: 8)
enum SessionMode {
  @HiveField(0)
  cashGame,
  @HiveField(1)
  tournament,
}

extension SessionModeX on SessionMode {
  bool get isTournament => this == SessionMode.tournament;
  bool get isCashGame => this == SessionMode.cashGame;
}

/// One-shot notices raised by the simple cash-game session timer.
enum SessionTimerNotice { tenMinutes, finished }

/// Raised once when an individual table's countdown reaches zero.
///
/// Carries the table's identity so the banker is told exactly WHICH
/// table finished — with several tables running, "timer finished" on its
/// own would be useless.
class TableTimerNotice {
  final String tableId;
  final String tableName;

  /// The duration that was configured, for the message text.
  final int plannedMinutes;

  const TableTimerNotice({
    required this.tableId,
    required this.tableName,
    required this.plannedMinutes,
  });
}

/// One-shot notices raised by the tournament blind timer.
enum BlindTimerNotice { tenMinutes, fiveMinutes, oneMinute, levelFinished }
