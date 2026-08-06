import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../providers/chip_bank_provider.dart';
import '../services/chip_tracking_service.dart';

/// Result of the distribution step: which denominations, how many.
/// Null means the banker chose to skip chip tracking entirely.
typedef ChipDistribution = Map<String, int>;

/// Optional step attached to a buy-in / rebuy / add-on.
///
/// DELIBERATELY OPTIONAL AND NEVER BLOCKING
/// The money transaction is the record of account; chips are a parallel
/// physical fact. So this sheet can always be skipped, and a mismatch
/// between chip value and transaction amount produces a *warning*, never
/// a refusal. A banker who is mid-game with a queue of players must never
/// be stopped from recording money because the chip maths is awkward.
class ChipDistributionSheet extends StatefulWidget {
  /// The money amount this distribution should ideally match.
  final double targetAmount;
  final AppCurrency currency;

  /// Pre-filled selection, when editing.
  final ChipDistribution? initial;

  const ChipDistributionSheet({
    super.key,
    required this.targetAmount,
    required this.currency,
    this.initial,
  });

  @override
  State<ChipDistributionSheet> createState() => _ChipDistributionSheetState();
}

class _ChipDistributionSheetState extends State<ChipDistributionSheet> {
  late Map<String, int> _selection;

  @override
  void initState() {
    super.initState();
    _selection = {...?widget.initial};
    if (_selection.isEmpty) {
      // Offer a sensible starting point rather than an empty grid — the
      // banker can adjust from there.
      _selection = ChipTrackingService.suggestDistribution(widget.targetAmount);
    }
  }

  double get _selectedValue => ChipTrackingService.valueOf(_selection);

  /// Tolerance guards against float noise, not real differences.
  bool get _matches => (_selectedValue - widget.targetAmount).abs() < 0.005;

  bool get _bankCanCover => ChipTrackingService.bankCanCover(_selection);

  void _set(String chipId, int qty) {
    setState(() {
      if (qty <= 0) {
        _selection.remove(chipId);
      } else {
        _selection[chipId] = qty;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chips = context.watch<ChipBankProvider>().chips;
    final fmt = CurrencyFormatter(widget.currency);
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.94,
        minChildSize: 0.5,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Icon(Icons.album_outlined,
                        size: 18, color: AppColors.gold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr('chip_distribution'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _selection = ChipTrackingService
                            .suggestDistribution(widget.targetAmount);
                      }),
                      child: Text(tr('suggest_chips')),
                    ),
                    TextButton(
                      onPressed: () => setState(_selection.clear),
                      child: Text(tr('clear_chips')),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    tr('chip_distribution_optional'),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
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
                            _DenominationRow(
                              label: chip.hasName
                                  ? '${fmt.format(chip.value)} · ${chip.name}'
                                  : fmt.format(chip.value),
                              available: ChipTrackingService.quantityAt(
                                  ChipLocation.bank, chip.id),
                              colorValue: chip.colorValue,
                              quantity: _selection[chip.id] ?? 0,
                              onChanged: (q) => _set(chip.id, q),
                              lineValue:
                                  fmt.format(chip.value * (_selection[chip.id] ?? 0)),
                            ),
                        ],
                      ),
              ),

              _Footer(
                fmt: fmt,
                target: widget.targetAmount,
                selected: _selectedValue,
                matches: _matches,
                bankCanCover: _bankCanCover,
                onSkip: () => Navigator.pop(context, <String, int>{}),
                onConfirm: () => Navigator.pop(context, _selection),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DenominationRow extends StatelessWidget {
  final String label;
  final int available;
  final int? colorValue;
  final int quantity;
  final String lineValue;
  final ValueChanged<int> onChanged;

  const _DenominationRow({
    required this.label,
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
            width: 26,
            height: 26,
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
                  '${tr('in_bank')}: $available',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: exceeds
                        ? AppColors.danger
                        : AppColors.textSecondary,
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
          _Stepper(
            value: quantity,
            onChanged: onChanged,
          ),
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
          width: 40,
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

class _Footer extends StatelessWidget {
  final CurrencyFormatter fmt;
  final double target;
  final double selected;
  final bool matches;
  final bool bankCanCover;
  final VoidCallback onSkip;
  final VoidCallback onConfirm;

  const _Footer({
    required this.fmt,
    required this.target,
    required this.selected,
    required this.matches,
    required this.bankCanCover,
    required this.onSkip,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
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
                    Text(tr('target_amount'),
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
                    Text(tr('chip_total'),
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
          if (!bankCanCover) ...[
            const SizedBox(height: 6),
            Text(
              tr('bank_cannot_cover'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.danger),
            ),
          ],

          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onSkip,
                  child: Text(tr('skip_chips')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: onConfirm,
                    icon: const Icon(Icons.check),
                    label: Text(tr('confirm')),
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
