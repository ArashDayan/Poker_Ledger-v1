import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/chip_movement.dart';
import '../../models/chip_type.dart';
import '../../models/enums.dart';
import '../../providers/chip_bank_provider.dart';
import '../../services/chip_tracking_service.dart';

/// End-of-session physical chip reconciliation.
///
/// THE ACCOUNTING RULE THIS SCREEN EXISTS TO PROVE
///
///   starting bank = current bank + with players + on tables + removed
///
/// Worked through with the numbers from the spec: a $20,000 bank issues
/// $10,000 in buy-ins and rebuys, takes $8,500 back in cash-outs and $500
/// in rake (rake is collected in chips, so it physically returns to the
/// Bank). The Bank therefore holds 20,000 − 10,000 + 8,500 + 500 =
/// $19,000, players still hold $1,000, and the two add to $20,000 — the
/// same chips that started the night.
///
/// WHY A PHYSICAL COUNT IS THE ONLY REAL CHECK
/// Every figure above is derived from the same movement log, so the
/// identity holds by construction and would report "balanced" even after
/// a genuine loss. It becomes a real reconciliation only when the banker
/// counts the case and enters what is actually there. Until then this
/// screen states plainly that nothing has been verified rather than
/// implying a clean result it cannot support.
///
/// NOTHING HERE WRITES A SINGLE CHIP. There is deliberately no "adjust to
/// match" action: manufacturing or deleting chips to force a zero would
/// destroy the only signal that something went wrong.
class SessionReconciliationScreen extends StatefulWidget {
  /// Limit to one session, or null for the whole inventory.
  final String? sessionId;
  final AppCurrency currency;

  const SessionReconciliationScreen({
    super.key,
    this.sessionId,
    this.currency = AppCurrency.usd,
  });

  @override
  State<SessionReconciliationScreen> createState() =>
      _SessionReconciliationScreenState();
}

class _SessionReconciliationScreenState
    extends State<SessionReconciliationScreen> {
  /// chipTypeId -> counted quantity. Absent means "not counted", which is
  /// distinct from "counted zero" and must stay distinct.
  final Map<String, int> _counts = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _countMode = false;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String id) =>
      _controllers.putIfAbsent(id, TextEditingController.new);

  void _prefillFromExpected() {
    for (final chip in context.read<ChipBankProvider>().chips) {
      final expected =
          ChipTrackingService.quantityAt(ChipLocation.bank, chip.id);
      _controllerFor(chip.id).text = '$expected';
      _counts[chip.id] = expected;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch so the report tracks any movement recorded elsewhere while
    // this screen is open.
    final provider = context.watch<ChipBankProvider>();
    final chips = provider.chips;
    final fmt = CurrencyFormatter(widget.currency);

    final report = ChipTrackingService.reconcile(
      sessionId: widget.sessionId,
      physicalCount: _counts.isEmpty ? null : _counts,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('session_chip_reconciliation')),
      ),
      body: chips.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  tr('no_chips_hint'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                _StatusCard(report: report, fmt: fmt),
                const SizedBox(height: 16),

                Text(tr('chip_accounting'),
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                _AccountingTable(report: report, fmt: fmt),

                const SizedBox(height: 20),
                _PhysicalCountSection(
                  countMode: _countMode,
                  chips: chips,
                  fmt: fmt,
                  counts: _counts,
                  controllerFor: _controllerFor,
                  onToggle: () => setState(() {
                    _countMode = !_countMode;
                    if (!_countMode) {
                      // Leaving count mode discards the count entirely,
                      // returning the report to its unverified state
                      // rather than leaving a half-entered figure that
                      // looks like a verified result.
                      _counts.clear();
                      for (final c in _controllers.values) {
                        c.clear();
                      }
                    }
                  }),
                  onPrefill: () => setState(_prefillFromExpected),
                  onCount: (id, raw) => setState(() {
                    final parsed = int.tryParse(raw.trim());
                    if (raw.trim().isEmpty || parsed == null || parsed < 0) {
                      _counts.remove(id);
                    } else {
                      _counts[id] = parsed;
                    }
                  }),
                ),

                const SizedBox(height: 20),
                _Note(text: tr('reconciliation_never_adjusts')),
              ],
            ),
    );
  }
}

/// The headline verdict: balanced, out by an amount, or not yet verified.
class _StatusCard extends StatelessWidget {
  final ChipReconciliation report;
  final CurrencyFormatter fmt;

