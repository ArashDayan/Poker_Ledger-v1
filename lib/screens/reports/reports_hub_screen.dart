import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../services/export_service.dart';
import '../../services/report_service.dart';

/// The reporting centre: lifetime and monthly banker performance, player
/// results across sessions, and PDF/CSV export of each.
///
/// Reached from the home screen, so reports are available without
/// opening a session — a banker reviewing last month's numbers should
/// not have to enter a live game to do it.
class ReportsHubScreen extends StatefulWidget {
  const ReportsHubScreen({super.key});

  @override
  State<ReportsHubScreen> createState() => _ReportsHubScreenState();
}

class _ReportsHubScreenState extends State<ReportsHubScreen> {
  late AppCurrency _currency;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _currency = ReportService.currenciesInUse().first;
  }

  Future<void> _run(Future<File> Function() build) async {
    setState(() => _busy = true);
    try {
      final file = await build();
      await ExportService.shareFile(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencies = ReportService.currenciesInUse();
    final fmt = CurrencyFormatter(_currency);
    final lifetime = ReportService.lifetime(_currency);
    final months = ReportService.monthly(_currency, maxMonths: 6);
    final players = ReportService.playerPerformance(_currency);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('reports')),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // Reports are always scoped to one currency: summing Toman and
          // dollars would produce a meaningless total.
          if (currencies.length > 1) ...[
            SegmentedButton<AppCurrency>(
              segments: [
                for (final c in currencies)
                  ButtonSegment(
                    value: c,
                    label: Text(c == AppCurrency.usd ? 'USD' : tr('toman')),
                  ),
              ],
              selected: {_currency},
              onSelectionChanged: (v) => setState(() => _currency = v.first),
            ),
            const SizedBox(height: 18),
          ],

          _headline(lifetime, fmt),
          const SizedBox(height: 14),

          _card(
            title: tr('banker_profit'),
            subtitle: tr('lifetime_statistics'),
            icon: Icons.trending_up,
            child: Column(
              children: [
                _row(tr('sessions'), '${lifetime.sessions}'),
                _row(tr('entries'), '${lifetime.players}'),
                _row(tr('money_in'), fmt.format(lifetime.moneyIn)),
                _row(tr('total_cash_out'), fmt.format(lifetime.cashedOut)),
                _row(tr('rake_collected'), fmt.format(lifetime.rake)),
                _row(tr('banker_profit'), fmt.format(lifetime.bankerProfit),
                    highlight: true),
              ],
            ),
            onPdf: () => _run(() => ExportService.exportBankerReportPdf(_currency)),
            onCsv: () => _run(() => ExportService.exportBankerReportCsv(_currency)),
          ),

          const SizedBox(height: 12),

          _card(
            title: tr('monthly_statistics'),
            subtitle: '${months.length} ${tr('months')}',
            icon: Icons.calendar_month_outlined,
            child: months.isEmpty
                ? _empty()
                : Column(
                    children: [
                      for (final m in months)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(m.localizedLabel,
                                    style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.bold)),
                              ),
                              Text('${m.sessions}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textSecondary)),
                              const SizedBox(width: 14),
                              Text(fmt.format(m.bankerProfit),
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.gold)),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),

          const SizedBox(height: 12),

          _card(
            title: tr('player_performance'),
            subtitle: '${players.length} ${tr('players')}',
            icon: Icons.groups_outlined,
            child: players.isEmpty
                ? _empty()
                : Column(
                    children: [
                      for (final p in players.take(10))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(p.name,
                                    style: const TextStyle(fontSize: 12.5),
                                    overflow: TextOverflow.ellipsis),
                              ),
                              Text('${p.sessions}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textSecondary)),
                              const SizedBox(width: 14),
                              Text(
                                '${p.net >= 0 ? '+' : ''}${fmt.format(p.net)}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: p.net >= 0
                                      ? AppColors.accentGreen
                                      : AppColors.danger,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (players.length > 10)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '+${players.length - 10} ${tr('more_in_export')}',
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ),
                    ],
                  ),
            onPdf: () =>
                _run(() => ExportService.exportPlayerPerformancePdf(_currency)),
            onCsv: () =>
                _run(() => ExportService.exportPlayerPerformanceCsv(_currency)),
          ),
        ],
      ),
    );
  }

  Widget _headline(PeriodStats s, CurrencyFormatter fmt) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(tr('banker_profit').toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              fmt.format(s.bankerProfit),
              style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: AppColors.gold),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${s.sessions} ${tr('sessions').toLowerCase()} · '
            '${tr('average')} ${fmt.format(s.averagePerSession)}',
            style: const TextStyle(
                fontSize: 11.5, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
    VoidCallback? onPdf,
    VoidCallback? onCsv,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.gold),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold)),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
          if (onPdf != null || onCsv != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                if (onPdf != null)
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _busy ? null : onPdf,
                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 17),
                      label: Text(tr('export_pdf'),
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
                if (onCsv != null)
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _busy ? null : onCsv,
                      icon: const Icon(Icons.table_view_outlined, size: 17),
                      label: Text(tr('export_csv'),
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool highlight = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            Text(value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: highlight ? AppColors.gold : AppColors.textPrimary,
                )),
          ],
        ),
      );

  Widget _empty() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Text(tr('no_data_yet'),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
        ),
      );
}
