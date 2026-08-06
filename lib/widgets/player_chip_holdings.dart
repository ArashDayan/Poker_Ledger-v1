import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../providers/chip_bank_provider.dart';
import '../screens/chip_bank/chip_movements_screen.dart';
import '../services/chip_tracking_service.dart';

/// Physical chips currently in front of one player, plus their movement
/// history.
///
/// Shown ALONGSIDE the financial figures, never instead of them. The two
/// are independent by design: a player's chip stack and their net money
/// position routinely differ, because winning and losing moves chips
/// between players without any money changing hands.
class PlayerChipHoldings extends StatelessWidget {
  final String playerId;
  final String? sessionId;
  final AppCurrency currency;

  const PlayerChipHoldings({
    super.key,
    required this.playerId,
    this.sessionId,
    this.currency = AppCurrency.usd,
  });

  @override
  Widget build(BuildContext context) {
    // Watch so a distribution recorded moments ago appears immediately.
    context.watch<ChipBankProvider>();

    final holding = ChipTrackingService.playerHolding(
      playerId,
      sessionId: sessionId,
    );
    final movements = ChipTrackingService.movementsForPlayer(
      playerId,
      sessionId: sessionId,
    );
    final fmt = CurrencyFormatter(currency);
    final stacks = holding.nonEmpty;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.album_outlined,
                  size: 16, color: AppColors.gold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('chips_held'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.gold,
                  ),
                ),
              ),
              if (movements.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChipMovementsScreen(
                        sessionId: sessionId,
                        location: ChipLocation.player(playerId),
                        currency: currency,
                      ),
                    ),
                  ),
                  child: Text(tr('movement_history'),
                      style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 8),

          if (stacks.isEmpty)
            Text(
              tr('no_chips_held'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            )
          else ...[
            ...stacks.map((s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${fmt.format(s.chipValue)} × ${s.quantity}',
                          style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textPrimary),
                        ),
                      ),
                      Text(
                        fmt.format(s.totalValue),
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 6),
            const Divider(height: 1),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('total_chip_value'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
                Text(
                  fmt.format(holding.totalValue),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.accentGreen,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
