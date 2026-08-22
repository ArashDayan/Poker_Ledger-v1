import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/chip_tracking_service.dart';
import '../../services/financial_capture_flow.dart';
import '../../services/session_service.dart';
import '../../services/sound_service.dart';
import '../../services/table_service.dart';
import '../../widgets/chip_flow.dart';
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
    final provider = context.read<SessionProvider>();
    final session = provider.current;
    // Seat numbers are per-table, so "Seat 3" alone is ambiguous once a
    // second table is open. Naming the table makes it impossible to
    // record a buy-in against the wrong person by mistake. Single-table
    // sessions keep the original, uncluttered row.
    final showTable = provider.isMultiTable && session != null;

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
                  title: Text('${tr('seat')} ${p.seatNumber} · ${p.name}'),
                  subtitle: showTable
                      // tableById() resolves a null tableId to the first
                      // table, which is exactly how playersAt() treats
                      // legacy players — so the label always matches the
                      // list the player was drawn from.
                      ? Text(
                          TableService.tableById(session, p.tableId).name,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                          ),
                        )
                      : null,
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
    // Evaluated at TAP time, so the list is always current — a player
    // seated a moment ago is already here without leaving the screen.
    // Scoped to the active table when multi-table, mirroring build().
    // Seated players only: a registered-but-unseated person has no
    // seat to take money at.
    final player = await _pickPlayer(
      context,
      provider.isMultiTable
          ? provider.playersAtActiveTable
          : provider.seatedPlayers,
    );
    if (player == null || !context.mounted) return;

    if (type == TransactionType.rebuy) {
      final eligible = SessionService.canRebuy(session, player.id);
      if (!eligible && context.mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('house_rule_notice')),
            content: Text(tr('rebuy_not_eligible_note')),
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
      title: '${type.localizedLabel} · ${player.name}',
      type: type,
      initialAmount: lastAmount,
      formatter: fmt,
      allowZero: type == TransactionType.cashOut,
      sessionId: session.id,
    );
    if (result == null || !context.mounted) return;

    final funding = await collectRequiredFunding(
      context,
      chipType: type,
      amount: result.amount,
      currency: session.currency,
    );
    if (!funding.shouldCommit || !context.mounted) return;

    final dist = ChipFlow.appliesTo(type)
        ? await ChipFlow.ask(context,
            amount: result.amount, currency: session.currency)
        : null;
    if (!context.mounted) return;
    try {
      final tx = await provider.recordTransaction(
        playerId: player.id,
        type: type,
        amount: result.amount,
        hostSignatureBase64: result.signature ?? '',
      );
      if (context.mounted) {
        // Phase 2a: person-scoped chip holding.
        await ChipFlow.apply(context,
            distribution: dist,
            type: type,
            sessionId: session.id,
            transactionId: tx.id,
            holderRefId: ChipTrackingService.holderRef(
                playerId: player.id, personId: player.personId));
        if (context.mounted) {
          await applyCollectedFunding(
            context,
            player: player,
            chipType: type,
            amount: result.amount,
            currency: session.currency,
            sessionId: session.id,
            transactionId: tx.id,
            funding: funding,
          );
        }
      }
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

  /// Dealer tips — chips taken off the table for the dealer.
  ///
  /// Deliberately modelled on the rake flow rather than a new mechanism:
  /// the amount is entered, the physical denominations are chosen, the
  /// money row is written, and the chips move table -> Bank. The only
  /// difference from rake is the transaction type, which is what keeps
  /// the money out of Host Profit.
  ///
  /// The chip step is asked BEFORE the money is written, so cancelling
  /// the denomination sheet cancels the whole action rather than leaving
  /// a money row with no chips behind it.
  Future<void> _dealerTips(BuildContext context) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);

    final result = await showQuickTransactionSheet(
      context,
      title: tr('dealer_tips'),
      type: TransactionType.dealerTips,
      formatter: fmt,
      sessionId: session.id,
    );
    if (result == null || !context.mounted) return;

    // Which table the chips physically came off. Table-level, like rake
    // and cash drop — a tip belongs to the table, not to one player.
    final tableId = provider.activeTableId;

    final dist = await ChipFlow.ask(
      context,
      amount: result.amount,
      currency: session.currency,
    );
    if (!context.mounted) return;

    try {
      final tx = await provider.recordTransaction(
        type: TransactionType.dealerTips,
        amount: result.amount,
        hostSignatureBase64: result.signature ?? '',
        tableId: tableId,
      );
      if (context.mounted) {
        await ChipFlow.apply(
          context,
          distribution: dist,
          type: TransactionType.dealerTips,
          sessionId: session.id,
          transactionId: tx.id,
          tableId: tableId,
        );
      }
      AppSounds.play(SoundEffect.rake);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }


  Future<void> _cashDrop(BuildContext context) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final result = await showQuickTransactionSheet(
      context,
      title: tr('cash_drop_to_safe'),
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
    // SESSION-WIDE list. Deliberately not narrowed: `recent` above is
    // session-wide too, and the name lookup further down resolves a
    // transaction's playerId against this list. Scoping it would show
    // the wrong name for another table's transaction — and its
    // `orElse: players.first` would throw once the active table is empty.
    final players = provider.players;
    // ACTION list — who the banker may act on right now.
    //
    // Scoped to the selected table in a multi-table session, matching
    // PlayersTab. Seat numbers repeat across tables, so a session-wide
    // picker let "Seat 3" mean two different people and a buy-in could
    // land on the wrong player. A single-table session gets the exact
    // same list as before.
    // Seated players only in the single-table branch (the multi-table
    // branch is already seat-scoped via playersAtActiveTable): the
    // quick-action buttons act on a seat, which an unseated
    // registration does not have.
    final actionPlayers =
        provider.isMultiTable ? provider.playersAtActiveTable : provider.seatedPlayers;

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
            _actionButton(context, tr('buy_in'), Icons.add_card, AppColors.accentGreen,
                actionPlayers.isEmpty
                    ? null
                    : () => _playerTransaction(context, TransactionType.buyIn)),
            _actionButton(context, tr('rebuy'), Icons.refresh, AppColors.accentGreen,
                actionPlayers.isEmpty
                    ? null
                    : () => _playerTransaction(context, TransactionType.rebuy)),
            _actionButton(context, tr('cash_out'), Icons.logout, AppColors.danger,
                actionPlayers.isEmpty
                    ? null
                    : () => _playerTransaction(context, TransactionType.cashOut)),
            _actionButton(context, tr('collect_rake'), Icons.percent, AppColors.gold,
                () => _collectRake(context)),
            _actionButton(context, tr('dealer_tips'), Icons.volunteer_activism,
                AppColors.warning, () => _dealerTips(context)),
            _actionButton(context, tr('cash_drop'), Icons.lock_outline, AppColors.textSecondary,
                () => _cashDrop(context)),
          ],
        ),
        if (actionPlayers.isEmpty) ...[
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
                    child: Text('${t.type.localizedLabel} · $name',
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
