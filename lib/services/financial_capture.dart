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

  /// Player hands cash to the banker as a deposit. Not a chip buy-in
  /// and not a credit repayment. Does not write the Chip Ledger.
  /// Does not become cashInForChips until explicitly converted.
  static Future<FinancialEvent?> recordFrontMoneyIn({
    required String? personId,
    required AppCurrency currency,
    required double amount,
    String? sessionId,
    PaymentMethod? paymentMethod,
    String? note,
    String? linkedTransactionId,
  }) {
    return _recordFrontMoney(
      personId: personId,
      currency: currency,
      type: FinancialEventType.frontMoneyIn,
      amount: amount,
      sessionId: sessionId,
      paymentMethod: paymentMethod,
      note: note,
      linkedTransactionId: linkedTransactionId,
    );
  }

  /// Banker returns deposited cash. Not a chip cash-out and not a
  /// conversion into play. Refuses more than the remaining deposit.
  static Future<FinancialEvent?> recordFrontMoneyOut({
    required String? personId,
    required AppCurrency currency,
    required double amount,
    String? sessionId,
    PaymentMethod? paymentMethod,
    String? note,
    String? linkedTransactionId,
  }) {
    return _recordFrontMoney(
      personId: personId,
      currency: currency,
      type: FinancialEventType.frontMoneyOut,
      amount: amount,
      sessionId: sessionId,
      paymentMethod: paymentMethod,
      note: note,
      linkedTransactionId: linkedTransactionId,
    );
  }

  /// Converts deposit into playing money: frontMoneyOut + cashInForChips.
  ///
  /// The banker must choose this explicitly. A deposit is never inferred
  /// as payment for chips. Does not write the Chip Ledger — the caller
  /// records the buy-in/rebuy and passes [linkedTransactionId].
  static Future<DepositToChipsPair?> useDepositForChips({
    required String? personId,
    required AppCurrency currency,
    required double amount,
    String? sessionId,
    String? linkedTransactionId,
  }) async {
    if (personId == null || personId.isEmpty) return null;
    if (amount <= 0) return null;

    final out = await recordFrontMoneyOut(
      personId: personId,
      currency: currency,
      amount: amount,
      sessionId: sessionId,
      linkedTransactionId: linkedTransactionId,
      note: 'Used for chips',
    );
    if (out == null) return null;

    try {
      final cashIn = await FinancialLedgerService.record(
        personId: personId,
        currency: currency,
        type: FinancialEventType.cashInForChips,
        amount: amount,
        sessionId: sessionId,
        linkedTransactionId: linkedTransactionId,
        note: 'From deposit',
      );
      return DepositToChipsPair(
        frontMoneyOut: out,
        cashInForChips: cashIn,
      );
    } catch (e) {
      await FinancialLedgerService.reverse(
        out.id,
        reason: 'Deposit-to-chips cash-in failed',
      );
      rethrow;
    }
  }

  static Future<FinancialEvent?> _recordFrontMoney({
    required String? personId,
    required AppCurrency currency,
    required FinancialEventType type,
    required double amount,
    String? sessionId,
    PaymentMethod? paymentMethod,
    String? note,
    String? linkedTransactionId,
  }) async {
    if (type != FinancialEventType.frontMoneyIn &&
        type != FinancialEventType.frontMoneyOut) {
      throw FinancialLedgerException(
        'Front money must be recorded as in or out.',
      );
    }
    if (personId == null || personId.isEmpty) return null;
    if (amount <= 0) return null;

    if (type == FinancialEventType.frontMoneyOut) {
      final held = FinancialLedgerService.depositHeldMinor(personId, currency);
      final want = MoneyUnits.toMinor(currency, amount);
      if (held <= 0 || want > held) {
        throw FinancialLedgerException(
          'Cannot use more deposit than is held.',
        );
      }
    }

    return FinancialLedgerService.record(
      personId: personId,
      currency: currency,
      type: type,
      amount: amount,
      sessionId: sessionId,
      paymentMethod: paymentMethod,
      note: note,
      linkedTransactionId: linkedTransactionId,
    );
  }
}

/// The two financial events written by [FinancialCapture.useDepositForChips].
class DepositToChipsPair {
  final FinancialEvent frontMoneyOut;
  final FinancialEvent cashInForChips;

  const DepositToChipsPair({
    required this.frontMoneyOut,
    required this.cashInForChips,
  });
}
