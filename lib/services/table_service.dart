import '../models/enums.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../models/table_participation.dart';
import '../models/transaction.dart';
import 'hive_service.dart';
import 'participation_service.dart';
import 'player_operation_guard.dart';
import 'session_service.dart';
import 'table_operation_event_service.dart';

/// Lifecycle of one table inside a session.
///
/// Deliberately independent of [SessionStatus]: a table closing is a
/// normal part of a night (the field consolidates, one table breaks),
/// whereas ending the session is the banker settling the bank. Closing
/// every table still does NOT end the session — only the banker does
/// that, explicitly, from End Session.
enum TableStatus { active, paused, closed }

extension TableStatusX on TableStatus {
  bool get isActive => this == TableStatus.active;
  bool get isPaused => this == TableStatus.paused;
  bool get isClosed => this == TableStatus.closed;

  /// Whether money can still be recorded at a table in this state.
  /// Paused is a soft state — dealing has stopped but the banker can
  /// still correct a mistake, so only Closed blocks new play.
  bool get acceptsPlay => this != TableStatus.closed;

  String get key => name;

  static TableStatus fromKey(String? key) {
    switch (key) {
      case 'paused':
        return TableStatus.paused;
      case 'closed':
        return TableStatus.closed;
      default:
        return TableStatus.active;
    }
  }
}

/// One physical table inside a session.
class PokerTable {
  /// Current supported game code. Other games (Omaha, Blackjack, etc.)
  /// are deliberately NOT implemented; the code is future-ready metadata
  /// only.
  static const String gameNoLimitHoldem = 'nlhe';

  /// Current supported limit/format code.
  static const String formatNoLimit = 'no_limit';

  final String id;
  final String name;
  final int seatCount;
  final int dealerSeat;

  /// Additive per-table metadata (locked J4). Stored in the same table
  /// map as the rest of the table, so no Hive adapter, typeId or
  /// migration is involved. Absent values on legacy tables are resolved
  /// from the session's own blinds in [tablesFor].
  final String game;
  final String format;
  final double smallStake;
  final double bigStake;

  /// Per-table lifecycle. Stored inside the same map as the rest of the
  /// table so no new Hive adapter or typeId is needed and every
  /// previously saved session still opens — an absent value reads as
  /// [TableStatus.active], which is what old data means.
  final TableStatus status;

  /// When the table was closed, for the session report.
  final DateTime? closedAt;

  /// Independent play clock for this table.
  ///
  /// Separate from the session timer on purpose: tables open at
  /// different times through the night, so "how long has THIS table been
  /// running" is a different question from "how long has the session
  /// been running". Both can be used at once.
  ///
  /// [runningSince] is null while the clock is stopped; [bankedSeconds]
  /// holds time already accumulated, so pausing and resuming never loses
  /// or double-counts a second.
  final DateTime? runningSince;
  final int bankedSeconds;

  /// Optional countdown target for THIS table, in minutes.
  ///
  /// Null means "no target" — the table simply counts up, which is the
  /// pre-existing behaviour and what every table saved before this
  /// feature reads as. Stored in the same table map as everything else,
  /// so no Hive adapter, typeId or migration is involved.
  final int? plannedMinutes;

  /// Set once the countdown has hit zero and the alarm has been raised,
  /// so the notice fires exactly once even though the shell polls every
  /// second. Persisted for the same reason the session timer persists
  /// its own flag: a rebuild or app restart must not re-trigger it.
  final bool finishNoticeShown;

  const PokerTable({
    required this.id,
    required this.name,
    required this.seatCount,
    required this.dealerSeat,
    this.game = gameNoLimitHoldem,
    this.format = formatNoLimit,
    this.smallStake = 0,
    this.bigStake = 0,
    this.status = TableStatus.active,
    this.closedAt,
    this.runningSince,
    this.bankedSeconds = 0,
    this.plannedMinutes,
    this.finishNoticeShown = false,
  });

  /// Total time this table has been in play.
  Duration get elapsed {
    var secs = bankedSeconds;
    if (runningSince != null) {
      secs += DateTime.now().difference(runningSince!).inSeconds;
    }
    return Duration(seconds: secs);
  }

  bool get timerRunning => runningSince != null;

  bool get hasStakes => smallStake > 0 && bigStake > 0;

  /// True when this table's game, limit format and stakes are identical
  /// to [other]. This is the J4 compatibility rule: an incompatible
  /// table must be connected via Table Cash-out + new Buy-in, never a
  /// direct transfer.
  bool compatibleWith(PokerTable other) =>
      game == other.game &&
      format == other.format &&
      smallStake == other.smallStake &&
      bigStake == other.bigStake;

  String get gameCode => game;
  String get formatCode => format;

  /// Whether a countdown target has been chosen for this table.
  bool get hasTimer => plannedMinutes != null && plannedMinutes! > 0;

  /// Time left on the countdown, or null when no target is set.
  ///
  /// Clamped at zero so a finished timer can never display negative
  /// time, even if the clock kept running for a moment before the shell
  /// noticed and paused it.
  Duration? get timeRemaining {
    if (!hasTimer) return null;
    final left = Duration(minutes: plannedMinutes!) - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// True once a targeted countdown has run out.
  bool get isFinished => hasTimer && timeRemaining == Duration.zero;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'seatCount': seatCount,
        'dealerSeat': dealerSeat,
        'game': game,
        'format': format,
        'smallStake': smallStake,
        'bigStake': bigStake,
        'status': status.key,
        'closedAt': closedAt?.toIso8601String(),
        'runningSince': runningSince?.toIso8601String(),
        'bankedSeconds': bankedSeconds,
        'plannedMinutes': plannedMinutes,
        'finishNoticeShown': finishNoticeShown,
      };

