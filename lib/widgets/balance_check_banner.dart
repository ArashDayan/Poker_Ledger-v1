import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../services/session_service.dart';

class BalanceCheckBanner extends StatelessWidget {
  final BalanceResult result;
  final CurrencyFormatter formatter;

  const BalanceCheckBanner({super.key, required this.result, required this.formatter});

  @override
  Widget build(BuildContext context) {
    final ok = result.isBalanced;
    final color = ok ? AppColors.accentGreen : AppColors.danger;

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
              Icon(ok ? Icons.check_circle : Icons.error, color: color),
              const SizedBox(width: 8),
              Text(
                ok ? 'Session Balanced' : 'Discrepancy Found',
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          if (!ok) ...[
            const SizedBox(height: 10),
            Text(
              'Difference: ${formatter.format(result.discrepancy.abs())} '
              '(${result.discrepancy > 0 ? "more cash in than out" : "more cash out than in"})',
              style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
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
            const SizedBox(height: 8),
            Text(tr('possible_causes'),
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 4),
            ...result.possibleCauses.map(
              (c) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('•  $c',
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ),
            ),
          ] else
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(tr('all_reconcile'),
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            ),
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
