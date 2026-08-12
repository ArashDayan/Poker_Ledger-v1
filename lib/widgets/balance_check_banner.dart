import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../services/rebate_service.dart';
import '../services/session_service.dart';

class BalanceCheckBanner extends StatelessWidget {
  final BalanceResult result;
  final CurrencyFormatter formatter;
  final DiscountChipReconciliation? discountChips;

  const BalanceCheckBanner({
    super.key,
    required this.result,
    required this.formatter,
    this.discountChips,
  });

  @override
  Widget build(BuildContext context) {
    final ok = result.isBalanced;
    final overlay = discountChips != null && discountChips!.hasIssued
        ? discountChips!
        : null;
    final explained = overlay?.explainsGap == true;
    final color = ok
        ? AppColors.accentGreen
        : (explained ? AppColors.warning : AppColors.danger);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok
                    ? Icons.check_circle
                    : (explained ? Icons.info_outline : Icons.error),
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  ok
                      ? tr('session_balanced')
                      : (explained
                          ? tr('rebate_books_explained_short')
                          : tr('discrepancy_found')),
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
          if (!ok) ...[
            const SizedBox(height: 10),
            Text(
              'Difference: ${formatter.format(result.discrepancy.abs())} '
              '(${result.discrepancy > 0 ? "more cash in than out" : "more cash out than in"})',
              style: const TextStyle(
                  color: AppColors.textPrimary, fontWeight: FontWeight.w600),
            ),
            if (result.knownIssues.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...result.knownIssues.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('•  $c',
                      style: const TextStyle(
                          color: AppColors.warning, fontSize: 12)),
                ),
              ),
            ],
            if (!explained) ...[
              const SizedBox(height: 8),
              Text(tr('possible_causes'),
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 4),
              ...result.possibleCauses.map(
                (c) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('•  $c',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ),
              ),
            ],
          ] else
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(tr('all_reconcile'),
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ),
          if (overlay != null) ...[
            const SizedBox(height: 10),
            Text(
              '${tr('rebate_chips_issued')}: ${formatter.format(overlay.issuedMajor)}',
              style: const TextStyle(fontSize: 12.5),
            ),
            Text(
              '${tr('rebate_books_residual')}: ${formatter.format(overlay.residualAfterDiscount)}',
              style: const TextStyle(fontSize: 12.5),
            ),
            Text(
              '${tr('rebate_implied_in_play')}: ${formatter.format(overlay.impliedStillInPlay)}',
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            Text(
              overlay.explainsGap
                  ? tr('settle_rebate_chips_explained')
                  : (overlay.booksBalancedWithPromoOut
                      ? tr('settle_rebate_chips_in_play')
                      : tr('settle_warn_rebate_chips')),
              style: const TextStyle(fontSize: 12, color: AppColors.warning),
            ),
          ],
          if (ok && result.playersNeverCashedOut.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning),
              ),
              child: Text(
                '${tr('heads_up_no_cashout')} '
                '${result.playersNeverCashedOut.map((p) => p.name).join(', ')}. '
                '${tr('no_cashout_double_check')}',
                style: const TextStyle(fontSize: 12, color: AppColors.warning),
              ),
            ),
          ],
          if (result.cashDropped > 0.005) ...[
            const SizedBox(height: 8),
            Text(
              'Cash dropped to safe: ${formatter.format(result.cashDropped)} '
              '(tracked separately, not part of the settlement equation).',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
