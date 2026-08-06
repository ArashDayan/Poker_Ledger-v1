import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/chip_type.dart';
import '../../providers/chip_bank_provider.dart';
import '../../services/chip_bank_service.dart';
import '../../providers/settings_provider.dart';
import '../../services/chip_tracking_service.dart';
import 'chip_audit_screen.dart';
import 'chip_editor_sheet.dart';
import 'chip_movements_screen.dart';

/// The banker's physical chip inventory.
///
/// Deliberately reachable from the home screen rather than buried in
/// Settings: counting the case is a routine pre-game task, not a
/// configuration change.
class ChipBankScreen extends StatelessWidget {
  const ChipBankScreen({super.key});

  Future<void> _openEditor(BuildContext context, {ChipType? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChipEditorSheet(existing: existing),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(existing == null ? tr('chip_added') : tr('chip_updated')),
      ));
    }
  }

  Future<void> _remove(BuildContext context, ChipType chip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('remove')),
        content: Text(tr('remove_chip_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            child: Text(tr('remove')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await context.read<ChipBankProvider>().removeChip(chip.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tr('chip_removed'))));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChipBankProvider>();
    final settings = context.watch<SettingsProvider>();
    final fmt = CurrencyFormatter(settings.defaultCurrency);
    final chips = provider.chips;
    final summary = provider.summary;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('chip_bank')),
        actions: [
          IconButton(
            tooltip: tr('chip_movements'),
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChipMovementsScreen(
                currency: settings.defaultCurrency,
              ),
            )),
          ),
          IconButton(
            tooltip: tr('chip_reconciliation'),
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChipAuditScreen(
                currency: settings.defaultCurrency,
              ),
            )),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context),
        icon: const Icon(Icons.add),
        label: Text(tr('add_chip_type')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _SummaryCard(summary: summary, fmt: fmt),
          const SizedBox(height: 12),
          if (!provider.isEmpty) ...[
            _LocationBreakdown(fmt: fmt),
            const SizedBox(height: 18),
          ] else
            const SizedBox(height: 6),

          if (chips.isEmpty)
            _EmptyState(onAdd: () => _openEditor(context))
          else ...[
            Text(
              tr('chip_inventory'),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            ...chips.map((c) => _ChipRow(
                  chip: c,
                  fmt: fmt,
                  onEdit: () => _openEditor(context, existing: c),
                  onRemove: () => _remove(context, c),
                  onAdjust: (delta) =>
                      context.read<ChipBankProvider>().adjustQuantity(
                            c.id,
                            delta,
                          ),
                )),
          ],

          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline,
                  size: 13, color: AppColors.accentGreen),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr('chip_bank_ledger_note'),
                  style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.35,
                      color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Totals for the whole case.
class _SummaryCard extends StatelessWidget {
  final ChipBankSummary summary;
  final CurrencyFormatter fmt;

  const _SummaryCard({required this.summary, required this.fmt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.savings_outlined,
                  size: 17, color: AppColors.gold),
              const SizedBox(width: 8),
              Text(
                tr('total_chip_bank_value'),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.goldLight,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Privacy mode applies: the case is worth real money, and a
          // banker hiding amounts should not have this on show.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              fmt.format(summary.totalValue),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: tr('total_chips'),
                  value: summary.totalChips.toString(),
                ),
              ),
              Container(width: 1, height: 30, color: AppColors.divider),
              Expanded(
                child: _Stat(
                  label: tr('chip_types'),
                  value: summary.typeCount.toString(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
              fontSize: 10.5, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// One denomination.
class _ChipRow extends StatelessWidget {
  final ChipType chip;
  final CurrencyFormatter fmt;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final void Function(int delta) onAdjust;

  const _ChipRow({
    required this.chip,
    required this.fmt,
    required this.onEdit,
    required this.onRemove,
    required this.onAdjust,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        chip.colorValue != null ? Color(chip.colorValue!) : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Colour swatch when set; a neutral chip glyph when not, so
              // a colourless inventory still reads as a list of chips.
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color ?? AppColors.surfaceElevated,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color != null
                        ? Colors.white.withValues(alpha: 0.25)
                        : AppColors.gold.withValues(alpha: 0.45),
                    width: 1.5,
                  ),
                ),
                child: color == null
                    ? const Icon(Icons.album_outlined,
                        size: 19, color: AppColors.gold)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // Value leads, because value is the required
                      // identifier — the name is decoration.
                      '${fmt.format(chip.value)}  ${tr('value_each')}',
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (chip.hasName)
                      Text(
                        chip.name!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textSecondary),
                      ),
                    if (chip.note != null)
                      Text(
                        chip.note!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontStyle: FontStyle.italic,
                          color: AppColors.textSecondary.withValues(alpha: 0.8),
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    fmt.format(chip.totalValue),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.accentGreen,
                    ),
                  ),
                  Text(
                    '${chip.quantity} × ${fmt.format(chip.value)}',
                    style: const TextStyle(
                        fontSize: 10.5, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Quick correction while physically counting the case.
              _StepButton(
                icon: Icons.remove,
                onTap: chip.quantity > 0 ? () => onAdjust(-1) : null,
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${chip.quantity}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _StepButton(icon: Icons.add, onTap: () => onAdjust(1)),
              const Spacer(),
              IconButton(
                tooltip: tr('edit'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined,
                    size: 18, color: AppColors.textSecondary),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: tr('remove'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: AppColors.danger),
                onPressed: onRemove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _StepButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled ? AppColors.divider : AppColors.divider.withValues(alpha: 0.4),
          ),
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled
              ? AppColors.textPrimary
              : AppColors.textSecondary.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Icon(Icons.album_outlined,
              size: 42, color: AppColors.gold.withValues(alpha: 0.5)),
          const SizedBox(height: 14),
          Text(
            tr('no_chips_yet'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr('no_chips_hint'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 11.5, height: 1.4, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 17),
            label: Text(tr('add_chip_type')),
          ),
        ],
      ),
    );
  }
}


/// Where the chips physically are right now, derived from the movement
/// log. Answers the spec's "always show" list at a glance.
class _LocationBreakdown extends StatelessWidget {
  final CurrencyFormatter fmt;
  const _LocationBreakdown({required this.fmt});

  @override
  Widget build(BuildContext context) {
    final bank = ChipTrackingService.bankHolding();
    final removed = ChipTrackingService.removedHolding();
    final tables = ChipTrackingService.allTableHoldings();
    final players = ChipTrackingService.allPlayerHoldings();

    var tableChips = 0;
    var tableValue = 0.0;
    for (final h in tables.values) {
      tableChips += h.totalChips;
      tableValue += h.totalValue;
    }
    var playerChips = 0;
    var playerValue = 0.0;
    for (final h in players.values) {
      playerChips += h.totalChips;
      playerValue += h.totalValue;
    }

    final rows = <List<Object>>[
      [tr('in_bank'), bank.totalChips, bank.totalValue, AppColors.accentGreen],
      [tr('on_tables'), tableChips, tableValue, AppColors.gold],
      [tr('with_players'), playerChips, playerValue, AppColors.textPrimary],
      [tr('removed_chips'), removed.totalChips, removed.totalValue,
          AppColors.warning],
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('chip_tracking'),
            style: const TextStyle(
                fontSize: 11.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: r[3] as Color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r[0] as String,
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.textPrimary),
                    ),
                  ),
                  Text(
                    '${r[1]}',
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 88,
                    child: Text(
                      fmt.format(r[2] as double),
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
