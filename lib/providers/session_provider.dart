import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../models/transaction.dart';
import '../services/hive_service.dart';
import '../services/session_service.dart';
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
  final List<StreamSubscription> _boxSubscriptions = [];
  bool _notifyScheduled = false;
  bool _disposed = false;

  SessionProvider() {
    _attachBoxWatchers();
  }

  void _attachBoxWatchers() {
    try {
      _boxSubscriptions.addAll([
        HiveService.players.watch().listen((_) => _scheduleNotify()),
        HiveService.transactions.watch().listen((_) => _scheduleNotify()),
        // The sessions watcher also refreshes the cached _current object.
        // Hive can hand back a different instance after a write from
        // another code path, and keeping the old one is how a stale
        // session (old house rules, old table list, old timer state)
        // survives until the banker reopens the session.
        HiveService.sessions.watch().listen((event) {
          if (_current != null && event.key == _current!.id) {
            final fresh = HiveService.sessions.get(_current!.id);
            if (fresh != null) _current = fresh;
          }
          _scheduleNotify();
        }),
      ]);
    } catch (_) {
      // Boxes not open (e.g. a unit test constructing the provider before
      // Hive init). The explicit notifyListeners() calls still cover every
      // mutation that goes through this class, so this is a degraded but
      // fully working mode, never a crash.
    }
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
      if (!_disposed) notifyListeners();
    });
  }

  /// Forces every listening screen to rebuild from Hive.
  ///
  /// Exposed for the rare in-place edit that mutates a model object's
  /// fields directly (the Edit Player sheet) — the write itself is picked
  /// up by the watchers, but calling this makes the refresh immediate
  /// rather than a microtask later.
  void refresh() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final sub in _boxSubscriptions) {
      sub.cancel();
    }
    _boxSubscriptions.clear();
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

  Future<void> removeTable(String tableId) async {
    if (_current == null) return;
    await TableService.removeTable(_current!, tableId);
    if (_activeTableId == tableId) _activeTableId = null;
    notifyListeners();
  }

  /// Moves a player between tables. Seating only — their transactions and
  /// the session balance are untouched.
  Future<void> movePlayerToTable(Player player, String tableId,
      {int? seat}) async {
    if (_current == null) return;
    await TableService.materialise(_current!);
    await TableService.movePlayer(_current!, player, tableId, seat: seat);
    notifyListeners();
  }

  List<Player> get players =>
      _current == null ? [] : SessionService.playersFor(_current!.id);

  List<LedgerTransaction> get transactions =>
      _current == null ? [] : SessionService.transactionsFor(_current!.id);

  double get totalBuyIn => _current == null ? 0 : SessionService.totalBuyIn(_current!.id);
  double get totalRebuy => _current == null ? 0 : SessionService.totalRebuy(_current!.id);
  double get totalCashOut => _current == null ? 0 : SessionService.totalCashOut(_current!.id);
  double get totalRake => _current == null ? 0 : SessionService.totalRake(_current!.id);
  double get totalCashDrop => _current == null ? 0 : SessionService.totalCashDrop(_current!.id);
  double get hostProfit => _current == null ? 0 : SessionService.hostProfit(_current!.id);
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
    final fresh = HiveService.sessions.get(_current!.id);
    if (fresh != null) _current = fresh;
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
  }) async {
    if (_current == null) throw StateError('No active session.');
    final player = Player(
      id: _uuid.v4(),
      sessionId: _current!.id,
      name: name,
      photoPath: photoPath,
      seatNumber: seatNumber,
      // New players are seated at whichever table the banker is looking
      // at. Single-table sessions pass null and keep the legacy shape.
      tableId: tableId ?? (isMultiTable ? activeTableId : null),
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
  }) async {
    final player = await addPlayer(
      name: name,
      seatNumber: seatNumber,
      photoPath: photoPath,
      tags: tags,
      sampleSignatureBase64: sampleSignatureBase64,
      sampleSignature2Base64: sampleSignature2Base64,
      tableId: tableId,
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
      notifyListeners();
    }
    return voided;
  }

  Future<void> redo() async {
    if (_current == null || _redoStack.isEmpty) return;
    final id = _redoStack.removeLast();
    await SessionService.redo(_current!.id, id);
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

  Future<void> voidTransactionById(String transactionId) async {
    await SessionService.voidTransaction(transactionId);
    notifyListeners();
  }

  Future<void> unvoidTransactionById(String transactionId) async {
    await SessionService.unvoidTransaction(transactionId);
    notifyListeners();
  }

  Future<void> deleteTransaction(String transactionId) async {
    await SessionService.deleteTransactionPermanently(transactionId);
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
    notifyListeners();
  }
}
