import 'package:uuid/uuid.dart';

import '../models/enums.dart';
import '../models/table_participation.dart';
import '../models/transaction.dart';
import 'hive_service.dart';

const _uuid = Uuid();

/// The money legs of one participation, DERIVED from the linked
/// transactions (P-1: no money is stored on the participation).
class ParticipationLegs {
  final double moneyIn; // buy-in + rebuy + transfer-in + re-entry
  final double moneyOut; // transfer-out + cash-out + table cash-out + house win
  final int legCount;

  const ParticipationLegs({
    required this.moneyIn,
    required this.moneyOut,
    required this.legCount,
  });

  double get net => moneyIn - moneyOut;
}

/// Table participation (Phase 6): the lifecycle of one person's
/// commitment to one table in one session.
///
/// P-1 INVARIANTS (enforced here)
///   * The entity stores identity + lifecycle ONLY; money is derived
///     from the linked transactions ([legsFor]).
///   * Exactly ONE open participation per (person-or-seat, table,
///     session): [openOrFind] returns the open one instead of
///     duplicating it.
///   * Every close writes exactly one closing leg elsewhere (the
///     transfer-out / cash-out / session-end transaction is stamped
///     with the participation id); the participation itself only
///     records when/why it closed.
///
/// DEGRADED MODE: if the participations box is not open (unit tests
/// that only open the money ledger), every operation is a silent
/// no-op — participation tracking is an overlay on the money ledger,
/// and the money ledger must never break because of it.
class ParticipationService {
  ParticipationService._();

