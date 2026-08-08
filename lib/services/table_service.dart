import '../models/player.dart';
import '../models/session.dart';
import 'hive_service.dart';
import 'session_service.dart';

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
  final String id;
  final String name;
  final int seatCount;
  final int dealerSeat;

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
        ),
      ];
    }
    return raw.map(PokerTable.fromMap).toList();
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
        .where((p) => p.tableId == tableId || (isFirst && p.tableId == null))
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

  /// Money currently in play at one table — buy-ins + rebuys − cash-outs
  /// for the players sitting there.
  ///
  /// Purely informational, for the host's own overview. It is NOT part of
  /// the balance check: rake is collected for the house as a whole, so
  /// only the session-level figure reconciles.
  static double moneyInPlayAt(PokerSession session, String tableId) {
    var total = 0.0;
    for (final p in playersAt(session, tableId)) {
      total += SessionService.playerTotalIn(session.id, p.id) -
          SessionService.playerTotalCashOut(session.id, p.id);
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
  static Future<String> addTable(
    PokerSession session, {
    String? name,
    int seatCount = 9,
  }) async {
    SessionService.assertSessionActive(session.id);
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
    );
    await _persist(session, [...tables, table]);
    return table.id;
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

  /// Moves a player to another table.
  ///
  /// Only touches seating — the player's transactions are untouched and
  /// stay attached to the session, so the ledger and balance check are
  /// unaffected by a table change mid-game. Throws if the target seat is
  /// taken, which the UI prevents by only offering free seats.
  static Future<void> movePlayer(
    PokerSession session,
    Player player,
    String targetTableId, {
    int? seat,
  }) async {
    SessionService.assertSessionActive(session.id);
    final blocked = seatingBlocker(session, targetTableId);
    if (blocked != null) throw StateError(blocked);
    final target = tableById(session, targetTableId);
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

    // Normalise: a player at the first table stores that table's id
    // explicitly from now on, so seating is unambiguous going forward.
    player.tableId = targetTableId;
    player.seatNumber = chosen;
    await player.save();

    // NOTE ON HISTORY: the player's existing transactions deliberately
    // keep the tableId they were recorded with. A buy-in taken at Table 1
    // happened at Table 1 — rewriting it to Table 2 because the player
    // later moved would falsify the audit trail and make a per-table
    // timeline lie about where money actually changed hands. Only future
    // transactions follow them to the new table.
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

  const TableSummary({
    required this.table,
    required this.playerCount,
    required this.moneyInPlay,
    required this.totalIn,
  });

  static List<TableSummary> forSession(PokerSession session) {
    return TableService.tablesFor(session)
        .map((t) => TableSummary(
              table: t,
              playerCount: TableService.playerCountAt(session, t.id),
              moneyInPlay: TableService.moneyInPlayAt(session, t.id),
              totalIn: TableService.buyInsAt(session, t.id),
            ))
        .toList();
  }
}

/// Convenience for callers that only have a session id.
List<PokerTable> tablesForSessionId(String sessionId) {
  final session = HiveService.sessions.get(sessionId);
  if (session == null) return const [];
  return TableService.tablesFor(session);
}
