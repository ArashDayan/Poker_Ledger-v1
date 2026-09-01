import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/chip_tracking_service.dart';
import '../../services/financial_capture_flow.dart';
import '../../services/player_identity_service.dart';
import '../../services/session_service.dart';
import '../../services/sound_service.dart';
import '../../services/table_service.dart';
import '../../widgets/quick_transaction_sheet.dart';
import '../../widgets/cashout_flow.dart';
import '../../widgets/chip_flow.dart';
import '../../widgets/last_hand_summary.dart';
import '../../widgets/poker_table_view.dart';
import '../../widgets/quick_rake_sheet.dart';
import '../../widgets/discount_review_entry.dart';
import '../../widgets/select_player_sheet.dart';
import '../../widgets/record_hand_sheet.dart';
import '../../widgets/table_selector_bar.dart';
import '../history/hand_history_screen.dart';
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
    if (result == null) return;

    // Phase 7 / 12: a seated cash-out from the table map is the
    // TABLE CASH-OUT — same path as Players tab and Player Action.
    // No funding (no cashier cash), no ChipFlow (chips stay the
    // person's holding), no session cashOut leg.
    if (type == TransactionType.cashOut) {
      final ok = await performTableCashOut(
        context,
        player: player,
        sessionId: session.id,
        amount: result.amount,
        hostSignatureBase64: result.signature ?? '',
      );
      if (!ok) return;
      AppSounds.play(AppSounds.forTransaction(type));
      return;
    }

    final funding = await collectRequiredFunding(
      context,
      chipType: type,
      amount: result.amount,
      currency: session.currency,
    );
    if (!funding.shouldCommit || !context.mounted) return;
    // Optional chip composition. Skip / dismiss does not abort.
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
        final holderRef = ChipTrackingService.holderRef(
            playerId: player.id, personId: player.personId);
        await ChipFlow.apply(context,
            distribution: dist,
            type: type,
            sessionId: session.id,
            transactionId: tx.id,
            holderRefId: holderRef);
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

  void _seatSheet(BuildContext context, SessionProvider provider, Player player) {
    final unlinked = player.personId == null ||
        player.personId!.isEmpty ||
        PlayerIdentityService.byId(player.personId) == null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('${tr('seat')} ${player.seatNumber} · ${player.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            // ICR-03: an occupied seat with no valid identity link must
            // not be left silently nameless. Linking is explicit and
            // never creates an identity.
            if (unlinked)
              ListTile(
                leading: const Icon(Icons.link, color: AppColors.gold),
                title: Text(tr('link_to_existing_player')),
                subtitle: Text(tr('unlinked_seat_hint'),
                    style: const TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  showLinkExistingPlayerSheet(context, player: player);
                },
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
              title: Text(tr('table_cash_out')),
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
            ListTile(
              leading: const Icon(Icons.savings_outlined, color: AppColors.gold),
              title: Text(tr('review_discount')),
              subtitle: Text(tr('discount_from_seat_hint'),
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                openDiscountReview(
                  context,
                  sessionId: provider.current!.id,
                  currency: provider.current!.currency,
                  player: player,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.style_outlined, color: AppColors.gold),
              title: Text(tr('record_hand')),
              onTap: () {
                Navigator.pop(ctx);
                _recordHand(context, provider);
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
    // ALWAYS ten seats, because the table artwork always shows ten
    // printed positions. A table configured for fewer marks the surplus
    // seats locked rather than omitting them — the pods stay in their
    // own fixed anchors, dimmed and non-tappable, so the geometry is
    // identical for a 6-, 8-, 9- or 10-seat table.
    final seats = [
      for (var n = 1; n <= TableAnchors.maxSeats; n++)
        SeatData(
          seatNumber: n,
          player: bySeat[n],
          profitLoss: bySeat[n] == null
              ? 0
              : SessionService.playerProfitLoss(session.id, bySeat[n]!.id),
          settled: bySeat[n] != null && !bySeat[n]!.isActive,
          hasCashedOut: bySeat[n] != null &&
              SessionService.hasCashedOut(session.id, bySeat[n]!.id),
          // STRICTLY the seat-count boundary. Deliberately NOT widened
          // for a seat that happens to hold a player: a seat outside the
          // configured count is locked, full stop. If a table was shrunk
          // while someone sat beyond the new limit, their pod renders
          // locked and the banker must raise the seat count to reach
          // them again — which is the honest signal that the table
          // configuration and the seating disagree.
          enabled: n <= table.seatCount,
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
                  // Seat-count boundary, enforced in BEHAVIOUR and not
                  // only in appearance. SeatWidget already refuses to
                  // deliver the tap for a locked seat, so this is the
                  // second of two independent gates: if the pod is ever
                  // made tappable again by a later change, a locked seat
                  // still cannot open the Add Player sheet or the seat
                  // sheet. Silent by design — a locked seat does
                  // absolutely nothing, per spec.
                  if (!seat.enabled) return;
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
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: LastHandSummary(
              hand: provider.lastHandAtActiveTable,
              formatter: fmt,
              tableName: table.name,
              onRecord: table.status.isClosed
                  ? null
                  : () => _recordHand(context, provider),
              onOpenHistory: () => _openHistory(context, session.id, table.id),
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

  Future<void> _recordHand(BuildContext context, SessionProvider provider) async {
    final tableId = provider.activeTableId;
    final hand = await showRecordHandSheet(context, tableId: tableId);
    if (hand != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('hand_recorded'))));
    }
  }

  void _openHistory(BuildContext context, String sessionId, String tableId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HandHistoryScreen(
        sessionId: sessionId,
        initialTableId: tableId,
      ),
    ));
  }
}