  static PokerTable fromMap(Map m) => PokerTable(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? 'Table',
        seatCount: (m['seatCount'] as num?)?.toInt() ?? 9,
        dealerSeat: (m['dealerSeat'] as num?)?.toInt() ?? 1,
        game: (m['game'] as String?) ?? gameNoLimitHoldem,
        format: (m['format'] as String?) ?? formatNoLimit,
        smallStake: (m['smallStake'] as num?)?.toDouble() ?? 0,
        bigStake: (m['bigStake'] as num?)?.toDouble() ?? 0,
        status: TableStatusX.fromKey(m['status'] as String?),
        closedAt: m['closedAt'] == null
            ? null
            : DateTime.tryParse(m['closedAt'] as String),
        runningSince: m['runningSince'] == null
            ? null
            : DateTime.tryParse(m['runningSince'] as String),
        bankedSeconds: (m['bankedSeconds'] as num?)?.toInt() ?? 0,
        // Absent in every table saved before per-table durations existed,
        // which correctly reads as "no countdown configured".
        plannedMinutes: (m['plannedMinutes'] as num?)?.toInt(),
        finishNoticeShown: (m['finishNoticeShown'] as bool?) ?? false,
      );

  PokerTable copyWith({
    String? name,
    int? seatCount,
    int? dealerSeat,
    String? game,
    String? format,
    double? smallStake,
    double? bigStake,
    TableStatus? status,
    DateTime? closedAt,
    bool clearClosedAt = false,
    DateTime? runningSince,
    bool clearRunningSince = false,
    int? bankedSeconds,
    int? plannedMinutes,
    bool clearPlannedMinutes = false,
    bool? finishNoticeShown,
  }) =>
      PokerTable(
        id: id,
        name: name ?? this.name,
        seatCount: seatCount ?? this.seatCount,
        dealerSeat: dealerSeat ?? this.dealerSeat,
        game: game ?? this.game,
        format: format ?? this.format,
        smallStake: smallStake ?? this.smallStake,
        bigStake: bigStake ?? this.bigStake,
        status: status ?? this.status,
        closedAt: clearClosedAt ? null : (closedAt ?? this.closedAt),
        runningSince:
            clearRunningSince ? null : (runningSince ?? this.runningSince),
        bankedSeconds: bankedSeconds ?? this.bankedSeconds,
        // Explicit clear flag because null means "no target", which is a
        // real value the caller may want to set — a plain nullable
        // parameter could not express "remove the duration".
        plannedMinutes:
            clearPlannedMinutes ? null : (plannedMinutes ?? this.plannedMinutes),
        finishNoticeShown: finishNoticeShown ?? this.finishNoticeShown,
      );
}

/// Multi-table management for a session.
///
/// DESIGN — why tables do not touch the money:
/// A table is a *seating* concept. Buy-ins, rebuys, cash-outs, rake and
/// the balance check all stay session-wide, because a host running three
/// tables still settles one bank at the end of the night. Keeping the
/// accounting session-scoped means the settlement engine, the balance
/// verification and every existing saved session are completely
/// unaffected by this feature — the only thing a table changes is which
/// group a player is displayed in and which seat numbers are free.
///
/// BACKWARDS COMPATIBILITY:
/// Sessions saved before multi-table support have `tables == null` and
/// players with `tableId == null`. [tablesFor] synthesises a single
/// default table from the session's existing `tableNumber` /
/// `tableSeatCount` / `dealerSeatIndex` fields, and [playersAt] treats a
/// null `tableId` as belonging to that first table. So an old session
/// opens as a normal one-table game, exactly as before, and only gains
/// the multi-table UI if the host actually adds a second table.
class TableService {
  /// Stable id used for the implicit first table of a legacy session.
  static const String defaultTableId = 'table-1';

  /// The tables in this session, always at least one.
  static List<PokerTable> tablesFor(PokerSession session) {
    final raw = session.tables;
    if (raw == null || raw.isEmpty) {
      return [
        PokerTable(
          id: defaultTableId,
          name: session.tableNumber.trim().isEmpty
              ? 'Table 1'
              : 'Table ${session.tableNumber.trim()}',
          seatCount: session.tableSeatCount,
          dealerSeat: session.dealerSeatIndex,
          smallStake: session.smallBlind,
          bigStake: session.bigBlind,
        ),
      ];
    }
    // Legacy tables saved before per-table metadata existed read a zero
    // stake; resolve those from the session's blinds so the Floor has an
    // honest "NLHE 1/2" label and compatibility can be evaluated.
    return raw.map(PokerTable.fromMap).map((t) {
      if (t.smallStake > 0 || t.bigStake > 0) return t;
      return t.copyWith(smallStake: session.smallBlind, bigStake: session.bigBlind);
    }).toList();
  }

  static bool isMultiTable(PokerSession session) => tablesFor(session).length > 1;

  static PokerTable tableById(PokerSession session, String? tableId) {
    final tables = tablesFor(session);
    if (tableId == null) return tables.first;
    return tables.firstWhere(
      (t) => t.id == tableId,
      orElse: () => tables.first,
    );
  }