  static bool get _boxOpen {
    try {
      HiveService.participations;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The open participation for this seat at this table in this
  /// session, or null.
  static TableParticipation? openFor({
    required String sessionId,
    required String seatPlayerId,
    required String tableId,
  }) {
    if (!_boxOpen) return null;
    for (final p in HiveService.participations.values) {
      if (p.sessionId != sessionId) continue;
      if (p.seatPlayerId != seatPlayerId) continue;
      if (p.tableId != tableId) continue;
      if (p.isOpen) return p;
    }
    return null;
  }

  /// Opens a participation for the seat's first money leg at the
  /// table — or returns the existing open one (P-1: one open per
  /// (person-or-seat, table, session)).
  ///
  /// [personId] null = an unlinked legacy seat (seat-scoped
  /// participation; no identity is ever invented).
  static TableParticipation openOrFind({
    required String sessionId,
    required String seatPlayerId,
    required String tableId,
    String? personId,
  }) {
    if (!_boxOpen) {
      throw StateError('Participation tracking is unavailable.');
    }
    final existing = openFor(
      sessionId: sessionId,
      seatPlayerId: seatPlayerId,
      tableId: tableId,
    );
    if (existing != null) return existing;

    final p = TableParticipation(
      id: _uuid.v4(),
      sessionId: sessionId,
      personId: (personId != null && personId.isNotEmpty) ? personId : null,
      tableId: tableId,
      seatPlayerId: seatPlayerId,
    );
    HiveService.participations.put(p.id, p);
    return p;
  }

  /// Stamps a recorded player money leg onto its participation.
  ///
  /// Called from [SessionService.recordTransaction] for player legs.
  /// Buy-in / rebuy / transfer-in OPEN (or join) the participation at
  /// the leg's table; transfer-out and cash-out stamp the open one
  /// (closing is the caller's step, which knows the reason). Table
  /// rows (no playerId) are never stamped.
  ///
  /// TRACKING NEVER BREAKS MONEY: any failure here is swallowed —
  /// participation is an overlay, and the money leg is the primary
  /// record. An unstamped leg settles exactly as before (P-1: money
  /// is derived from the transactions, not the participations).
  static void stampTransaction(LedgerTransaction tx) {
    if (!_boxOpen || tx.playerId == null) return;
    final tableId = tx.tableId;
    if (tableId == null || tableId.isEmpty) return;

    try {
      final t = tx.type;
      // A re-entry (Phase 7) OPENS the new participation the same way a
      // buy-in does: the player commits their carried chips to this
      // table. It is a commitment, not a purchase — no chips move and no
      // wallet event is written; the participation is how the ledger
      // records that the held chips are now committed at this table.
      final opens =
          t == TransactionType.buyIn ||
          t == TransactionType.rebuy ||
          t == TransactionType.transferIn ||
          t == TransactionType.reentry;

      TableParticipation? p;
      if (opens) {
        String? personId;
        try {
          personId = HiveService.players.get(tx.playerId!)?.personId;
        } catch (_) {}
        p = openOrFind(
          sessionId: tx.sessionId,
          seatPlayerId: tx.playerId!,
          tableId: tableId,
          personId: personId,
        );
      } else {
        // transfer-out / table-cash-out (Phase 7) / legacy cash-out:
        // stamp the open one at the leg's table, if there is one
        // (legacy flows without a tracked participation stay unstamped
        // — settlement is unaffected).
        p = openFor(
          sessionId: tx.sessionId,
          seatPlayerId: tx.playerId!,
          tableId: tableId,
        );
      }
      if (p == null) return;

      tx.participationId = p.id;
      p.save();
    } catch (_) {
      // Degrade silently — the money leg proceeds unstamped.
    }
  }

  /// Closes the participation with the given reason. Idempotent: an
  /// already-closed participation is returned unchanged.
  static TableParticipation? close(String participationId,
      {required ParticipationCloseReason reason}) {
    if (!_boxOpen) return null;
    final p = HiveService.participations.get(participationId);
    if (p == null) return null;
    if (p.isClosed) return p;
    p.status = ParticipationStatus.closed;
    p.closedAt = DateTime.now();
    p.closeReason = reason;
    p.save();
    return p;
  }

  /// Moves an open participation to a new table (a DRY seat move —
  /// the person moved without carrying money). The commitment follows
  /// the seat; no legs are involved.
  static void moveTable(String participationId, String newTableId) {
    if (!_boxOpen) return;
    final p = HiveService.participations.get(participationId);
    if (p == null || !p.isOpen) return;
    if (p.tableId == newTableId) return;
    p.tableId = newTableId;
    p.save();
  }

  /// Closes every open participation in the session (session end:
  /// the commitment ended with the session).
  static int closeOpenAtSessionEnd(String sessionId) {
    if (!_boxOpen) return 0;
    var closed = 0;
    for (final p in HiveService.participations.values.toList()) {
      if (p.sessionId != sessionId || !p.isOpen) continue;
      close(p.id, reason: ParticipationCloseReason.sessionEnd);
      closed++;
    }
    return closed;
  }

  /// The derived money legs of a participation (P-1: derived, never
  /// stored). Voided transactions are excluded, matching every other
  /// settlement figure.
  static ParticipationLegs legsFor(String participationId) {
    if (!_boxOpen) {
      return const ParticipationLegs(moneyIn: 0, moneyOut: 0, legCount: 0);
    }
    var moneyIn = 0.0;
    var moneyOut = 0.0;
    var count = 0;
    for (final t in HiveService.transactions.values) {
      if (t.participationId != participationId) continue;
      if (t.isVoided) continue;
      // Re-entry (Phase 7) is an in-leg of the commitment: the carried
      // chips are committed to this table (no purchase, no chips moved).
      final isIn = t.type == TransactionType.buyIn ||
          t.type == TransactionType.rebuy ||
          t.type == TransactionType.transferIn ||
          t.type == TransactionType.reentry;
      // Table cash-out (Phase 7) and house wins (Phase 7) are out-legs:
      // the commitment leaves this table (carried out) or is banked by
      // the house at a house-banked game.
      final isOut =
          t.type == TransactionType.transferOut ||
          t.type == TransactionType.cashOut ||
          t.type == TransactionType.tableCashOut ||
          t.type == TransactionType.houseWin;
      if (!isIn && !isOut) continue;
      if (isIn) {
        moneyIn += t.amount;
      } else {
        moneyOut += t.amount;
      }
      count++;
    }
    return ParticipationLegs(moneyIn: moneyIn, moneyOut: moneyOut, legCount: count);
  }

  /// Every participation in a session, newest first.
  static List<TableParticipation> forSession(String sessionId) {
    if (!_boxOpen) return const [];
    final list = HiveService.participations
        .values
        .where((p) => p.sessionId == sessionId)
        .toList()
      ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    return list;
  }

  /// The person's OPEN participations across all sessions (the
  /// wallet's derived reference — Phase 3 integration).
  static List<TableParticipation> openForPerson(String personId) {
    if (!_boxOpen) return const [];
    return HiveService.participations.values
        .where((p) => p.personId == personId && p.isOpen)
        .toList()
      ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
  }
}
