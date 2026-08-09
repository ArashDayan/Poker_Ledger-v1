import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../providers/chip_bank_provider.dart';
import '../services/chip_tracking_service.dart';
import 'chip_picker_list.dart';

/// Physical chips moving directly from one player to another.
///
/// WHY THE BANK AND THE MONEY LEDGER ARE BOTH UNTOUCHED
/// When one player pushes chips to another — settling a side bet, paying
/// off a loan between themselves, or simply handing over a pot — no chips
/// enter or leave the Bank, and the house is not a party to it. Bank
/// inventory is therefore unchanged by construction: both the `from` and
/// `to` of the recorded movement are player locations, so the Bank's
/// derived balance cannot move.
///
/// Equally, no [LedgerTransaction] is created. The banker's settlement is
/// computed from buy-ins, rebuys and cash-outs; a private transfer
/// between two players is not any of those. Recording one here would
/// corrupt both players' financial positions. What this DOES fix is the
/// physical picture: cash-out chip counts now reconcile against who is
/// actually holding what.
Future<bool> showChipTransferSheet(
  BuildContext context, {
  required List<Player> players,
  required AppCurrency currency,
  required String sessionId,
  Player? initialFrom,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChipTransferSheet(
      players: players,
      currency: currency,
      sessionId: sessionId,
      initialFrom: initialFrom,
    ),
  );
  return result ?? false;
}

class _ChipTransferSheet extends StatefulWidget {
  final List<Player> players;
  final AppCurrency currency;
  final String sessionId;
  final Player? initialFrom;

  const _ChipTransferSheet({
    required this.players,
    required this.currency,
    required this.sessionId,
    this.initialFrom,
  });

  @override
  State<_ChipTransferSheet> createState() => _ChipTransferSheetState();
}

class _ChipTransferSheetState extends State<_ChipTransferSheet> {
  Player? _from;
  Player? _to;
  final Map<String, int> _selection = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
  }

  Player? _byId(String? id) {
    if (id == null) return null;
    for (final p in widget.players) {
      if (p.id == id) return p;
    }
    return null;
  }

  double get _value => ChipTrackingService.valueOf(_selection);

  int get _chipCount =>
      _selection.values.fold(0, (sum, q) => sum + q);

  /// The source must actually hold the chips. This is a hard gate: chips
  /// a player does not have cannot be handed to anyone, and allowing it
  /// would drive that player's derived holding negative — a state that
  /// silently poisons the reconciliation report.
  bool get _sourceCanCover {
    final f = _from;
    if (f == null) return false;
    for (final e in _selection.entries) {
      final held =
          ChipTrackingService.quantityAt(ChipLocation.player(f.id), e.key);
      if (e.value > held) return false;
    }
    return true;
  }

  bool get _canConfirm =>
      _from != null &&
      _to != null &&
      _from!.id != _to!.id &&
      _chipCount > 0 &&
      _sourceCanCover &&
      !_saving;

  Future<void> _confirm() async {
    final f = _from;
    final t = _to;
    if (f == null || t == null) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChipTrackingService.recordPlayerTransfer(
        fromPlayerId: f.id,
        toPlayerId: t.id,
        distribution: _selection,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      context.read<ChipBankProvider>().refresh();
      messenger.showSnackBar(
        SnackBar(content: Text(tr('transfer_recorded'))),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChipBankProvider>();
    final chips = provider.chips;
    final fmt = CurrencyFormatter(widget.currency);
    final f = _from;

    final sourceAvailable = <String, int>{};
    for (final c in chips) {
      sourceAvailable[c.id] = f == null
          ? 0
          : ChipTrackingService.quantityAt(ChipLocation.player(f.id), c.id);
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('player_chip_transfer'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          tr('player_chip_transfer_desc'),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                children: [
                  _PlayerField(
                    label: tr('from_player'),
                    value: _from?.id,
                    players: widget.players,
                    enabled: !_saving,
                    onChanged: (id) => setState(() {
                      _from = _byId(id);
                      // Holdings are per-player, so a selection made
                      // against the previous source is meaningless now.
                      _selection.clear();
                      if (_to?.id == _from?.id) _to = null;
                    }),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Icon(Icons.south,
                        size: 20, color: AppColors.gold.withValues(alpha: 0.8)),
                  ),
                  const SizedBox(height: 10),
                  _PlayerField(
                    label: tr('to_player'),
                    value: _to?.id,
                    // A player cannot transfer to themselves; removing
                    // the option is clearer than rejecting it later.
                    players: widget.players
                        .where((p) => p.id != _from?.id)
                        .toList(),
                    enabled: !_saving,
                    onChanged: (id) => setState(() => _to = _byId(id)),
                  ),

                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('chips_to_transfer'),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary),
                        ),
                      ),
                      Text(
                        fmt.formatRaw(_value),
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.accentGreen),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (f == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        tr('choose_source_player_first'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    )
                  else
                    ChipPickerList(
                      chips: chips,
                      fmt: fmt,
                      selection: _selection,
                      available: sourceAvailable,
                      availableLabel: tr('player_holds'),
                      hideUnavailable: true,
                      onChanged: (id, q) => setState(() {
                        if (q <= 0) {
                          _selection.remove(id);
                        } else {
                          _selection[id] = q;
                        }
                      }),
                    ),
                ],
              ),
            ),

            _TransferFooter(
              fmt: fmt,
              value: _value,
              chipCount: _chipCount,
              hasBoth: _from != null && _to != null,
              sourceCanCover: _sourceCanCover,
              saving: _saving,
              canConfirm: _canConfirm,
              onCancel: () => Navigator.pop(context, false),
              onConfirm: _confirm,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerField extends StatelessWidget {
  final String label;
  final String? value;
  final List<Player> players;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  const _PlayerField({
    required this.label,
    required this.value,
    required this.players,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          hint: Text(tr('choose_player')),
          items: [
            for (final p in players)
              DropdownMenuItem(
                value: p.id,
                child: Text('Seat ${p.seatNumber} · ${p.name}',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}

class _TransferFooter extends StatelessWidget {
  final CurrencyFormatter fmt;
  final double value;
  final int chipCount;
  final bool hasBoth;
  final bool sourceCanCover;
  final bool saving;
  final bool canConfirm;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _TransferFooter({
    required this.fmt,
    required this.value,
    required this.chipCount,
    required this.hasBoth,
    required this.sourceCanCover,
    required this.saving,
    required this.canConfirm,
    required this.onCancel,
    required this.onConfirm,
  });

  String? get _blocker {
    if (!hasBoth) return tr('choose_both_players');
    if (chipCount <= 0) return tr('select_chips_to_transfer');
    if (!sourceCanCover) return tr('player_lacks_chips');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _blocker;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('total_chips'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary)),
                    Text('$chipCount',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(tr('transfer_value'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary)),
                    Text(fmt.formatRaw(value),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.accentGreen)),
                  ],
                ),
              ),
            ],
          ),
          if (blocker != null) ...[
            const SizedBox(height: 8),
            Text(
              blocker,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.warning),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            tr('transfer_no_money_note'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 10.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: saving ? null : onCancel,
                  child: Text(tr('cancel')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: canConfirm ? onConfirm : null,
                    icon: saving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.swap_calls),
                    label: Text(tr('confirm_transfer')),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