  /// The table a player is sitting at. A null [Player.tableId] means the
  /// session's first table (legacy data).
  static PokerTable tableForPlayer(PokerSession session, Player player) =>
      tableById(session, player.tableId);

  /// Players seated at one table, ordered by seat.
  static List<Player> playersAt(PokerSession session, String tableId) {
    final tables = tablesFor(session);
    final isFirst = tables.isNotEmpty && tables.first.id == tableId;
    return SessionService.playersFor(session.id)
        // Seated players only. An unseated registration stores
        // tableId == null, which the first-table mapping below would
        // otherwise absorb into the first table — seat occupancy,
        // dealer movement, close gating and the table view must never
        // see a player who holds no seat.
        .where((p) =>
            p.seated &&
            (p.tableId == tableId || (isFirst && p.tableId == null)))
        .toList()
      ..sort((a, b) => a.seatNumber.compareTo(b.seatNumber));
  }

  static int playerCountAt(PokerSession session, String tableId) =>
      playersAt(session, tableId).length;

  /// Seats already taken at a table, excluding [excludePlayerId] so a
  /// player being edited still sees their own seat as available.
  static Set<int> occupiedSeats(
    PokerSession session,
    String tableId, {
    String? excludePlayerId,
  }) =>
      playersAt(session, tableId)
          .where((p) => p.id != excludePlayerId)
          .map((p) => p.seatNumber)
          .toSet();

  /// Lowest free seat at a table, or null when it is full.
  static int? firstFreeSeat(PokerSession session, String tableId) {
    final table = tableById(session, tableId);
    final taken = occupiedSeats(session, tableId);
    for (var i = 1; i <= table.seatCount; i++) {
      if (!taken.contains(i)) return i;
    }
    return null;
  }

  /// Money currently in play at one table — the seated players' net
  /// commitment to the session's table play (Phase 7):
  ///
  ///   totalIn + re-entries − cash-outs − house wins
  ///
  /// A re-entered player (carried chips committed to this table) counts
  /// at their NET commitment — the re-entry cancels the matching table
  /// cash-out, so the same chips are not counted twice. A house win
  /// reduces the commitment (the chips became casino-owned).
  ///
  /// Purely informational, for the host's own overview. It is NOT part of
  /// the balance check: rake is collected for the house as a whole, so
  /// only the session-level figure reconciles.
  static double moneyInPlayAt(PokerSession session, String tableId) {
    var total = 0.0;
    for (final p in playersAt(session, tableId)) {
      total += SessionService.playerTotalIn(session.id, p.id) +
          SessionService.playerReentry(session.id, p.id) -
          SessionService.playerTotalCashOut(session.id, p.id) -
          SessionService.playerHouseWin(session.id, p.id);
    }
    return total;
  }

  static double buyInsAt(PokerSession session, String tableId) {
    var total = 0.0;
    for (final p in playersAt(session, tableId)) {
      total += SessionService.playerTotalIn(session.id, p.id);
    }
    return total;
  }

  // ---------------------------------------------------------------- writes

  /// NLHE / No Limit only (locked J4, additive model). Any other game or
  /// limit format is refused at the service boundary rather than accepted
  /// through the UI and silently breaking compatibility later.
  static void validateGameMetadata({
    required String game,
    required String format,
  }) {
    if (game != PokerTable.gameNoLimitHoldem) {
      throw StateError(
          'Only $PokerTable.gameNoLimitHoldem is supported on this table.');
    }
    if (format != PokerTable.formatNoLimit) {
      throw StateError(
          'Only $PokerTable.formatNoLimit is supported on this table.');
    }
  }

  static Future<void> _persist(PokerSession session, List<PokerTable> tables) async {
    session.tables = tables.map((t) => t.toMap()).toList();
    // Keep the legacy single-table fields pointing at a live table so any
    // code (or old backup) still reading them stays correct. Prefer the
    // first OPEN table, so a closed first table doesn't leave the legacy
    // mirror describing a table nobody is playing at.
    final first = tables.firstWhere(
      (t) => !t.status.isClosed,
      orElse: () => tables.first,
    );
    session.tableSeatCount = first.seatCount;
    session.dealerSeatIndex = first.dealerSeat;
    await session.save();
  }

  /// Adds a table. Returns its id.
  ///
  /// [game]/[format]/[smallStake]/[bigStake] default to the session's
  /// current game metadata (NLHE / No Limit + session blinds), so a
  /// newly opened table is compatible with the legacy single-table game
  /// until the operator changes it.
  static Future<String> addTable(
    PokerSession session, {
    String? name,
    int seatCount = 9,
    String? game,
    String? format,
    double? smallStake,
    double? bigStake,
  }) async {
    SessionService.assertSessionActive(session.id);
    final gameCode = game ?? PokerTable.gameNoLimitHoldem;
    final formatCode = format ?? PokerTable.formatNoLimit;
    validateGameMetadata(game: gameCode, format: formatCode);
    final tables = tablesFor(session);
    // Ids are never reused, even after a delete, so a stale tableId on a
    // player can never silently re-point at a different table.
    var n = tables.length + 1;
    while (tables.any((t) => t.id == 'table-$n')) {
      n++;
    }
    final table = PokerTable(
      id: 'table-$n',
      name: (name == null || name.trim().isEmpty) ? 'Table $n' : name.trim(),
      seatCount: seatCount,
      dealerSeat: 1,
      game: gameCode,
      format: formatCode,
      smallStake: smallStake ?? session.smallBlind,
      bigStake: bigStake ?? session.bigBlind,
    );
    await _persist(session, [...tables, table]);
    return table.id;
  }

