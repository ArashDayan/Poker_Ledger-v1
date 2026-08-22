import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/player.dart';
import '../../providers/session_provider.dart';
import '../../services/financial_capture_flow.dart';
import '../../widgets/cashout_flow.dart';
import '../../services/player_identity_service.dart';
import '../../services/player_registry_service.dart';
import '../../models/chip_movement.dart';
import '../../services/chip_tracking_service.dart';
import '../../services/session_service.dart';
import '../../services/sound_service.dart';
import '../../services/table_service.dart';
import '../../widgets/identity_link_sheet.dart';
import '../../widgets/player_card.dart';
import '../../widgets/player_type_badge.dart';
import '../../widgets/signature_compare_sheet.dart';
import '../../widgets/signature_pad.dart';
import '../../widgets/table_selector_bar.dart';
import '../../widgets/chip_flow.dart';
import '../../widgets/discount_review_entry.dart';
import '../../widgets/quick_transaction_sheet.dart';
import '../player_action/player_action_screen.dart';
import '../player_action/player_ledger_screen.dart';
import '../player_account/player_account_screen.dart';
import '../player_history/player_history_screen.dart';

/// Players tab: seat management + the fast per-player money actions.
/// This is the banker's main screen during a live game — adding a player
/// and recording their opening buy-in is ONE action here (see
/// [showAddPlayerSheet]), and every subsequent buy-in/rebuy/cash-out is a
/// tap-then-confirm quick sheet rather than a full-screen form.
class PlayersTab extends StatelessWidget {
  const PlayersTab({super.key});

  /// Opens the add/edit player sheet.
  ///
  /// [presetTableId] is the table the banker was actually looking at when
  /// they tapped an empty seat. Passing it makes the destination explicit
  /// rather than inferred: without it the provider had to guess from
  /// `isMultiTable`, which reads false whenever `session.tables` has not
  /// been materialised yet, and the player was then stored with a null
  /// tableId and vanished from the table the banker was standing at.
  ///
  /// Null means "no specific table" (the Players tab / app-bar entry
  /// points), where the provider's existing default is correct.
  static Future<void> showAddPlayerSheet(BuildContext context,
      {Player? existing, int? presetSeat, String? presetTableId}) async {
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
                    return ChoiceChip(
                      label: Text(tag.localizedLabel),
                      selected: selected,
                      // Classification is mutually exclusive: at most ONE
                      // may be held at a time. Clearing the set before
                      // adding is what enforces that — and it also
                      // normalises any legacy record that was saved with
                      // several tags, the moment the banker touches it.
                      //
                      // Re-tapping the selected chip clears it, so "no
                      // classification" stays a reachable, valid state.
                      onSelected: (v) => setSheetState(() {
                        tags.clear();
                        if (v) tags.add(tag);
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

                    // BLACKLIST GATE — creation path only.
                    //
                    // Placed here, after validation but before anything
                    // is written, so every add-player route funnels
                    // through it: the Players tab, an empty seat on the
                    // poker table, and the app-bar action all open this
                    // same sheet.
                    //
                    // Editing an existing player returned above, which
                    // is deliberate: they are already seated, so warning
                    // about it would be noise rather than a decision.
                    //
                    // A strong warning, never a lock — Continue seats
                    // them normally, Cancel abandons the add entirely.
                    if (PlayerRegistryService.isBlacklistedName(
                        nameCtrl.text.trim())) {
                      final proceed = await confirmBlacklistedPlayer(
                        ctx,
                        playerName: nameCtrl.text.trim(),
                      );
                      if (!proceed) return;
                    }

                    // IDENTITY GATE — creation path only.
                    //
                    // A name match is only a suggestion. The service
                    // never auto-links; this dialog is the confirmation
                    // the rule requires. Cancel aborts the add so a
                    // dismissed prompt cannot silently create a
                    // duplicate person or merge two people.
                    final name = nameCtrl.text.trim();
                    String? personId;
                    try {
                      personId =
                          await PlayerIdentityService.resolveForSeating(
                        name: name,
                        confirm: (suggestions) => confirmIdentityLink(
                          ctx,
                          typedName: name,
                          suggestions: suggestions,
                        ),
                      );
                    } catch (e) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('$e')));
                      }
                      return;
                    }
                    if (personId == null &&
                        PlayerIdentityService.suggest(name).isNotEmpty) {
                      // Suggestions existed and the banker cancelled.
                      return;
                    }

