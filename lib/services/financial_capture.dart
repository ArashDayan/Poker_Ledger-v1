import '../models/enums.dart';
import '../models/financial_event.dart';
import 'financial_ledger_service.dart';

/// How chips issued (buy-in / rebuy) were funded.
///
/// This is NOT inferred from the Chip Ledger. The banker must choose.
/// [notRecorded] writes nothing — that is the legacy "Not recorded" state.
enum ChipFunding {
  paidCash,
  credit,
  marker,
  notRecorded,
}

/// How a chip cash-out was settled in real money (C-2).
enum ChipCashOutFunding {
  paidCash,
  unbacked,
  notRecorded,
}

/// Maps an explicit banker choice onto a Financial Ledger write.
///
/// Does not read Buy-in/Rebuy/cash-out totals. Does not call
/// [SessionService]. A missing personId or a skip choice is a no-op,
/// never an invented event.
class FinancialCapture {
  FinancialCapture._();

  static FinancialEventType? typeForFunding(ChipFunding funding) {
    switch (funding) {
      case ChipFunding.paidCash:
        return FinancialEventType.cashInForChips;
      case ChipFunding.credit:
      case ChipFunding.marker:
        return FinancialEventType.creditIssued;
      case ChipFunding.notRecorded:
        return null;
    }
  }

  static FinancialEventType? typeForCashOut(ChipCashOutFunding funding) {
    switch (funding) {
      case ChipCashOutFunding.paidCash:
        return FinancialEventType.cashOutForChips;
      case ChipCashOutFunding.unbacked:
        return FinancialEventType.cashOutUnbacked;
      case ChipCashOutFunding.notRecorded:
        return null;
    }
  }

  static bool markerRequiresSignature(ChipFunding funding) =>
      funding == ChipFunding.marker;

  /// Records funding for chips just issued. Returns null when nothing
  /// should be written (skip, no person, non-positive amount).
  static Future<FinancialEvent?> recordFunding({
    required String? personId,
    required AppCurrency currency,
    required ChipFunding funding,
    required double amount,
    String? sessionId,
    String? linkedTransactionId,
    String? signatureBase64,
    PaymentMethod? paymentMethod,
    String? note,
  }) async {
    final type = typeForFunding(funding);
    if (type == null) return null;
    if (personId == null || personId.isEmpty) return null;
    if (amount <= 0) return null;
    if (funding == ChipFunding.marker &&
        (signatureBase64 == null || signatureBase64.isEmpty)) {
      throw FinancialLedgerException(
        'A marker requires the player\'s signature.',
      );
    }
    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: type,
      amount: amount,
      sessionId: sessionId,
      linkedTransactionId: linkedTransactionId,
      signatureBase64: signatureBase64,
      paymentMethod: paymentMethod,
      note: note ??
          (funding == ChipFunding.marker ? 'Marker' : null),
    );
  }

  /// Records how a chip cash-out was paid. A $0 bust writes nothing
  /// (the Financial Ledger refuses a zero amount).
  static Future<FinancialEvent?> recordCashOutFunding({
    required String? personId,
    required AppCurrency currency,
    required ChipCashOutFunding funding,
    required double amount,
    String? sessionId,
    String? linkedTransactionId,
    String? signatureBase64,
    PaymentMethod? paymentMethod,
    String? note,
  }) async {
    final type = typeForCashOut(funding);
    if (type == null) return null;
    if (personId == null || personId.isEmpty) return null;
    if (amount <= 0) return null;
    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: type,
      amount: amount,
      sessionId: sessionId,
      linkedTransactionId: linkedTransactionId,
      signatureBase64: signatureBase64,
      paymentMethod: paymentMethod,
      note: note,
    );
  }
}