  /// Updates per-table game/format/stakes metadata. Purely additive —
  /// no seating, money or history is touched.
  static Future<void> setTableMetadata(
    PokerSession session,
    String tableId, {
    String? game,
    String? format,
    double? smallStake,
    double? bigStake,
  }) async {
    SessionService.assertSessionActive(session.id);
    final current = tableById(session, tableId);
    final gameCode = game ?? current.game;
    final formatCode = format ?? current.format;
    validateGameMetadata(game: gameCode, format: formatCode);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      return t.copyWith(
        game: game,
        format: format,
        smallStake: smallStake,
        bigStake: bigStake,
      );
    }).toList();
    await _persist(session, tables);
  }

  static Future<void> renameTable(
      PokerSession session, String tableId, String name) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session)
        .map((t) => t.id == tableId ? t.copyWith(name: name.trim()) : t)
        .toList();
    await _persist(session, tables);
  }

  static Future<void> setSeatCount(
      PokerSession session, String tableId, int seatCount) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      return t.copyWith(
        seatCount: seatCount,
        dealerSeat: t.dealerSeat > seatCount ? 1 : t.dealerSeat,
      );
    }).toList();
    await _persist(session, tables);
  }

  /// Advances the dealer button to the next occupied seat at that table.
  static Future<void> moveDealer(PokerSession session, String tableId) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session);
    final table = tableById(session, tableId);
    final occupied = playersAt(session, tableId).map((p) => p.seatNumber).toSet();
    var next = table.dealerSeat;
    for (var i = 0; i < table.seatCount; i++) {
      next = next % table.seatCount + 1;
      if (occupied.isEmpty || occupied.contains(next)) break;
    }
    await _persist(
      session,
      tables.map((t) => t.id == tableId ? t.copyWith(dealerSeat: next) : t).toList(),
    );
  }

  // ---------------------------------------------------------------
  // Table lifecycle
  //
  // CRITICAL: none of these touch the session. Closing a table is a
  // seating/lifecycle change; the session ends only when the banker
  // ends it. There is deliberately no code path here that writes
  // SessionStatus.
  // ---------------------------------------------------------------

  static List<PokerTable> openTables(PokerSession session) =>
      tablesFor(session).where((t) => !t.status.isClosed).toList();

  static bool hasOpenTable(PokerSession session) =>
      openTables(session).isNotEmpty;

  /// Why a table can't be closed yet, or null when it can.
  ///
  /// Unlike removal, closing does NOT require the session to keep a
  /// minimum number of tables — a banker may legitimately close the last
  /// table and still have an open session while they settle up. It does
  /// require the table to be empty of unsettled players, because closing
  /// a table with money still on it would strand that money.
  static String? closeBlocker(PokerSession session, String tableId) {
    final unsettled = playersAt(session, tableId)
        .where((p) => !SessionService.hasCashedOut(session.id, p.id))
        .toList();
    if (unsettled.isNotEmpty) {
      return 'Cash out or move these players first: '
          '${unsettled.map((p) => p.name).join(', ')}.';
    }
    return null;
  }

  static Future<void> setTableStatus(
    PokerSession session,
    String tableId,
    TableStatus status,
  ) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      // Closing or pausing a table also stops its clock — a table that
      // isn't being dealt shouldn't keep accruing play time.
      final stopClock = !status.isActive && t.timerRunning;
      return t.copyWith(
        status: status,
        closedAt: status.isClosed ? DateTime.now() : null,
        clearClosedAt: !status.isClosed,
        bankedSeconds: stopClock ? t.elapsed.inSeconds : t.bankedSeconds,
        clearRunningSince: stopClock,
      );
    }).toList();
    await _persist(session, tables);
  }

  static Future<void> pauseTable(PokerSession session, String tableId) =>
      setTableStatus(session, tableId, TableStatus.paused);

  static Future<void> resumeTable(PokerSession session, String tableId) =>
      setTableStatus(session, tableId, TableStatus.active);

  /// Closes one table. The session keeps running regardless of how many
  /// other tables remain open.
  static Future<void> closeTable(PokerSession session, String tableId) async {
    if (closeBlocker(session, tableId) != null) return;
    await setTableStatus(session, tableId, TableStatus.closed);
  }

  static Future<void> reopenTable(PokerSession session, String tableId) =>
      setTableStatus(session, tableId, TableStatus.active);

  /// Whether a table can be removed. The last table never can, and a
  /// table with players must be emptied first — silently reseating
  /// someone else's money is not something to do implicitly.
  static String? removalBlocker(PokerSession session, String tableId) {
    final tables = tablesFor(session);
    if (tables.length <= 1) return 'A session must always have at least one table.';
    if (playerCountAt(session, tableId) > 0) {
      return 'Move or cash out the players at this table first.';
    }
    return null;
  }

  static Future<void> removeTable(PokerSession session, String tableId) async {
    SessionService.assertSessionActive(session.id);
    if (removalBlocker(session, tableId) != null) return;
    final tables = tablesFor(session).where((t) => t.id != tableId).toList();
    await _persist(session, tables);
  }

  // ---------------------------------------------------------------
  // Per-table play clock
  // ---------------------------------------------------------------

  static Future<void> startTableTimer(
      PokerSession session, String tableId) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId || t.timerRunning) return t;
      // Starting a clock that has already run out would immediately
      // re-finish. Refusing here keeps the finished state stable; the
      // banker resets or re-sets the duration to run it again.
      if (t.isFinished) return t;
      return t.copyWith(runningSince: DateTime.now());
    }).toList();
    await _persist(session, tables);
  }

  /// Assigns (or clears) this table's countdown target.
  ///
  /// Passing null removes the target and the table reverts to counting
  /// up, exactly as tables behaved before durations existed. Setting a
  /// duration clears any previous finished state so the same table can be
  /// timed again for the next level.
  static Future<void> setTableTimerDuration(
    PokerSession session,
    String tableId,
    int? minutes,
  ) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      if (minutes == null || minutes <= 0) {
        return t.copyWith(
          clearPlannedMinutes: true,
          finishNoticeShown: false,
        );
      }
      return t.copyWith(
        plannedMinutes: minutes,
        finishNoticeShown: false,
      );
    }).toList();
    await _persist(session, tables);
  }

  /// Stops the clock and returns it to zero, keeping the chosen duration
  /// so the banker can simply press play again.
  ///
  /// Deliberately does NOT touch [TableStatus]: a table can be active
  /// with a stopped timer, or paused with one running. The two concepts
  /// stay independent.
  static Future<void> stopTableTimer(
      PokerSession session, String tableId) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      return t.copyWith(
        bankedSeconds: 0,
        clearRunningSince: true,
        finishNoticeShown: false,
      );
    }).toList();
    await _persist(session, tables);
  }

  /// Called by the provider the moment a countdown hits zero: banks the
  /// exact elapsed time, stops the clock so it cannot drift negative, and
  /// marks the notice as delivered so the alarm fires only once.
  static Future<void> markTableTimerFinished(
      PokerSession session, String tableId) async {
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      return t.copyWith(
        // Clamp to exactly the planned duration rather than whatever the
        // wall clock reached, so the display lands on 00:00:00.
        bankedSeconds: t.hasTimer
            ? Duration(minutes: t.plannedMinutes!).inSeconds
            : t.elapsed.inSeconds,
        clearRunningSince: true,
        finishNoticeShown: true,
      );
    }).toList();
    await _persist(session, tables);
  }

  static Future<void> pauseTableTimer(
      PokerSession session, String tableId) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId || !t.timerRunning) return t;
      // Bank the running time before clearing the start stamp, so
      // resuming continues from where it stopped.
      return t.copyWith(
        bankedSeconds: t.elapsed.inSeconds,
        clearRunningSince: true,
      );
    }).toList();
    await _persist(session, tables);
  }

  static Future<void> resetTableTimer(
      PokerSession session, String tableId) async {
    SessionService.assertSessionActive(session.id);
    final tables = tablesFor(session).map((t) {
      if (t.id != tableId) return t;
      return t.copyWith(
        bankedSeconds: 0,
        runningSince: t.timerRunning ? DateTime.now() : null,
        clearRunningSince: !t.timerRunning,
        // A reset countdown must be able to finish (and alarm) again.
        finishNoticeShown: false,
      );
    }).toList();
    await _persist(session, tables);
  }

  /// Guard used before seating or moving a player onto a table.
  /// Returns a reason string when the table can't take them, else null.
  static String? seatingBlocker(PokerSession session, String tableId) {
    final table = tableById(session, tableId);
    if (table.status.isClosed) {
      return '${table.name} is closed. Reopen it or choose another table.';
    }
    return null;
  }

  /// Moves a player to another table, accounting for the money they
  /// physically carry with them.
  ///
  /// THE AMOUNT IS ALWAYS MANUAL AND MUST BE EXPLICIT (locked J1).
  /// The app deliberately does not model how many chips sit in front of
  /// a player. The banker physically counts the stack the player carries
  /// away; that count is the only authority.
  ///
  /// FUNDED vs DRY
  ///   * A funded transfer MUST pass a positive [amount] and a host
  ///     [hostSignatureBase64] (J2). A missing amount is refused — it is
  ///     never interpreted as zero.
  ///   * A transfer with no chips MUST set [dryMove] = true. This writes
  ///     no ledger leg and carries the explicit dry state into the
  ///     immutable Transfer Event; it still requires the host/floor
  ///     confirmation (J2) before the seat is moved.
  ///
  /// THE ACCOUNTING MODEL (reused)
  ///   transferOut @ source table == transferIn @ destination table.
  /// Session totals are neutral. No ChipMovement, no cash-out, no buy-in.
  ///
  /// J4 COMPATIBILITY
  ///   A direct transfer is refused unless the source and destination
  ///   table share the same game, format and stakes.
  static Future<void> movePlayer(
    PokerSession session,
    Player player,
    String targetTableId, {
    int? seat,
    double? amount,
    bool dryMove = false,
    String? reason,
    String? operatorName,
    String? hostSignatureBase64,
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) async {
    SessionService.assertSessionActive(session.id);
    PlayerOperationGuard.requireRegistered(player, 'a table transfer');

    if (!player.seated) {
      throw StateError(
          'This player is not seated. Seat them before moving tables.');
    }

    // J4: source/destination compatibility before any write.
    final source = tableForPlayer(session, player);
    final target = tableById(session, targetTableId);
    if (source.id == targetTableId) {
      throw StateError(
          'Use the same-table seat change action instead of a table transfer.');
    }
    if (!source.compatibleWith(target)) {
      throw StateError(
          'Direct transfer blocked: ${target.name} has different game, '
          'stakes or format. Use Table Cash-out on ${source.name} then '
          'Buy-in at ${target.name}.');
    }

    final blocked = seatingBlocker(session, targetTableId);
    if (blocked != null) throw StateError(blocked);
    final taken = occupiedSeats(session, targetTableId, excludePlayerId: player.id);

    int? chosen = seat;
    if (chosen == null) {
      for (var i = 1; i <= target.seatCount; i++) {
        if (!taken.contains(i)) {
          chosen = i;
          break;
        }
      }
    }
    if (chosen == null) {
      throw StateError('${target.name} is full.');
    }
    if (taken.contains(chosen)) {
      throw StateError('Seat $chosen at ${target.name} is already taken.');
    }

    // J1: carried amount is explicit, never inferred from null.
    if (amount != null && amount < 0) {
      throw ArgumentError('Transfer amount cannot be negative.');
    }
    final funded = !dryMove;
    if (funded && amount == null) {
      throw StateError(
          'A carried amount is required for a funded transfer, or use Dry Move / 0 Chips.');
    }
    if (funded && amount == 0) {
      throw StateError(
          'Use Dry Move / 0 Chips for a zero-carry seat change.');
    }
    final carried = funded ? amount! : 0.0;

    // J2: a table transfer is not final without host confirmation on the
    // move itself and on every ledger leg it writes. This applies to a
    // Dry Move too — it is still a player-table operation authorised by
    // the host/floor, never an unconfirmed seat shuffle.
    if (hostSignatureBase64 == null || hostSignatureBase64.isEmpty) {
      throw StateError('A host confirmation is required for a table transfer.');
    }

    final sourceTableId = source.id;
    final sourceSeat = player.seatNumber;
    LedgerTransaction? outTx;
    LedgerTransaction? inTx;

    // LEG 1 — out of the source table, written while the player is still
    // seated there so recordTransaction files it against that table.
    if (carried > 0) {
      outTx = await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: player.id,
        type: TransactionType.transferOut,
        amount: carried,
        hostSignatureBase64: hostSignatureBase64,
        operatorName: operatorName,
        secondVerifierName: secondVerifierName,
        secondVerifierSignature: secondVerifierSignature,
        tableId: sourceTableId,
        note: 'Moved to ${target.name}',
      );
    }

    // Normalise: a player at the first table stores that table's id
    // explicitly from now on, so seating is unambiguous going forward.
    player.tableId = targetTableId;
    player.seatNumber = chosen;
    await player.save();

    // LEG 2 — into the destination table, written only after the seat
    // has moved, so it is attributed to the new table.
    if (carried > 0) {
      inTx = await SessionService.recordTransaction(
        sessionId: session.id,
        playerId: player.id,
        type: TransactionType.transferIn,
        amount: carried,
        hostSignatureBase64: hostSignatureBase64,
        operatorName: operatorName,
        secondVerifierName: secondVerifierName,
        secondVerifierSignature: secondVerifierSignature,
        tableId: targetTableId,
        note: 'Moved from ${source.name}',
      );
    }

    // Phase 6 — participation lifecycle (locked J7):
    //  * FUNDED move: source closes, destination opens.
    //  * DRY move: the open participation follows the seat.
    String? sourceParticipationId;
    String? destinationParticipationId;
    final openP = ParticipationService.openFor(
      sessionId: session.id,
      seatPlayerId: player.id,
      tableId: sourceTableId,
    );
    if (openP != null) {
      sourceParticipationId = openP.id;
      if (carried > 0) {
        ParticipationService.close(
            openP.id,
            reason: ParticipationCloseReason.transferOut);
      } else {
        ParticipationService.moveTable(openP.id, targetTableId);
      }
    }
    if (outTx?.participationId != null) {
      sourceParticipationId = outTx!.participationId;
    }
    if (inTx?.participationId != null) {
      destinationParticipationId = inTx!.participationId;
    }

    // J3 — immutable audit event linking both legs and participations.
    await TableOperationEventService.appendTransfer(
      playerId: player.id,
      personId: player.personId,
      sourceTableId: sourceTableId,
      sourceSeat: sourceSeat,
      destinationTableId: targetTableId,
      destinationSeat: chosen,
      carriedAmount: funded ? carried : 0,
      dryMove: !funded,
      reason: reason ?? 'voluntary',
      operatorName: operatorName,
      hostSignatureBase64: hostSignatureBase64 ?? '',
      secondVerifierName: secondVerifierName,
      secondVerifierSignature: secondVerifierSignature,
      transferOutTransactionId: outTx?.id ?? '',
      transferInTransactionId: inTx?.id ?? '',
      sourceParticipationId: sourceParticipationId,
      destinationParticipationId: destinationParticipationId,
    );

    // NOTE ON HISTORY: the player's existing transactions deliberately
    // keep the tableId they were recorded with. Historical buy-ins/
    // rebuys/cash-outs are not rewritten.
    //
    // NOTE ON CHIPS: deliberately no ChipMovement is written here.
    // Physical chips are tracked against ChipLocation.player(id), not
    // against a table — the player's holding travels with them.
  }

  /// RE-ENTRY (Phase 7): seats the (unseated) player at
  /// [targetTableId] using chips they ALREADY hold in their person-scoped
  /// chip holding, and records the commitment.
  ///
  /// THE FINANCIAL MODEL — THIS IS NOT A PURCHASE
  /// The carried chips were already purchased (a buy-in or a wallet
  /// issuance — possibly in a previous session). Re-entry moves the
  /// player's EXISTING commitment into the new table context:
  ///   * ONE `reentry` money leg (the counted amount, signature):
  ///     session money IN at the destination table. It is NOT a buy-in —
  ///     [SessionService.totalBuyIn] and every wallet figure are
  ///     untouched, so the original purchase is never counted twice.
  ///   * NO chip movement: the chips already sit in the person-scoped
  ///     holding and travel with the person.
  ///   * NO Financial Ledger event: no cash changes hands.
  ///   * A NEW TableParticipation opens at the destination (stamped by
  ///     the re-entry leg); the previous participation was closed by the
  ///     table cash-out (or a move). Any stale still-open one is closed
  ///     here so exactly one open commitment per (person, table, session)
  ///     stays true.
  ///
  /// The counted [amount] is the banker's fact (E9) — recorded exactly
  /// as entered, like every other player money leg.
  static Future<LedgerTransaction> reenterWithHeldChips(
    PokerSession session,
    Player player,
    String targetTableId, {
    int? seat,
    required double amount,
    required String hostSignatureBase64,
    String? note,
  }) async {
    SessionService.assertSessionActive(session.id);
    PlayerOperationGuard.requireRegistered(player, 'a re-entry');
    if (player.seated) {
      throw StateError(
          'This player is already seated. Cash them out of the table (or '
          'move them) before a re-entry.');
    }
    final personId = player.personId;
    if (personId == null || personId.isEmpty) {
      throw StateError(
          'Re-entry commits the person\'s held chips — link a person to '
          'this player first.');
    }
    if (amount <= 0) {
      throw ArgumentError(
          'Re-entry needs a positive carried amount — the player is '
          'committing chips they hold.');
    }
    final blocked = seatingBlocker(session, targetTableId);
    if (blocked != null) throw StateError(blocked);
    final target = tableById(session, targetTableId);
    final taken = occupiedSeats(session, targetTableId,
        excludePlayerId: player.id);

    int? chosen = seat;
    if (chosen == null) {
      for (var i = 1; i <= target.seatCount; i++) {
        if (!taken.contains(i)) {
          chosen = i;
          break;
        }
      }
    }
    if (chosen == null) {
      throw StateError('${target.name} is full.');
    }
    if (taken.contains(chosen)) {
      throw StateError('Seat $chosen at ${target.name} is already taken.');
    }

    // The commitment moves: close any stale still-open participation at
    // ANOTHER table (the normal path closed it at the table cash-out).
    for (final p in ParticipationService.forSession(session.id)) {
      if (p.seatPlayerId != player.id || !p.isOpen) continue;
      if (p.tableId == targetTableId) continue;
      ParticipationService.close(p.id,
          reason: ParticipationCloseReason.tableCashOut);
    }

    // Seat first, then write the leg: recordTransaction attributes a
    // player leg to the table the player is sitting at, and the re-entry
    // stamp opens the new participation there.
    player.tableId = targetTableId;
    player.seatNumber = chosen;
    player.seated = true;
    await player.save();

    return SessionService.recordTransaction(
      sessionId: session.id,
      playerId: player.id,
      type: TransactionType.reentry,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      note: note ?? 'Re-entry with held chips',
    );
  }

  /// Ensures the session has an explicit table list. Called before the
  /// first structural change so legacy sessions get their implicit table
  /// written down rather than mutating silently.
  static Future<void> materialise(PokerSession session) async {
    if (session.tables != null && session.tables!.isNotEmpty) return;
    await _persist(session, tablesFor(session));
    // Existing players keep tableId == null, which playersAt() maps to
    // the first table — no player rewrite needed, so nothing can go
    // wrong for a session that is mid-game.
  }
}

