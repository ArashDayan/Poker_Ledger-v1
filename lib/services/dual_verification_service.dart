import '../models/table_operation_event.dart';
import 'hive_service.dart';
import 'table_operation_event_service.dart';

/// Sensitivity policy + second-authorisation capability (locked J8).
///
/// This is a reusable policy object, not a one-off wire for table
/// transfer. It owns:
///   * the configurable threshold (stored in the untyped settings box —
///     no Hive typeId, no backup schema change beyond the existing
///     portable-settings mechanism);
///   * the decision "does this amount require a second authorisation?";
///   * the append-only audit event for the two-authorisation check.
///
/// No monetary threshold is hard-coded here. When the policy is off, or
/// no threshold is configured, normal single-authorisation operations
/// continue unchanged.
class DualVerificationSettings {
  final bool enabled;
  final double? threshold;

  const DualVerificationSettings({
    this.enabled = false,
    this.threshold,
  });
}

/// Both authorising actors plus the mandatory reason for an operation
/// that ALWAYS requires two-person verification -- no monetary
/// threshold applies (finalised product decisions):
///   * D1 -- every manual Chip Bank inventory adjustment;
///   * D2 -- the standalone player-holding reconciliation workflow.
///
/// The first operator's identity + signature ride the same fields the
/// threshold-based events already use ([TableOperationEvent.operatorName]
/// and [TableOperationEvent.hostSignatureBase64]), so there is exactly
/// one verification architecture, not a parallel one.
class DualAuthorization {
  final String reason;
  final String operatorName;
  final String operatorSignatureBase64;
  final String secondVerifierName;
  final String secondVerifierSignature;

  const DualAuthorization({
    required this.reason,
    required this.operatorName,
    required this.operatorSignatureBase64,
    required this.secondVerifierName,
    required this.secondVerifierSignature,
  });
}

class DualVerificationService {

  DualVerificationService._();

  static const String enabledKey = 'dual_verification_enabled';
  static const String thresholdKey = 'dual_verification_threshold';

  static bool get isEnabled =>
      HiveService.settings.get(enabledKey, defaultValue: false) as bool? ??
      false;

  static double? get threshold {
    final raw = HiveService.settings.get(thresholdKey);
    if (raw is num) return raw.toDouble();
    return null;
  }

  static DualVerificationSettings get settings =>
      DualVerificationSettings(
        enabled: isEnabled,
        threshold: threshold,
      );

  /// Whether an operation of [amount] requires a second authorisation.
  ///
  /// No arbitrary number: the operator must configure a threshold. If a
  /// threshold has been configured, an amount equal to or above it is
  /// sensitive.
  static bool requiresSecond(double amount) {
    if (!isEnabled) return false;
    final t = threshold;
    if (t == null) return false;
    return amount >= t;
  }

  static Future<void> configure({bool? enabled, double? threshold}) async {
    if (enabled != null) {
      await HiveService.settings.put(enabledKey, enabled);
    }
    if (threshold != null) {
      await HiveService.settings.put(thresholdKey, threshold);
    }
  }

  static Future<void> clearThreshold() async {
    await HiveService.settings.delete(thresholdKey);
  }

