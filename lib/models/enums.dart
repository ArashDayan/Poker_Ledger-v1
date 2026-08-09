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
      this == TransactionType.transferIn;

  /// Money moving OUT of the host's box/table float.
  bool get isOutflow =>
      this == TransactionType.cashOut ||
      this == TransactionType.cashDrop ||
      this == TransactionType.transferOut;

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
