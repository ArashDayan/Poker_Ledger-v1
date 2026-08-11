import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../services/export_service.dart';
import '../../services/hive_service.dart';
import '../../services/session_service.dart';
import '../../widgets/balance_check_banner.dart';
import '../../widgets/stat_card.dart';

/// Standalone-Scaffold wrapper around [ReportsTab] for deep links /
/// post-session viewing. The session shell uses [ReportsTab] directly.
class ReportsScreen extends StatelessWidget {
  final String sessionId;
  const ReportsScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('session_report'))),
      body: ReportsTab(sessionId: sessionId),
    );
  }
}

class ReportsTab extends StatefulWidget {
  final String sessionId;
  const ReportsTab({super.key, required this.sessionId});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  bool _exporting = false;

  Future<void> _export(bool pdf) async {
    setState(() => _exporting = true);
    try {
      final session = HiveService.sessions.get(widget.sessionId)!;
      // A tournament gets its own result sheet — prize pool, payouts and
      // final standings — instead of the cash-game settlement layout.
      final file = pdf
          ? (session.isTournament
              ? await ExportService.exportTournamentPdf(session)
              : await ExportService.exportSessionPdf(session))
          : await ExportService.exportSessionCsv(session);
      await ExportService.shareFile(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('export_failed')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = HiveService.sessions.get(widget.sessionId)!;
    final fmt = CurrencyFormatter(session.currency);
    final balance = SessionService.checkBalance(session.id);
    final players = SessionService.playersFor(session.id);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(session.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text('${session.location} · ${tr('table')} ${session.tableNumber}',
            style: const TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 16),
        BalanceCheckBanner(result: balance, formatter: fmt),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.7,
          children: [
            StatCard(label: tr('money_in_buyin_rebuy'), icon: Icons.arrow_downward,
                value: fmt.format(balance.moneyIn)),
            StatCard(label: tr('money_out_cashout_rake'), icon: Icons.arrow_upward,
                value: fmt.format(balance.moneyOut)),
            StatCard(
              label: tr('difference'),
              icon: balance.isBalanced ? Icons.check_circle : Icons.error_outline,
              value: fmt.format(balance.discrepancy),
              valueColor: balance.isBalanced ? AppColors.accentGreen : AppColors.danger,
            ),
            StatCard(label: tr('rake_collected'), icon: Icons.percent,
                value: fmt.format(SessionService.totalRake(session.id)),
                valueColor: AppColors.gold),
            StatCard(label: tr('cash_drops'), icon: Icons.safety_check,
                value: fmt.format(SessionService.totalCashDrop(session.id))),
            StatCard(label: tr('host_profit'), icon: Icons.savings,
                value: fmt.format(SessionService.hostProfit(session.id)),
                valueColor: AppColors.accentGreen),
          ],
        ),
        const SizedBox(height: 20),
        Text(tr('players'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        ...players.map((p) {
          final pl = SessionService.playerProfitLoss(session.id, p.id);
          return Card(
            child: ListTile(
              title: Text('${tr('seat')} ${p.seatNumber} · ${p.name}'),
              trailing: Text(
                '${pl >= 0 ? '+' : ''}${fmt.format(pl)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: pl >= 0 ? AppColors.accentGreen : AppColors.danger,
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _exporting ? null : () => _export(true),
                icon: const Icon(Icons.picture_as_pdf),
                label: Text(tr('export_pdf')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _exporting ? null : () => _export(false),
                icon: const Icon(Icons.table_chart),
                label: Text(tr('export_csv')),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
