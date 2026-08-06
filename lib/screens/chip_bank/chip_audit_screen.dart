import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../providers/chip_bank_provider.dart';
import '../../services/chip_bank_service.dart';
import '../../services/chip_tracking_service.dart';

/// Session chip reconciliation.
///
/// The identity being checked:
///   total owned = bank + tables + players + removed
///
/// The banker optionally enters a physical count of the case. Without it
/// this screen still shows where everything is, but reports no
/// discrepancy — there is nothing independent to compare against, and
/// inventing a number would be worse than useless.
class ChipAuditScreen extends StatefulWidget {
  /// Limit to one session, or null for the whole inventory.
  final String? sessionId;
  final AppCurrency currency;

  const ChipAuditScreen({
    super.key,
    this.sessionId,
    this.currency = AppCurrency.usd,
  });

  @override
  State<ChipAuditScreen> createState() => _ChipAuditScreenState();
}

class _ChipAuditScreenState extends State<ChipAuditScreen> {
  /// chipTypeId -> counted quantity. Absent means "not counted".
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

  @override
  Widget build(BuildContext context) {
    // Watch so the report refreshes the instant a movement is recorded.
    context.watch<ChipBankProvider>();

    final fmt = CurrencyFormatter(widget.currency);
    final report = ChipTrackingService.audit(
      sessionId: widget.sessionId,
      physicalCount: _counts.isEmpty ? null : _counts,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('chip_reconciliation')),
        actions: [
          IconButton(
            tooltip: tr('verify_count'),
            icon: Icon(
              _countMode ? Icons.calculate : Icons.fact_check_outlined,
              color: _countMode ? AppColors.gold : null,
            ),
            onPressed: () => setState(() => _countMode = !_countMode),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _VerdictCard(report: report, fmt: fmt),
          const SizedBox(height: 16),

          _TotalsGrid(report: report),
          const SizedBox(height: 18),

          if (_countMode) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: AppColors.gold.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('physical_count'),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.gold)),
                  const SizedBox(height: 4),
                  Text(tr('physical_count_hint'),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                  const SizedBox(height: 10),
                  ...ChipBankService.allChips().map((chip) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              fmt.format(chip.value),
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textPrimary),
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: TextField(
                              controller: _controllerFor(chip.id),
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 8),
                              ),
                              onChanged: (v) => setState(() {
                                final n = int.tryParse(v.trim());
                                if (n == null) {
                                  _counts.remove(chip.id);
                                } else {
                                  _counts[chip.id] = n;
                                }
                              }),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],

          Text(tr('chip_audit'),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 8),

          if (report.lines.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.divider),
              ),
              child: Text(tr('no_movements_yet'),
                  style: const TextStyle(color: AppColors.textSecondary)),
            )
          else
            ...report.lines.map((l) => _AuditRow(line: l, fmt: fmt)),

          const SizedBox(height: 18),
          _Note(text: tr('players_holding_chips_note')),
          const SizedBox(height: 8),
          _Note(text: tr('chip_tracking_note')),
        ],
      ),
    );
  }
}

class _VerdictCard extends StatelessWidget {
  final ChipAuditReport report;
  final CurrencyFormatter fmt;
  const _VerdictCard({required this.report, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final verified = report.wasVerified;
    final ok = report.balances;

    final Color color;
    final IconData icon;
    final String title;

    if (!verified) {
      color = AppColors.textSecondary;
      icon = Icons.info_outline;
      title = tr('not_verified_note');
    } else if (ok) {
      color = AppColors.accentGreen;
      icon = Icons.verified_outlined;
      title = tr('chips_balanced');
    } else {
      color = AppColors.danger;
      icon = Icons.report_problem_outlined;
      title = tr('chips_discrepancy');
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (verified && !ok) ...[
            const SizedBox(height: 10),
            Text(
              '${report.chipDiscrepancy.abs()} '
              '${report.chipDiscrepancy > 0 ? tr('chips_missing') : tr('chips_extra')}'
              '  ·  ${fmt.formatRaw(report.valueDiscrepancy.abs())}',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Text(tr('possible_locations'),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            ...report.problemLines.map((l) => Text(
                  '• ${fmt.formatRaw(l.chipValue)} — '
                  '${tr('expected_in_bank')} ${l.expectedInBank}, '
                  '${tr('counted_in_bank')} ${l.countedInBank}',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textPrimary),
                )),
          ],
        ],
      ),
    );
  }
}

class _TotalsGrid extends StatelessWidget {
  final ChipAuditReport report;
  const _TotalsGrid({required this.report});

  @override
  Widget build(BuildContext context) {
    final cells = <List<String>>[
      [tr('total_inventory'), '${report.totalInventory}'],
      [tr('in_bank'), '${report.totalInBank}'],
      [tr('on_tables'), '${report.totalOnTables}'],
      [tr('with_players'), '${report.totalWithPlayers}'],
      [tr('removed_chips'), '${report.totalRemoved}'],
      [tr('accounted_for'), '${report.totalAccountedFor}'],
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Wrap(
        runSpacing: 12,
        children: [
          for (final c in cells)
            SizedBox(
              width: (MediaQuery.of(context).size.width - 32 - 28) / 3,
              child: Column(
                children: [
                  Text(c[1],
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(c[0],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textSecondary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  final ChipAuditLine line;
  final CurrencyFormatter fmt;
  const _AuditRow({required this.line, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final bad = line.wasCounted && !line.balances;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: bad ? AppColors.danger : AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  fmt.format(line.chipValue),
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary),
                ),
              ),
              Text(
                '${line.totalInventory} ${tr('total_inventory').toLowerCase()}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Cell(label: tr('in_bank'), value: '${line.inBank}'),
              _Cell(label: tr('on_tables'), value: '${line.onTables}'),
              _Cell(label: tr('with_players'), value: '${line.withPlayers}'),
              _Cell(label: tr('removed_chips'), value: '${line.removed}'),
            ],
          ),
          if (line.wasCounted) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${tr('expected_in_bank')}: ${line.expectedInBank}   ·   '
                    '${tr('counted_in_bank')}: ${line.countedInBank}',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
                Text(
                  line.balances
                      ? '✓'
                      : '${line.discrepancy > 0 ? '−' : '+'}${line.discrepancy.abs()}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: line.balances
                        ? AppColors.accentGreen
                        : AppColors.danger,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final String label;
  final String value;
  const _Cell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary)),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 9.5, color: AppColors.textSecondary)),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline,
            size: 13, color: AppColors.accentGreen),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
                fontSize: 10.5, height: 1.35, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
