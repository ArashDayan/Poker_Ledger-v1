import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/enums.dart';
import '../../providers/product_nav_controller.dart';
import '../../providers/session_provider.dart';
import '../chip_bank/chip_bank_screen.dart';
import '../dashboard/dashboard_tab.dart';
import '../history/hand_history_screen.dart';
import '../history/transaction_history_screen.dart';
import '../home/session_list_screen.dart';
import '../house_rules/house_rules_screen.dart';
import '../players/players_tab.dart';
import '../reports/reports_hub_screen.dart';
import '../settings/settings_screen.dart';
import '../transactions/transactions_tab.dart';

/// House — the back-office destination of the product shell (ICR-02).
///
/// Everything that belongs to the HOUSE rather than to one night at one
/// table: the chip bank (the case/cage inventory), reports, house
/// rules, the session book (past nights — the audit door), and
/// configuration (settings carries backup/export and licensing).
///
/// When a session is live, its working surfaces (dashboards, actions,
/// timeline, seated players, hands) are offered here as pushed,
/// contextual pages too — tools, not navigation. The product spine
/// stays Floor | Players | House; none of these are tabs.
class HouseHubScreen extends StatelessWidget {
  const HouseHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>().current;
    final live = session != null && session.status != SessionStatus.ended;

    return Scaffold(
      appBar: AppBar(title: Text(tr('nav_house'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (live) ...[
            _SectionHeader(tr('session_tools')),
            _ToolTile(
              icon: Icons.dashboard_outlined,
              label: tr('dashboard'),
              onTap: () => _pushTool(
                context,
                title: tr('dashboard'),
                child: DashboardTab(
                  onViewTable: () {
                    Navigator.of(context).pop();
                    context.read<ProductNavController>().goToFloor();
                  },
                  onViewPlayers: () => _pushTool(
                    context,
                    title: tr('players'),
                    child: const PlayersTab(),
                  ),
                  onViewHistory: () => _pushTool(
                    context,
                    title: tr('timeline'),
                    child: const HistoryTab(),
                  ),
                ),
              ),
            ),
            _ToolTile(
              icon: Icons.bolt_outlined,
              label: tr('actions'),
              onTap: () => _pushTool(context,
                  title: tr('actions'), child: const TransactionsTab()),
            ),
            _ToolTile(
              icon: Icons.receipt_long_outlined,
              label: tr('timeline'),
              onTap: () => _pushTool(context,
                  title: tr('timeline'), child: const HistoryTab()),
            ),
            _ToolTile(
              icon: Icons.people_outline,
              label: tr('players'),
              onTap: () => _pushTool(context,
                  title: tr('players'), child: const PlayersTab()),
            ),
            _ToolTile(
              icon: Icons.style_outlined,
              label: tr('hand_history'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => HandHistoryScreen(sessionId: session.id))),
            ),
            const Divider(height: 24),
            _SectionHeader(tr('nav_house')),
          ],
          _ToolTile(
            icon: Icons.inventory_2_outlined,
            label: tr('chip_bank'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChipBankScreen())),
          ),
          _ToolTile(
            icon: Icons.summarize_outlined,
            label: tr('reports'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ReportsHubScreen())),
          ),
          _ToolTile(
            icon: Icons.history,
            label: tr('sessions'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SessionListScreen())),
          ),
          _ToolTile(
            icon: Icons.gavel_outlined,
            label: tr('house_rules'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HouseRulesScreen())),
          ),
          _ToolTile(
            icon: Icons.settings_outlined,
            label: tr('settings'),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            child: Text(
              tr('house_hub_hint'),
              style:
                  const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// Session tools stay ordinary pushed pages with their own AppBar —
  /// the shell's destinations never reshape around a transient session.
  static void _pushTool(BuildContext context,
      {required String title, required Widget child}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: child),
    ));
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.bold,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ToolTile(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.gold),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right,
          size: 18, color: AppColors.textSecondary),
      onTap: onTap,
    );
  }
}
