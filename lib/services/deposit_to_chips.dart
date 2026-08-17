import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/player.dart';
import '../models/transaction.dart';
import 'financial_capture.dart';
import 'financial_ledger_service.dart';
import 'session_service.dart';

/// One explicit banker action: convert Deposit into chips.
///
/// Writes, in order:
///   1. a normal Chip Ledger buy-in/rebuy (SessionService)
///   2. frontMoneyOut (reduces remaining Deposit)
///   3. cashInForChips (the converted cash is now playing money)
///
/// Both financial events carry [LedgerTransaction.id] as
/// [FinancialEvent.linkedTransactionId] (audit only).
///
/// A Deposit is never inferred as payment. The banker must call this.
/// FinancialLedgerService is not imported into SessionService; this
/// file is the only bridge.
class DepositToChipsResult {
  final LedgerTransaction chipTransaction;
  final FinancialEvent frontMoneyOut;
  final FinancialEvent cashInForChips;

  const DepositToChipsResult({
    required this.chipTransaction,
    required this.frontMoneyOut,
    required this.cashInForChips,
  });
}

class DepositToChips {
  DepositToChips._();

  /// Seat in [sessionId] linked to [personId], or null.
  static Player? seatedPlayer(String sessionId, String personId) {
    for (final p in SessionService.playersFor(sessionId)) {
      if (p.personId == personId) return p;
    }
    return null;
  }

  static Future<DepositToChipsResult> convert({
    required String personId,
    required String sessionId,
    required String playerId,
    required AppCurrency currency,
    required double amount,
    required String hostSignatureBase64,
  }) async {
    if (personId.isEmpty) {
      throw FinancialLedgerException('personId is required.');
    }
    if (amount <= 0) {
      throw FinancialLedgerException('Amount must be positive.');
    }
    final held = FinancialLedgerService.depositHeldMinor(personId, currency);
    final want = MoneyUnits.toMinor(currency, amount);
    if (held <= 0 || want > held) {
      throw FinancialLedgerException(
        'Cannot use more deposit than is held.',
      );
    }

    final alreadyIn = SessionService.playerBuyInOnly(sessionId, playerId);
    final type =
        alreadyIn > 0 ? TransactionType.rebuy : TransactionType.buyIn;

    final tx = await SessionService.recordTransaction(
      sessionId: sessionId,
      playerId: playerId,
      type: type,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      note: 'From deposit',
    );

    final pair = await FinancialCapture.useDepositForChips(
      personId: personId,
      currency: currency,
      amount: amount,
      sessionId: sessionId,
      linkedTransactionId: tx.id,
    );
    if (pair == null) {
      throw FinancialLedgerException(
        'Chip buy-in was saved. The deposit conversion failed.',
      );
    }
    return DepositToChipsResult(
      chipTransaction: tx,
      frontMoneyOut: pair.frontMoneyOut,
      cashInForChips: pair.cashInForChips,
    );
  }
}
