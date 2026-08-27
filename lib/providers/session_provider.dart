import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../models/transaction.dart';
import '../models/hand.dart';
import '../services/box_watch_hub.dart';
import '../services/hand_service.dart';
import '../services/hive_service.dart';
import '../services/participation_service.dart';
import '../services/player_identity_service.dart';
import '../services/session_service.dart';
import '../services/chip_tracking_service.dart';
import '../services/table_service.dart';
import '../services/tournament_service.dart';

const _uuid = Uuid();

/// Drives the active session screen: exposes live totals, players and the
/// transaction log, and re-notifies listeners after every mutation so the
/// dashboard always reflects the true state of the ledger.
class SessionProvider extends ChangeNotifier {
  PokerSession? _current;
  final List<String> _redoStack = []; // voided transaction ids available to redo

  /// Live subscriptions to the underlying Hive boxes.
  ///
  /// WHY THIS EXISTS — the live-refresh fix:
  /// Every getter on this provider reads straight from Hive on demand, so
  /// the data is always correct the moment something repaints. The bug was
  /// never stale data, it was a *missed repaint*: a screen only rebuilds
  /// when [notifyListeners] fires, and several write paths reached Hive
  /// without going through this provider —
  /// `SessionService.markPlayerSettled`, `advanceLevel`, `undoLast` and the
  /// transaction mutators all call `HiveObject.save()` directly, and
  /// `PlayersTab` mutates `player.name`/`seatNumber`/`tags` in place before
  /// saving. Any of those left the UI showing the previous frame until the
  /// session was closed and reopened (which re-ran `loadSession`, which
  /// *did* notify).
  ///
  /// Rather than hunt every call site and hope no future one is missed,
  /// the provider now listens to the boxes themselves. Hive fires these
  /// watchers on *any* write — including in-place `.save()` from deep
  /// inside a service — so a repaint is guaranteed regardless of which
  /// path performed the write. Per-call `notifyListeners()` is kept as
  /// well: it makes the update synchronous for the common path, while the
  /// watchers act as the safety net. Both are coalesced (see
  /// [_scheduleNotify]) so a burst of writes still causes only one rebuild.
  late final BoxWatchHub _watchHub;
  bool _notifyScheduled = false;
  bool _disposed = false;
  int _revision = 0;

  SessionProvider() {
    _watchHub = BoxWatchHub(onEvent: _onBoxEvent);
    attachWatchers();
  }

  /// Monotonic counter incremented on every listener notify. Screens can
  /// include it in a ValueKey so an IndexedStack child cannot keep a
  /// stale Element when the ledger changes.
  int get revision => _revision;

  bool get watchersHealthy =>
      _watchHub.isAttached('players') &&
      _watchHub.isAttached('transactions') &&
      _watchHub.isAttached('sessions');

  Set<String> get attachedWatcherNames => _watchHub.attachedNames;
  Set<String> get failedWatcherNames => _watchHub.failedNames;

  void _onBoxEvent() {
    _refreshCurrentFromBox();
    _scheduleNotify();
  }

  void _refreshCurrentFromBox() {
    if (_current == null) return;
    try {
      final fresh = HiveService.sessions.get(_current!.id);
      if (fresh != null) _current = fresh;
    } catch (_) {
      // Box not readable; keep the in-memory session.
    }
  }

  /// Attach (or retry) Hive watchers one box at a time.
  ///
  /// Safe to call repeatedly. Used from the constructor, [loadSession]
  /// and [reloadCurrent] so a cold start that constructed this provider
  /// before a box was open does not stay permanently stale.
  bool attachWatchers() {
    if (_disposed) return false;
    _watchHub.attach('players', () => HiveService.players.watch());
    _watchHub.attach('transactions', () => HiveService.transactions.watch());
    _watchHub.attach('sessions', () {
      return HiveService.sessions.watch().map((event) {
        if (_current != null && event.key == _current!.id) {
          _refreshCurrentFromBox();
        }
        return event;
      });
    });
    _watchHub.attach(
        'financialEvents', () => HiveService.financialEvents.watch());
    _watchHub.attach('hands', () => HiveService.hands.watch());
    return watchersHealthy;
  }

  /// Re-attempts any watcher that failed last time. Not a poll loop —
  /// called when a session is opened or the banker returns to the shell.
  bool retryFailedWatchers() {
    attachWatchers();
    return watchersHealthy;
  }

