import '../models/player.dart';
import '../models/session.dart';
import '../models/table_operation_event.dart';
import 'player_operation_guard.dart';
import 'table_operation_event_service.dart';
import 'table_service.dart';

/// Operational table workflows that are explicitly NOT financial:
/// same-table seat change, temporary absence, return from absence, and
/// unseat/leave without cash-out.
///
/// These write no ledger transaction, no ChipMovement, no buy-in/cash-out
/// and no transfer leg. Their only persist is the Player seat pointer (for
/// seat change/unseat) and the append-only [TableOperationEvent] audit
/// record.
class TableMovementService {
  TableMovementService._();

  /// Same-table seat change. Non-financial.
  static Future<void> changeSeat(
    PokerSession session,
    Player player,
    int destinationSeat, {
    String? operatorName,
    String? reason,
  }) async {
    PlayerOperationGuard.requireRegistered(player, 'a seat change');
    if (!player.seated) {
      throw StateError('This player is not seated.');
    }
    final table = TableService.tableForPlayer(session, player);
    if (destinationSeat < 1 || destinationSeat > table.seatCount) {
      throw StateError('Seat $destinationSeat is outside the table.');
    }
    final sourceSeat = player.seatNumber;
    if (sourceSeat == destinationSeat) {
      throw StateError('The player is already in that seat.');
    }
    final taken = TableService.occupiedSeats(
      session,
      table.id,
      excludePlayerId: player.id,
    );
    if (taken.contains(destinationSeat)) {
      throw StateError('Seat $destinationSeat is already occupied.');
    }

    player.seatNumber = destinationSeat;
    await player.save();

    await TableOperationEventService.append(TableOperationEvent(
      id: TableOperationEventService.newId(),
      operation: TableOperationType.seatChange,
      playerId: player.id,
      personId: player.personId,
      sourceTableId: table.id,
      sourceSeat: sourceSeat,
      destinationTableId: table.id,
      destinationSeat: destinationSeat,
      reason: reason,
      operatorName: operatorName,
    ));
  }

  /// Temporary absence (locked J5). Player identity, seat, participation
  /// and stack/table association are all preserved. No ledger, no chips.
  static Future<void> startTemporaryAbsence(
    PokerSession session,
    Player player, {
    String? operatorName,
    String? reason,
  }) async {
    PlayerOperationGuard.requireRegistered(player, 'temporary absence');
    if (!player.seated) {
      throw StateError('This player is not seated.');
    }
    await TableOperationEventService.append(TableOperationEvent(
      id: TableOperationEventService.newId(),
      operation: TableOperationType.temporaryAbsence,
      playerId: player.id,
      personId: player.personId,
      sourceTableId: player.tableId,
      sourceSeat: player.seatNumber,
      reason: reason ?? 'temporary absence',
      operatorName: operatorName,
    ));
  }

  /// Marks the end of a temporary absence. The seat/participation were
  /// never changed, so returning preserves them exactly.
  static Future<void> endTemporaryAbsence(
    PokerSession session,
    Player player, {
    String? operatorName,
    String? reason,
  }) async {
    PlayerOperationGuard.requireRegistered(player, 'returning from absence');
    if (!player.seated) {
      throw StateError('This player is not seated.');
    }
    await TableOperationEventService.append(TableOperationEvent(
      id: TableOperationEventService.newId(),
      operation: TableOperationType.returnFromAbsence,
      playerId: player.id,
      personId: player.personId,
      sourceTableId: player.tableId,
      sourceSeat: player.seatNumber,
      reason: reason ?? 'returned',
      operatorName: operatorName,
    ));
  }

  /// Unseat / leave WITHOUT cash-out (locked J6).
  ///
  /// * The seat becomes available.
  /// * Identity and history remain.
  /// * No Money Out and no cash-out/table-cash-out/transfer is written.
  /// * If the floor picks up chips, that is recorded as an explicit
  ///   held-chips event. The person-scoped chip holding already remains
  ///   with the player, so the system does not invent or move chips.
  static Future<void> unseat({
    required PokerSession session,
    required Player player,
    bool heldByFloor = true,
    double? heldAmount,
    String? operatorName,
    String? reason,
  }) async {
    PlayerOperationGuard.requireRegistered(player, 'unseat/leave');
    if (!player.seated) {
      throw StateError('This player is not already seated.');
    }
    final sourceTableId = player.tableId;
    final sourceSeat = player.seatNumber;

    player.seated = false;
    player.tableId = null;
    player.seatNumber = 0;
    await player.save();

    try {
      await TableOperationEventService.append(TableOperationEvent(
        id: TableOperationEventService.newId(),
        operation: TableOperationType.unseat,
        playerId: player.id,
        personId: player.personId,
        sourceTableId: sourceTableId,
        sourceSeat: sourceSeat,
        reason: reason ?? (heldByFloor ? 'unseat (held)' : 'unseat (leave)'),
        operatorName: operatorName,
      ));

      if (heldByFloor) {
        await TableOperationEventService.append(TableOperationEvent(
          id: TableOperationEventService.newId(),
          operation: TableOperationType.heldChips,
          playerId: player.id,
          personId: player.personId,
          sourceTableId: sourceTableId,
          sourceSeat: sourceSeat,
          carriedAmount: heldAmount,
          reason: reason ?? 'chips held by floor',
          operatorName: operatorName,
        ));
      }
    } on Object {
      // COMPENSATION: the seat row was already freed. An unseat whose
      // audit events cannot be written must not stand unaudited —
      // restore the exact seat state so the operation can be retried,
      // then surface the failure. (If the restore itself fails the
      // original error still propagates; the seat/audit divergence is
      // visible on the floor immediately rather than discovered in the
      // audit log later.)
      try {
        player.seated = true;
        player.tableId = sourceTableId;
        player.seatNumber = sourceSeat;
        await player.save();
      } catch (_) {}
      rethrow;
    }
  }
}