                    final buyIn = double.tryParse(buyInCtrl.text.replaceAll(',', ''));
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
                          // Explicit destination when the sheet was
                          // opened from a table's empty seat.
                          tableId: presetTableId,
                          personId: personId,
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
                      title: tr('buy_in'),
                      type: TransactionType.buyIn,
                      initialAmount: buyIn,
                      formatter: fmt,
                      sessionId: provider.current!.id,
                    );
                    if (result == null) return;
                    final funding = await collectRequiredFunding(
                      context,
                      chipType: TransactionType.buyIn,
                      amount: result.amount,
                      currency: provider.current!.currency,
                    );
                    if (!funding.shouldCommit || !context.mounted) return;
                    // Chip composition is optional. Skip / dismiss does
                    // not abort the already-confirmed buy-in + funding.
                    final openingDist = await ChipFlow.ask(
                      context,
                      amount: result.amount,
                      currency: provider.current!.currency,
                    );
                    if (!context.mounted) return;
                    try {
                      final created = await provider.addPlayerWithBuyIn(
                        name: name,
                        seatNumber: seat,
                        tags: tagList,
                        buyInAmount: result.amount,
                        hostSignatureBase64: result.signature,
                        sampleSignatureBase64: sample,
                        sampleSignature2Base64: sample2,
                        tableId: presetTableId,
                        personId: personId,
                      );
                      if (context.mounted) {
                        // The opening buy-in is the last transaction the
                        // provider wrote for this player.
                        final tx = SessionService.transactionsFor(
                                provider.current!.id)
                            .where((t) => t.playerId == created.id)
                            .toList();
                        if (tx.isNotEmpty) {
                          await ChipFlow.apply(
                            context,
                            distribution: openingDist,
                            type: TransactionType.buyIn,
                            sessionId: provider.current!.id,
                            transactionId: tx.last.id,
                            // Phase 2a: chips enter the person's holding.
                            holderRefId: ChipTrackingService.holderRef(
                                playerId: created.id,
                                personId: created.personId),
                          );
                          if (context.mounted) {
                            await applyCollectedFunding(
                              context,
                              player: created,
                              chipType: TransactionType.buyIn,
                              amount: result.amount,
                              currency: provider.current!.currency,
                              sessionId: provider.current!.id,
                              transactionId: tx.last.id,
                              funding: funding,
                            );
                          }
                        }
                      }
                      AppSounds.play(SoundEffect.buyIn);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
                  child: Text(isEdit ? 'Save Changes' : 'Continue'),
                ),
                // Remove from seat: frees the seat, keeps the
                // registration, the records and the person. Confirm
                // first — it changes who the seat points at, and the
                // confirmation says exactly what survives.
                if (isEdit && existing != null && existing.seated) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () async {
                      final ok = await confirmUnseat(ctx);
                      if (!ok) return;
                      try {
                        await provider.unseatPlayer(existing);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx)
                              .showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                    },
                    child: Text(tr('unseat_player'),
                        style: const TextStyle(color: AppColors.danger)),
                  ),
                ],
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

    // Phase 7: a seated cash-out is the TABLE CASH-OUT — the table
    // level. No funding question (no cash comes back — the counted
    // chips stay the person's physical holding), no chip composition
    // step, no cage redemption (that is the person-level redemption,
    // from the player account).
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

    final dist = ChipFlow.appliesTo(type)
        ? await ChipFlow.ask(
            context,
            amount: result.amount,
            currency: session.currency,
          )
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
        await ChipFlow.apply(context,
            distribution: dist,
            type: type,
            sessionId: session.id,
            transactionId: tx.id,
            // Phase 2a: person-scoped chip holding.
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

  /// Registers a player for the ACTIVE SESSION without a seat.
  ///
  /// The identity is resolved with the same confirm-on-suggest rule as
  /// seating (a name match is only a suggestion; cancel aborts), then
  /// the provider writes an unseated registration row. No money, chips
  /// or seat are touched.
  static Future<void> showRegisterForSessionSheet(BuildContext context) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current;
    if (session == null) return;
    final nameCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollable: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('register_player_title'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(tr('register_player_hint'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: tr('name')),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;

                // BLACKLIST GATE — same rule as the add-player flow.
                if (PlayerRegistryService.isBlacklistedName(name)) {
                  final proceed = await confirmBlacklistedPlayer(
                    ctx,
                    playerName: name,
                  );
                  if (!proceed) return;
                }

                // IDENTITY GATE — confirm-on-suggest, never auto-link.
                String? personId;
                try {
                  personId = await PlayerIdentityService.resolveForSeating(
                    name: name,
                    confirm: (suggestions) => confirmIdentityLink(
                      ctx,
                      typedName: name,
                      suggestions: suggestions,
                    ),
                  );
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('$e')));
                  }
                  return;
                }
                if (personId == null &&
                    PlayerIdentityService.suggest(name).isNotEmpty) {
                  // Suggestions existed and the banker cancelled.
                  return;
                }
                if (personId == null) return;
                final alreadyRegistered =
                    SessionService.registeredForSession(session.id, personId) !=
                        null;
                if (ctx.mounted) Navigator.pop(ctx);

                try {
                  await provider.registerPlayer(
                    personId: personId,
                    name: name,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(alreadyRegistered
                            ? '${name} ${tr('already_registered')}'
                            : '${name} — ${tr('not_seated')}'),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e')));
                  }
                }
              },
              child: Text(tr('register_player')),
            ),
          ],
        ),
      ),
    );
  }

  /// Seats a registered (unseated) player. Table list + first free
  /// seat per table, mirroring the move-player sheet's shape.
  static Future<void> showSeatRegisteredSheet(
      BuildContext context, Player player) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current;
    if (session == null) return;
    final tables = TableService.tablesFor(session);

    await showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final live = context.read<SessionProvider>().livePlayer(player);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${tr('seat_registered_title')}: ${live.name}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(tr('not_seated'),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(height: 14),
                ...tables.map((t) {
                  final free = TableService.firstFreeSeat(session, t.id);
                  final count = TableService.playerCountAt(session, t.id);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.table_bar_outlined,
                        color: AppColors.accentGreen),
                    title: Text(t.name),
                    subtitle: Text(free == null
                        ? '${tr('full')} ($count/${t.seatCount})'
                        : '${tr('seat')} $free ${tr('free')} · $count/${t.seatCount} ${tr('seated')}'),
                    enabled: free != null,
                    onTap: free == null
                        ? null
                        : () async {
                            try {
                              await provider.seatRegisteredPlayer(live, t.id);
                              if (ctx.mounted) Navigator.pop(ctx);
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(content: Text('$e')));
                              }
                            }
                          },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// RE-ENTRY (Phase 7): the unseated player commits the chips they
  /// ALREADY hold (person-scoped holding) to a table.
  ///
  /// Step 1 — choose the table (same shape as the seat sheet).
  /// Step 2 — the counted carried amount (pre-filled with the person's
  /// held chips) + host signature, through the standard quick sheet.
  ///
  /// THE GUARANTEES (enforced in the service, surfaced here):
  ///   * NO second buy-in — totalBuyIn and every wallet figure are
  ///     untouched; the original purchase is never counted again.
  ///   * NO chip movement — the held chips travel with the person.
  ///   * NO cash changes hands — no Financial Ledger event.
  ///   * A NEW TableParticipation opens at the destination.
  static Future<void> showReentrySheet(BuildContext context, Player player) async {
    final provider = context.read<SessionProvider>();
    final session = provider.current;
    if (session == null) return;
    final personId = player.personId;
    if (personId == null || personId.isEmpty) return;

    // The person's held chips — the pre-fill for the counted amount.
    // A holding the chip ledger has under-recorded simply pre-fills a
    // lower number; the banker's count remains the authority (E9).
    double held = 0;
    try {
      held = ChipTrackingService
              .holdingAt(ChipLocation.player(personId))
              .totalValue;
    } catch (_) {
      // Chip boxes not open — pre-fill stays empty.
    }

    final fmt = CurrencyFormatter(session.currency);
    await showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final live = context.read<SessionProvider>().livePlayer(player);
        final tables = TableService.tablesFor(session);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('${tr('reentry_title')}: ${live.name}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(tr('reentry_body'),
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textSecondary)),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(tr('reentry_held_label'),
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                    Text(fmt.format(held),
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.gold)),
                  ],
                ),
                const SizedBox(height: 14),
                ...tables.map((t) {
                  final free = TableService.firstFreeSeat(session, t.id);
                  final count = TableService.playerCountAt(session, t.id);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.login,
                        color: AppColors.accentGreen),
                    title: Text(t.name),
                    subtitle: Text(free == null
                        ? '${tr('full')} ($count/${t.seatCount})'
                        : '${tr('seat')} $free ${tr('free')} · $count/${t.seatCount} ${tr('seated')}'),
                    enabled: free != null,
                    onTap: free == null
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            if (!context.mounted) return;
                            final result = await showQuickTransactionSheet(
                              context,
                              title:
                                  '${tr('reentry')} · ${live.name}',
                              type: TransactionType.reentry,
                              initialAmount: held > 0 ? held : null,
                              formatter: fmt,
                              allowZero: false,
                              sessionId: session.id,
                            );
                            if (result == null) return;
                            if (result.signature == null ||
                                result.signature!.isEmpty) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content:
                                          Text(tr('host_signature_required_tx'))),
                                );
                              }
                              return;
                            }
                            try {
                              await context
                                  .read<SessionProvider>()
                                  .reenterWithHeldChips(
                                    context
                                        .read<SessionProvider>()
                                        .livePlayer(player),
                                    t.id,
                                    amount: result.amount,
                                    hostSignatureBase64: result.signature!,
                                  );
                              if (context.mounted) {
                                AppSounds.play(AppSounds
                                    .forTransaction(
                                        TransactionType.reentry));
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(
                                        SnackBar(content: Text('$e')));
                              }
                            }
                          },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Removes a seated player from their seat. Confirm-first, and the
  /// confirmation states explicitly what is (and is not) preserved —
  /// the row, its records and the person all survive; only the seat
  /// is freed.
  static Future<bool> confirmUnseat(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('unseat_confirm_title')),
        content: Text(tr('unseat_confirm_body'), style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('unseat_player')),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Deletes a clean unseated registration. Blocked (with explanation)
  /// whenever the row carries this session's records — the provider
  /// enforces the same rule, so the UI can never be the only guard.
  static Future<void> removeRegistrationFlow(
      BuildContext context, Player player) async {
    final provider = context.read<SessionProvider>();
    final hasRecords = SessionService
            .transactionsFor(provider.current!.id, includeVoided: true)
            .any((t) => t.playerId == player.id);
    if (hasRecords) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('remove_registration_blocked'))));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('remove_registration_confirm_title')),
        content:
            Text(tr('remove_registration_confirm_body'), style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(tr('remove_registration')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await provider.removeRegistration(player);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// One row in the "Registered — not seated" section. Deliberately
  /// smaller than [PlayerCard]: an unseated registration has no buy-in,
  /// no stack and no money actions to offer — only seating, the
  /// person's account, history, and (when clean) removal.
  Widget _unseatedRow(
      BuildContext context, SessionProvider provider, Player p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.feltGreen,
                child: Text(
                  p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(tr('not_seated'),
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              // RE-ENTRY (Phase 7): commit the person's held chips to a
              // table — no buy-in, no chip movement, no cash. Only for
              // person-linked rows (an unlinked legacy seat has no
              // person-scoped holding to carry).
              if (p.personId != null && p.personId!.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => showReentrySheet(context, p),
                  icon: const Icon(Icons.login, size: 15),
                  label: Text(tr('reentry_player'),
                      style: const TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(36)),
                ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                onPressed: () => showSeatRegisteredSheet(context, p),
                icon: const Icon(Icons.format_list_numbered, size: 15),
                label: Text(tr('seat_player'),
                    style: const TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(36)),
              ),
              const SizedBox(width: 6),
              if (p.personId != null && p.personId!.isNotEmpty)
                IconButton(
                  tooltip: tr('view_financial_account'),
                  icon: const Icon(Icons.account_balance_wallet_outlined,
                      size: 18, color: AppColors.gold),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlayerAccountScreen(
                        personId: p.personId!,
                        displayName: p.name,
                      ),
                    ),
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: tr('manage_player'),
                icon: const Icon(Icons.more_vert,
                    size: 18, color: AppColors.textSecondary),
                padding: EdgeInsets.zero,
                onSelected: (v) {
                  if (v == 'history' &&
                      p.personId != null &&
                      p.personId!.isNotEmpty &&
                      mounted) {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PlayerHistoryScreen(
                          playerName: p.name, personId: p.personId),
                    ));
                  } else if (v == 'remove') {
                    removeRegistrationFlow(context, p);
                  }
                },
                itemBuilder: (_) => [
                  if (p.personId != null && p.personId!.isNotEmpty)
                    PopupMenuItem(
                      value: 'history',
                      child: Row(
                        children: [
                          const Icon(Icons.history, size: 18),
                          const SizedBox(width: 10),
                          Text(tr('history')),
                        ],
                      ),
                    ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline,
                            size: 18, color: AppColors.danger),
                        const SizedBox(width: 10),
                        Text(tr('remove_registration'),
                            style: const TextStyle(color: AppColors.danger)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    // Seated players only, scoped to the selected table so a busy
    // floor stays readable. Unseated registrations are listed below in
    // their own section — they hold no seat and take no money actions.
    final players = provider.isMultiTable
        ? provider.playersAtActiveTable
        : provider.seatedPlayers;
    final unseated = provider.unseatedPlayers;

    if (players.isEmpty && unseated.isEmpty) {
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
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => showRegisterForSessionSheet(context),
                      icon: const Icon(Icons.badge_outlined),
                      label: Text(tr('register_player')),
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
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: () => showRegisterForSessionSheet(context),
            icon: const Icon(Icons.person_add, size: 16),
            label: Text(tr('register_player'),
                style: const TextStyle(fontSize: 12)),
          ),
        ),
        if (unseated.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(tr('unseated_players'),
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary)),
          ),
          for (final p in unseated) _unseatedRow(context, provider, p),
          const SizedBox(height: 10),
        ],
        if (players.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(tr('no_players_yet'),
                style:
                    const TextStyle(color: AppColors.textSecondary)),
          ),
        ...players.map((p) {
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
                hasCashedOut: SessionService.hasCashedOut(session.id, p.id),
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
              const SizedBox(height: 6),
              DiscountReviewTile(
                sessionId: session.id,
                currency: session.currency,
                player: p,
              ),
              const SizedBox(height: 6),
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
                                PlayerHistoryScreen(
                                    playerName: p.name,
                                    personId: p.personId)))),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
      ],
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
