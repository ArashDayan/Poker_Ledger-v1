import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/player.dart';

/// Row shown on the Players/Table views for one seated player.
///
/// Shows the buy-in/rebuy/cash-out breakdown and the player's net result
/// (cash-out minus buy-in/rebuy) — never a "current stack" figure, since
/// a winner's cash-out can legitimately exceed what they put in and there
/// is no meaningful cap to display here. [isActive] is host-controlled
/// via [onToggleSettled], not inferred from any balance.
///
/// Private tags are intentionally NOT shown here. A banker's phone is
/// visible across the table constantly during live play, and a label
/// like "Problem Player" rendered on an ordinary card is a real
/// professional risk — tags still exist and are editable from the
/// edit-player sheet (opened deliberately, banker-only), they just don't
/// render on the always-visible card.
class PlayerCard extends StatelessWidget {
  final Player player;
  final double buyIn;
  final double rebuy;
  final double cashOut;
  final double profitLoss;
  final CurrencyFormatter formatter;
  final VoidCallback onTap;
  final VoidCallback onToggleSettled;
  final VoidCallback onEdit;

  /// Only supplied when the session runs more than one table, so a
  /// single-table game keeps exactly the card it always had.
  final VoidCallback? onMoveTable;

  /// Opens this player's complete chronological ledger.
  final VoidCallback? onLedger;

  const PlayerCard({
    super.key,
    required this.player,
    required this.buyIn,
    required this.rebuy,
    required this.cashOut,
    required this.profitLoss,
    required this.formatter,
    required this.onTap,
    required this.onToggleSettled,
    required this.onEdit,
    this.onMoveTable,
    this.onLedger,
  });

  @override
  Widget build(BuildContext context) {
    final isUp = profitLoss >= 0;
    final settled = !player.isActive;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              GestureDetector(
                onTap: onToggleSettled,
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: AppColors.feltGreen,
                  backgroundImage:
                      player.photoPath != null ? AssetImage(player.photoPath!) : null,
                  child: player.photoPath == null
                      ? Text(player.name.isNotEmpty ? player.name[0].toUpperCase() : '?',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text('${tr('seat')} ${player.seatNumber} · ${player.name}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (settled) ...[
                          const SizedBox(width: 5),
                          const Icon(Icons.check_circle, size: 13, color: AppColors.accentGreen),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Buy-in ${formatter.format(buyIn)} · Rebuy ${formatter.format(rebuy)} · '
                      'Out ${formatter.format(cashOut)}',
                      style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${isUp ? '+' : ''}${formatter.format(profitLoss)}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isUp ? AppColors.accentGreen : AppColors.danger,
                    ),
                  ),
                  Text(settled ? 'Settled' : 'Playing',
                      style: const TextStyle(fontSize: 9.5, color: AppColors.textSecondary)),
                ],
              ),
              if (onLedger != null)
                IconButton(
                  onPressed: onLedger,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  icon: const Icon(Icons.receipt_long_outlined,
                      size: 18, color: AppColors.textSecondary),
                  tooltip: tr('complete_ledger'),
                ),
              if (onMoveTable != null)
                IconButton(
                  onPressed: onMoveTable,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  icon: const Icon(Icons.swap_horiz,
                      size: 18, color: AppColors.textSecondary),
                  tooltip: tr('move_to_table'),
                ),
              IconButton(
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.textSecondary),
                tooltip: tr('edit_player_tooltip'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
