import 'package:poker_ledger/models/financial_event.dart';

import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/player.dart';
import '../models/table_participation.dart';
import '../models/transaction.dart';
import 'chip_tracking_service.dart';
import 'dual_verification_service.dart';
import 'financial_capture.dart';
import 'financial_ledger_service.dart';
import 'hive_service.dart';
import 'participation_service.dart';
import 'player_operation_guard.dart';
import 'session_service.dart';
import 'table_service.dart';

/// Raised when a redemption is refused by the marker gate (E2).
class RedemptionException implements Exception {
  final String message;
  RedemptionException(this.message);
  @override
  String toString() => message;
}

/// The E2 marker-gate message, shared by the service and the UI
/// pre-check so the wording can never drift.
String redemptionMarkerBlockMessage({
  required int outstandingMinor,
  required AppCurrency currency,
}) {
  final major = MoneyUnits.toMajor(currency, outstandingMinor);
  return 'A marker of ${major.toStringAsFixed(0)} is still outstanding: '
      'redeem at least that amount to settle it in the same redemption, '
      'or repay the marker first.';
}

/// Result of a final cage redemption.
class RedemptionResult {
  /// The counted value the person handed to the cage.
  final double amount;

  /// The cage's cash for the person: the redemption amount minus any
  /// marker settled in the same redemption (the E2 netting).
  final double cashPaid;

  /// The marker amount settled out of this redemption (0 when no
  /// marker was outstanding).
  final double markerSettled;

  /// The chip movements that returned the chips to the case (empty
  /// when chip tracking was skipped).
  final List<ChipMovement> movements;

  /// The redemption's financial leg (cashOutForChips / cashOutUnbacked),
  /// or null when the funding was recorded as notRecorded.
  final FinancialEvent? financial;

  /// The marker settlement leg (creditRepaid), when a marker was
  /// settled in this redemption.
  final FinancialEvent? markerRepaid;

  const RedemptionResult({
    required this.amount,
    required this.cashPaid,
    required this.markerSettled,
    required this.movements,
    this.financial,
    this.markerRepaid,
  });
}

/// Final cage redemption (Phase 7): the cage operation that returns the
/// PERSON's chips to the bank.
///
/// Conceptually separate from [tableCashOut]:
///   * table cash-out — table level: the participation closes, the
///     chips stay the person's physical holding, session money OUT;
///   * redemption    — cage level: the chips return to the Bank
///     (chip movement person -> bank), the person's own cash returns
///     to them as cash (cashOutForChips / cashOutUnbacked).
///
/// A redemption writes NO session money leg: the chips already left
/// table play at the table cash-out (or were never committed to table
/// play), so the session identity
///     buyIn + rebuy = cashOut + tableCashOut + rake + tips + stillInPlay
/// stays intact — a redemption is a cage conversion, not a table outflow.
///
/// MARKER GATE (approved E2, deferred here from Phase 5): a redemption
/// is blocked while credit is outstanding, EXCEPT the combined
/// redeem-and-settle: redemption C >= outstanding M settles the marker
/// (creditRepaid M) and pays C - M; C < M is refused.
class RedemptionService {
  RedemptionService._();

