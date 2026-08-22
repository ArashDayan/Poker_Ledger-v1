import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../models/transaction.dart';
import '../providers/chip_bank_provider.dart';
import '../services/chip_tracking_service.dart';
import '../services/hive_service.dart';
import 'chip_flow.dart';

/// Edits the physical chip breakdown already recorded against a money
/// transaction.
///
/// WHAT THIS DOES *NOT* DO
/// It never touches the transaction's amount, its signature, its void
/// state, or anything the settlement engine reads. The money leg is
/// already final by the time this opens; only the physical chip
/// composition is being corrected.
///
/// HOW THE CORRECTION IS APPLIED
/// Not by rewriting the original records. [ChipTrackingService.editDistribution]
/// appends compensating reversal movements that cancel what is currently
/// in force, then appends the corrected composition. The resulting
/// balances are identical to a correct original entry, but the movement
/// log still shows the mistake, the reversal, and the fix — which is the
/// whole point of an audit trail. Nothing is ever deleted.
Future<bool> showChipCompositionEditor(
  BuildContext context, {
  required LedgerTransaction transaction,
  required AppCurrency currency,
  String? tableId,
}) async {
  if (!ChipFlow.appliesTo(transaction.type)) return false;

  // A voided transaction has no chip legs in force — they were all
  // reversed. Editing here would re-issue chips against a transaction
  // that has no money effect, and would then make Restore a no-op
  // because it skips when movements are already active. The Timeline
  // already hides the menu entry; this is the guard that makes the rule
  // hold for any future caller.
  if (transaction.isVoided) return false;

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChipCompositionEditor(
      transaction: transaction,
      currency: currency,
      tableId: tableId,
    ),
  );
  return result ?? false;
}

class _ChipCompositionEditor extends StatefulWidget {
  final LedgerTransaction transaction;
  final AppCurrency currency;
  final String? tableId;

  const _ChipCompositionEditor({
    required this.transaction,
    required this.currency,
    this.tableId,
  });

  @override
  State<_ChipCompositionEditor> createState() => _ChipCompositionEditorState();
}

class _ChipCompositionEditorState extends State<_ChipCompositionEditor> {
  /// The breakdown as it stands on disk, captured once at open. Shown
  /// beside the editable copy so the banker can see exactly what they
  /// are changing.
  late final Map<String, int> _original;
  late Map<String, int> _selection;
  bool _saving = false;

  /// Where this transaction's chips physically come from (Phase 2b,
  /// direction-correct): the Bank for outflows; the holder's
  /// PERSON-scoped holding for inflows (seat ref only when the seat is
  /// legacy-unlinked); the table for table-level flows.
  ChipLocation get _sourceLocation {
    final out = ChipFlow.leavesBank(widget.transaction.type);
    if (out) return ChipLocation.bank;
    final ref = widget.transaction.playerId;
    if (ref != null) {
      final seat = HiveService.players.get(ref);
      return ChipLocation.player(ChipTrackingService.holderRef(
          playerId: ref, personId: seat?.personId));
    }
    return widget.tableId != null
        ? ChipLocation.table(widget.tableId)
        : ChipLocation.bank;
  }

  @override
  void initState() {
    super.initState();
    _original = _activeDistribution();
    _selection = {..._original};
  }

  /// Rebuilds the currently-in-force composition from the movement log.
  /// Reversed legs are already excluded by the service, so a transaction
  /// that was voided and restored reports what is actually in force now.
  Map<String, int> _activeDistribution() {
    final dist = <String, int>{};
    for (final m
        in ChipTrackingService.activeMovementsForTransaction(
            widget.transaction.id)) {
      dist[m.chipTypeId] = (dist[m.chipTypeId] ?? 0) + m.quantity;
    }
    return dist;
  }

  double get _selectedValue => ChipTrackingService.valueOf(_selection);
  double get _originalValue => ChipTrackingService.valueOf(_original);

  bool get _changed {
    if (_selection.length != _original.length) return true;
    for (final e in _selection.entries) {
      if ((_original[e.key] ?? 0) != e.value) return true;
    }
    return false;
  }

