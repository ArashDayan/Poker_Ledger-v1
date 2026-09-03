import 'package:uuid/uuid.dart';

import '../models/table_operation_event.dart';
import 'hive_service.dart';

const _uuid = Uuid();

/// Persistence for the immutable [TableOperationEvent] audit surface.
///
/// Storage is an untyped Hive box (`transfer_events_box`) holding JSON
/// maps — deliberately no new Hive typeId. The service only appends; it
/// exposes no edit/delete API, so the historical record cannot be
/// silently rewritten. A correction is a new event with `correctsId`.
class TableOperationEventService {
  TableOperationEventService._();

  static String newId() => _uuid.v4();

  static bool get _boxOpen {
    try {
      HiveService.transferEvents;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Appends the event and returns the stored copy.
  static Future<TableOperationEvent> append(
    TableOperationEvent event,
  ) async {
    if (!_boxOpen) {
      throw StateError('Transfer event storage is unavailable.');
    }
    await HiveService.transferEvents.put(event.id, event.toJson());
    return event;
  }

  static TableOperationEvent? byId(String id) {
    if (!_boxOpen || id.isEmpty) return null;
    final raw = HiveService.transferEvents.get(id);
    if (raw is! Map) return null;
    return TableOperationEvent.fromJson(Map<String, dynamic>.from(raw));
  }

  static List<TableOperationEvent> all() {
    if (!_boxOpen) return const [];
    return HiveService.transferEvents.values
        .whereType<Map>()
        .map((m) => TableOperationEvent.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  static List<TableOperationEvent> forPlayer(String playerId) {
    if (!_boxOpen || playerId.isEmpty) return const [];
    return all()
        .where((e) => e.playerId == playerId || e.personId == playerId)
        .toList();
  }

  /// Most recent non-correction event for the player, if any.
  static TableOperationEvent? latestForPlayer(String playerId) {
    final rows = forPlayer(playerId)
        .where((e) => e.correctsId == null || e.correctsId!.isEmpty)
        .toList();
    if (rows.isEmpty) return null;
    return rows.last;
  }

  /// Convenience for a transfer: appends a single event linking the two
  /// ledger legs and both participations.
  static Future<TableOperationEvent> appendTransfer({
    required String playerId,
    String? personId,
    required String sourceTableId,
    required int sourceSeat,
    required String destinationTableId,
    required int destinationSeat,
    required double? carriedAmount,
    required bool dryMove,
    String? reason,
    String? operatorName,
    required String hostSignatureBase64,
    String? secondVerifierName,
    String? secondVerifierSignature,
    required String transferOutTransactionId,
    required String transferInTransactionId,
    String? sourceParticipationId,
    String? destinationParticipationId,
  }) {
    return append(TableOperationEvent(
      id: newId(),
      operation: TableOperationType.tableTransfer,
      playerId: playerId,
      personId: personId,
      sourceTableId: sourceTableId,
      sourceSeat: sourceSeat,
      destinationTableId: destinationTableId,
      destinationSeat: destinationSeat,
      carriedAmount: carriedAmount,
      dryMove: dryMove,
      reason: reason,
      operatorName: operatorName,
      hostSignatureBase64: hostSignatureBase64,
      secondVerifierName: secondVerifierName,
      secondVerifierSignature: secondVerifierSignature,
      transferOutTransactionId: transferOutTransactionId,
      transferInTransactionId: transferInTransactionId,
      sourceParticipationId: sourceParticipationId,
      destinationParticipationId: destinationParticipationId,
    ));
  }

  /// Appends a correction/void marker without mutating the target.
  static Future<TableOperationEvent> correct({
    required String correctsId,
    String? playerId,
    String? reason,
    String? operatorName,
  }) {
    return append(TableOperationEvent(
      id: newId(),
      operation: TableOperationType.tableTransfer,
      playerId: playerId,
      correctsId: correctsId,
      reason: reason,
      operatorName: operatorName,
      correctionNote: 'Correction/void marker',
    ));
  }
}