  /// TABLE CASH-OUT: the person leaves the table carrying the counted
  /// chips (the count is authoritative — E9).
  ///
  /// Writes, in order:
  ///   1. the `tableCashOut` money leg (stamped to the open
  ///      participation by recordTransaction; signature required);
  ///   2. closes the open participation (reason tableCashOut);
  ///   3. unseats the seat row (Phase 1 semantics).
  ///
  /// NO chip movement: the chips stay the person's physical holding
  /// (person-scoped chip ledger — the holding is unchanged).
  static Future<LedgerTransaction> tableCashOut({
    required String sessionId,
    required String seatPlayerId,
    required double amount,
    required String hostSignatureBase64,
    String? note,
    String? operatorName,
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) async {
    if (amount < 0) {
      throw RedemptionException('A table cash-out count cannot be negative.');
    }
    if (hostSignatureBase64.isEmpty) {
      throw RedemptionException(
          'A table cash-out requires the host signature.');
    }
    // J8: the configurable second-authorisation gate runs before any
    // write so a sensitive table cash-out is not even partially
    // recorded without the second signature.
    if (DualVerificationService.requiresSecond(amount) &&
        (secondVerifierSignature == null ||
            secondVerifierSignature.isEmpty)) {
      throw RedemptionException(
          'A second authorisation is required for this table cash-out.');
    }

    // Identity gate (J5) before any write: a table cash-out releases the
    // person's chips and closes their participation, so the seat must
    // resolve to a registered Player Master identity.
    Player? seat;
    try {
      seat = HiveService.players.get(seatPlayerId);
    } catch (_) {}
    PlayerOperationGuard.requireRegistered(seat, 'a table cash-out');

    // 1. The money leg. recordTransaction stamps it to the open
    // participation (if any) — a legacy seat without a tracked
    // participation stays unstamped, which settles as before.
    final tx = await SessionService.recordTransaction(
      sessionId: sessionId,
      playerId: seatPlayerId,
      type: TransactionType.tableCashOut,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      operatorName: operatorName,
      secondVerifierName: secondVerifierName,
      secondVerifierSignature: secondVerifierSignature,
      note: note ?? 'Table cash-out (counted)',
    );

    // 2. Close the participation, if one is open for this seat. A
    // legacy seat stores tableId null = the session's first table.
    String? tableId;
    final seatTableId = seat?.tableId;
    if (seatTableId != null && seatTableId.isNotEmpty) {
      tableId = seatTableId;
    } else {
      try {
        final tables =
            TableService.tablesFor(HiveService.sessions.get(sessionId)!);
        if (tables.isNotEmpty) tableId = tables.first.id;
      } catch (_) {}
    }
    if (tableId != null) {
      final open = ParticipationService.openFor(
        sessionId: sessionId,
        seatPlayerId: seatPlayerId,
        tableId: tableId,
      );
      if (open != null) {
        ParticipationService.close(open.id,
            reason: ParticipationCloseReason.tableCashOut);
      }
    }

    // 3. Unseat: the chips stay with the person (no chip movement).
    if (seat != null && seat.seated) {
      seat.seated = false;
      seat.tableId = null;
      await seat.save();
    }
    return tx;
  }

  /// FINAL REDEMPTION at the cage: the person's counted chips return
  /// to the Bank and their own cash returns to them as cash.
  ///
  /// [composition] — the counted chips (person-scoped holding -> bank,
  /// reason cashOut). Null/empty when chip tracking is skipped (no
  /// chip types configured); the money and financial legs still record.
  ///
  /// The marker gate runs FIRST (E2): outstanding M > 0 and
  /// amount < M -> [RedemptionException]; amount >= M -> the marker is
  /// settled (creditRepaid M) and the person is paid amount - M.
  static Future<RedemptionResult> redeem({
    required String personId,
    required AppCurrency currency,
    required double amount,
    required ChipCashOutFunding funding,
    Map<String, int>? composition,
    String? sessionId,
    String? hostSignatureBase64,
    String? operatorName,
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) async {
    if (personId.isEmpty) {
      throw RedemptionException('A redemption needs a person.');
    }
    if (amount < 0) {
      throw RedemptionException('A redemption amount cannot be negative.');
    }
    // J8: configurable second-authorisation gate. A cage redemption of a
    // sensitive amount requires two authorisations before the bank
    // movement / financial leg is written.
    // J5: a cage redemption is a person-level financial-chip operation;
    // the person must be a registered Player Master identity.
    PlayerOperationGuard.requireRegisteredPerson(personId, 'a redemption');

    final dual = DualVerificationService.requiresSecond(amount);
    if (dual &&
        (secondVerifierSignature == null ||
            secondVerifierSignature.isEmpty)) {
      throw RedemptionException(
          'A second authorisation is required for this redemption.');
    }

    // MARKER GATE (E2): no redemption while a marker is outstanding,
    // except the combined redeem-and-settle (C >= M settles it). This
    // is a physical/business rule, so it applies regardless of whether
    // the funding is recorded. The creditRepaid settlement RECORD,
    // however, is only written when the redemption is recorded at all
    // (a notRecorded redemption writes nothing, so nothing is settled
    // in the ledger).
    final recorded = funding != ChipCashOutFunding.notRecorded;
    final outstandingMinor =
        FinancialLedgerService.creditOutstandingMinor(personId, currency);
    if (outstandingMinor > 0 &&
        MoneyUnits.toMinor(currency, amount) < outstandingMinor) {
      throw RedemptionException(redemptionMarkerBlockMessage(
          outstandingMinor: outstandingMinor, currency: currency));
    }
    final settleMarker = recorded && outstandingMinor > 0;
    final markerSettled =
        settleMarker ? MoneyUnits.toMajor(currency, outstandingMinor) : 0.0;

    // Chips return to the case — person-scoped, never P2P.
    final movements = <ChipMovement>[];
    final cleaned = {
      for (final e in (composition ?? const <String, int>{}).entries)
        if (e.value > 0) e.key: e.value,
    };
    if (cleaned.isNotEmpty) {
      movements.addAll(await ChipTrackingService.recordDistribution(
        distribution: cleaned,
        from: ChipLocation.player(personId),
        to: ChipLocation.bank,
        reason: ChipMovementReason.cashOut,
        sessionId: sessionId,
        note: 'cage redemption',
      ));
    }

    // The person's own cash returns to them as cash.
    FinancialEvent? financial;
    if (amount > 0) {
      financial = await FinancialCapture.recordCashOutFunding(
        personId: personId,
        currency: currency,
        funding: funding,
        amount: amount,
        sessionId: sessionId,
        signatureBase64: hostSignatureBase64,
        note: 'Cage redemption',
      );
    }

    // Marker settled in the same redemption (the E2 netting).
    FinancialEvent? markerRepaid;
    if (settleMarker) {
      markerRepaid = await FinancialLedgerService.record(
        personId: personId,
        currency: currency,
        type: FinancialEventType.creditRepaid,
        amount: markerSettled,
        sessionId: sessionId,
        signatureBase64: hostSignatureBase64,
        note: 'Marker settled in redemption',
      );
    }

    if (dual) {
      await DualVerificationService.recordVerification(
        operation: 'cage_redemption',
        personId: personId,
        amount: amount,
        operatorName: operatorName ?? '',
        secondVerifierName: secondVerifierName ?? '',
        hostSignatureBase64: hostSignatureBase64 ?? '',
        secondVerifierSignature: secondVerifierSignature ?? '',
        relatedTransactionId: financial?.id ?? markerRepaid?.id,
      );
    }

    return RedemptionResult(
      amount: amount,
      cashPaid: amount - markerSettled,
      markerSettled: markerSettled,
      movements: movements,
      financial: financial,
      markerRepaid: markerRepaid,
    );
  }
}