  void _set(String id, int qty) {
    setState(() {
      if (qty <= 0) {
        _selection.remove(id);
      } else {
        _selection[id] = qty;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Phase 2a: a composition correction must keep the chips on the
      // PERSON's holding (the seat row ref for a legacy unlinked seat).
      final seatRef = widget.transaction.playerId;
      final seat = seatRef == null ? null : HiveService.players.get(seatRef);
      await ChipFlow.edit(
        context,
        transactionId: widget.transaction.id,
        distribution: _selection,
        type: widget.transaction.type,
        sessionId: widget.transaction.sessionId,
        holderRefId: seatRef == null
            ? null
            : ChipTrackingService.holderRef(
                playerId: seatRef, personId: seat?.personId),
        tableId: widget.tableId,
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(tr('chip_composition_updated'))),
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
    final amount = widget.transaction.amount;

    // Chips leaving the bank are limited by what the bank holds — but
    // the quantity ALREADY committed by this transaction is notionally
    // returned first by the reversal, so it counts as available.
    final out = ChipFlow.leavesBank(widget.transaction.type);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('edit_chip_composition'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context, false),
                      ),
                    ],
                  ),
                  Text(
                    '${widget.transaction.type.label} · ${fmt.formatRaw(amount)}',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr('edit_chip_composition_note'),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),

            // The as-recorded breakdown, read-only.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: _OriginalPanel(
                original: _original,
                originalValue: _originalValue,
                fmt: fmt,
                chipLabel: _chipLabel,
              ),
            ),

            Expanded(
              child: chips.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr('no_chips_yet'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      children: [
                        for (final chip in chips)
                          Builder(builder: (_) {
                            // What the SOURCE can supply (Phase 2b,
                            // direction-correct: bank for outflows, the
                            // holder's person holding for inflows, the
                            // table for table-level flows), with this
                            // transaction's own contribution added back
                            // because the edit reverses it first.
                            final atSource = ChipTrackingService.quantityAt(
                                _sourceLocation, chip.id);
                            final committed = _original[chip.id] ?? 0;
                            final available = atSource + committed;
                            return _EditRow(
                              label: (chip.name != null &&
                                      chip.name!.isNotEmpty)
                                  ? '${fmt.format(chip.value)} · ${chip.name}'
                                  : fmt.format(chip.value),
                              was: committed,
                              available: available,
                              sourceLabel: out
                                  ? tr('in_bank')
                                  : tr('source_available'),
                              showAvailable: true,
                              colorValue: chip.colorValue,
                              quantity: _selection[chip.id] ?? 0,
                              lineValue: fmt.format(
                                  chip.value * (_selection[chip.id] ?? 0)),
                              onChanged: (q) => _set(chip.id, q),
                            );
                          }),
                      ],
                    ),
            ),

            _EditFooter(
              fmt: fmt,
              target: amount,
              selected: _selectedValue,
              changed: _changed,
              saving: _saving,
              onCancel: () => Navigator.pop(context, false),
              onSave: _save,
            ),
          ],
        ),
      ),
    );
  }

  String _chipLabel(String chipTypeId, CurrencyFormatter fmt) {
    // Deliberately not `firstOrNull` (package:collection) — a plain loop
    // keeps this file dependency-free and handles a denomination that
    // was deleted after the movement was recorded.
    for (final chip in context.read<ChipBankProvider>().chips) {
      if (chip.id != chipTypeId) continue;
      return (chip.name != null && chip.name!.isNotEmpty)
          ? '${fmt.format(chip.value)} · ${chip.name}'
          : fmt.format(chip.value);
    }
    return tr('unknown_chip');
  }
}

/// Read-only display of the composition as originally recorded.
class _OriginalPanel extends StatelessWidget {
  final Map<String, int> original;
  final double originalValue;
  final CurrencyFormatter fmt;
  final String Function(String, CurrencyFormatter) chipLabel;

  const _OriginalPanel({
    required this.original,
    required this.originalValue,
    required this.fmt,
    required this.chipLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                tr('originally_recorded'),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                fmt.formatRaw(originalValue),
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (original.isEmpty)
            Text(
              tr('no_chips_recorded'),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSecondary),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in original.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${chipLabel(e.key, fmt)} × ${e.value}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textPrimary),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EditRow extends StatelessWidget {
  final String label;
  final int was;
  final int available;
  final bool showAvailable;
  /// Localized label for where [available] lives ("In bank" /
  /// "Available at source").
  final String sourceLabel;
  final int? colorValue;
  final int quantity;
  final String lineValue;
  final ValueChanged<int> onChanged;

  const _EditRow({
    required this.label,
    required this.was,
    required this.available,
    required this.showAvailable,
    required this.sourceLabel,
    required this.quantity,
    required this.lineValue,
    required this.onChanged,
    this.colorValue,
  });

  @override
  Widget build(BuildContext context) {
    final exceeds = showAvailable && quantity > available;
    final changed = quantity != was;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: exceeds
              ? AppColors.danger
              : (changed ? AppColors.gold : AppColors.divider),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: colorValue != null
                  ? Color(colorValue!)
                  : AppColors.background,
              shape: BoxShape.circle,
              border: Border.all(
                  color: AppColors.gold.withValues(alpha: 0.4), width: 1.2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  showAvailable
                      ? '${tr('was')}: $was · $sourceLabel: $available'
                      : '${tr('was')}: $was',
                  style: TextStyle(
                    fontSize: 10.5,
                    color:
                        exceeds ? AppColors.danger : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (quantity > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                lineValue,
                style: const TextStyle(
                    fontSize: 11.5, color: AppColors.accentGreen),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniButton(
                icon: Icons.remove,
                onTap: quantity > 0 ? () => onChanged(quantity - 1) : null,
              ),
              Container(
                width: 36,
                alignment: Alignment.center,
                child: Text(
                  '$quantity',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: quantity > 0
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ),
              _MiniButton(
                  icon: Icons.add, onTap: () => onChanged(quantity + 1)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _MiniButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.divider),
        ),
        child: Icon(
          icon,
          size: 15,
          color: onTap == null
              ? AppColors.textSecondary.withValues(alpha: 0.4)
              : AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _EditFooter extends StatelessWidget {
  final CurrencyFormatter fmt;
  final double target;
  final double selected;
  final bool changed;
  final bool saving;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  const _EditFooter({
    required this.fmt,
    required this.target,
    required this.selected,
    required this.changed,
    required this.saving,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final matches = (selected - target).abs() < 0.005;

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
                    Text(tr('transaction_amount'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary)),
                    Text(fmt.formatRaw(target),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary)),
                  ],
                ),
              ),
              Icon(
                matches ? Icons.check_circle_outline : Icons.warning_amber,
                size: 20,
                color: matches ? AppColors.accentGreen : AppColors.warning,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(tr('new_chip_total'),
                        style: const TextStyle(
                            fontSize: 10.5,
                            color: AppColors.textSecondary)),
                    Text(
                      fmt.formatRaw(selected),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: matches
                            ? AppColors.accentGreen
                            : AppColors.warning,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!matches) ...[
            const SizedBox(height: 8),
            Text(
              tr('chip_mismatch_short'),
              style: const TextStyle(fontSize: 11, color: AppColors.warning),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            tr('edit_keeps_audit_trail'),
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
                    onPressed: (!changed || saving) ? null : onSave,
                    icon: saving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check),
                    label: Text(tr('save_composition')),
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
