import '../models/enums.dart';
import '../models/player.dart';
import '../models/session.dart';
import 'session_service.dart';

/// One blind level (or a scheduled break) in a tournament structure.
class BlindLevel {
  final double smallBlind;
  final double bigBlind;
  final double ante;
  final int minutes;

  /// A break is a level with no blinds — the clock still runs, but the
  /// blinds don't advance while players are away from the table.
  final bool isBreak;

  const BlindLevel({
    required this.smallBlind,
    required this.bigBlind,
    this.ante = 0,
    required this.minutes,
    this.isBreak = false,
  });

  Map<String, dynamic> toMap() => {
        'sb': smallBlind,
        'bb': bigBlind,
        'ante': ante,
        'minutes': minutes,
        'isBreak': isBreak,
      };

  static BlindLevel fromMap(Map m) => BlindLevel(
        smallBlind: (m['sb'] as num?)?.toDouble() ?? 0,
        bigBlind: (m['bb'] as num?)?.toDouble() ?? 0,
        ante: (m['ante'] as num?)?.toDouble() ?? 0,
        minutes: (m['minutes'] as num?)?.toInt() ?? 15,
        isBreak: m['isBreak'] as bool? ?? false,
      );

  BlindLevel copyWith({
    double? smallBlind,
    double? bigBlind,
    double? ante,
    int? minutes,
    bool? isBreak,
  }) =>
      BlindLevel(
        smallBlind: smallBlind ?? this.smallBlind,
        bigBlind: bigBlind ?? this.bigBlind,
        ante: ante ?? this.ante,
        minutes: minutes ?? this.minutes,
        isBreak: isBreak ?? this.isBreak,
      );

  String get label => isBreak ? 'Break' : '$_fmt(smallBlind) / $_fmt(bigBlind)';
  String get blindsText =>
      '${_fmt(smallBlind)} / ${_fmt(bigBlind)}${ante > 0 ? ' (ante ${_fmt(ante)})' : ''}';

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

/// A finishing position and what it pays.
class PayoutSpot {
  final int position;
  final double percentage;
  final double amount;
  final Player? player;

  const PayoutSpot({
    required this.position,
    required this.percentage,
    required this.amount,
    this.player,
  });
}

/// Tournament accounting and clock management.
///
/// DELIBERATELY SEPARATE FROM THE CASH-GAME ENGINE.
/// `SessionService.checkBalance` and every cash-game money path are
/// untouched by this class. A tournament settles completely differently:
/// entries feed a prize pool that is paid out by finishing position at
/// the end, rather than players cashing out individually whenever they
/// leave. Trying to express both through one settlement model would have
/// compromised the cash-game logic that already works, so the two live
/// side by side and never share code.
///
/// Money still flows through the SAME ledger (`LedgerTransaction`), so
/// buy-ins, rebuys and payouts are recorded, signed and auditable exactly
/// like cash-game transactions. Only the interpretation differs.
class TournamentService {
  // ---------------------------------------------------------------
  // Structure
  // ---------------------------------------------------------------

  /// A sensible default structure for a home-game tournament: 20-minute
  /// levels with a break every fourth level.
  static List<BlindLevel> defaultStructure({double startingBigBlind = 50}) {
    final levels = <BlindLevel>[];
    var bb = startingBigBlind;
    for (var i = 0; i < 12; i++) {
      if (i > 0 && i % 4 == 0) {
        levels.add(const BlindLevel(
            smallBlind: 0, bigBlind: 0, minutes: 10, isBreak: true));
      }
      levels.add(BlindLevel(
        smallBlind: bb / 2,
        bigBlind: bb,
        ante: i >= 4 ? bb / 4 : 0,
        minutes: 20,
      ));
      // Standard escalation: roughly 1.5x per level, rounded to
      // something a dealer can actually make change for.
      bb = _roundBlind(bb * 1.5);
    }
    return levels;
  }

  static double _roundBlind(double v) {
    if (v < 100) return (v / 25).round() * 25;
    if (v < 1000) return (v / 50).round() * 50;
    if (v < 10000) return (v / 500).round() * 500;
    return (v / 5000).round() * 5000;
  }

  static List<BlindLevel> levelsFor(PokerSession session) {
    final raw = session.blindLevels;
    if (raw == null || raw.isEmpty) return defaultStructure();
    return raw.map(BlindLevel.fromMap).toList();
  }

  static BlindLevel currentLevel(PokerSession session) {
    final levels = levelsFor(session);
    final i = session.currentBlindIndex.clamp(0, levels.length - 1);
    return levels[i];
  }

  static BlindLevel? nextLevel(PokerSession session) {
    final levels = levelsFor(session);
    final i = session.currentBlindIndex + 1;
    return i < levels.length ? levels[i] : null;
  }

  static Future<void> saveStructure(
      PokerSession session, List<BlindLevel> levels) async {
    SessionService.assertSessionActive(session.id);
    session.blindLevels = levels.map((l) => l.toMap()).toList();
    if (session.currentBlindIndex >= levels.length) {
      session.currentBlindIndex = levels.isEmpty ? 0 : levels.length - 1;
    }
    await session.save();
  }

