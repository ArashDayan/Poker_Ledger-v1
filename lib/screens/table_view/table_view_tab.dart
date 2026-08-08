import '../../core/localization/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/session_service.dart';
import '../../services/sound_service.dart';
import '../../services/table_service.dart';
import '../../widgets/quick_transaction_sheet.dart';
import '../../widgets/poker_table_view.dart';
import '../../widgets/quick_rake_sheet.dart';
import '../../widgets/table_selector_bar.dart';
import '../players/players_tab.dart';
import '../player_action/player_ledger_screen.dart';

/// A real poker-room seat map: a premium oval felt table, seats arranged
/// clockwise, a realistic dealer button that moves, and tap-a-seat to
/// act. This is the spatial companion to the Players list — same data,
/// laid out the way a banker actually sees the table.
class TableViewTab extends StatelessWidget {
  const TableViewTab({super.key});

  Future<void> _quickAction(
    BuildContext context,
    SessionProvider provider,
    Player player,
    TransactionType type,
  ) async {
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);

    if (type == TransactionType.rebuy) {
      final eligible = SessionService.canRebuy(session, player.id);
      if (!eligible) {
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
    if (result == null) return;
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

  void _seatSheet(BuildContext context, SessionProvider provider, Player player) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Seat ${player.seatNumber} · ${player.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ListTile(
              leading: const Icon(Icons.add_card, color: AppColors.accentGreen),
              title: Text(tr('buy_in')),
              onTap: () {
                Navigator.pop(ctx);
                _quickAction(context, provider, player, TransactionType.buyIn);
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh, color: AppColors.accentGreen),
              title: Text(tr('rebuy')),
              onTap: () {
                Navigator.pop(ctx);
                _quickAction(context, provider, player, TransactionType.rebuy);
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: AppColors.danger),
              title: Text(tr('cash_out')),
              onTap: () {
                Navigator.pop(ctx);
                _quickAction(context, provider, player, TransactionType.cashOut);
              },
            ),
            // Mode 1 — rake taken from THIS player's pot. Recorded
            // against them so it shows in their history, while the money
            // still counts as house income in the session total.
            ListTile(
              leading: const Icon(Icons.percent, color: AppColors.gold),
              title: Text(tr('quick_rake')),
              subtitle: Text(tr('rake_from_this_player'),
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                showQuickRakeSheet(context, player: player);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: AppColors.textSecondary),
              title: Text(tr('edit_player')),
              onTap: () {
                Navigator.pop(ctx);
                PlayersTab.showAddPlayerSheet(context, existing: player);
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined, color: AppColors.textSecondary),
              title: Text(tr('full_details')),
              subtitle: Text(tr('every_action'),
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                // "Full Details" now opens the player's COMPLETE ledger —
                // every buy-in, rebuy, cash-out, edit, signature and note
                // in order — rather than just their running totals.
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlayerLedgerScreen(player: player)));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final table = provider.activeTable;
    final fmt = CurrencyFormatter(session.currency);
    final players = TableService.playersAt(session, table.id);
    final bySeat = {for (final p in players) p.seatNumber: p};

    // Seat data is assembled here so PokerTableView stays pure layout —
    // it draws what it is given and owns no business logic.
    final seats = [
      for (var n = 1; n <= table.seatCount; n++)
        SeatData(
          seatNumber: n,
          player: bySeat[n],
          profitLoss: bySeat[n] == null
              ? 0
              : SessionService.playerProfitLoss(session.id, bySeat[n]!.id),
          settled: bySeat[n] != null && !bySeat[n]!.isActive,
          moneyLabel: bySeat[n] == null
              ? null
              : fmt.format(
                  SessionService.playerTotalIn(session.id, bySeat[n]!.id)),
        ),
    ];

    return Container(
      // Poker-room atmosphere: a warm pool of light overhead falling off
      // into deep shadow, so the table sits IN a room rather than on a
      // flat black rectangle.
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.3,
          colors: [Color(0xFF1E2E28), Color(0xFF121C18), Color(0xFF080D0B)],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      child: Column(
        children: [
          const TableSelectorBar(),
          TableStatusBar(table: table),
          // The table takes all remaining height, so the whole felt is
          // visible on a phone without scrolling.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: PokerTableView(
                seats: seats,
                dealerSeat: table.dealerSeat,
                tableName: table.name,
                status: table.status,
                onDealerTap: table.status.isClosed
                    ? null
                    : () => provider.moveDealerAt(table.id),
                onSeatTap: (seat) {
                  if (table.status.isClosed) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(tr('table_closed_hint'))),
                    );
                    return;
                  }
                  if (seat.player == null) {
                    // Pass the table being viewed explicitly, so the new
                    // player is seated HERE rather than wherever the
                    // provider would otherwise infer.
                    PlayersTab.showAddPlayerSheet(context,
                        presetSeat: seat.seatNumber,
                        presetTableId: table.id);
                  } else {
                    _seatSheet(context, provider, seat.player!);
                  }
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              tr('tap_seat_hint'),
              style: const TextStyle(
                  fontSize: 10.5, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
