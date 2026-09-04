import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/financial_event.dart';
import '../services/rebate_service.dart';
import 'chip_flow.dart';
import 'dual_verification_sheet.dart';

/// Suggest + confirm a Discount grant. Never writes until Confirm.
///
/// [bustRealized] and [chipCashOutWithoutFunding] are the same flags
/// [RebateService.suggest] / [RebateService.grant] need, so a $0 bust
/// can reach banker confirmation and an unfunded cash-out cannot.
Future<FinancialEvent?> askRebateGrant(
  BuildContext context, {
  required String sessionId,
  required String personId,
  required AppCurrency currency,
  String? playerId,
  bool bustRealized = false,
  bool chipCashOutWithoutFunding = false,
}) async {
  final suggestion = RebateService.suggest(
    sessionId: sessionId,
    personId: personId,
    currency: currency,
    bustRealized: bustRealized,
    chipCashOutWithoutFunding: chipCashOutWithoutFunding,
  );
  if (!context.mounted) return null;

  final fmt = CurrencyFormatter(currency);
  var asChips = true;

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
      child: StatefulBuilder(
        builder: (ctx, setSheet) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('review_discount'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(tr('rebate_hint'),
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                      height: 1.35)),
              const SizedBox(height: 12),
              _line(tr('rebate_cycle'), '${suggestion.cycleIndex}'),
              if (suggestion.periodEnd != null)
                _line(
                    tr('rebate_period'),
                    '${_fmtPeriodDT(suggestion.periodStart)}'
                    ' → '
                    '${_fmtPeriodDT(suggestion.periodEnd)}'),
              if (suggestion.periodEnded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(tr('rebate_period_ended'),
                      style: const TextStyle(
                          color: AppColors.warning, fontSize: 12.5)),
                ),
              _line(tr('rebate_gross_loss'),
                  fmt.format(MoneyUnits.toMajor(currency, suggestion.grossLossMinor))),
              _line(tr('rebate_eligible_loss'),
                  fmt.format(MoneyUnits.toMajor(currency, suggestion.eligibleLossMinor))),
              _line(tr('rebate_granted'),
                  fmt.format(MoneyUnits.toMajor(currency, suggestion.grantMinor))),
              if (!suggestion.canGrant) ...[
                const SizedBox(height: 10),
                Text(suggestion.blockReason ?? tr('rebate_not_eligible'),
                    style: const TextStyle(color: AppColors.warning, fontSize: 13)),
              ],
              const SizedBox(height: 14),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text(tr('rebate_as_chips'))),
                  ButtonSegment(value: false, label: Text(tr('rebate_as_cash'))),
                ],
                selected: {asChips},
                onSelectionChanged: suggestion.canGrant
                    ? (v) => setSheet(() => asChips = v.first)
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                asChips ? tr('rebate_as_chips_hint') : tr('rebate_as_cash_hint'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary, height: 1.35),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: suggestion.canGrant
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: Text(tr('confirm_rebate_grant')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('cancel')),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return null;

  // J8: a grant at/above the configured threshold is a sensitive money
  // operation — collect the second authorisation before any write (the
  // service boundary re-checks and fails closed).
  final grantMajor = MoneyUnits.toMajor(currency, suggestion.grantMinor);
  final secondVerifier = await collectSecondVerifierIfRequired(
    context,
    amount: grantMajor,
    currency: currency,
    operationLabel: tr('review_discount'),
  );
  if (secondVerifier == null || !context.mounted) return null;
  final secondVerifierName =
      secondVerifier.isRequired ? secondVerifier.name : null;
  final secondVerifierSignature =
      secondVerifier.isRequired ? secondVerifier.signature : null;

  if (asChips) {
    if (playerId == null || playerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('rebate_need_chips'))),
      );
      return null;
    }
    final dist = await ChipFlow.ask(
      context,
      amount: grantMajor,
      currency: currency,
    );
    if (!context.mounted) return null;
    if (!RebateService.hasChipCounts(dist)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('rebate_need_chips'))),
      );
      return null;
    }
    return RebateService.grantAsChips(
      sessionId: sessionId,
      personId: personId,
      currency: currency,
      playerId: playerId,
      distribution: dist!,
      bustRealized: bustRealized,
      chipCashOutWithoutFunding: chipCashOutWithoutFunding,
      secondVerifierName: secondVerifierName,
      secondVerifierSignature: secondVerifierSignature,
    );
  }

  return RebateService.grant(
    sessionId: sessionId,
    personId: personId,
    currency: currency,
    asChips: false,
    bustRealized: bustRealized,
    chipCashOutWithoutFunding: chipCashOutWithoutFunding,
    secondVerifierName: secondVerifierName,
    secondVerifierSignature: secondVerifierSignature,
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

/// Compact local timestamp for period display.
String _fmtPeriodDT(DateTime? dt) =>
    dt == null ? '' : '${dt.toLocal()}'.substring(0, 16);
