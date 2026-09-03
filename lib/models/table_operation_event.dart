/// Append-only table movement / transfer / absence / seat audit record.
///
/// This is the OPERATIONAL audit surface that links the accounting legs
/// (the two `LedgerTransaction` rows) with the participation lifecycle and
/// the operator who authorised the move. It exists in addition to the
/// ledger, never as a second representation of money.
///
/// PERSISTENCE / IMMUTABILITY
///   * Stored as a plain JSON map in the untyped `transfer_events_box`.
///     No Hive typeId is consumed and Hive model files are untouched.
///   * Once written it is never edited or deleted.
///   * A correction is a NEW event whose [correctsId] points at the
///     original, so the original remains the historical fact.
enum TableOperationType {
  tableTransfer,
  temporaryAbsence,
  returnFromAbsence,
  unseat,
  heldChips,
  seatChange,
  dualVerification,
}

class TableOperationEvent {
  final String id;
  final TableOperationType operation;

  final String? playerId;
  final String? personId;

  final String? sourceTableId;
  final int? sourceSeat;
  final String? destinationTableId;
  final int? destinationSeat;

  final double? carriedAmount;
  final bool dryMove;

  final String? reason;
  final String? operatorId;
  final String? operatorName;

  final String? hostSignatureBase64;
  final String? secondVerifierName;
  final String? secondVerifierSignature;

  final DateTime timestamp;

  final String? transferOutTransactionId;
  final String? transferInTransactionId;
  final String? sourceParticipationId;
  final String? destinationParticipationId;

  /// The id of the original event when this is a correction/void record.
  final String? correctsId;
  final String? correctionNote;

  const TableOperationEvent({
    required this.id,
    required this.operation,
    this.playerId,
    this.personId,
    this.sourceTableId,
    this.sourceSeat,
    this.destinationTableId,
    this.destinationSeat,
    this.carriedAmount,
    this.dryMove = false,
    this.reason,
    this.operatorId,
    this.operatorName,
    this.hostSignatureBase64,
    this.secondVerifierName,
    this.secondVerifierSignature,
    DateTime? timestamp,
    this.transferOutTransactionId,
    this.transferInTransactionId,
    this.sourceParticipationId,
    this.destinationParticipationId,
    this.correctsId,
    this.correctionNote,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'operation': operation.name,
        'playerId': playerId,
        'personId': personId,
        'sourceTableId': sourceTableId,
        'sourceSeat': sourceSeat,
        'destinationTableId': destinationTableId,
        'destinationSeat': destinationSeat,
        'carriedAmount': carriedAmount,
        'dryMove': dryMove,
        'reason': reason,
        'operatorId': operatorId,
        'operatorName': operatorName,
        'hostSignatureBase64': hostSignatureBase64,
        'secondVerifierName': secondVerifierName,
        'secondVerifierSignature': secondVerifierSignature,
        'timestamp': timestamp.toIso8601String(),
        'transferOutTransactionId': transferOutTransactionId,
        'transferInTransactionId': transferInTransactionId,
        'sourceParticipationId': sourceParticipationId,
        'destinationParticipationId': destinationParticipationId,
        'correctsId': correctsId,
        'correctionNote': correctionNote,
      };

  /// Parses a stored JSON map. Unknown/absent fields degrade to null rather
  /// than throwing, so an old event block can never break a newer restore.
  static TableOperationEvent fromJson(Map<String, dynamic> j) {
    final op = TableOperationType.values.firstWhere(
      (o) => o.name == (j['operation'] as String? ?? '').trim(),
      orElse: () => TableOperationType.tableTransfer,
    );
    return TableOperationEvent(
      id: j['id'] as String? ?? '',
      operation: op,
      playerId: j['playerId'] as String?,
      personId: j['personId'] as String?,
      sourceTableId: j['sourceTableId'] as String?,
      sourceSeat: (j['sourceSeat'] as num?)?.toInt(),
      destinationTableId: j['destinationTableId'] as String?,
      destinationSeat: (j['destinationSeat'] as num?)?.toInt(),
      carriedAmount: (j['carriedAmount'] as num?)?.toDouble(),
      dryMove: j['dryMove'] as bool? ?? false,
      reason: j['reason'] as String?,
      operatorId: j['operatorId'] as String?,
      operatorName: j['operatorName'] as String?,
      hostSignatureBase64: j['hostSignatureBase64'] as String?,
      secondVerifierName: j['secondVerifierName'] as String?,
      secondVerifierSignature: j['secondVerifierSignature'] as String?,
      timestamp: DateTime.tryParse(j['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      transferOutTransactionId:
          j['transferOutTransactionId'] as String?,
      transferInTransactionId: j['transferInTransactionId'] as String?,
      sourceParticipationId: j['sourceParticipationId'] as String?,
      destinationParticipationId:
          j['destinationParticipationId'] as String?,
      correctsId: j['correctsId'] as String?,
      correctionNote: j['correctionNote'] as String?,
    );
  }
}
