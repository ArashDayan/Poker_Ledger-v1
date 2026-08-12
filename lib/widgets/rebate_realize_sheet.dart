import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../services/rebate_service.dart';

/// Confirm realisation of an exposed grant against a cash-out.
///
/// The player still receives [plan.actualCashPaidMinor] when there is
/// no clawback, or cash-out minus clawback when C > G.
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

  final fmt = CurrencyFormatter(currency);
  final confirmed = await showModalBottomSheet<bool>(
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
          _line(tr('rebate_granted'),
              fmt.format(MoneyUnits.toMajor(currency, plan.exposedBeforeMinor))),
          _line(tr('rebate_player_receives'),
              fmt.format(MoneyUnits.toMajor(currency, plan.actualCashPaidMinor))),
          _line(tr('rebate_returned_now'),
              fmt.format(MoneyUnits.toMajor(currency, plan.returnedMinor))),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('confirm_rebate_realize')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return null;
  return RebateService.realizeCashOut(
    sessionId: sessionId,
    personId: personId,
    currency: currency,
    cashOutMinor: cashOutMinor,
    linkedTransactionId: linkedTransactionId,
  );
}

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