  /// Coalesces a burst of box events into a single rebuild.
  ///
  /// Seating nine players or recording a buy-in (which writes a player AND
  /// a transaction) would otherwise fire several notifications in the same
  /// frame and rebuild the whole session shell repeatedly. Collapsing them
  /// onto one microtask keeps the table smooth during rapid entry.
  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) {
        _revision++;
        notifyListeners();
      }
    });
  }

  /// Forces every listening screen to rebuild from Hive.
  ///
  /// Exposed for the rare in-place edit that mutates a model object's
  /// fields directly (the Edit Player sheet) — the write itself is picked
  /// up by the watchers, but calling this makes the refresh immediate
  /// rather than a microtask later.
  void refresh() {
    if (_disposed) return;
    attachWatchers();
    _refreshCurrentFromBox();
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _watchHub.dispose();
    super.dispose();
  }

  /// Which table the seating-oriented screens (Table view, Players) are
  /// currently showing. Null = the session's first table.
  ///
  /// This is view state, not stored data: money is session-wide, so the
  /// selected table only affects what is displayed and where a newly
  /// seated player lands.
  String? _activeTableId;

  PokerSession? get current => _current;

  /// The tables in this session (always at least one — a legacy session
  /// synthesises one from its existing table fields).
  List<PokerTable> get tables =>
      _current == null ? const [] : TableService.tablesFor(_current!);

  bool get isMultiTable =>
      _current != null && TableService.isMultiTable(_current!);

  String get activeTableId {
    final list = tables;
    if (list.isEmpty) return TableService.defaultTableId;
    if (_activeTableId != null && list.any((t) => t.id == _activeTableId)) {
      return _activeTableId!;
    }
    // Default to a table that is actually in play, so opening a session
    // never lands the banker on a table that was closed hours ago.
    final open = list.where((t) => !t.status.isClosed);
    return open.isNotEmpty ? open.first.id : list.first.id;
  }

  /// Tables still in play (active or paused).
  List<PokerTable> get openTables =>
      _current == null ? const [] : TableService.openTables(_current!);

  /// Status of the table currently being viewed.
  TableStatus get activeTableStatus => activeTable.status;

  PokerTable get activeTable =>
      TableService.tableById(_current!, activeTableId);

  void setActiveTable(String tableId) {
    _activeTableId = tableId;
    notifyListeners();
  }

  /// Re-reads a player from storage by id.
  ///
  /// Screens that were pushed with a Player object hold a snapshot taken
  /// at push time. If that player is then renamed, reseated or moved to
  /// another table, the pushed screen keeps showing the old values until
  /// it is closed and reopened — which is exactly the "Player page shows
  /// old Table information" bug. Those screens call this on every build
  /// so they always render live data.
  Player? playerById(String id) {
    final p = HiveService.players.get(id);
    if (p == null || _current == null) return p;
    return p.sessionId == _current!.id ? p : null;
  }

  /// Live player, falling back to the caller's snapshot if the record has
  /// been deleted, so a screen mid-navigation can never crash.
  Player livePlayer(Player snapshot) => playerById(snapshot.id) ?? snapshot;

  /// Players at the currently selected table.
  List<Player> get playersAtActiveTable => _current == null
      ? []
      : TableService.playersAt(_current!, activeTableId);

  List<TableSummary> get tableSummaries =>
      _current == null ? const [] : TableSummary.forSession(_current!);

  Future<void> addTable({String? name, int seatCount = 9}) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    final id = await TableService.addTable(_current!,
        name: name, seatCount: seatCount);
    _activeTableId = id;
    notifyListeners();
  }

  Future<void> renameTable(String tableId, String name) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.renameTable(_current!, tableId, name);
    notifyListeners();
  }

  Future<void> setTableSeatCountFor(String tableId, int seatCount) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.setSeatCount(_current!, tableId, seatCount);
    notifyListeners();
  }

  Future<void> moveDealerAt(String tableId) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.moveDealer(_current!, tableId);
    notifyListeners();
  }

  String? tableRemovalBlocker(String tableId) =>
      _current == null ? null : TableService.removalBlocker(_current!, tableId);

  /// Why this table can't be closed yet, or null when it can.
  String? tableCloseBlocker(String tableId) =>
      _current == null ? null : TableService.closeBlocker(_current!, tableId);

  Future<void> setTableStatus(String tableId, TableStatus status) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.setTableStatus(_current!, tableId, status);
    // If the banker just closed the table they were viewing, move them to
    // one that is still running rather than leaving them on a dead table.
    if (status.isClosed && _activeTableId == tableId) {
      final open = TableService.openTables(_current!);
      _activeTableId = open.isNotEmpty ? open.first.id : null;
    }
    notifyListeners();
  }

  Future<void> pauseTable(String tableId) =>
      setTableStatus(tableId, TableStatus.paused);

  Future<void> resumeTable(String tableId) =>
      setTableStatus(tableId, TableStatus.active);

  /// Closes a single table. The SESSION stays open — only End Session
  /// closes a session.
  Future<void> closeTable(String tableId) async {
    if (tableCloseBlocker(tableId) != null) return;
    await setTableStatus(tableId, TableStatus.closed);
  }

  Future<void> reopenTable(String tableId) =>
      setTableStatus(tableId, TableStatus.active);

  Future<void> startTableTimer(String tableId) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.startTableTimer(_current!, tableId);
    notifyListeners();
  }

  Future<void> pauseTableTimer(String tableId) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.pauseTableTimer(_current!, tableId);
    notifyListeners();
  }

  Future<void> resetTableTimer(String tableId) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.resetTableTimer(_current!, tableId);
    notifyListeners();
  }

  /// Stops this table's clock and returns it to zero, keeping the chosen
  /// duration so it can simply be started again.
  Future<void> stopTableTimer(String tableId) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.stopTableTimer(_current!, tableId);
    notifyListeners();
  }

  /// Sets (or clears, with null) this table's countdown duration.
  Future<void> setTableTimerDuration(String tableId, int? minutes) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.setTableTimerDuration(_current!, tableId, minutes);
    notifyListeners();
  }

  /// Returns a notice for ONE table whose countdown has just run out, or
  /// null. Polled by the session shell's existing one-second ticker, so
  /// no additional timer is introduced.
  ///
  /// Each table is evaluated independently: finishing table 1 has no
  /// effect on tables 2 and 3, which keep running and will raise their
  /// own notices when their own targets are reached. One notice is
  /// returned per tick so two simultaneous expiries produce two separate,
  /// correctly-labelled alerts rather than one merged message.
  ///
  /// Touches nothing but the table map — no money, no transactions.
  TableTimerNotice? consumeTableTimerNotice() {
    final session = _current;
    if (session == null || session.status == SessionStatus.ended) return null;

    for (final table in TableService.tablesFor(session)) {
      if (!table.hasTimer || table.finishNoticeShown) continue;
      if (!table.isFinished) continue;

      // Stop the clock at exactly the planned duration and flag the
      // notice as delivered, so this fires once and never goes negative.
      TableService.markTableTimerFinished(session, table.id);
      _scheduleNotify();
      return TableTimerNotice(
        tableId: table.id,
        tableName: table.name,
        plannedMinutes: table.plannedMinutes!,
      );
    }
    return null;
  }

  Future<void> removeTable(String tableId) async {
    if (_current == null) return;
    await TableService.removeTable(_current!, tableId);
    if (_activeTableId == tableId) _activeTableId = null;
    notifyListeners();
  }

  /// Moves a player between tables. Seating only — their transactions and
  /// the session balance are untouched.
  /// Moves a player to another table, carrying [amount] of money with
  /// them. See [TableService.movePlayer] for the accounting model.
  Future<void> movePlayerToTable(Player player, String tableId,
      {int? seat, double? amount}) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.movePlayer(_current!, player, tableId,
        seat: seat, amount: amount);
    notifyListeners();
  }

  List<Player> get players =>
      _current == null ? [] : SessionService.playersFor(_current!.id);

  List<LedgerTransaction> get transactions =>
      _current == null ? [] : SessionService.transactionsFor(_current!.id);

  double get totalBuyIn => _current == null ? 0 : SessionService.totalBuyIn(_current!.id);
  double get totalRebuy => _current == null ? 0 : SessionService.totalRebuy(_current!.id);
  double get totalCashOut => _current == null ? 0 : SessionService.totalCashOut(_current!.id);
  // Phase 7: carried chips committed via re-entry (session money IN,
  // never a purchase), and house-banked game revenue (reported
  // separately from rake).
  double get totalReentry => _current == null ? 0 : SessionService.totalReentry(_current!.id);
  double get totalHouseWin => _current == null ? 0 : SessionService.totalHouseWin(_current!.id);
  double get totalRake => _current == null ? 0 : SessionService.totalRake(_current!.id);
  double get totalCashDrop => _current == null ? 0 : SessionService.totalCashDrop(_current!.id);
  double get hostProfit => _current == null ? 0 : SessionService.hostProfit(_current!.id);

  /// Chips tipped to the dealer this session. Reported separately from
  /// [hostProfit] (rake + house wins). Tips are never host profit.
  double get totalDealerTips =>
      _current == null ? 0 : SessionService.totalDealerTips(_current!.id);
  double get moneyStillInPlay =>
      _current == null ? 0 : SessionService.moneyStillInPlay(_current!.id);
  int get currentLevel => _current?.currentLevel ?? 1;

  BalanceResult? get balance =>
      _current == null ? null : SessionService.checkBalance(_current!.id);

  bool get canUndo => transactions.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  Future<PokerSession> createSession({
    required String name,
    required String location,
    required DateTime dateTime,
    required double smallBlind,
    required double bigBlind,
    required double rakePercentage,
    required String tableNumber,
    required AppCurrency currency,
    String? hostName,
    double? buyInCapAmount,
    double? defaultBuyInAmount,
    RakeMode rakeMode = RakeMode.percentage,
    double? fixedRakeAmount,
    int rebuyLastLevel = 6,
    List<double>? quickRakeAmounts,
    SessionMode mode = SessionMode.cashGame,
    List<BlindLevel>? blindLevels,
    double? tournamentBuyIn,
    double? tournamentFee,
    double? tournamentRebuy,
    double? tournamentAddOn,
    int? startingStack,
    List<double>? payoutPercentages,
    bool rebateEnabled = false,
    double? rebateMinLoss,
    double? rebatePercent,
    DateTime? plannedEndAt,
  }) async {
    final session = PokerSession(
      id: _uuid.v4(),
      name: name,
      location: location,
      dateTime: dateTime,
      smallBlind: smallBlind,
      bigBlind: bigBlind,
      rakePercentage: rakePercentage,
      tableNumber: tableNumber,
      currency: currency,
      hostName: hostName,
      buyInCapAmount: buyInCapAmount,
      defaultBuyInAmount: defaultBuyInAmount,
      rakeMode: rakeMode,
      fixedRakeAmount: fixedRakeAmount,
      rebuyLastLevel: rebuyLastLevel,
      quickRakeAmounts: quickRakeAmounts,
      mode: mode,
      blindLevels: blindLevels?.map((l) => l.toMap()).toList(),
      tournamentBuyIn: tournamentBuyIn,
      tournamentFee: tournamentFee,
      tournamentRebuy: tournamentRebuy,
      tournamentAddOn: tournamentAddOn,
      startingStack: startingStack,
      payoutPercentages: payoutPercentages,
      rebateEnabled: rebateEnabled,
      rebateMinLoss: rebateMinLoss,
      rebatePercent: rebatePercent,
      plannedEndAt: plannedEndAt,
    );
    await HiveService.sessions.put(session.id, session);
    _current = session;
    notifyListeners();
    return session;
  }

  void loadSession(PokerSession session) {
    _current = session;
    _redoStack.clear();
    notifyListeners();
  }

  /// Re-reads the active session from storage. Used when returning to a
  /// session that may have been mutated elsewhere (e.g. House Rules edits
  /// applied from a pushed screen) so the shell never renders a stale copy.
  void reloadCurrent() {
    if (_current == null) return;
    attachWatchers();
    _refreshCurrentFromBox();
    _revision++;
    notifyListeners();
  }

  Future<Player> addPlayer({
    required String name,
    String? photoPath,
    required int seatNumber,
    List<PlayerTag>? tags,
    String? sampleSignatureBase64,
    /// Second reference specimen, captured in the same Add Player step.
    ///
    /// Optional and defaulting to null so every existing caller keeps
    /// working and players created with only one sample stay valid.
    String? sampleSignature2Base64,
    String? tableId,
    /// Permanent identity to attach to this seat. Null leaves the seat
    /// unlinked — the correct state for every caller that has not gone
    /// through confirm-on-suggest. This method never invents or
    /// suggests a personId.
    String? personId,
  }) async {
    if (_current == null) throw StateError('No active session.');

    // Materialise BEFORE any table inference.
    //
    // `tablesFor()` synthesises a single table for a session whose
    // `tables` list was never written, WITHOUT persisting it — so
    // `isMultiTable` reported false even when the banker had already
    // opened a second table, and the player below was stored with a null
    // tableId. A null tableId is only ever visible on the FIRST table, so
    // the player silently vanished from the table the banker was
    // standing at. Every other table mutator already materialises first;
    // this path was the one that did not.
    //
    // Cheap and idempotent: it returns immediately once tables exist.
    if (tableId == null) {
      await TableService.materialise(_current!);
    }

    // Resolve the destination ONCE, so the value written is the value
    // that was reasoned about.
    //
    // An explicitly supplied tableId always wins — when Add Player was
    // opened from a specific table, that table is the answer and nothing
    // should be inferred. Only the table-less entry points (Players tab,
    // app-bar button) fall back to the previous behaviour, which keeps
    // single-table sessions writing null exactly as before.
    final resolvedTableId =
        tableId ?? (isMultiTable ? activeTableId : null);

    final player = Player(
      id: _uuid.v4(),
      sessionId: _current!.id,
      name: name,
      photoPath: photoPath,
      seatNumber: seatNumber,
      tableId: resolvedTableId,
      tags: tags,
      sampleSignatureBase64:
          (sampleSignatureBase64 != null && sampleSignatureBase64.isNotEmpty)
              ? sampleSignatureBase64
              : null,
      sampleSignatureAt:
          (sampleSignatureBase64 != null && sampleSignatureBase64.isNotEmpty)
              ? DateTime.now()
              : null,
      // Sample 2 is persisted here for exactly the same reason as Sample
      // 1: it is captured during Add Player, so it must reach the record
      // at creation. Previously it was dropped, which left Timeline's
      // "Sample 2" area blank until the banker re-signed it from Edit
      // Player. Same null/empty guard, so an unsigned pad stays null
      // rather than storing an empty string.
      sampleSignature2Base64:
          (sampleSignature2Base64 != null && sampleSignature2Base64.isNotEmpty)
              ? sampleSignature2Base64
              : null,
      sampleSignature2At:
          (sampleSignature2Base64 != null && sampleSignature2Base64.isNotEmpty)
              ? DateTime.now()
              : null,
      personId: personId,
    );
    await HiveService.players.put(player.id, player);
    notifyListeners();
    return player;
  }

  /// The fast path a banker actually uses at the table: seat a player and
  /// record their opening buy-in in one action, instead of creating the
  /// player then navigating to a separate screen to log the buy-in.
  /// [buyInAmount] of 0/null skips the buy-in transaction (e.g. someone
  /// railing who hasn't bought in yet).
  Future<Player> addPlayerWithBuyIn({
    required String name,
    required int seatNumber,
    required double? buyInAmount,
    required String? hostSignatureBase64,
    String? photoPath,
    List<PlayerTag>? tags,
    String? sampleSignatureBase64,
    String? sampleSignature2Base64,
    String? tableId,
    String? personId,
  }) async {
    final player = await addPlayer(
      name: name,
      seatNumber: seatNumber,
      photoPath: photoPath,
      tags: tags,
      sampleSignatureBase64: sampleSignatureBase64,
      sampleSignature2Base64: sampleSignature2Base64,
      tableId: tableId,
      personId: personId,
    );
    if (buyInAmount != null && buyInAmount > 0) {
      if (hostSignatureBase64 == null || hostSignatureBase64.isEmpty) {
        throw StateError('A host signature is required to confirm the opening buy-in.');
      }
      await recordTransaction(
        playerId: player.id,
        type: TransactionType.buyIn,
        amount: buyInAmount,
        hostSignatureBase64: hostSignatureBase64,
      );
    }
    return player;
  }

  // ---------------------------------------------------------------
  // Pre-seat registration (Phase 1).
  //
  // Registration and seating are separate concepts:
  //   * registerPlayer  — the person exists in this session, no seat.
  //   * seatRegisteredPlayer — the registration takes a table + seat.
  //   * unseatPlayer — the registration gives up its seat and stays.
  //   * removeRegistration — deletes ONLY a clean unseated row.
  //
  // Seating operations never write a transaction, a financial event or
  // a chip movement: they move the seat pointer on an existing row and
  // nothing else. Financial history therefore survives every seat
  // change by construction.
  // ---------------------------------------------------------------

  /// Registered (not seated) players in the active session.
  List<Player> get unseatedPlayers =>
      _current == null ? const [] : SessionService.unseatedPlayersFor(_current!.id);

  /// Seated players in the active session.
  List<Player> get seatedPlayers =>
      _current == null ? const [] : SessionService.seatedPlayersFor(_current!.id);

  /// Registers [personId] for the active session without giving them a
  /// seat.
  ///
  /// Idempotent per (session, person): if the person already has a row
  /// in this session — seated or not — that row is returned unchanged.
  /// [personId] must already exist (created/confirmed by the caller
  /// through [PlayerIdentityService]); this method never invents or
  /// links identities.
  Future<Player> registerPlayer({
    required String personId,
    required String name,
  }) async {
    if (_current == null) throw StateError('No active session.');
    if (personId.trim().isEmpty) {
      throw StateError('A registered player needs a confirmed person.');
    }
    final existing = SessionService.registeredForSession(_current!.id, personId);
    if (existing != null) return existing;

    final player = Player(
      id: _uuid.v4(),
      sessionId: _current!.id,
      name: name.trim().isEmpty ? (PlayerIdentityService.byId(personId)?.displayName ?? '') : name.trim(),
      seatNumber: 0, // placeholder — no seat logic reads it while unseated
      tableId: null,
      personId: personId,
      seated: false,
    );
    await HiveService.players.put(player.id, player);
    notifyListeners();
    return player;
  }

  /// Seats a registered (unseated) player at [tableId].
  ///
  /// [seat] null takes the first free seat. The move writes ONLY the
  /// seat fields on the existing row — no transaction, no financial
  /// event, no chip movement. The opening buy-in, when the banker
  /// wants one, is recorded afterwards through the normal money flow.
  Future<Player> seatRegisteredPlayer(Player player, String tableId,
      {int? seat}) async {
    if (_current == null) throw StateError('No active session.');
    if (player.seated) return player; // already seated — nothing to do
    SessionService.assertSessionActive(_current!.id);
    // Materialise so the destination table is explicit on the session,
    // matching the add-player path (a synthesized table id stored on
    // the player would outlive the session's implicit table).
    await TableService.materialise(_current!);

    final blocked = TableService.seatingBlocker(_current!, tableId);
    if (blocked != null) throw StateError(blocked);
    final target = TableService.tableById(_current!, tableId);
    final taken = TableService.occupiedSeats(_current!, tableId,
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

    player.tableId = tableId;
    player.seatNumber = chosen;
    player.seated = true;
    await player.save();
    notifyListeners();
    return player;
  }

  /// RE-ENTRY (Phase 7): seats the unseated [player] at [tableId] using
  /// the chips they already hold, and records the `reentry` commitment.
  ///
  /// See [TableService.reenterWithHeldChips] for the financial model:
  /// ONE re-entry money leg (NOT a buy-in — the original purchase is
  /// never counted again), NO chip movement (the held chips travel with
  /// the person), NO Financial Ledger event (no cash changes hands),
  /// and a NEW TableParticipation at the destination.

  /// Latest non-voided hand at the table being viewed.
  Hand? get lastHandAtActiveTable {
    if (_current == null) return null;
    return HandService.lastForTable(_current!.id, activeTableId);
  }

  Future<Hand> recordHand({
    required String tableId,
    required HandKind kind,
    required List<HandResultDraft> drafts,
    double? potAmount,
    double rakeAmount = 0,
    double houseWinAmount = 0,
    String? note,
    String? hostSignatureBase64,
    Map<String, Map<String, int>>? postHandCounts,
    Map<String, int>? rakeChips,
    Map<String, Map<String, int>>? houseWinChipsByPlayer,
  }) async {
    if (_current == null) throw StateError('No active session.');
    final hand = await HandService.record(
      sessionId: _current!.id,
      tableId: tableId,
      kind: kind,
      drafts: drafts,
      potAmount: potAmount,
      rakeAmount: rakeAmount,
      houseWinAmount: houseWinAmount,
      note: note,
      hostSignatureBase64: hostSignatureBase64,
      postHandCounts: postHandCounts,
      rakeChips: rakeChips,
      houseWinChipsByPlayer: houseWinChipsByPlayer,
    );
    notifyListeners();
    return hand;
  }

  Future<Hand> voidHand(String handId) async {
    final hand = await HandService.voidHand(handId);
    notifyListeners();
    return hand;
  }

  Future<LedgerTransaction> reenterWithHeldChips(
    Player player,
    String tableId, {
    int? seat,
    required double amount,
    required String hostSignatureBase64,
    String? note,
  }) async {
    if (_current == null) throw StateError('No active session.');
    await TableService.materialise(_current!);
    final tx = await TableService.reenterWithHeldChips(
      _current!,
      player,
      tableId,
      seat: seat,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      note: note,
    );
    _redoStack.clear();
    notifyListeners();
    return tx;
  }

  /// Removes the player from their seat; the registration (and every
  /// record attached to it) stays in the session.
  ///
  /// The only writes are `seated = false` and `tableId = null`.
  /// seatNumber is kept as history, transactions / financial events /
  /// chip movements / the person link are untouched, and the freed
  /// seat is immediately available to another player.
  Future<void> unseatPlayer(Player player) async {
    if (_current == null) throw StateError('No active session.');
    if (!player.seated) return; // already unseated — idempotent
    SessionService.assertSessionActive(_current!.id);
    player.seated = false;
    player.tableId = null;
    await player.save();
    notifyListeners();
  }

  /// Deletes an unseated registration row.
  ///
  /// Refused whenever the row carries this session's records
  /// (transactions, voided or not) — deleting history is exactly what
  /// this phase must not do. A clean registration row (never seated,
  /// never recorded) may be deleted; the underlying person identity
  /// and all cross-session financial history survive either way.
  Future<void> removeRegistration(Player player) async {
    if (_current == null) throw StateError('No active session.');
    if (player.seated) {
      throw StateError(
          'This player is seated. Remove them from the seat first.');
    }
    SessionService.assertSessionActive(_current!.id);
    final hasRecords = SessionService
            .transactionsFor(_current!.id, includeVoided: true)
            .any((t) => t.playerId == player.id);
    if (hasRecords) {
      throw StateError(
          'This player has records in this session and cannot be removed. '
          'Remove them from the seat instead.');
    }
    await HiveService.players.delete(player.id);
    notifyListeners();
  }

  /// Stores (or replaces) the player's reference signature specimen.
  /// Re-stamps the capture date so a host can always tell how current
  /// the sample on file is.
  /// Stores the SECOND reference signature.
  Future<void> setPlayerSampleSignature2(
      Player player, String? base64Png) async {
    if (base64Png == null || base64Png.isEmpty) {
      player.sampleSignature2Base64 = null;
      player.sampleSignature2At = null;
    } else {
      player.sampleSignature2Base64 = base64Png;
      player.sampleSignature2At = DateTime.now();
    }
    await player.save();
    notifyListeners();
  }

  Future<void> setPlayerSampleSignature(Player player, String? base64Png) async {
    if (base64Png == null || base64Png.isEmpty) {
      player.sampleSignatureBase64 = null;
      player.sampleSignatureAt = null;
    } else {
      player.sampleSignatureBase64 = base64Png;
      player.sampleSignatureAt = DateTime.now();
    }
    await player.save();
    notifyListeners();
  }

  Future<void> updatePlayer(Player player) async {
    await player.save();
    // A rename updates the identity's display spelling only. The
    // personId itself never changes here — that would be a merge.
    final linkedId = player.personId;
    if (linkedId != null && linkedId.isNotEmpty) {
      await PlayerIdentityService.touchDisplayName(linkedId, player.name);
    }
    notifyListeners();
  }

  Future<void> toggleFavorite(Player player) async {
    player.isFavorite = !player.isFavorite;
    await player.save();
    notifyListeners();
  }

  /// Host-controlled: mark a player settled/left the table, or bring them
  /// back to "playing". Never inferred from a balance calculation.
  Future<void> toggleSettled(Player player) async {
    await SessionService.markPlayerSettled(player, settled: player.isActive);
    notifyListeners();
  }

  // ---------------------------------------------------------------
  // Simple cash-game session timer.
  //
  // A countdown the banker opts into, with a warning near the end. It
  // never blocks anything and never auto-ends the session — ending is
  // always a deliberate action, because money is on the table.
  // ---------------------------------------------------------------

  /// Sets (or clears, with null) the planned session length.
  Future<void> setPlannedMinutes(int? minutes) async {
    if (_current == null) return;
    _current!.plannedMinutes = (minutes != null && minutes > 0) ? minutes : null;
    // Re-arm both notices so changing the duration mid-session behaves
    // sensibly rather than staying permanently "already warned".
    _current!.tenMinuteWarningShown = false;
    _current!.finishNoticeShown = false;
    await _current!.save();
    notifyListeners();
  }

  Duration? get timeRemaining => _current?.timeRemaining;
  bool get hasTimer => _current?.hasTimer ?? false;

  /// Returns a notice to show once, or null. Called from the shell's
  /// existing one-second ticker, so no extra timer is introduced.
  SessionTimerNotice? consumeTimerNotice() {
    final s = _current;
    if (s == null || !s.hasTimer || s.status == SessionStatus.ended) return null;
    final left = s.timeRemaining;
    if (left == null) return null;

    if (left == Duration.zero && !s.finishNoticeShown) {
      s.finishNoticeShown = true;
      s.tenMinuteWarningShown = true;
      s.save();
      return SessionTimerNotice.finished;
    }
    if (left > Duration.zero &&
        left <= const Duration(minutes: 10) &&
        !s.tenMinuteWarningShown) {
      s.tenMinuteWarningShown = true;
      s.save();
      return SessionTimerNotice.tenMinutes;
    }
    return null;
  }

  // ---------------------------------------------------------------
  // Tournament mode.
  //
  // Entirely separate from cash-game settlement: none of these touch
  // checkBalance or any cash-game money path.
  // ---------------------------------------------------------------

  bool get isTournament => _current?.isTournament ?? false;

  List<BlindLevel> get blindLevels =>
      _current == null ? const [] : TournamentService.levelsFor(_current!);

  BlindLevel? get currentBlindLevel =>
      _current == null ? null : TournamentService.currentLevel(_current!);

  BlindLevel? get nextBlindLevel =>
      _current == null ? null : TournamentService.nextLevel(_current!);

  Duration get blindTimeRemaining => _current == null
      ? Duration.zero
      : TournamentService.remainingInLevel(_current!);

  bool get blindTimerRunning => _current?.blindTimerRunning ?? false;

  double get prizePool =>
      _current == null ? 0 : TournamentService.prizePool(_current!);

  double get remainingPrizePool =>
      _current == null ? 0 : TournamentService.remainingPool(_current!);

  double get houseFee =>
      _current == null ? 0 : TournamentService.houseFee(_current!);

  int get entryCount =>
      _current == null ? 0 : TournamentService.entryCount(_current!);

  List<PayoutSpot> get payoutTable =>
      _current == null ? const [] : TournamentService.payoutTable(_current!);

  List<Player> get activePlayers =>
      _current == null ? const [] : TournamentService.activePlayers(_current!.id);

  List<Player> get eliminatedPlayers => _current == null
      ? const []
      : TournamentService.eliminatedPlayers(_current!.id);

  Future<void> startBlindTimer() async {
    if (_current == null) return;
    await TournamentService.startTimer(_current!);
    notifyListeners();
  }

  Future<void> pauseBlindTimer() async {
    if (_current == null) return;
    await TournamentService.pauseTimer(_current!);
    notifyListeners();
  }

  Future<void> resetBlindLevel() async {
    if (_current == null) return;
    await TournamentService.resetLevel(_current!);
    notifyListeners();
  }

  Future<void> nextBlind() async {
    if (_current == null) return;
    await TournamentService.advanceLevel(_current!);
    notifyListeners();
  }

  Future<void> previousBlind() async {
    if (_current == null) return;
    await TournamentService.previousLevel(_current!);
    notifyListeners();
  }

  Future<void> saveBlindStructure(List<BlindLevel> levels) async {
    if (_current == null) return;
    await TournamentService.saveStructure(_current!, levels);
    notifyListeners();
  }

  Future<void> savePayoutPercentages(List<double> pcts) async {
    if (_current == null) return;
    await TournamentService.savePayouts(_current!, pcts);
    notifyListeners();
  }

  Future<int> eliminatePlayer(Player player) async {
    if (_current == null) return 0;
    final pos = await TournamentService.eliminatePlayer(_current!, player);
    notifyListeners();
    return pos;
  }

  Future<void> reinstatePlayer(Player player) async {
    if (_current == null) return;
    await TournamentService.reinstatePlayer(_current!, player);
    notifyListeners();
  }

  Future<Player?> finaliseWinner() async {
    if (_current == null) return null;
    final w = await TournamentService.finaliseWinner(_current!);
    notifyListeners();
    return w;
  }

  /// Blind-timer notice for the shell's existing ticker.
  BlindTimerNotice? consumeBlindNotice() =>
      _current == null ? null : TournamentService.consumeNotice(_current!);

  Future<void> advanceLevel() async {
    if (_current == null) return;
    await SessionService.advanceLevel(_current!);
    notifyListeners();
  }

  Future<LedgerTransaction> recordTransaction({
    String? playerId,
    required TransactionType type,
    required double amount,
    required String hostSignatureBase64,
    String? note,
    String? voiceNotePath,
    String? tableId,
  }) async {
    if (_current == null) throw StateError('No active session.');
    final tx = await SessionService.recordTransaction(
      sessionId: _current!.id,
      playerId: playerId,
      type: type,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      note: note,
      voiceNotePath: voiceNotePath,
      // Table-level rows (rake, cash drop) are attributed to the table
      // the banker is currently working at. Player rows resolve their own
      // table inside the service, from the player record.
      tableId: tableId ?? (isMultiTable ? activeTableId : null),
    );
    _redoStack.clear();
    notifyListeners();
    return tx;
  }

  /// Voids the most recent transaction and returns it, so the caller can
  /// tell the banker exactly what was just undone — after a burst of
  /// quick actions, "Undo" alone doesn't say which one it reversed.
  LedgerTransaction? undo() {
    if (_current == null) return null;
    final voided = SessionService.undoLast(_current!.id);
    if (voided != null) {
      _redoStack.add(voided.id);
      // Undo is a void by another name — the chips must come back too.
      //
      // This method is deliberately synchronous: callers use its return
      // value to name the transaction they just undid. The chip reversal
      // is asynchronous, so it is sequenced with `then` rather than
      // dropped — notifying again on completion means the Bank figure
      // refreshes once the movements are actually on disk, instead of
      // the UI reading a half-written ledger. Errors are surfaced in
      // debug rather than silently swallowed; the money undo has already
      // succeeded by this point and is never rolled back by a chip
      // failure.
      // `ignore: discarded_futures` is not used: the future IS handled,
      // just not awaited. Written with unawaited-style chaining that
      // needs no extra import for the movement type.
      ChipTrackingService.reverseForTransaction(voided.id, note: 'undo')
          .then(
        (_) => notifyListeners(),
        onError: (Object e) => debugPrint(
            'Chip reversal failed for undo of ${voided.id}: $e'),
      );
      notifyListeners();
    }
    return voided;
  }

  Future<void> redo() async {
    if (_current == null || _redoStack.isEmpty) return;
    final id = _redoStack.removeLast();
    await SessionService.redo(_current!.id, id);
    // Redo un-voids, so the chips it took back must go out again.
    await ChipTrackingService.reapplyForTransaction(id);
    notifyListeners();
  }

  /// Pre-fill helper for the fast workflow: last amount this player was
  /// given for [type], falling back to the session's default entry fee.
  /// Pre-fill helper for the fast workflow: last amount this player was
  /// given for [type], falling back to the session's default entry fee —
  /// but ONLY for buy-in/rebuy. A cash-out must NEVER pre-fill from the
  /// buy-in default: a player's first cash-out of the night has no prior
  /// cash-out to reuse, and silently reusing the entry-fee amount there
  /// produces a pre-filled number with no relationship to what the player
  /// is actually owed — exactly the kind of number a banker on autopilot
  /// could tap through without rereading. Cash-out simply starts blank.
  double? lastAmountFor(String playerId, TransactionType type) {
    if (_current == null) return null;
    final last = SessionService.lastAmountForPlayer(_current!.id, playerId, type);
    if (last != null) return last;
    if (type == TransactionType.cashOut) return null;
    return _current!.defaultBuyInAmount;
  }

  Future<LedgerTransaction> updateTransaction({
    required String transactionId,
    required double amount,
    String? note,
    String? hostSignatureBase64,
  }) async {
    final tx = await SessionService.updateTransaction(
      transactionId: transactionId,
      amount: amount,
      note: note,
      hostSignatureBase64: hostSignatureBase64,
    );
    notifyListeners();
    return tx;
  }

  /// Voids a transaction AND reverses its physical chip movements.
  ///
  /// Leaving the chips in place would make the Bank wrong: the money is
  /// gone from the ledger but the chips would still read as handed out.
  /// The reversal is appended, never deleted, so the history still shows
  /// the original movement and the correction.
  Future<void> voidTransactionById(String transactionId) async {
    await SessionService.voidTransaction(transactionId);
    await ChipTrackingService.reverseForTransaction(transactionId,
        note: 'void');
    notifyListeners();
  }

  /// Restores a voided transaction and re-applies the exact chip
  /// composition that was reversed, denomination for denomination.
  Future<void> unvoidTransactionById(String transactionId) async {
    await SessionService.unvoidTransaction(transactionId);
    await ChipTrackingService.reapplyForTransaction(transactionId);
    notifyListeners();
  }

  /// Permanent removal. Unlike void this is not an audit event the
  /// banker will revisit, so the chip records go with it rather than
  /// leaving orphaned movements pointing at a transaction that no
  /// longer exists.
  Future<void> deleteTransaction(String transactionId) async {
    await SessionService.deleteTransactionPermanently(transactionId);
    await ChipTrackingService.deleteForTransaction(transactionId);
    notifyListeners();
  }

  /// Persists edits made on the House Rules screen directly onto the
  /// current session — these are genuinely per-game, banker-editable
  /// settings, not fixed app constants.
  Future<void> updateHouseRules({
    double? buyInCapAmount,
    double? defaultBuyInAmount,
    int? rebuyLastLevel,
    RakeMode? rakeMode,
    double? rakePercentage,
    double? fixedRakeAmount,
    List<Map>? tieredRakeRules,
    double? tieredMaxRake,
    double? tieredNoRakeAtOrAbove,
    List<double>? quickRakeAmounts,
    bool? rebuyLevelEnforcementEnabled,
    bool? rebateEnabled,
    double? rebateMinLoss,
    double? rebatePercent,
    DateTime? plannedEndAt,
    bool clearPlannedEndAt = false,
  }) async {
    if (_current == null) return;
    final s = _current!;
    s.buyInCapAmount = buyInCapAmount;
    s.defaultBuyInAmount = defaultBuyInAmount;
    if (rebuyLastLevel != null) s.rebuyLastLevel = rebuyLastLevel;
    if (rakeMode != null) s.rakeMode = rakeMode;
    if (rakePercentage != null) s.rakePercentage = rakePercentage;
    s.fixedRakeAmount = fixedRakeAmount;
    if (tieredRakeRules != null) s.tieredRakeRules = tieredRakeRules;
    s.tieredMaxRake = tieredMaxRake;
    s.tieredNoRakeAtOrAbove = tieredNoRakeAtOrAbove;
    if (quickRakeAmounts != null) s.quickRakeAmounts = quickRakeAmounts;
    if (rebuyLevelEnforcementEnabled != null) {
      s.rebuyLevelEnforcementEnabled = rebuyLevelEnforcementEnabled;
    }
    if (rebateEnabled != null) s.rebateEnabled = rebateEnabled;
    if (rebateMinLoss != null) s.rebateMinLoss = rebateMinLoss;
    if (rebatePercent != null) s.rebatePercent = rebatePercent;
    if (clearPlannedEndAt) {
      s.plannedEndAt = null;
    } else if (plannedEndAt != null) {
      s.plannedEndAt = plannedEndAt;
    }
    await s.save();
    notifyListeners();
  }

  Future<void> setTableSeatCount(int count) async {
    if (_current == null) return;
    _current!.tableSeatCount = count;
    if (_current!.dealerSeatIndex > count) _current!.dealerSeatIndex = 1;
    await _current!.save();
    notifyListeners();
  }

  /// Advances the dealer button clockwise to the next OCCUPIED seat when
  /// possible (falls back to simply cycling the seat number if the table
  /// is empty or has one player) — matches how a real dealer button moves.
  Future<void> moveDealerButton() async {
    if (_current == null) return;
    final s = _current!;
    final occupiedSeats = players.map((p) => p.seatNumber).toSet();
    int next = s.dealerSeatIndex;
    for (int i = 0; i < s.tableSeatCount; i++) {
      next = next % s.tableSeatCount + 1;
      if (occupiedSeats.isEmpty || occupiedSeats.contains(next)) break;
    }
    s.dealerSeatIndex = next;
    await s.save();
    notifyListeners();
  }

  Future<void> startBreak() async {
    if (_current == null || _current!.status == SessionStatus.ended) return;
    _current!.status = SessionStatus.onBreak;
    _current!.breakStartedAt = DateTime.now();
    await _current!.save();
    notifyListeners();
  }

  Future<void> endBreak() async {
    if (_current == null ||
        _current!.breakStartedAt == null ||
        _current!.status == SessionStatus.ended) {
      return;
    }
    final seconds = DateTime.now().difference(_current!.breakStartedAt!).inSeconds;
    _current!.totalBreakSeconds += seconds;
    _current!.breakStartedAt = null;
    _current!.status = SessionStatus.active;
    await _current!.save();
    notifyListeners();
  }

  Future<void> endSession() async {
    if (_current == null) return;
    _current!.status = SessionStatus.ended;
    _current!.endedAt = DateTime.now();
    await _current!.save();
    // Phase 6: the session's commitments end with the session — every
    // still-open participation closes with reason sessionEnd.
    ParticipationService.closeOpenAtSessionEnd(_current!.id);
    notifyListeners();
  }
}