/// Session-wide totals grouped per table, for the host's overview.
class TableSummary {
  final PokerTable table;
  final int playerCount;
  final double moneyInPlay;
  final double totalIn;

  /// Buy-ins + rebuys recorded AT THIS TABLE.
  ///
  /// WHY THESE ARE TRANSACTION-DERIVED AND [moneyInPlay] IS NOT
  /// [moneyInPlay] and [totalIn] above sum the CURRENT occupants'
  /// player totals, so a player who moves tables carries their whole
  /// history with them to the new table. That is the right answer for
  /// "how much is sitting at this table right now", which is what the
  /// table selector bar uses them for.
  ///
  /// It is the wrong answer for a financial summary. A buy-in taken at
  /// Table 1 belongs to Table 1's takings for the night even if the
  /// player later moved. So every figure below is folded from the
  /// transactions themselves via [SessionService.transactionsForTable],
  /// keyed on [LedgerTransaction.tableId].
  ///
  /// Both are kept: they answer different questions and neither is
  /// derivable from the other.
  final double moneyIn;

  /// Cash-outs + rake recorded at this table. Mirrors the session-level
  /// `BalanceResult.moneyOut`, which is also cash-out plus rake.
  final double moneyOut;

  final double cashOut;

  /// Phase 7: table cash-outs AT THIS TABLE — the players who left
  /// carrying counted chips. Already included in [moneyOut]; kept
  /// separate so the UI can explain where the money went (it stayed the
  /// person's holding — it is not a cage redemption).
  final double tableCashOut;

