import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../widgets/financial_funding_sheet.dart';
import 'financial_capture.dart';

/// After a chip Buy-in/Rebuy/Cash-out is safely stored, ask how real
/// money moved and write the Financial Ledger. Failures here never
/// roll back the chip transaction.
Future<void> captureFundingAfterChipTx(
  BuildContext context, {
  required Player player,
  required TransactionType chipType,
  required double amount,
  required AppCurrency currency,
  required String sessionId,
  required String transactionId,
}) async {
  if (amount <= 0) return;
  final personId = player.personId;
  if (personId == null || personId.isEmpty) return;

  final fmt = CurrencyFormatter(currency);

  try {
    if (chipType == TransactionType.buyIn ||
        chipType == TransactionType.rebuy) {
      if (!context.mounted) return;
      final choice = await askChipFunding(context,
          formatter: fmt, amount: amount);
      if (!context.mounted) return;
      await FinancialCapture.recordFunding(
        personId: personId,
        currency: currency,
        funding: choice.funding,
        amount: amount,
        sessionId: sessionId,
        linkedTransactionId: transactionId,
        signatureBase64: choice.markerSignature,
      );
    } else if (chipType == TransactionType.cashOut) {
      if (!context.mounted) return;
      final funding = await askChipCashOutFunding(context,
          formatter: fmt, amount: amount);
      if (!context.mounted) return;
      await FinancialCapture.recordCashOutFunding(
        personId: personId,
        currency: currency,
        funding: funding,
        amount: amount,
        sessionId: sessionId,
        linkedTransactionId: transactionId,
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('financial_record_failed')}: $e')),
      );
    }
  }
}
