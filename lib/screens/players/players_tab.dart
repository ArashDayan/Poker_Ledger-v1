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
import '../../services/table_service.dart';
import '../../widgets/player_card.dart';
import '../../widgets/signature_compare_sheet.dart';
import '../../widgets/signature_pad.dart';
import '../../widgets/table_selector_bar.dart';
import '../../widgets/quick_transaction_sheet.dart';
import '../player_action/player_action_screen.dart';
import '../player_action/player_ledger_screen.dart';
import '../player_history/player_history_screen.dart';

/// Players tab: seat management + the fast per-player money actions.
/// This is the banker's main screen during a live game — adding a player
/// and recording their opening buy-in is ONE action here (see
/// [showAddPlayerSheet]), and every subsequent buy-in/rebuy/cash-out is a
/// tap-then-confirm quick sheet rather than a full-screen form.
class PlayersTab extends StatelessWidget {
  const PlayersTab({super.key});

  static Future<void> showAddPlayerSheet(BuildContext context,
      {Player? existing, int? presetSeat}) async {
    final provider = context.read<SessionProvider>();
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    int? selectedSeat = existing?.seatNumber ?? presetSeat;
    final buyInCtrl = TextEditingController(
      text: isEdit ? '' : (provider.current?.defaultBuyInAmount?.toStringAsFixed(0) ?? ''),
    );
    final tags = <PlayerTag>{...(existing?.tags ?? [])};
    // The player's own reference signature. Captured once, at the table,
    // when they sit down — it is the specimen every later transaction
    // signature gets compared against if a dispute comes up.
    String sampleSignature = existing?.sampleSignatureBase64 ?? '';
    // Second specimen. Two samples let the app measure how much this
    // person's own signature naturally varies, which is what makes a
    // similarity score meaningful rather than arbitrary.
    String sampleSignature2 = existing?.sampleSignature2Base64 ?? '';
    // Snapshot of what was already on file, so we can tell "showing a
    // saved sample" apart from "the banker is drawing a new one".
    final existingSample = existing?.sampleSignatureBase64 ?? '';
    final existingSample2 = existing?.sampleSignature2Base64 ?? '';
    final fmt = CurrencyFormatter(provider.current!.currency);
    // Seat numbers are per-table, so both the seat grid and the
    // "already taken" check must be scoped to the table this player is
    // being seated at — Table 1 Seat 3 and Table 2 Seat 3 are two
    // different people.
    final targetTableId = existing != null
        ? TableService.tableForPlayer(provider.current!, existing).id
        : provider.activeTableId;
    final targetTable =
        TableService.tableById(provider.current!, targetTableId);
    final tableSeatCount = targetTable.seatCount;
    final occupiedByOthers = TableService.occupiedSeats(
      provider.current!,
      targetTableId,
      excludePlayerId: existing?.id,
    );

    // Phase 1: banker-only setup — name, seat, buy-in amount, private tags.
    // Tags are never shown again past this point, especially not on the
    // signature step the player themselves sees.
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(isEdit ? 'Edit Player' : 'Add Player',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                if (provider.isMultiTable) ...[
                  const SizedBox(height: 4),
                  Text(targetTable.name,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.accentGreen)),
                ],
                const SizedBox(height: 12),
                TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: InputDecoration(labelText: tr('name'))),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('seat'), style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(tableSeatCount, (i) => i + 1).map((seatNum) {
                    final takenByOther = occupiedByOthers.contains(seatNum);
                    final isSelected = selectedSeat == seatNum;
                    return ChoiceChip(
                      label: Text('$seatNum'),
                      selected: isSelected,
                      onSelected: takenByOther
                          ? null
                          : (v) => setSheetState(() => selectedSeat = v ? seatNum : null),
                      backgroundColor: takenByOther ? AppColors.divider.withValues(alpha: 0.3) : null,
                      labelStyle: takenByOther
                          ? const TextStyle(color: AppColors.textSecondary, decoration: TextDecoration.lineThrough)
                          : null,
                    );
                  }).toList(),
                ),
                if (!isEdit) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: buyInCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: tr('initial_buy_in'),
                      hintText: tr('skip_for_now'),
                      prefixText: fmt.symbol == '\$' ? '\$ ' : null,
                      suffixText: fmt.symbol == '\$' ? null : fmt.symbol,
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('player_sample_signature'),
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    tr('sample_signature_hint'),
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
                const SizedBox(height: 8),
                // An EXISTING saved sample shows as a preview with a
                // Recapture button. A sample being drawn right now must
                // NOT swap to a preview the instant the pen lifts — that
                // was the multi-stroke bug. The pad stays live, accepting
                // as many strokes as the player needs, and only commits
                // when they press Confirm.
                if (existingSample.isNotEmpty && sampleSignature == existingSample) ...[
                  SignatureImage(base64Png: sampleSignature, height: 96),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.verified_outlined,
                          size: 15, color: AppColors.accentGreen),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('${tr('sample_on_file')} 1',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.accentGreen)),
                      ),
                      TextButton(
                        onPressed: () => setSheetState(() => sampleSignature = ''),
                        child: Text(tr('recapture'),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ] else
                  SignaturePad(
                    requireConfirm: true,
                    height: 140,
                    caption: '${tr('sample_signature')} 1',
                    onChanged: (sig) => setSheetState(() => sampleSignature = sig),
                  ),
                const SizedBox(height: 12),
                if (existingSample2.isNotEmpty &&
                    sampleSignature2 == existingSample2) ...[
                  SignatureImage(base64Png: sampleSignature2, height: 96),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.verified_outlined,
                          size: 15, color: AppColors.accentGreen),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('${tr('sample_on_file')} 2',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.accentGreen)),
                      ),
                      TextButton(
                        onPressed: () =>
                            setSheetState(() => sampleSignature2 = ''),
                        child: Text(tr('recapture'),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ] else
                  SignaturePad(
                    requireConfirm: true,
                    height: 140,
                    caption: '${tr('sample_signature')} 2',
                    onChanged: (sig) =>
                        setSheetState(() => sampleSignature2 = sig),
                  ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('private_tags'),
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: PlayerTag.values.map((tag) {
                    final selected = tags.contains(tag);
                    return FilterChip(
                      label: Text(tag.label),
                      selected: selected,
                      onSelected: (v) => setSheetState(() {
                        v ? tags.add(tag) : tags.remove(tag);
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () async {
                    if (nameCtrl.text.trim().isEmpty) return;
                    if (selectedSeat == null) {
                      ScaffoldMessenger.of(ctx)
                          .showSnackBar(SnackBar(content: Text(tr('choose_seat_first'))));
                      return;
                    }
                    final seat = selectedSeat!;
                    if (existing != null) {
                      final player = existing;
                      player.name = nameCtrl.text.trim();
                      player.seatNumber = seat;
                      player.tags = tags.toList();
                      if (sampleSignature != (player.sampleSignatureBase64 ?? '')) {
                        await provider.setPlayerSampleSignature(
                            player, sampleSignature.isEmpty ? null : sampleSignature);
                      }
                      if (sampleSignature2 !=
                          (player.sampleSignature2Base64 ?? '')) {
                        await provider.setPlayerSampleSignature2(player,
                            sampleSignature2.isEmpty ? null : sampleSignature2);
                      }
                      // updatePlayer persists and notifies; refresh() makes
                      // the rename/reseat visible on every open tab in the
                      // same frame rather than a microtask later.
                      await provider.updatePlayer(player);
                      provider.refresh();
                      if (ctx.mounted) Navigator.pop(ctx);
                      return;
                    }

                    final buyIn = double.tryParse(buyInCtrl.text.replaceAll(',', ''));
                    final name = nameCtrl.text.trim();
                    final tagList = tags.toList();
                    final sample = sampleSignature.isEmpty ? null : sampleSignature;
                    // Sample 2 is captured in this same sheet, so it has
                    // to be carried into creation alongside Sample 1 —
                    // otherwise it is discarded when the sheet closes.
                    final sample2 =
                        sampleSignature2.isEmpty ? null : sampleSignature2;
                    Navigator.pop(ctx); // close the config sheet first

                    if ((buyIn ?? 0) <= 0) {
                      try {
                        await provider.addPlayerWithBuyIn(
                          name: name,
                          seatNumber: seat,
                          tags: tagList,
                          buyInAmount: null,
                          hostSignatureBase64: null,
                          sampleSignatureBase64: sample,
                          sampleSignature2Base64: sample2,
                        );
                        AppSounds.play(SoundEffect.addPlayer);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                      return;
                    }

                    // Phase 2: minimal player-facing signing step — ONLY
                    // action, amount, signature. No name context beyond the
                    // amount, no tags, nothing judgmental.
                    if (!context.mounted) return;
                    final result = await showQuickTransactionSheet(
                      context,
                      title: 'Buy-in',
                      type: TransactionType.buyIn,
                      initialAmount: buyIn,
                      formatter: fmt,
                      sessionId: provider.current!.id,
                    );
                    if (result == null) return;
                    try {
                      await provider.addPlayerWithBuyIn(
                        name: name,
                        seatNumber: seat,
                        tags: tagList,
                        buyInAmount: result.amount,
                        hostSignatureBase64: result.signature,
                        sampleSignatureBase64: sample,
                        sampleSignature2Base64: sample2,
                      );
                      AppSounds.play(SoundEffect.buyIn);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
                  child: Text(isEdit ? 'Save Changes' : 'Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    // Scoped to the selected table so a busy floor stays readable; a
    // single-table session sees exactly the same list as before.
    final players = provider.isMultiTable
        ? provider.playersAtActiveTable
        : provider.players;

    if (players.isEmpty) {
      return Column(
        children: [
          const TableSelectorBar(),
          Expanded(
            child: Center(
              child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.people_outline, size: 40, color: AppColors.textSecondary),
              const SizedBox(height: 12),
              Text(tr('no_players_yet'), style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () => showAddPlayerSheet(context),
                      icon: const Icon(Icons.person_add),
                      label: Text(tr('add_player')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(children: [
      const TableSelectorBar(),
      Expanded(
        child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: players.map((p) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PlayerCard(
                player: p,
                buyIn: SessionService.playerBuyInOnly(session.id, p.id),
                rebuy: SessionService.playerRebuyOnly(session.id, p.id),
                cashOut: SessionService.playerTotalCashOut(session.id, p.id),
                profitLoss: SessionService.playerProfitLoss(session.id, p.id),
                formatter: fmt,
                onToggleSettled: () => provider.toggleSettled(p),
                onEdit: () => showAddPlayerSheet(context, existing: p),
                onMoveTable: provider.isMultiTable
                    ? () => showMovePlayerSheet(context, p)
                    : null,
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => PlayerActionScreen(player: p))),
                onLedger: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlayerLedgerScreen(player: p))),
              ),
              Row(
                children: [
                  Expanded(
                    child: _quickChip(context, 'Buy-in', Icons.add_card,
                        () => _quickAction(context, provider, p, TransactionType.buyIn)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _quickChip(context, 'Rebuy', Icons.refresh,
                        () => _quickAction(context, provider, p, TransactionType.rebuy)),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _quickChip(context, 'Cash-out', Icons.logout,
                        () => _quickAction(context, provider, p, TransactionType.cashOut)),
                  ),
                  const SizedBox(width: 6),
                  // Straight to this player's cross-session record — the
                  // "is this regular up or down against me overall?"
                  // question a banker asks before extending credit.
                  SizedBox(
                    width: 40,
                    child: _quickChip(context, '', Icons.history,
                        () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                PlayerHistoryScreen(playerName: p.name)))),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
        ),
      ),
    ]);
  }

  Widget _quickChip(BuildContext context, String label, IconData icon, VoidCallback onTap) {
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(36),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
    // An empty label renders as an icon-only button, so the history
    // shortcut can sit alongside the money actions without crowding them.
    if (label.isEmpty) {
      return OutlinedButton(
        onPressed: onTap,
        style: style,
        child: Icon(icon, size: 16),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: style,
    );
  }
}