  final double rake;
  final double cashDrop;

  /// Chips tipped to the dealer from this table. Already included in
  /// [moneyOut]; exposed separately so the Dashboard can state it on its
  /// own line without recomputing it.
  ///
  /// NEVER part of [hostProfit] — see [TransactionType.dealerTips].
  final double dealerTips;

  /// Phase 7: re-entries AT THIS TABLE — carried chips committed by
  /// players who left another table. Already included in [moneyIn]; NOT
  /// a buy-in (totalBuyIn is untouched), just the same chips back in
  /// table play.
  final double reentry;

  /// Phase 7: house wins banked from this table's players at
  /// house-banked games. Already included in [moneyOut]; house-game
  /// revenue, kept separate from [rake] in every report.
  final double houseWin;

  /// Money carried onto / off this table by players changing seats.
  /// Already included in [moneyIn] / [moneyOut]; kept separately so the
  /// UI can explain a table whose figures moved without a buy-in.
  final double transferIn;
  final double transferOut;

  /// True once this table is settled: everything that came in has either
  /// been paid out, raked, or carried to another table.
  ///
  ///   Money In = Money Out + Rake      (rake is inside Money Out)
  ///
  /// Tolerance absorbs floating-point noise only.
  bool get isSettled => currentPot.abs() < 0.005;