  // ---------------------------------------------------------------
  // Blind clock
  // ---------------------------------------------------------------

  /// Seconds elapsed in the current level, including time accumulated
  /// before the last pause.
  static int elapsedSecondsInLevel(PokerSession session) {
    var elapsed = session.levelElapsedSeconds;
    if (session.blindTimerRunning && session.levelStartedAt != null) {
      elapsed += DateTime.now().difference(session.levelStartedAt!).inSeconds;
    }
    return elapsed;
  }

  static Duration remainingInLevel(PokerSession session) {
    final total = currentLevel(session).minutes * 60;
    final left = total - elapsedSecondsInLevel(session);
    return Duration(seconds: left < 0 ? 0 : left);
  }

  static bool levelComplete(PokerSession session) =>
      remainingInLevel(session) == Duration.zero;

  static Future<void> startTimer(PokerSession session) async {
    SessionService.assertSessionActive(session.id);
    if (session.blindTimerRunning) return;
    session.blindTimerRunning = true;
    session.levelStartedAt = DateTime.now();
    await session.save();
  }

  static Future<void> pauseTimer(PokerSession session) async {
    SessionService.assertSessionActive(session.id);
    if (!session.blindTimerRunning) return;
    // Bank the running time so resuming never loses or repeats seconds.
    session.levelElapsedSeconds = elapsedSecondsInLevel(session);
    session.blindTimerRunning = false;
    session.levelStartedAt = null;
    await session.save();
  }

  static Future<void> resetLevel(PokerSession session) async {
    SessionService.assertSessionActive(session.id);
    session.levelElapsedSeconds = 0;
    session.levelStartedAt =
        session.blindTimerRunning ? DateTime.now() : null;
    session.blindNoticesShown = [];
    await session.save();
  }

  static Future<void> gotoLevel(PokerSession session, int index) async {
    SessionService.assertSessionActive(session.id);
    final levels = levelsFor(session);
    if (levels.isEmpty) return;
    session.currentBlindIndex = index.clamp(0, levels.length - 1);
    session.levelElapsedSeconds = 0;
    session.levelStartedAt =
        session.blindTimerRunning ? DateTime.now() : null;
    session.blindNoticesShown = [];
    await session.save();
  }

  static Future<void> advanceLevel(PokerSession session) =>
      gotoLevel(session, session.currentBlindIndex + 1);

  static Future<void> previousLevel(PokerSession session) =>
      gotoLevel(session, session.currentBlindIndex - 1);

  /// Returns a notice to show once, or null. Driven by the session
  /// shell's existing one-second ticker, so no extra timer is created.
  static BlindTimerNotice? consumeNotice(PokerSession session) {
    if (!session.isTournament || !session.blindTimerRunning) return null;
    if (session.status == SessionStatus.ended) return null;

    final shown = {...(session.blindNoticesShown ?? const <String>[])};
    final left = remainingInLevel(session);

    BlindTimerNotice? fire(BlindTimerNotice n, String key) {
      if (shown.contains(key)) return null;
      shown.add(key);
      session.blindNoticesShown = shown.toList();
      session.save();
      return n;
    }

    if (left == Duration.zero) {
      return fire(BlindTimerNotice.levelFinished, 'end');
    }
    if (left <= const Duration(minutes: 1)) {
      return fire(BlindTimerNotice.oneMinute, '1m');
    }
    if (left <= const Duration(minutes: 5)) {
      return fire(BlindTimerNotice.fiveMinutes, '5m');
    }
    if (left <= const Duration(minutes: 10)) {
      return fire(BlindTimerNotice.tenMinutes, '10m');
    }
    return null;
  }

  // ---------------------------------------------------------------
  // Entries, prize pool
  // ---------------------------------------------------------------

  /// Everything collected from players: entries + rebuys + add-ons.
  ///
  /// Read straight from the ledger, so it is always consistent with the
  /// recorded, signed transactions rather than a separately maintained
  /// counter that could drift.
  static double totalCollected(String sessionId) =>
      SessionService.totalBuyIn(sessionId) + SessionService.totalRebuy(sessionId);

  /// The house's cut — the per-entry fee times the number of entries.
  /// Rake collected the cash-game way is added on top if the host used
  /// it, so nothing is ever double-counted or lost.
  static double houseFee(PokerSession session) {
    final fee = session.tournamentFee ?? 0;
    if (fee <= 0) return SessionService.totalRake(session.id);
    return fee * entryCount(session) + SessionService.totalRake(session.id);
  }

  /// What the players are actually competing for.
  static double prizePool(PokerSession session) {
    final pool = totalCollected(session.id) - houseFee(session);
    return pool < 0 ? 0 : pool;
  }

  /// Number of paid entries (buy-in transactions).
  static int entryCount(PokerSession session) => SessionService
      .transactionsFor(session.id)
      .where((t) => t.type == TransactionType.buyIn)
      .length;

