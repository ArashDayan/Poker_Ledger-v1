import 'package:hive/hive.dart';
import 'enums.dart';

part 'session.g.dart';

@HiveType(typeId: 6)
class PokerSession extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String location;

  @HiveField(3)
  DateTime dateTime;

  @HiveField(4)
  double smallBlind;

  @HiveField(5)
  double bigBlind;

  @HiveField(6)
  double rakePercentage; // e.g. 5.0 == 5%

  @HiveField(7)
  String tableNumber;

  @HiveField(8)
  SessionStatus status;

  @HiveField(9)
  AppCurrency currency;

  @HiveField(10)
  DateTime? endedAt;

  @HiveField(11)
  int totalBreakSeconds;

  @HiveField(12)
  DateTime? breakStartedAt;

  @HiveField(13)
  String? hostName;

  /// Current blind/tournament level. Drives rebuy eligibility.
  @HiveField(14)
  int currentLevel;

  /// Total money-in cap per player (buy-in + rebuys). Null/0 = no cap.
  @HiveField(15)
  double? buyInCapAmount;

  /// Suggested amount to pre-fill for a fresh buy-in (house entry fee).
  @HiveField(16)
  double? defaultBuyInAmount;

  /// Which rake mode the Collect Rake dialog should use for this session.
  @HiveField(17)
  RakeMode rakeMode;

  /// Flat rake amount when [rakeMode] is [RakeMode.fixed].
  @HiveField(18)
  double? fixedRakeAmount;

  /// Tiered rake table when [rakeMode] is [RakeMode.tiered]. Each entry is
  /// `{'upperBound': double, 'rake': double}`, sorted ascending by
  /// upperBound; a pot below a tier's upperBound uses that tier's rake.
  /// Null = use the built-in house-rule defaults (RakeCalculator.defaultTiers).
  @HiveField(19)
  List<Map>? tieredRakeRules;

  /// Rake applied to any pot at/above the highest configured tier and
  /// below [tieredNoRakeAtOrAbove]. Null = use the default (3,000,000).
  @HiveField(20)
  double? tieredMaxRake;

  /// Pot size at/above which no rake is taken at all. Null = use the
  /// default (50,000,000).
  @HiveField(21)
  double? tieredNoRakeAtOrAbove;

  /// Last blind level rebuys are offered at all (house rule, editable per
  /// session). The "catch-up" bundle is offered at this level and the one
  /// before it.
  @HiveField(22)
  int rebuyLastLevel;

  /// How many seats the Table view lays out around the oval (6/8/9/10).
  @HiveField(23)
  int tableSeatCount;

  /// Seat number currently holding the dealer button. Advances clockwise
  /// via TableViewTab's "Move Dealer" control.
  @HiveField(24)
  int dealerSeatIndex;

  /// One-tap rake amounts for the Collect Rake quick buttons. Null = use
  /// the built-in default set.
  @HiveField(25)
  List<double>? quickRakeAmounts;

  /// When false, rebuys are never gated by blind level at all — for
  /// tables that don't run formal levels, where level-based rebuy rules
  /// would otherwise fire a house-rule warning on every single rebuy of
  /// the night. Defaults to true (levels enforced) to match the existing
  /// house-rule behavior for tables that do use them.
  @HiveField(26)
  bool rebuyLevelEnforcementEnabled;

  /// The tables running in this session.
  ///
  /// Each entry is `{'id': String, 'name': String, 'seatCount': int,
  /// 'dealerSeat': int}`. Stored as plain maps rather than a new Hive
  /// type so no new adapter/typeId is needed and every previously saved
  /// session still opens.
  ///
  /// Null or empty means a classic single-table session: the app
  /// synthesises one table from [tableNumber] / [tableSeatCount] /
  /// [dealerSeatIndex], so existing games behave exactly as before and
  /// the multi-table UI only appears once a second table is added.
  ///
  /// IMPORTANT: tables organise SEATING only. All money — buy-ins,
  /// rebuys, cash-outs, rake and the balance check — stays session-wide,
  /// because a host running three tables settles one bank at the end of
  /// the night, not three. The settlement engine is untouched by this.
  @HiveField(27)
  List<Map>? tables;

  /// Planned length of a cash-game session in minutes, or null for the
  /// normal open-ended game.
  ///
  /// This is the SIMPLE session timer only — a countdown with a warning
  /// near the end. It has nothing to do with tournament blind levels,
  /// and it never blocks or auto-ends anything: when it reaches zero the
  /// banker is told, and that is all. Ending a session stays a
  /// deliberate, explicit action.
  @HiveField(28)
  int? plannedMinutes;

  /// Set once the 10-minute warning has been shown, so it fires exactly
  /// once rather than on every tick.
  @HiveField(29)
  bool tenMinuteWarningShown;

  /// Set once the finish notice has been shown, for the same reason.
  @HiveField(30)
  bool finishNoticeShown;

  // ------------------------------------------------------------------
  // Tournament mode.
  //
  // All of these are null/absent on a cash game, and every cash-game
  // code path ignores them entirely — the settlement engine, the balance
  // check and the existing screens are untouched by tournament data.
  // Sessions saved before tournament support default to cashGame, so
  // they open exactly as they always did.
  // ------------------------------------------------------------------

  /// Cash game or tournament. Chosen at creation and fixed for the life
  /// of the session — converting mid-game would invalidate the money
  /// already recorded under the other set of rules.
  @HiveField(31)
  SessionMode mode;

  /// Blind levels, in order. Each entry is
  /// `{'sb': double, 'bb': double, 'ante': double, 'minutes': int,
  ///   'isBreak': bool}`.
  ///
  /// Stored as plain maps rather than a new Hive type so no extra
  /// adapter/typeId is needed and older sessions still open cleanly.
  @HiveField(32)
  List<Map>? blindLevels;

  /// Index into [blindLevels] of the level currently being played.
  @HiveField(33)
  int currentBlindIndex;

  /// When the current blind level started running. Null while paused.
  @HiveField(34)
  DateTime? levelStartedAt;

  /// Seconds already elapsed in the current level before the last pause,
  /// so pausing and resuming never loses or repeats time.
  @HiveField(35)
  int levelElapsedSeconds;

  /// Whether the blind clock is currently running.
  @HiveField(36)
  bool blindTimerRunning;

  /// Tournament entry fee (the buy-in that funds the prize pool).
  @HiveField(37)
  double? tournamentBuyIn;

  /// Portion of each entry the house keeps. Kept separate from the prize
  /// pool so players can always be shown exactly what they are playing
  /// for.
  @HiveField(38)
  double? tournamentFee;

  /// Cost of one rebuy. Null when rebuys are not offered.
  @HiveField(39)
  double? tournamentRebuy;

  /// Cost of one add-on. Null when add-ons are not offered.
  @HiveField(40)
  double? tournamentAddOn;

  /// Starting chip stack for an entry — display only, never money.
  @HiveField(41)
  int? startingStack;

  /// Prize payout percentages by finishing position, e.g. [50, 30, 20].
  /// Must total 100; the UI enforces that before saving.
  @HiveField(42)
  List<double>? payoutPercentages;

  /// Notice flags so each blind-timer alert fires exactly once per level.
  @HiveField(43)
  List<String>? blindNoticesShown;

  PokerSession({
    required this.id,
    required this.name,
    required this.location,
    required this.dateTime,
    required this.smallBlind,
    required this.bigBlind,
    this.rakePercentage = 0,
    required this.tableNumber,
    this.status = SessionStatus.active,
    this.currency = AppCurrency.usd,
    this.endedAt,
    this.totalBreakSeconds = 0,
    this.breakStartedAt,
    this.hostName,
    this.currentLevel = 1,
    this.buyInCapAmount,
    this.defaultBuyInAmount,
    this.rakeMode = RakeMode.percentage,
    this.fixedRakeAmount,
    this.tieredRakeRules,
    this.tieredMaxRake,
    this.tieredNoRakeAtOrAbove,
    this.rebuyLastLevel = 6,
    this.tableSeatCount = 9,
    this.dealerSeatIndex = 1,
    this.quickRakeAmounts,
    this.rebuyLevelEnforcementEnabled = true,
    this.tables,
    this.plannedMinutes,
    this.tenMinuteWarningShown = false,
    this.finishNoticeShown = false,
    this.mode = SessionMode.cashGame,
    this.blindLevels,
    this.currentBlindIndex = 0,
    this.levelStartedAt,
    this.levelElapsedSeconds = 0,
    this.blindTimerRunning = false,
    this.tournamentBuyIn,
    this.tournamentFee,
    this.tournamentRebuy,
    this.tournamentAddOn,
    this.startingStack,
    this.payoutPercentages,
    this.blindNoticesShown,
  });

  bool get isTournament => mode == SessionMode.tournament;

  /// Time left on the simple session timer, or null when no duration was
  /// set. Clamped at zero — it never goes negative.
  Duration? get timeRemaining {
    if (plannedMinutes == null || plannedMinutes! <= 0) return null;
    final left = Duration(minutes: plannedMinutes!) - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  bool get hasTimer => plannedMinutes != null && plannedMinutes! > 0;

  bool get timerFinished {
    final left = timeRemaining;
    return left != null && left == Duration.zero;
  }

  Duration get elapsed {
    final end = endedAt ?? DateTime.now();
    final total = end.difference(dateTime);
    return total - Duration(seconds: totalBreakSeconds);
  }

  /// Serialization for local backup/restore (JSON file, not Firestore —
  /// kept deliberately simple/flat so it's easy to inspect or hand-edit).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'location': location,
        'dateTime': dateTime.toIso8601String(),
        'smallBlind': smallBlind,
        'bigBlind': bigBlind,
        'rakePercentage': rakePercentage,
        'tableNumber': tableNumber,
        'status': status.index,
        'currency': currency.index,
        'endedAt': endedAt?.toIso8601String(),
        'totalBreakSeconds': totalBreakSeconds,
        'breakStartedAt': breakStartedAt?.toIso8601String(),
        'hostName': hostName,
        'currentLevel': currentLevel,
        'buyInCapAmount': buyInCapAmount,
        'defaultBuyInAmount': defaultBuyInAmount,
        'rakeMode': rakeMode.index,
        'fixedRakeAmount': fixedRakeAmount,
        'tieredRakeRules': tieredRakeRules,
        'tieredMaxRake': tieredMaxRake,
        'tieredNoRakeAtOrAbove': tieredNoRakeAtOrAbove,
        'rebuyLastLevel': rebuyLastLevel,
        'tableSeatCount': tableSeatCount,
        'dealerSeatIndex': dealerSeatIndex,
        'quickRakeAmounts': quickRakeAmounts,
        'tables': tables,
        'mode': mode.index,
        'blindLevels': blindLevels,
        'currentBlindIndex': currentBlindIndex,
        'levelStartedAt': levelStartedAt?.toIso8601String(),
        'levelElapsedSeconds': levelElapsedSeconds,
        'blindTimerRunning': blindTimerRunning,
        'tournamentBuyIn': tournamentBuyIn,
        'tournamentFee': tournamentFee,
        'tournamentRebuy': tournamentRebuy,
        'tournamentAddOn': tournamentAddOn,
        'startingStack': startingStack,
        'payoutPercentages': payoutPercentages,
        'blindNoticesShown': blindNoticesShown,
        'plannedMinutes': plannedMinutes,
        'tenMinuteWarningShown': tenMinuteWarningShown,
        'finishNoticeShown': finishNoticeShown,
        'rebuyLevelEnforcementEnabled': rebuyLevelEnforcementEnabled,
      };

  static PokerSession fromJson(Map<String, dynamic> json) => PokerSession(
        id: json['id'] as String,
        name: json['name'] as String,
        location: json['location'] as String,
        dateTime: DateTime.parse(json['dateTime'] as String),
        smallBlind: (json['smallBlind'] as num).toDouble(),
        bigBlind: (json['bigBlind'] as num).toDouble(),
        rakePercentage: (json['rakePercentage'] as num?)?.toDouble() ?? 0,
        tableNumber: json['tableNumber'] as String,
        status: SessionStatus.values[json['status'] as int],
        currency: AppCurrency.values[json['currency'] as int],
        endedAt: json['endedAt'] == null ? null : DateTime.parse(json['endedAt'] as String),
        totalBreakSeconds: json['totalBreakSeconds'] as int? ?? 0,
        breakStartedAt:
            json['breakStartedAt'] == null ? null : DateTime.parse(json['breakStartedAt'] as String),
        hostName: json['hostName'] as String?,
        currentLevel: json['currentLevel'] as int? ?? 1,
        buyInCapAmount: (json['buyInCapAmount'] as num?)?.toDouble(),
        defaultBuyInAmount: (json['defaultBuyInAmount'] as num?)?.toDouble(),
        rakeMode: RakeMode.values[json['rakeMode'] as int? ?? 0],
        fixedRakeAmount: (json['fixedRakeAmount'] as num?)?.toDouble(),
        tieredRakeRules: (json['tieredRakeRules'] as List?)?.cast<Map>(),
        tieredMaxRake: (json['tieredMaxRake'] as num?)?.toDouble(),
        tieredNoRakeAtOrAbove: (json['tieredNoRakeAtOrAbove'] as num?)?.toDouble(),
        rebuyLastLevel: json['rebuyLastLevel'] as int? ?? 6,
        tableSeatCount: json['tableSeatCount'] as int? ?? 9,
        dealerSeatIndex: json['dealerSeatIndex'] as int? ?? 1,
        quickRakeAmounts:
            (json['quickRakeAmounts'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        rebuyLevelEnforcementEnabled: json['rebuyLevelEnforcementEnabled'] as bool? ?? true,
        tables: (json['tables'] as List?)?.cast<Map>(),
        mode: SessionMode.values[(json['mode'] as int?) ?? 0],
        blindLevels: (json['blindLevels'] as List?)?.cast<Map>(),
        currentBlindIndex: json['currentBlindIndex'] as int? ?? 0,
        levelStartedAt: json['levelStartedAt'] == null
            ? null
            : DateTime.parse(json['levelStartedAt'] as String),
        levelElapsedSeconds: json['levelElapsedSeconds'] as int? ?? 0,
        blindTimerRunning: json['blindTimerRunning'] as bool? ?? false,
        tournamentBuyIn: (json['tournamentBuyIn'] as num?)?.toDouble(),
        tournamentFee: (json['tournamentFee'] as num?)?.toDouble(),
        tournamentRebuy: (json['tournamentRebuy'] as num?)?.toDouble(),
        tournamentAddOn: (json['tournamentAddOn'] as num?)?.toDouble(),
        startingStack: json['startingStack'] as int?,
        payoutPercentages: (json['payoutPercentages'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList(),
        blindNoticesShown:
            (json['blindNoticesShown'] as List?)?.map((e) => '$e').toList(),
        plannedMinutes: json['plannedMinutes'] as int?,
        tenMinuteWarningShown: json['tenMinuteWarningShown'] as bool? ?? false,
        finishNoticeShown: json['finishNoticeShown'] as bool? ?? false,
      );
}