  /// Money still in play at this table: in − out − rake. Same formula as
  /// [SessionService.moneyStillInPlay], scoped to one table.
  final double currentPot;

  /// The house's take from this table. Mirrors
  /// [SessionService.hostProfit]: poker rake + house-banked game wins
  /// (Phase 7 — the two stay separately reported as [rake] /
  /// [houseWin]; this is only their sum).
  double get hostProfit => rake + houseWin;

  const TableSummary({
    required this.table,
    required this.playerCount,
    required this.moneyInPlay,
    required this.totalIn,
    this.moneyIn = 0,
    this.moneyOut = 0,
    this.cashOut = 0,
    this.tableCashOut = 0,
    this.rake = 0,
    this.cashDrop = 0,
    this.dealerTips = 0,
    this.reentry = 0,
    this.houseWin = 0,
    this.transferIn = 0,
    this.transferOut = 0,
    this.currentPot = 0,
  });

  static List<TableSummary> forSession(PokerSession session) {
    final tables = TableService.tablesFor(session);
    final firstId = tables.isEmpty ? null : tables.first.id;

    return tables.map((t) {
      // Legacy rows carry a null tableId meaning "the first table", so
      // the first table must absorb them or a pre-multi-table session
      // would report zero for everything.
      final txs = SessionService.transactionsForTable(
        session.id,
        t.id,
        isFirstTable: firstId == t.id,
      );

      double sum(TransactionType type) => txs
          .where((x) => x.type == type)
          .fold(0.0, (s, x) => s + x.amount);

      final buyIn = sum(TransactionType.buyIn);
      final rebuy = sum(TransactionType.rebuy);
      final cashOut = sum(TransactionType.cashOut);
      final tableCashOut = sum(TransactionType.tableCashOut);
      final rake = sum(TransactionType.rakeCollection);
      final drop = sum(TransactionType.cashDrop);
      final tips = sum(TransactionType.dealerTips);
      // Phase 7: carried chips committed to this table by players who
      // left another table (NOT a buy-in), and chips the house banked
      // from this table's players at house-banked games.
      final reentry = sum(TransactionType.reentry);
      final houseWin = sum(TransactionType.houseWin);
      // Money arriving with, and leaving with, players who changed table.
      final transferIn = sum(TransactionType.transferIn);
      final transferOut = sum(TransactionType.transferOut);

      // Money entering this table: bought in here, carried in by a move,
      // or committed by a re-entry with held chips (Phase 7).
      final moneyIn = buyIn + rebuy + transferIn + reentry;
      // Money leaving this table: paid out to players (cage redemption),
      // carried out of the table by a table cash-out (Phase 7 — the
      // chips stay the person's holding), retained by the house as rake,
      // banked by the house at a house-banked game (Phase 7), tipped to
      // the dealer, or carried away to another table. Each appears here
      // ONCE — they are not added anywhere else.
      final moneyOut =
          cashOut + tableCashOut + rake + houseWin + tips + transferOut;

      return TableSummary(
        table: t,
        playerCount: TableService.playerCountAt(session, t.id),
        moneyInPlay: TableService.moneyInPlayAt(session, t.id),
        totalIn: TableService.buyInsAt(session, t.id),
        moneyIn: moneyIn,
        moneyOut: moneyOut,
        cashOut: cashOut,
        tableCashOut: tableCashOut,
        rake: rake,
        cashDrop: drop,
        dealerTips: tips,
        reentry: reentry,
        houseWin: houseWin,
        transferIn: transferIn,
        transferOut: transferOut,
        // What is still physically on this table. Once the table is
        // fully settled this reaches zero, which is the reconciliation
        // rule: Money In = Money Out + Rake, with rake already inside
        // Money Out.
        currentPot: moneyIn - moneyOut,
      );
    }).toList();
  }
}

/// Convenience for callers that only have a session id.
List<PokerTable> tablesForSessionId(String sessionId) {
  final session = HiveService.sessions.get(sessionId);
  if (session == null) return const [];
  return TableService.tablesFor(session);
}