  /// Fail-closed J8 gate for service boundaries that are not
  /// [LedgerTransaction]-based (financial events, chip exchanges, …).
  ///
  /// Throws when [amount] is at/above the configured threshold and the
  /// second authorisation is missing (signature first, then the
  /// verifier's name — the same two-step contract the ledger services
  /// use). No-ops below the threshold or when the policy is off, so
  /// existing callers below the threshold are unchanged.
  static void requireForAmount({
    required double amount,
    required String operation,
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) {
    if (!requiresSecond(amount)) return;
    if (secondVerifierSignature == null || secondVerifierSignature.isEmpty) {
      throw StateError(
        'A second authorisation is required for $operation.',
      );
    }
    if (secondVerifierName == null || secondVerifierName.trim().isEmpty) {
      throw StateError(
        'The second verifier name is required for $operation.',
      );
    }
  }

  /// Appends the J8 two-actor audit event for a service-level write.
  ///
  /// Only records when the amount is actually at/above the threshold —
  /// the audit stream then carries exactly the authorisations that were
  /// required, never noise. [operatorName] and [hostSignatureBase64]
  /// may be empty where the caller's own record already carries the
  /// primary actor's signature.
  static Future<void> recordForAmount({
    required String operation,
    required double amount,
    String? playerId,
    String? personId,
    String? secondVerifierName,
    String? secondVerifierSignature,
    String? hostSignatureBase64,
    String? relatedTransactionId,
  }) async {
    if (!requiresSecond(amount)) return;
    await recordVerification(
      operation: operation,
      playerId: playerId,
      personId: personId,
      amount: amount,
      operatorName: '',
      secondVerifierName: secondVerifierName ?? '',
      hostSignatureBase64: hostSignatureBase64 ?? '',
      secondVerifierSignature: secondVerifierSignature ?? '',
      relatedTransactionId: relatedTransactionId,
    );
  }

  /// Appends an audit event recording the second-authorisation check.
  ///
  /// [operation] should be descriptive (e.g. "table_transfer",
  /// "table_cash_out", "buy_in"). This event is operational audit only —
  /// it writes no money and does not duplicate the transfer legs.
  static Future<TableOperationEvent> recordVerification({
    required String operation,
    String? playerId,
    String? personId,
    String? sourceTableId,
    String? destinationTableId,
    double? amount,
    required String operatorName,
    required String secondVerifierName,
    required String hostSignatureBase64,
    required String secondVerifierSignature,
    String? relatedTransactionId,
    String? relatedTransferEventId,
  }) {
    // Audit integrity: a dual-authorisation event must identify the
    // second verifier, not merely store an anonymous signature. Fail
    // clearly rather than recording an audit row that cannot name both
    // actors.
    if (secondVerifierName.trim().isEmpty) {
      throw StateError(
          'A second verifier name is required to record dual authorisation.');
    }
    return TableOperationEventService.append(TableOperationEvent(
      id: TableOperationEventService.newId(),
      operation: TableOperationType.dualVerification,
      playerId: playerId,
      personId: personId,
      sourceTableId: sourceTableId,
      destinationTableId: destinationTableId,
      carriedAmount: amount,
      reason: operation,
      operatorName: operatorName,
      hostSignatureBase64: hostSignatureBase64,
      secondVerifierName: secondVerifierName,
      secondVerifierSignature: secondVerifierSignature,
      transferOutTransactionId: relatedTransactionId,
      transferInTransactionId: relatedTransferEventId,
    ));
  }

  /// ALWAYS-ON two-person gate for operations with no monetary
  /// threshold (finalised product decisions D1 / D2): every manual
  /// chip-bank inventory adjustment and the standalone player-holding
  /// reconciliation. Deliberately independent of [isEnabled] and
  /// [threshold] -- the decision is that these operations are
  /// sensitive at ANY size, so the configurable threshold policy is
  /// not consulted at all.
  ///
  /// Fails closed BEFORE any write when the mandatory reason, the
  /// first operator's identity + signature, or the second verifier's
  /// identity + signature is missing.
  static void requireAlways(
    DualAuthorization authorization,
    String operation,
  ) {
    if (authorization.reason.trim().isEmpty) {
      throw StateError('A reason is required for $operation.');
    }
    if (authorization.operatorName.trim().isEmpty) {
      throw StateError(
          'The first operator must be identified for $operation.');
    }
    if (authorization.operatorSignatureBase64.isEmpty) {
      throw StateError('The first operator must sign $operation.');
    }
    if (authorization.secondVerifierSignature.isEmpty) {
      throw StateError(
          'A second verifier signature is required for $operation.');
    }
    if (authorization.secondVerifierName.trim().isEmpty) {
      throw StateError(
          'The second verifier must be identified for $operation.');
    }
  }

  /// Appends the immutable two-actor audit event for an ALWAYS-dual
  /// operation, carrying the structured adjustment facts alongside
  /// the authorisation: chip denomination + previous / counted
  /// quantities (D1 inventory adjustments), holding value before /
  /// after the count (D2 reconciliations). [detail] is optional extra
  /// context appended after the operator's reason (e.g. a unit-value
  /// change note).
  static Future<void> recordAlways({
    required String operation,
    required DualAuthorization authorization,
    String? playerId,
    String? personId,
    String? chipTypeId,
    int? previousQuantity,
    int? countedQuantity,
    double? denominationValue,
    double? previousValue,
    double? countedValue,
    double? carriedAmount,
    String? detail,
    String? relatedTransactionId,
  }) async {
    var reason = '$operation \u00b7 ${authorization.reason.trim()}';
    if (detail != null && detail.trim().isNotEmpty) {
      reason = '$reason \u00b7 ${detail.trim()}';
    }
    await TableOperationEventService.append(TableOperationEvent(
      id: TableOperationEventService.newId(),
      operation: TableOperationType.dualVerification,
      playerId: playerId,
      personId: personId,
      carriedAmount: carriedAmount,
      reason: reason,
      operatorName: authorization.operatorName.trim(),
      hostSignatureBase64: authorization.operatorSignatureBase64,
      secondVerifierName: authorization.secondVerifierName.trim(),
      secondVerifierSignature: authorization.secondVerifierSignature,
      chipTypeId: chipTypeId,
      previousQuantity: previousQuantity,
      countedQuantity: countedQuantity,
      denominationValue: denominationValue,
      previousValue: previousValue,
      countedValue: countedValue,
      transferOutTransactionId: relatedTransactionId,
    ));
  }
}