  const _StatusCard({required this.report, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final Color colour;
    final IconData icon;
    final String title;
    final String body;

    if (!report.wasVerified) {
      colour = AppColors.textSecondary;
      icon = Icons.help_outline;
      title = tr('not_yet_verified');
      body = tr('not_yet_verified_body');
    } else if (report.balances) {
      colour = AppColors.accentGreen;
      icon = Icons.verified_outlined;
      title = tr('chips_balanced');
      body = tr('chips_balanced_body');
    } else {
      colour = AppColors.danger;
      icon = Icons.error_outline;
      // Positive discrepancy = the log expects more than was counted, so
      // chips are missing. Negative = more chips than expected.
      title = report.discrepancy > 0
          ? tr('chips_missing')
          : tr('chips_surplus');
      body = report.discrepancy > 0
          ? tr('chips_missing_body')
          : tr('chips_surplus_body');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colour, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: colour,
                  ),
                ),
              ),
              if (report.wasVerified)
                Text(
                  fmt.formatRaw(report.discrepancy.abs()),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colour,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
                fontSize: 11.5, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Every figure the banker needs to explain where the chips are, in the
/// order the explanation naturally runs.
class _AccountingTable extends StatelessWidget {
  final ChipReconciliation report;
  final CurrencyFormatter fmt;

  const _AccountingTable({required this.report, required this.fmt});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        children: [
          _Line(
            label: tr('starting_bank_chip_value'),
            value: fmt.formatRaw(report.startingBankValue),
            emphasis: true,
          ),
          const _Divider(),
          _Line(
            label: tr('current_bank_chip_value'),
            value: fmt.formatRaw(report.currentBankValue),
            colour: AppColors.accentGreen,
          ),
          _Line(
            label: tr('chips_held_by_players'),
            value: fmt.formatRaw(report.withPlayers),
          ),
          _Line(
            label: tr('chips_on_tables'),
            value: fmt.formatRaw(report.onTables),
          ),
          _Line(
            label: tr('removed_lost_damaged'),
            value: fmt.formatRaw(report.removed),
            colour: report.removed > 0 ? AppColors.warning : null,
          ),
          const _Divider(),
          // Informational: rake chips are already inside the current bank
          // figure above, so this is a breakdown, not an addend.
          _Line(
            label: tr('rake_returned_to_bank'),
            value: fmt.formatRaw(report.rakeReturnedToBank),
            colour: AppColors.gold,
            hint: tr('included_in_bank_total'),
          ),
          const _Divider(),
          _Line(
            label: tr('expected_total_chips'),
            value: fmt.formatRaw(report.totalAccountedFor),
            emphasis: true,
          ),
          _Line(
            label: tr('physical_count'),
            value: report.wasVerified
                ? fmt.formatRaw(report.countedBankValue!)
                : tr('not_entered'),
            colour: report.wasVerified ? null : AppColors.textSecondary,
            hint: report.wasVerified ? tr('bank_only') : null,
          ),
          const _Divider(),
          _Line(
            label: tr('final_discrepancy'),
            value: report.wasVerified
                ? fmt.formatRaw(report.discrepancy)
                : tr('unverified'),
            emphasis: true,
            colour: !report.wasVerified
                ? AppColors.textSecondary
                : (report.balances
                    ? AppColors.accentGreen
                    : AppColors.danger),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasis;
  final Color? colour;
  final String? hint;

  const _Line({
    required this.label,
    required this.value,
    this.emphasis = false,
    this.colour,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: emphasis ? 13 : 12.5,
                    fontWeight:
                        emphasis ? FontWeight.bold : FontWeight.normal,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasis ? 14.5 : 13,
              fontWeight: emphasis ? FontWeight.bold : FontWeight.w600,
              color: colour ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, color: AppColors.divider);
}

/// Optional physical count of the case, per denomination.
class _PhysicalCountSection extends StatelessWidget {
  final bool countMode;
  final List<ChipType> chips;
  final CurrencyFormatter fmt;
  final Map<String, int> counts;
  final TextEditingController Function(String) controllerFor;
  final VoidCallback onToggle;
  final VoidCallback onPrefill;
  final void Function(String id, String raw) onCount;

  const _PhysicalCountSection({
    required this.countMode,
    required this.chips,
    required this.fmt,
    required this.counts,
    required this.controllerFor,
    required this.onToggle,
    required this.onPrefill,
    required this.onCount,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(tr('physical_count'),
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary)),
            ),
            TextButton.icon(
              onPressed: onToggle,
              icon: Icon(countMode ? Icons.close : Icons.pin_outlined,
                  size: 16),
              label:
                  Text(countMode ? tr('cancel_count') : tr('enter_count')),
            ),
          ],
        ),
        Text(
          tr('physical_count_hint'),
          style: const TextStyle(
              fontSize: 11, color: AppColors.textSecondary),
        ),
        if (countMode) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onPrefill,
              icon: const Icon(Icons.download_outlined, size: 15),
              label: Text(tr('prefill_expected')),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            tr('prefill_expected_hint'),
            style: const TextStyle(
                fontSize: 10.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          for (final chip in chips)
            _CountRow(
              chip: chip,
              fmt: fmt,
              controller: controllerFor(chip.id),
              expected: ChipTrackingService.quantityAt(
                  ChipLocation.bank, chip.id),
              counted: counts[chip.id],
              onChanged: (raw) => onCount(chip.id, raw),
            ),
        ],
      ],
    );
  }
}

class _CountRow extends StatelessWidget {
  final ChipType chip;
  final CurrencyFormatter fmt;
  final TextEditingController controller;
  final int expected;
  final int? counted;
  final ValueChanged<String> onChanged;

  const _CountRow({
    required this.chip,
    required this.fmt,
    required this.controller,
    required this.expected,
    required this.counted,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final delta = counted == null ? 0 : counted! - expected;
    final off = counted != null && delta != 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: off ? AppColors.danger : AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: chip.colorValue != null
                  ? Color(chip.colorValue!)
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
                  fmt.format(chip.value),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary),
                ),
                Text(
                  '${tr('expected')}: $expected'
                  '${off ? ' · ${delta > 0 ? '+' : ''}$delta' : ''}',
                  style: TextStyle(
                    fontSize: 10.5,
                    color:
                        off ? AppColors.danger : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 78,
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                isDense: true,
                hintText: tr('counted'),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 8),
              ),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline,
              size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
