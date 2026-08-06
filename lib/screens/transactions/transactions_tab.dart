import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/session_service.dart';
import '../../services/sound_service.dart';
import '../../widgets/quick_rake_sheet.dart';
import '../../widgets/quick_transaction_sheet.dart';

/// Fast action center: the big buttons a banker reaches for constantly —
/// buy-in/rebuy/cash-out (pick a player, then the quick sheet), plus the
/// table-level actions (rake, cash drop) that don't belong to one player.
/// This is deliberately separate from the Players list so both stay fast
/// and uncluttered for their own use case.
class TransactionsTab extends StatelessWidget {
  const TransactionsTab({super.key});

  Future<Player?> _pickPlayer(BuildContext context, List<Player> players) {
    if (players.isEmpty) return Future.value(null);
    return showModalBottomSheet<Player>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(tr('choose_player'), style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ...players.map((p) => ListTile(
                  title: Text('Seat ${p.seatNumber} · ${p.name}'),
                  onTap: () => Navigator.pop(ctx, p),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _playerTransaction(BuildContext context, TransactionType type) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final player = await _pickPlayer(context, provider.players);
    if (player == null || !context.mounted) return;

    if (type == TransactionType.rebuy) {
      final eligible = SessionService.canRebuy(session, player.id);
      if (!eligible && context.mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('house_rule_notice')),
            content: Text('${player.name} is not eligible for another rebuy at level '
                '${session.currentLevel} under the current house rules.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
              ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true), child: Text(tr('proceed_anyway'))),
            ],
          ),
        );
        if (proceed != true) return;
      }
    }
    if (!context.mounted) return;

    final lastAmount = provider.lastAmountFor(player.id, type);
    final result = await showQuickTransactionSheet(
      context,
      title: '${type.label} · ${player.name}',
      type: type,
      initialAmount: lastAmount,
      formatter: fmt,
      allowZero: type == TransactionType.cashOut,
      sessionId: session.id,
    );
    if (result == null || !context.mounted) return;

    try {
      await provider.recordTransaction(
        playerId: player.id,
        type: type,
        amount: result.amount,
        hostSignatureBase64: result.signature ?? '',
      );
      AppSounds.play(AppSounds.forTransaction(type));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Mode 2 — general session rake, no player ownership.
  Future<void> _collectRake(BuildContext context) =>
      showQuickRakeSheet(context);


  Future<void> _cashDrop(BuildContext context) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final result = await showQuickTransactionSheet(
      context,
      title: 'Cash Drop to Safe',
      type: TransactionType.cashDrop,
      formatter: fmt,
      sessionId: session.id,
    );
    if (result == null) return;
    await provider.recordTransaction(
      type: TransactionType.cashDrop,
      amount: result.amount,
      hostSignatureBase64: '',
    );
    AppSounds.play(SoundEffect.cashDrop);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final recent = provider.transactions.reversed.take(8).toList();
    final players = provider.players;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        Text(tr('quick_actions'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.4,
          children: [
            _actionButton(context, 'Buy-in', Icons.add_card, AppColors.accentGreen,
                players.isEmpty ? null : () => _playerTransaction(context, TransactionType.buyIn)),
            _actionButton(context, 'Rebuy', Icons.refresh, AppColors.accentGreen,
                players.isEmpty ? null : () => _playerTransaction(context, TransactionType.rebuy)),
            _actionButton(context, 'Cash-out', Icons.logout, AppColors.danger,
                players.isEmpty ? null : () => _playerTransaction(context, TransactionType.cashOut)),
            _actionButton(context, 'Collect Rake', Icons.percent, AppColors.gold,
                () => _collectRake(context)),
            _actionButton(context, 'Cash Drop', Icons.lock_outline, AppColors.textSecondary,
                () => _cashDrop(context)),
          ],
        ),
        if (players.isEmpty) ...[
          const SizedBox(height: 8),
          Text(tr('add_player_first'),
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
        const SizedBox(height: 24),
        Text(tr('recent_activity'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(tr('no_transactions_yet'), style: TextStyle(color: AppColors.textSecondary)),
          )
        else
          ...recent.map((t) {
            final name = t.playerId == null
                ? 'Table'
                : players.firstWhere((p) => p.id == t.playerId, orElse: () => players.first).name;
            final color = t.type.isInflow ? AppColors.accentGreen : AppColors.danger;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('${t.type.label} · $name',
                        style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    '${t.type.isInflow ? '+' : '-'}${fmt.format(t.amount)}',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _actionButton(
      BuildContext context, String label, IconData icon, Color color, VoidCallback? onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.surfaceElevated,
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        elevation: 0,
      ),
    );
  }
}
