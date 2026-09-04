import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../services/rebate_service.dart';
import 'dual_verification_sheet.dart';

/// Realise an exposed grant against a cash-out.
///
/// Lost-in-play (C <= G) is journalled even if the sheet is dismissed —
/// it does not change the cash handed to the player.
///
/// Remaining-loss reconciliation (C > G) requires Confirm because that
/// reduces cash paid. Banker Override is a separate button: pay the
/// full face amount, journal the waived reconciliation, and close the
/// cycle. Cancel is not an override.
Future<FinancialEvent?> askRebateRealize(
  BuildContext context, {
  required String sessionId,
  required String personId,
  required AppCurrency currency,
  required int cashOutMinor,
  String? linkedTransactionId,
}) async {
  final plan = RebateService.previewRealization(
    sessionId: sessionId,
    personId: personId,
    currency: currency,
    cashOutMinor: cashOutMinor,
  );
  if (!plan.closesGrant) return null;

  Future<FinancialEvent?> persist({required bool? confirmed}) {
    if (!RebateService.shouldPersistRealization(plan, confirmed: confirmed)) {
      return Future.value(null);
    }
    return RebateService.realizeCashOut(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      cashOutMinor: cashOutMinor,
      linkedTransactionId: linkedTransactionId,
    );
  }

  if (!context.mounted) return persist(confirmed: null);

  final fmt = CurrencyFormatter(currency);
  final recon = plan.clawbackMinor > 0;

  final choice = await showModalBottomSheet<_RealizeChoice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('rebate_realize_title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(tr('rebate_realize_body'),
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.textSecondary, height: 1.35)),
          const SizedBox(height: 12),
          _line(tr('rebate_original_loss'),
              fmt.format(MoneyUnits.toMajor(currency, plan.originalLossMinor))),
          _line(tr('rebate_granted'),
              fmt.format(MoneyUnits.toMajor(currency, plan.exposedBeforeMinor))),
          _line(tr('rebate_own_cash_out'),
              fmt.format(MoneyUnits.toMajor(currency, plan.cashOutMinor))),
          if (recon) ...[
            _line(tr('rebate_remaining_loss'),
                fmt.format(MoneyUnits.toMajor(currency, plan.remainingLossMinor))),
            _line(tr('rebate_remaining_entitlement'),
                fmt.format(MoneyUnits.toMajor(
                    currency, plan.remainingEntitlementMinor))),
            _line(tr('rebate_reconciliation'),
                fmt.format(MoneyUnits.toMajor(currency, plan.clawbackMinor))),
            _line(tr('rebate_normal_paid'),
                fmt.format(MoneyUnits.toMajor(currency, plan.normalPaidMinor))),
          ] else
            _line(tr('rebate_lost_in_play'),
                fmt.format(MoneyUnits.toMajor(currency, plan.returnedMinor))),
          _line(tr('rebate_actual_paid'),
              fmt.format(MoneyUnits.toMajor(currency, plan.actualCashPaidMinor))),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, _RealizeChoice.confirm),
            child: Text(recon
                ? tr('confirm_rebate_realize')
                : tr('confirm')),
          ),
          if (recon) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, _RealizeChoice.override),
              child: Text(tr('rebate_pay_full')),
            ),
            const SizedBox(height: 4),
            Text(
              tr('rebate_realize_override_hint'),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary, height: 1.35),
            ),
            const SizedBox(height: 4),
            Text(
              '${tr('rebate_waived')}: '
              '${fmt.format(MoneyUnits.toMajor(currency, plan.clawbackMinor))}'
              ' · ${tr('rebate_override_paid')}: '
              '${fmt.format(MoneyUnits.toMajor(currency, plan.cashOutMinor))}',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary, height: 1.35),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _RealizeChoice.cancel),
              child: Text(tr('cancel')),
            ),
          ],
        ],
      ),
    ),
  );

  if (choice == _RealizeChoice.override) {
    // J8: the override is a discretionary house-money waiver (pay the
    // full cash-out and permanently waive the reconciliation). A waiver
    // at/above the configured threshold needs the second authorisation
    // before it is journalled; the service re-checks and fails closed.
    final waivedMajor =
        MoneyUnits.toMajor(currency, plan.waivedMinor);
    final secondVerifier = await collectSecondVerifierIfRequired(
      context,
      amount: waivedMajor,
      currency: currency,
      operationLabel: tr('rebate_pay_full'),
    );
    if (secondVerifier == null || !context.mounted) return null;
    return RebateService.realizeCashOut(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      cashOutMinor: cashOutMinor,
      linkedTransactionId: linkedTransactionId,
      override: true,
      secondVerifierName:
          secondVerifier.isRequired ? secondVerifier.name : null,
      secondVerifierSignature: secondVerifier.isRequired
          ? secondVerifier.signature
          : null,
    );
  }
  return persist(confirmed: choice == _RealizeChoice.confirm);
}

enum _RealizeChoice { confirm, override, cancel }

Widget _line(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}
