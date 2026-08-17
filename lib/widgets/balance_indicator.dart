import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../services/rebate_service.dart';
import '../services/session_service.dart';
import 'balance_check_banner.dart';

/// The compact, glanceable balance state shown while a session is
/// ACTIVE — a colored dot plus a one-line label. Tapping it opens the
/// full [BalanceCheckBanner] with the breakdown and possible causes. The
/// full banner itself is reserved for the End Session flow, where it
/// deserves the extra weight.
class BalanceIndicator extends StatelessWidget {
  final BalanceResult result;
  final CurrencyFormatter formatter;
  final DiscountChipReconciliation? discountChips;

  const BalanceIndicator({
    super.key,
    required this.result,
    required this.formatter,
    this.discountChips,
  });

  Color get _color {
    final overlay = discountChips;
    if (overlay != null && overlay.explainsGap) return AppColors.warning;
    if (overlay != null && overlay.booksBalancedWithPromoOut) {
      return AppColors.gold;
    }
    switch (result.severity) {
      case BalanceSeverity.balanced:
        return AppColors.accentGreen;
      case BalanceSeverity.small:
        return AppColors.warning;
      case BalanceSeverity.large:
        return AppColors.danger;
    }
  }

  String get _label {
    final overlay = discountChips;
    if (overlay != null && overlay.explainsGap) {
      return tr('rebate_books_explained_short');
    }
    if (overlay != null && overlay.booksBalancedWithPromoOut) {
      return tr('rebate_promo_in_play');
    }
    switch (result.severity) {
      case BalanceSeverity.balanced:
        return 'Balanced';
      case BalanceSeverity.small:
        return 'Small difference';
      case BalanceSeverity.large:
        return 'Large difference';
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: BalanceCheckBanner(
              result: result,
              formatter: formatter,
              discountChips: discountChips,
            ),
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(_label,
                style: TextStyle(
                    color: _color, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 15, color: _color),
          ],
        ),
      ),
    );
  }
}
