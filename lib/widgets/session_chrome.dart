import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/localization/enum_labels.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../providers/session_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/chip_bank/session_reconciliation_screen.dart';
import '../screens/home/session_list_screen.dart';
import '../screens/house_rules/house_rules_screen.dart';
import '../screens/reports/reports_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../services/financial_ledger_service.dart';
import '../services/session_service.dart';
import 'chip_exchange_sheet.dart';
import 'table_selector_bar.dart';
import 'void_linked_financial_sheet.dart';

/// Session-level chrome shared by the product shell's Floor and the
/// legacy session console.
///
/// WHY THIS FILE EXISTS (ICR-02)
/// Floor | Players | House replaced the five-tab session shell as the
/// product root. The table's live workflow still needs the same
/// session actions regardless of which host is on screen — undo/redo,
/// table manager, chip exchange, chip reconciliation, privacy. Those
/// actions are extracted here ONCE so Floor and the (pushed, legacy)
/// SessionShellScreen can never drift apart on anything that touches
/// money. Nothing in this file changes what any action DOES.
///
/// Zero new behaviour: the implementations are the ones the session
/// shell already ran.

/// The eye icon. Lives right here because it must be reachable the
/// instant someone leans over the table — one tap, never buried in
/// Settings.
class PrivacyToggleButton extends StatelessWidget {
  const PrivacyToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return IconButton(
      tooltip: settings.privacyMode
          ? 'Show amounts'
          : 'Hide amounts (privacy mode)',
      onPressed: () => context.read<SettingsProvider>().togglePrivacyMode(),
      icon: Icon(
        settings.privacyMode
            ? Icons.visibility_off_outlined
            : Icons.visibility_outlined,
        color: settings.privacyMode ? AppColors.gold : null,
      ),
    );
  }
}

/// Opens the per-session chip reconciliation (bank count vs ledger).
Future<void> openSessionReconciliation(BuildContext context) async {
  final session = context.read<SessionProvider>().current;
  if (session == null) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => SessionReconciliationScreen(
      sessionId: session.id,
      currency: session.currency,
    ),
  ));
}

/// Opens the chip exchange sheet for the live session's players.
Future<void> openSessionChipExchange(BuildContext context) async {
  final provider = context.read<SessionProvider>();
  final session = provider.current;
  if (session == null) return;
  await showChipExchangeSheet(
    context,
    players: provider.players,
    currency: session.currency,
    sessionId: session.id,
  );
}

/// Undo the last transaction of the live session, honouring the
/// linked-financial choice flow the ledger requires (ICR-neutral:
/// identical behaviour to the legacy shell's handler).
Future<void> runSessionUndo(BuildContext context) async {
  final provider = context.read<SessionProvider>();
  final session = provider.current;
  if (session == null) return;
  final txs = SessionService.transactionsFor(session.id);
  if (txs.isEmpty) return;
  final last = txs.last;
  final linked = FinancialLedgerService.activeEventsLinkedTo(last.id);
  VoidChipFinancialChoice? choice;
  if (linked.isNotEmpty) {
    choice = await askVoidChipWithLinkedFinancial(
      context,
      transactionId: last.id,
      formatter: CurrencyFormatter(session.currency),
    );
    if (choice == null || !context.mounted) return;
  }
  final voided = provider.undo();
  if (voided == null || !context.mounted) return;
  if (choice == VoidChipFinancialChoice.chipAndReverseLinked) {
    await FinancialLedgerService.reverseLinkedTo(voided.id);
  } else if (choice == VoidChipFinancialChoice.chipOnly && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('void_chip_only_warn'))),
    );
  }
  final fmt = CurrencyFormatter(session.currency);
  final playerName = voided.playerId == null
      ? 'the table'
      : provider.players
          .firstWhere((p) => p.id == voided.playerId,
              orElse: () => provider.players.first)
          .name;
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
          '${tr('undone')}: ${voided.type.localizedLabel} · ${fmt.format(voided.amount)} · $playerName'),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// The "…" overflow of anything hosting a live session. Undo/redo stay
/// deliberately small and out of the way — a banker reaches for them
/// rarely, and they shouldn't compete with buttons used constantly.
///
/// [includeSwitchNight] is Floor's addition: Floor IS the session, so
/// leaving the night (to pick another or end it) is a first-class
/// action there. The legacy console navigates by tabs instead and keeps
/// the historical menu unchanged.
class SessionOverflowMenu extends StatelessWidget {
  final bool includeSwitchNight;
  const SessionOverflowMenu({super.key, this.includeSwitchNight = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    if (session == null) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: tr('more'),
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'undo':
            runSessionUndo(context);
            break;
          case 'redo':
            provider.redo();
            break;
          case 'switch_night':
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SessionListScreen()));
            break;
          case 'tables':
            showTableManagerSheet(context);
            break;
          case 'chip_exchange':
            openSessionChipExchange(context);
            break;
          case 'chip_reconcile':
            openSessionReconciliation(context);
            break;
          case 'house_rules':
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const HouseRulesScreen()));
            break;
          case 'reports':
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReportsScreen(sessionId: session.id)));
            break;
          case 'settings':
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SettingsScreen()));
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'undo',
          enabled: provider.canUndo,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.undo, size: 18),
            title: Text(tr('undo_last'), style: const TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'redo',
          enabled: provider.canRedo,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.redo, size: 18),
            title: Text(tr('redo'), style: const TextStyle(fontSize: 13)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (includeSwitchNight) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'switch_night',
            child: ListTile(
              leading: const Icon(Icons.date_range_outlined),
              title: Text(tr('switch_night')),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'tables',
          child: ListTile(
            leading: const Icon(Icons.table_bar_outlined),
            title: Text(tr('tables')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'chip_exchange',
          enabled: provider.players.isNotEmpty,
          child: ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(tr('chip_exchange')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'chip_reconcile',
          child: ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: Text(tr('session_chip_reconciliation')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'house_rules',
          child: ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: Text(tr('house_rules')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'reports',
          child: ListTile(
            leading: const Icon(Icons.summarize_outlined),
            title: Text(tr('reports')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(tr('settings')),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
