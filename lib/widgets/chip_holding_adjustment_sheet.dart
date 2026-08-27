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

/// Reconciles a player's RECORDED chip holding with the ACTUAL physical
/// stack — the auditable bridge between "the log says 2M" and "the
/// player is holding 5M".
///
/// CHIP-ONLY BY DESIGN
/// This appends ChipMovementReason.adjustment movements and nothing
/// else. No money transaction, no FinancialEvent, no buy-in/rebuy/
/// cash-out, no rake — the settlement engine and the Discount engine
/// never see it. The correction is append-only: nothing recorded before
/// is edited or deleted.
Future<bool> showChipHoldingAdjustmentSheet(
  BuildContext context, {
  required List<Player> players,
  required AppCurrency currency,
  required String sessionId,
  Player? initialPlayer,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChipHoldingAdjustmentSheet(
      players: players,
      currency: currency,
      sessionId: sessionId,
      initialPlayer: initialPlayer,
    ),
  );
  return result ?? false;
}

class _ChipHoldingAdjustmentSheet extends StatefulWidget {
  final List<Player> players;
  final AppCurrency currency;
  final String sessionId;
  final Player? initialPlayer;

  const _ChipHoldingAdjustmentSheet({
    required this.players,
    required this.currency,
    required this.sessionId,
    this.initialPlayer,
  });

  @override
  State<_ChipHoldingAdjustmentSheet> createState() =>
      _ChipHoldingAdjustmentSheetState();
}

class _ChipHoldingAdjustmentSheetState
    extends State<_ChipHoldingAdjustmentSheet> {
  Player? _player;
  final Map<String, TextEditingController> _counts = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _player = widget.initialPlayer ??
        (widget.players.length == 1 ? widget.players.first : null);
    _seedCounts();
  }

  @override
  void dispose() {
    for (final c in _counts.values) {
      c.dispose();
    }
    super.dispose();
  }

  Player? _byId(String? id) {
    if (id == null) return null;
    for (final p in widget.players) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Pre-fill every denomination with the RECORDED quantity, so the
  /// banker edits only what the physical count disagrees with.
  void _seedCounts() {
    final chips = context.read<ChipBankProvider>().chips;
    for (final c in chips) {
      _counts[c.id]?.dispose();
      final held = _player == null
          ? 0
          : ChipTrackingService.quantityAt(
              ChipLocation.player(_player!.id), c.id);
      _counts[c.id] = TextEditingController(text: '$held');
    }
  }

  Map<String, int> _parsedCounts() {
    final out = <String, int>{};
    _counts.forEach((id, ctrl) {
      final v = int.tryParse(ctrl.text.trim());
      if (v != null && v >= 0) out[id] = v;
    });
    return out;
  }

  bool get _valid {
    if (_player == null) return false;
    final parsed = _parsedCounts();
    if (parsed.isEmpty) return false;
    // Every controller must parse — a half-typed number blocks confirm.
    if (parsed.length != _counts.length) return false;
    // At least one denomination must actually differ from the recorded
    // holding, otherwise there is nothing to adjust.
    var differs = false;
    for (final e in parsed.entries) {
      final held =
          ChipTrackingService.quantityAt(ChipLocation.player(_player!.id), e.key);
      if (held != e.value) {
        differs = true;
        break;
      }
    }
    return differs;
  }

  double _valueOf(Map<String, int> counts) =>
      ChipTrackingService.valueOf(counts);

  Future<void> _confirm() async {
    final p = _player;
    if (p == null) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Phase 2a: the count re-anchors the PERSON's holding (the
      // reference the ledger uses), not the seat's.
      final made = await ChipTrackingService.adjustPlayerHoldingToCount(
        playerId: ChipTrackingService.holderRef(
            playerId: p.id, personId: p.personId),
        counted: _parsedCounts(),
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      context.read<ChipBankProvider>().refresh();
      messenger.showSnackBar(
        SnackBar(
            content: Text(made.isEmpty
                ? tr('count_unchanged')
                : tr('holding_adjustment_recorded'))),
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
    final p = _player;

    final recorded = <String, int>{};
    for (final c in chips) {
      recorded[c.id] = p == null
          ? 0
          : ChipTrackingService.quantityAt(ChipLocation.player(p.id), c.id);
    }
    final parsed = _parsedCounts();
    final recordedValue = _valueOf(recorded);
    final countedValue =
        parsed.length == _counts.length ? _valueOf(parsed) : 0.0;

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
                          tr('chip_holding_adjustment'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Text(
                          tr('chip_holding_adjustment_desc'),
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
                  DropdownButtonFormField<String>(
                    value: p?.id,
                    isExpanded: true,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: tr('select_player'),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                    ),
                    items: [
                      for (final pl in widget.players)
                        DropdownMenuItem(
                          value: pl.id,
                          child: Text(
                              '${tr('seat')} ${pl.seatNumber} · ${pl.name}',
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (id) => setState(() {
                              _player = _byId(id);
                              _seedCounts();
                            }),
                  ),
                  const SizedBox(height: 14),
                  if (p != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color:
                            AppColors.gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(tr('current_recorded_holding'),
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.textSecondary)),
                          Text(fmt.formatRaw(recordedValue),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    for (final c in chips)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                c.hasName
                                    ? '${fmt.formatRaw(c.value)} · ${c.name}'
                                    : fmt.formatRaw(c.value),
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            Text(
                              '${tr('recorded')}: ${recorded[c.id] ?? 0}',
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textSecondary),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 92,
                              child: TextField(
                                controller: _counts[c.id],
                                keyboardType: TextInputType.number,
                                enabled: !_saving,
                                textAlign: TextAlign.center,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: tr('physical_count'),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(tr('choose_player_first'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary)),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(16)),
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
                            Text(tr('recorded'),
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.textSecondary)),
                            Text(fmt.formatRaw(recordedValue),
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward,
                        size: 18,
                        color: AppColors.gold.withValues(alpha: 0.8),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(tr('counted'),
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.textSecondary)),
                            Text(fmt.formatRaw(countedValue),
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: countedValue > recordedValue
                                        ? AppColors.accentGreen
                                        : AppColors.textPrimary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('adjustment_no_money_note'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10.5, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed:
                              _saving ? null : () => Navigator.pop(context, false),
                          child: Text(tr('cancel')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 46,
                          child: ElevatedButton.icon(
                            onPressed:
                                _valid && !_saving ? _confirm : null,
                            icon: _saving
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.fact_check_outlined),
                            label: Text(tr('confirm_exchange')),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
