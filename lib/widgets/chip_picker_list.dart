import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_type.dart';

/// A denomination picker with no target amount attached.
///
/// WHY THIS IS SEPARATE FROM [ChipDistributionSheet]
/// That sheet exists to compose a specific money amount: it suggests a
/// breakdown, compares against a target, and warns on mismatch. The
/// exchange and player-transfer flows have no money leg at all — there is
/// nothing to match against, and suggesting a breakdown would be actively
/// wrong. So they share the row/stepper presentation but not the
/// target-amount behaviour.
///
/// [available] is the live quantity at the SOURCE location. Going over it
/// is shown in red but not blocked here; the owning sheet decides whether
/// that is fatal, because "the bank is short of $25 chips" is a warning
/// while "this player does not hold those chips" is an error.
class ChipPickerList extends StatelessWidget {
  final List<ChipType> chips;
  final CurrencyFormatter fmt;

  /// chipTypeId -> chosen quantity.
  final Map<String, int> selection;

  /// chipTypeId -> how many exist at the source location.
  final Map<String, int> available;

  /// Label for the availability line, e.g. "In bank" or the player name.
  final String availableLabel;

  final void Function(String chipTypeId, int quantity) onChanged;

  /// Hides denominations the source does not hold at all. Used for the
  /// "give" side of an exchange, where offering a chip the player cannot
  /// possibly hand over is just noise.
  final bool hideUnavailable;

  const ChipPickerList({
    super.key,
    required this.chips,
    required this.fmt,
    required this.selection,
    required this.available,
    required this.availableLabel,
    required this.onChanged,
    this.hideUnavailable = false,
  });

  @override
  Widget build(BuildContext context) {
    final visible = hideUnavailable
        ? chips
            .where((c) =>
                (available[c.id] ?? 0) > 0 || (selection[c.id] ?? 0) > 0)
            .toList()
        : chips;

    if (visible.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          '$availableLabel — 0',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 12, color: AppColors.textSecondary),
        ),
      );
    }

    return Column(
      children: [
        for (final chip in visible)
          _PickerRow(
            label: (chip.name != null && chip.name!.isNotEmpty)
                ? '${fmt.format(chip.value)} · ${chip.name}'
                : fmt.format(chip.value),
            availableLabel: availableLabel,
            available: available[chip.id] ?? 0,
            colorValue: chip.colorValue,
            quantity: selection[chip.id] ?? 0,
            lineValue: fmt.format(chip.value * (selection[chip.id] ?? 0)),
            onChanged: (q) => onChanged(chip.id, q),
          ),
      ],
    );
  }
}

class _PickerRow extends StatelessWidget {
  final String label;
  final String availableLabel;
  final int available;
  final int? colorValue;
  final int quantity;
  final String lineValue;
  final ValueChanged<int> onChanged;

  const _PickerRow({
    required this.label,
    required this.availableLabel,
    required this.available,
    required this.quantity,
    required this.lineValue,
    required this.onChanged,
    this.colorValue,
  });

  @override
  Widget build(BuildContext context) {
    final exceeds = quantity > available;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: exceeds ? AppColors.danger : AppColors.divider,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color:
                  colorValue != null ? Color(colorValue!) : AppColors.background,
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
                  '$availableLabel: $available',
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
          _Stepper(value: quantity, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _Stepper({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SmallButton(
          icon: Icons.remove,
          onTap: value > 0 ? () => onChanged(value - 1) : null,
        ),
        Container(
          width: 36,
          alignment: Alignment.center,
          child: Text(
            '$value',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: value > 0
                  ? AppColors.textPrimary
                  : AppColors.textSecondary,
            ),
          ),
        ),
        _SmallButton(icon: Icons.add, onTap: () => onChanged(value + 1)),
      ],
    );
  }
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _SmallButton({required this.icon, this.onTap});

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
