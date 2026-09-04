import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../models/player.dart';
import '../providers/session_provider.dart';
import '../services/dual_verification_service.dart';
import '../services/financial_capture.dart';
import '../services/financial_ledger_service.dart';
import '../services/rebate_service.dart';
import '../services/redemption_service.dart';
import 'dual_verification_sheet.dart';
import 'rebate_grant_sheet.dart';
import 'rebate_realize_sheet.dart';

/// Phase 7 — the two conceptually separate cash-out operations
/// (TABLE CASH-OUT IS NOT THE FINAL CAGE REDEMPTION).
///
/// TABLE CASH-OUT (table level, [performTableCashOut]): the operator's
/// count (authoritative — E9) closes the person's table participation,
/// frees the seat, and records the session money-out. The chips STAY
/// the person's physical holding (person-scoped chip ledger — no chip
/// movement). A $0 table cash-out is a bust and closes any open
/// Discount cycle (legacy parity: a bust realizes).
///
/// CAGE REDEMPTION (cage level, [performCageRedemption]): the person's
/// counted chips return to the Bank (person -> bank), the person's own
/// cash returns to them as cash (cashOutForChips / cashOutUnbacked),
/// the marker gate nets (E2), and the Discount cycle closes (the
/// existing engine, parity).
///
/// Both return true on completion, false when refused (a snackbar
/// explains why).

/// The E2 marker gate pre-check for the UI: null when the redemption
/// may proceed, otherwise the blocking message (the service enforces
/// the same rule — this exists so the UI can explain BEFORE the heavy
/// work).
String? redemptionMarkerBlock({
  required String? personId,
  required AppCurrency currency,
  required double amount,
}) {
  if (personId == null || personId.isEmpty) return null;
  final outstanding =
      FinancialLedgerService.creditOutstandingMinor(personId, currency);
  if (outstanding > 0 &&
      MoneyUnits.toMinor(currency, amount) < outstanding) {
    return redemptionMarkerBlockMessage(
      outstandingMinor: outstanding,
      currency: currency,
    );
  }
  return null;
}

/// TABLE CASH-OUT: the person leaves the table carrying the counted
/// chips. See the file docs for the model.
Future<bool> performTableCashOut(
  BuildContext context, {
  required Player player,
  required String sessionId,
  required double amount,
  required String hostSignatureBase64,
  String? operatorName,
  String? secondVerifierName,
  String? secondVerifierSignature,
}) async {
  try {
    // J8: a sensitive table cash-out needs the second authorisation
    // before the service writes anything.
    if (DualVerificationService.requiresSecond(amount) &&
        (secondVerifierSignature == null ||
            secondVerifierSignature.isEmpty)) {
      final second = await showDualVerificationSheet(
        context,
        amount: amount,
        formatter: CurrencyFormatter(_sessionCurrency(context)),
        operationLabel: tr('cash_out'),
      );
      if (second == null) return false;
      secondVerifierSignature = second.signature;
      secondVerifierName = second.name;
    }

    final tx = await RedemptionService.tableCashOut(
      sessionId: sessionId,
      seatPlayerId: player.id,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      operatorName: operatorName,
      secondVerifierName: secondVerifierName ?? operatorName,
      secondVerifierSignature: secondVerifierSignature,
    );

    // A $0 table cash-out is a bust: the open Discount cycle closes
    // here (legacy parity — a busted player realizes at the bust).
    // A counted (> 0) cash-out keeps the cycle open: it closes at the
    // cage redemption.
    final personId = player.personId;
    final bust = amount == 0;
    if (bust && personId != null && personId.isNotEmpty) {
      await askRebateRealize(
        context,
        sessionId: sessionId,
        personId: personId,
        currency: _sessionCurrency(context),
        cashOutMinor: 0,
        linkedTransactionId: tx.id,
      );
      if (!context.mounted) return true;
      final cfg = RebateService.configFor(sessionId);
      if (cfg.isUsable) {
        final sug = RebateService.suggest(
          sessionId: sessionId,
          personId: personId,
          currency: _sessionCurrency(context),
          bustRealized: true,
        );
        if (sug.canGrant) {
          await askRebateGrant(
            context,
            sessionId: sessionId,
            personId: personId,
            currency: _sessionCurrency(context),
            playerId: player.id,
            bustRealized: true,
          );
        }
      }
    }
    return true;
  } on RedemptionException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
}

