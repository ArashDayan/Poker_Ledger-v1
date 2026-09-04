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
}
