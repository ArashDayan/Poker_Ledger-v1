import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../providers/session_provider.dart';
import '../services/chip_tracking_service.dart';
import '../services/table_service.dart';
import 'chip_distribution_sheet.dart';

/// Phase 2b — table float management: seed / replenish (bank → table),
/// and the table-close count-back return (table → bank).
///
/// The float is DERIVED (the table's chip location), never stored. A
/// negative float on a float-less (home) table is "pot consumption" —
/// reported, never an error (E4 / Phase 0).
Future<void> showTableFloatSheet(
  BuildContext context,
  PokerTable table,
  AppCurrency currency,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final provider = context.read<SessionProvider>();
      final session = provider.current!;
      return _TableFloatSheet(
        table: table,
        sessionId: session.id,
        currency: currency,
      );
    },
  );
}

class _TableFloatSheet extends StatefulWidget {
  final PokerTable table;
  final String sessionId;
  final AppCurrency currency;

  const _TableFloatSheet({
    required this.table,
    required this.sessionId,
    required this.currency,
  });

  @override
  State<_TableFloatSheet> createState() => _TableFloatSheetState();
}

class _TableFloatSheetState extends State<_TableFloatSheet> {
  final TextEditingController _amountCtrl = TextEditingController();
  bool _working = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  /// The table's current derived float position.
  (ChipHolding, double) get _float {
    final holding = ChipTrackingService.tableHolding(widget.table.id);
    return (holding, holding.totalValue);
  }

  /// Seed (empty float) or replenish (existing float): bank → table.
  /// Bank-anchored composition — the chips come from the case.
  Future<void> _fund() async {
    final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
    final isSeed = _float.$2 <= 0;
    final dist = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChipDistributionSheet(
        targetAmount: amount,
        currency: widget.currency,
        source: null, // the Bank
      ),
    );
    if (dist == null || dist.isEmpty || !mounted) return;
    setState(() => _working = true);
    try {
      if (isSeed) {
        await ChipTrackingService.seedTableFloat(
          widget.table.id,
          dist,
          sessionId: widget.sessionId,
        );
      } else {
        await ChipTrackingService.replenishTableFloat(
          widget.table.id,
          dist,
          sessionId: widget.sessionId,
        );
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Table-close count-back: the banker COUNTS THE TRAY; the sheet is
  /// pre-filled with the derived tray, and whatever is confirmed is the
  /// counted (physical) fact. A difference from the derived tray is the
  /// variance slip — recorded in the movement note, never auto-corrected.
  Future<void> _countBackReturn() async {
    final derived = _float.$2;
    final dist = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChipDistributionSheet(
        targetAmount: derived > 0 ? derived : 0,
        currency: widget.currency,
        source: ChipLocation.table(widget.table.id),
      ),
    );
    if (dist == null || !mounted) return; // null = dismissed, {} = skip
    if (dist.isEmpty) return;
    setState(() => _working = true);
    try {
      await ChipTrackingService.returnTableFloat(
        widget.table.id,
        counted: dist,
        sessionId: widget.sessionId,
        note: tr('float_count_back_note'),
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = CurrencyFormatter(widget.currency);
    final (holding, total) = _float;
    final negative = total < -0.005;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.94,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Icon(Icons.table_bar_outlined,
                      size: 18, color: AppColors.accentGreen),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${tr('table_float')} · ${widget.table.name}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  Text(
                    fmt.format(total),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: negative
                          ? AppColors.warning
                          : AppColors.accentGreen,
                    ),
                  ),
                ],
              ),
            ),
            if (negative) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  tr('float_pot_consumption'),
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.warning),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: holding.isEmpty
                  ? Center(
                      child: Text(tr('float_empty'),
                          style: const TextStyle(
                              color: AppColors.textSecondary)),
                    )
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      children: [
                        for (final s in holding.nonEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Text(
                                  '${fmt.format(s.chipValue)} · ${s.quantity}  ·  ${fmt.format(s.totalValue)}',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.textPrimary),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _amountCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(
                              decimal: true),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: tr('float_amount'),
                        prefixText:
                            fmt.symbol == '\$' ? '\$ ' : null,
                        suffixText: fmt.symbol == '\$' ? null : fmt.symbol,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: OutlinedButton(
                      onPressed: _working ? null : _fund,
                      child: Text(
                          total <= 0 ? tr('float_seed') : tr('float_replenish')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 4,
                    child: OutlinedButton(
                      onPressed: _working ? null : _countBackReturn,
                      child: Text(tr('float_return_count')),
                    ),
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