  static int rebuyCount(PokerSession session) => SessionService
      .transactionsFor(session.id)
      .where((t) => t.type == TransactionType.rebuy)
      .length;

  /// Total paid out to players so far (recorded as cash-outs).
  static double totalPaidOut(String sessionId) =>
      SessionService.totalCashOut(sessionId);

  /// Prize pool still to be distributed.
  static double remainingPool(PokerSession session) {
    final left = prizePool(session) - totalPaidOut(session.id);
    return left < 0 ? 0 : left;
  }

  // ---------------------------------------------------------------
  // Payout structure
  // ---------------------------------------------------------------

  /// A reasonable default payout spread for the field size.
  static List<double> defaultPayouts(int players) {
    if (players <= 3) return [100];
    if (players <= 6) return [65, 35];
    if (players <= 9) return [50, 30, 20];
    if (players <= 18) return [40, 25, 18, 10, 7];
    return [35, 22, 15, 10, 8, 5, 5];
  }

  static List<double> payoutsFor(PokerSession session) {
    final saved = session.payoutPercentages;
    if (saved != null && saved.isNotEmpty) return saved;
    return defaultPayouts(SessionService.playersFor(session.id).length);
  }

  static Future<void> savePayouts(
      PokerSession session, List<double> percentages) async {
    SessionService.assertSessionActive(session.id);
    session.payoutPercentages = percentages;
    await session.save();
  }

  /// The prize table: each paid position, its percentage, its cash value
  /// and (once known) who finished there.
  static List<PayoutSpot> payoutTable(PokerSession session) {
    final pool = prizePool(session);
    final pcts = payoutsFor(session);
    // Index finishers by position once rather than scanning the player
    // list for every payout row.
    final byPosition = <int, Player>{
      for (final p in SessionService.playersFor(session.id))
        if (p.finishPosition != null) p.finishPosition!: p,
    };
    return [
      for (var i = 0; i < pcts.length; i++)
        PayoutSpot(
          position: i + 1,
          percentage: pcts[i],
          amount: pool * pcts[i] / 100,
          player: byPosition[i + 1],
        ),
    ];
  }

  /// What a given finishing position is owed.
  static double prizeForPosition(PokerSession session, int position) {
    final pcts = payoutsFor(session);
    if (position < 1 || position > pcts.length) return 0;
    return prizePool(session) * pcts[position - 1] / 100;
  }

  // ---------------------------------------------------------------
  // Eliminations and rankings
  // ---------------------------------------------------------------

  // Seated players only: a pre-seat registration is not a tournament
  // entry, so it must never appear in the active/eliminated rosters.
  static List<Player> activePlayers(String sessionId) =>
      SessionService.playersFor(sessionId)
          .where((p) => p.seated && p.finishPosition == null)
          .toList();

  static List<Player> eliminatedPlayers(String sessionId) {
    final out = SessionService.playersFor(sessionId)
        .where((p) => p.seated && p.finishPosition != null)
        .toList()
      ..sort((a, b) => a.finishPosition!.compareTo(b.finishPosition!));
    return out;
  }

  /// Busts a player out.
  ///
  /// The finishing position is derived from how many players are still
  /// in: with 7 left, the next player out finishes 7th. Computing it
  /// rather than asking the banker removes the most common tournament
  /// bookkeeping error, and it is always correct as long as eliminations
  /// are recorded in order.
  static Future<int> eliminatePlayer(PokerSession session, Player player) async {
    SessionService.assertSessionActive(session.id);
    if (player.finishPosition != null) return player.finishPosition!;
    final remaining = activePlayers(session.id).length;
    final position = remaining < 1 ? 1 : remaining;
    player.finishPosition = position;
    player.eliminatedAt = DateTime.now();
    player.isActive = false;
    await player.save();
    return position;
  }

  /// Undoes an elimination — the banker tapped the wrong seat.
  static Future<void> reinstatePlayer(
      PokerSession session, Player player) async {
    SessionService.assertSessionActive(session.id);
    player.finishPosition = null;
    player.eliminatedAt = null;
    player.isActive = true;
    await player.save();
  }

  /// Live standings: players still in (by chips-in, as a proxy for
  /// commitment) followed by the eliminated in finishing order.
  static List<Player> rankings(String sessionId) {
    final active = activePlayers(sessionId);
    final out = eliminatedPlayers(sessionId);
    return [...active, ...out];
  }

  /// Whether the tournament has a single player left.
  static bool isComplete(String sessionId) =>
      activePlayers(sessionId).length <= 1 &&
      SessionService.playersFor(sessionId).isNotEmpty;

  /// Awards the winner their finishing position when only one remains,
  /// so the final table closes out cleanly without the banker having to
  /// "eliminate" the champion.
  static Future<Player?> finaliseWinner(PokerSession session) async {
    final active = activePlayers(session.id);
    if (active.length != 1) return null;
    final winner = active.first;
    winner.finishPosition = 1;
    await winner.save();
    return winner;
  }
}
