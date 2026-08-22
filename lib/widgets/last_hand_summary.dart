import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/localization/enum_labels.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/hand.dart';

/// Compact last-hand card for the table being viewed.
class LastHandSummary extends StatelessWidget {
  final Hand? hand;
  final CurrencyFormatter formatter;
  final String? tableName;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onRecord;

  const LastHandSummary({
    super.key,
    required this.hand,
    required this.formatter,
    this.tableName,
    this.onOpenHistory,
    this.onRecord,
  });

  @override
  Widget build(BuildContext context) {
    final h = hand;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: h == null ? _empty() : _filled(h),
    );
  }

  Widget _empty() {
    return Row(
      children: [
        const Icon(Icons.style_outlined, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            tr('last_hand_empty'),
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
        if (onRecord != null)
          TextButton(
            onPressed: onRecord,
            child: Text(tr('record_hand')),
          ),
      ],
    );
  }

  Widget _filled(Hand h) {
    final winners = h.results.where((r) => r.isWinner).toList();
    final split = winners.length > 1;
    return InkWell(
      onTap: onOpenHistory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tr('last_hand').toUpperCase(),
                style: const TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 1.0,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${tr('hand_number')} #${h.handNumber}',
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 6),
              Text(
                h.kind.localizedLabel,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
              const Spacer(),
              if (split)
                Text(tr('hand_split_pot'),
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.gold)),
              if (onRecord != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('record_hand'),
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: onRecord,
                ),
              ],
            ],
          ),
          Text(
            '${h.completedAt.toString().substring(0, 16)}'
            '${tableName == null ? '' : ' · $tableName'}',
            style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          for (final r in h.results)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${tr('seat')} ${r.seatNumber} · ${r.nameSnapshot}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    '${r.chipChange >= 0 ? '+' : ''}${formatter.format(r.chipChange)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: r.isWinner
                          ? AppColors.accentGreen
                          : (r.isLoser
                              ? AppColors.danger
                              : AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              _metric(tr('hand_pot'), formatter.format(h.potAmount)),
              _metric(
                tr('hand_rake'),
                h.rakeAmount > 0 ? formatter.format(h.rakeAmount) : '—',
                color: AppColors.gold,
              ),
              _metric(
                tr('hand_house_win'),
                h.houseWinAmount > 0
                    ? formatter.format(h.houseWinAmount)
                    : '—',
                color: AppColors.gold,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 9.5, color: AppColors.textSecondary)),
          Text(value,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color ?? AppColors.textPrimary)),
        ],
      ),
    );
  }
}