/// CAGE REDEMPTION: the person's counted chips return to the Bank and
/// their own cash returns to them as cash. The marker gate nets (E2).
/// The Discount cycle closes here (existing engine, parity).
Future<bool> performCageRedemption(
  BuildContext context, {
  required Player? player, // the seat row, when the person is seated
  required String personId,
  required String? sessionId,
  required AppCurrency currency,
  required double amount,
  required ChipCashOutFunding funding,
  required String hostSignatureBase64,
  Map<String, int>? composition,
  String? operatorName,
  String? secondVerifierName,
  String? secondVerifierSignature,
}) async {
  try {
    // The marker gate is a physical/business rule (E2): it applies to
    // any redemption while a marker is outstanding, regardless of
    // whether the funding is recorded.
    final block = redemptionMarkerBlock(
        personId: personId, currency: currency, amount: amount);
    if (block != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(block)));
      }
      return false;
    }

    // J8: a sensitive cage redemption needs the second authorisation
    // before the bank movement / financial leg is written.
    if (DualVerificationService.requiresSecond(amount) &&
        (secondVerifierSignature == null ||
            secondVerifierSignature.isEmpty)) {
      final second = await showDualVerificationSheet(
        context,
        amount: amount,
        formatter: CurrencyFormatter(currency),
        operationLabel: tr('cash_out'),
      );
      if (second == null) return false;
      secondVerifierSignature = second.signature;
      secondVerifierName = second.name;
    }

    final result = await RedemptionService.redeem(
      personId: personId,
      currency: currency,
      amount: amount,
      funding: funding,
      composition: composition,
      sessionId: sessionId,
      hostSignatureBase64: hostSignatureBase64,
      operatorName: operatorName,
      secondVerifierName: secondVerifierName ?? operatorName,
      secondVerifierSignature: secondVerifierSignature,
    );

    // The Discount cycle closes at the redemption — the existing
    // engine, parity with the legacy cash-out realization: only a
    // paid redemption realizes; an unfunded one may still surface the
    // grant prompt (legacy behavior).
    final bust = amount == 0;
    final paidOwnCash = funding == ChipCashOutFunding.paidCash;
    final unfunded =
        funding == ChipCashOutFunding.notRecorded ||
            funding == ChipCashOutFunding.unbacked;
    if (sessionId != null && sessionId.isNotEmpty) {
      if (bust || paidOwnCash) {
        final cashOutMinor =
            amount > 0 ? MoneyUnits.toMinor(currency, amount) : 0;
        await askRebateRealize(
          context,
          sessionId: sessionId,
          personId: personId,
          currency: currency,
          cashOutMinor: cashOutMinor,
          linkedTransactionId: null,
        );
      }
      if (!context.mounted) return true;
      final cfg = RebateService.configFor(sessionId);
      if (cfg.isUsable) {
        final sug = RebateService.suggest(
          sessionId: sessionId,
          personId: personId,
          currency: currency,
          bustRealized: bust,
          chipCashOutWithoutFunding: unfunded,
        );
        if (sug.canGrant && player != null) {
          await askRebateGrant(
            context,
            sessionId: sessionId,
            personId: personId,
            currency: currency,
            playerId: player.id,
            bustRealized: bust,
          );
        }
      }
    }
    return result != null;
  } on RedemptionException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
}

/// The active session's currency (the redemption UI is person-level,
/// so the currency comes from the session context when available).
AppCurrency _sessionCurrency(BuildContext context) {
  try {
    return context.read<SessionProvider>().current?.currency ??
        AppCurrency.usd;
  } catch (_) {
    return AppCurrency.usd;
  }
}
