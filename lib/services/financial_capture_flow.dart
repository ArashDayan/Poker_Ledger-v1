import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/player.dart';
import '../widgets/financial_funding_sheet.dart';
import '../widgets/rebate_grant_sheet.dart';
import '../widgets/rebate_realize_sheet.dart';
import 'confirm_gate.dart';
import 'financial_capture.dart';
import 'rebate_service.dart';

/// Collects the required funding choice BEFORE any ledger write.
///
/// Returns [CollectedFunding.abort] when the banker backs out or
/// dismisses the sheet. Callers must not commit Session, Chip, or
/// Financial rows in that case.
Future<CollectedFunding> collectRequiredFunding(
  BuildContext context, {
  required TransactionType chipType,
  required double amount,
  required AppCurrency currency,
}) async {
  if (!ConfirmGate.fundingRequired(chipType, amount)) {
    if (chipType == TransactionType.cashOut && amount == 0) {
      return const CollectedFunding.zeroCashOut();
    }
    return const CollectedFunding.none();
  }

  final fmt = CurrencyFormatter(currency);
  if (chipType == TransactionType.buyIn || chipType == TransactionType.rebuy) {
    if (!context.mounted) return const CollectedFunding.abort();
    final choice = await askChipFunding(context, formatter: fmt, amount: amount);
    if (choice == null) return const CollectedFunding.abort();
    return CollectedFunding.buyIn(choice);
  }

  if (chipType == TransactionType.cashOut) {
    if (!context.mounted) return const CollectedFunding.abort();
    final funding = await askChipCashOutFunding(
      context,
      formatter: fmt,
      amount: amount,
    );
    if (funding == null) return const CollectedFunding.abort();
    return CollectedFunding.cashOut(funding);
  }

  return const CollectedFunding.none();
}

/// Writes Financial Ledger (and Discount follow-ups) AFTER the chip
/// transaction is stored. [funding] must already have been confirmed.
///
/// Failures here never roll back the chip transaction.
Future<void> applyCollectedFunding(
  BuildContext context, {
  required Player player,
  required TransactionType chipType,
  required double amount,
  required AppCurrency currency,
  required String sessionId,
  required String transactionId,
  required CollectedFunding funding,
}) async {
  if (funding.aborted) return;
  final personId = player.personId;
  if (personId == null || personId.isEmpty) return;
  if (amount < 0) return;

  try {
    if (chipType == TransactionType.buyIn ||
        chipType == TransactionType.rebuy) {
      final choice = funding.buyIn;
      if (choice == null) return;
      await FinancialCapture.recordFunding(
        personId: personId,
        currency: currency,
        funding: choice.funding,
        amount: amount,
        sessionId: sessionId,
        linkedTransactionId: transactionId,
        signatureBase64: choice.markerSignature,
      );
      return;
    }

    if (chipType != TransactionType.cashOut) return;

    ChipCashOutFunding? cashFunding = funding.cashOut;
    if (amount > 0 && cashFunding != null) {
      await FinancialCapture.recordCashOutFunding(
        personId: personId,
        currency: currency,
        funding: cashFunding,
        amount: amount,
        sessionId: sessionId,
        linkedTransactionId: transactionId,
      );
    }
    if (!context.mounted) return;
    final bustRealized = amount == 0;
    final paidOwnCash = cashFunding == ChipCashOutFunding.paidCash;
    final unfunded = cashFunding == ChipCashOutFunding.notRecorded ||
        cashFunding == ChipCashOutFunding.unbacked;
    // Only a paid cash-out or a $0 bust realises Discount. Missing
    // funding must not invent cashOutForChips or a fake loss.
    if (bustRealized || paidOwnCash) {
      final cashOutMinor =
          amount > 0 ? MoneyUnits.toMinor(currency, amount) : 0;
      await askRebateRealize(
        context,
        sessionId: sessionId,
        personId: personId,
        currency: currency,
        cashOutMinor: cashOutMinor,
        linkedTransactionId: transactionId,
      );
    }
    if (!context.mounted) return;
    final cfg = RebateService.configFor(sessionId);
    if (cfg.isUsable) {
      final sug = RebateService.suggest(
        sessionId: sessionId,
        personId: personId,
        currency: currency,
        bustRealized: bustRealized,
        chipCashOutWithoutFunding: unfunded,
      );
      if (sug.canGrant || unfunded) {
        await askRebateGrant(
          context,
          sessionId: sessionId,
          personId: personId,
          currency: currency,
          playerId: player.id,
          bustRealized: bustRealized,
          chipCashOutWithoutFunding: unfunded,
        );
      }
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('financial_record_failed')}: $e')),
      );
    }
  }
}
