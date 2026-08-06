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
    }
  }

  /// Money moving INTO the host's box/table float.
  bool get isInflow =>
      this == TransactionType.buyIn ||
      this == TransactionType.rebuy ||
      this == TransactionType.rakeCollection;

  /// Money moving OUT of the host's box/table float.
  bool get isOutflow =>
      this == TransactionType.cashOut || this == TransactionType.cashDrop;
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

/// One-shot notices raised by the tournament blind timer.
enum BlindTimerNotice { tenMinutes, fiveMinutes, oneMinute, levelFinished }
