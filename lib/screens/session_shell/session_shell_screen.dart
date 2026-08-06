import 'dart:async';
import '../../core/localization/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/session.dart';
import '../../providers/session_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/hive_service.dart';
import '../../services/sound_service.dart';
import '../../widgets/poker_chip_logo.dart';
import '../../widgets/table_selector_bar.dart';
import '../dashboard/dashboard_tab.dart';
import '../history/transaction_history_screen.dart';
import '../house_rules/house_rules_screen.dart';
import '../players/players_tab.dart';
import '../reports/reports_screen.dart';
import '../settings/settings_screen.dart';
import '../table_view/table_view_tab.dart';
import '../tournament/tournament_tab.dart';
import '../transactions/transactions_tab.dart';

/// Top-level navigation for an active session: Dashboard, Table, Players,
/// Actions, Timeline — the five things a banker actually reaches for
/// during live play. Reports, House Rules, and Settings don't need to be
/// opened mid-hand, so they live behind the AppBar's "More" menu instead
/// of eating a tab slot — speed over tab count.
///
/// "Live Session" from the original nav sketch is this shell itself —
/// Dashboard and Live Session were the same live view, so they're
/// consolidated into one tab rather than duplicated. "History" is now
/// called "Timeline" — same screen, name matches what it actually is:
/// every buy-in, rebuy, cash-out, rake, cash drop, edit, and void, in
/// order. Reports stayed a separate, export-only destination so it and
/// Timeline don't duplicate each other.
class SessionShellScreen extends StatefulWidget {
  final String sessionId;
  const SessionShellScreen({super.key, required this.sessionId});

  @override
  State<SessionShellScreen> createState() => _SessionShellScreenState();
}

class _SessionShellScreenState extends State<SessionShellScreen> {
  static const _dashboardIndex = 0;
  static const _tableIndex = 1;
  static const _playersIndex = 2;
  static const _timelineIndex = 4;

  int _index = _dashboardIndex;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final session = HiveService.sessions.get(widget.sessionId);
    if (session != null) {
      context.read<SessionProvider>().loadSession(session);
    }
    // Drives the live timer on the Dashboard tab without every tab needing
    // its own ticker.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      // The simple session timer piggybacks on this existing tick rather
      // than adding a second one.
      final provider = context.read<SessionProvider>();
      final notice = provider.consumeTimerNotice();
      if (notice != null) _showTimerNotice(notice);
      final blind = provider.consumeBlindNotice();
      if (blind != null) _showBlindNotice(blind);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _goTo(int index) => setState(() => _index = index);

  /// Blind-timer alerts. Same non-modal treatment as the cash-game
  /// timer: a snackbar plus haptic, never a dialog that could land on
  /// top of a transaction the banker is mid-way through recording.
  void _showBlindNotice(BlindTimerNotice notice) {
    if (!mounted) return;
    late final String message;
    late final Color colour;
    switch (notice) {
      case BlindTimerNotice.tenMinutes:
        message = tr('ten_min_remaining');
        colour = AppColors.textSecondary;
        break;
      case BlindTimerNotice.fiveMinutes:
        message = tr('five_min_remaining');
        colour = AppColors.warning;
        break;
      case BlindTimerNotice.oneMinute:
        message = tr('one_min_remaining');
        colour = AppColors.warning;
        break;
      case BlindTimerNotice.levelFinished:
        message = tr('level_finished');
        colour = AppColors.danger;
        break;
    }
    AppSounds.playWithHaptic(SoundEffect.rake);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(
            seconds: notice == BlindTimerNotice.levelFinished ? 10 : 5),
        backgroundColor: colour,
        content: Row(
          children: [
            const Icon(Icons.timer_outlined, color: Colors.black, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message,
                  style: const TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows the one-shot session-timer notice. Deliberately a snackbar
  /// plus haptic rather than a modal: it must never sit on top of a
  /// half-finished transaction the banker is in the middle of recording.
  void _showTimerNotice(SessionTimerNotice notice) {
    if (!mounted) return;
    final finished = notice == SessionTimerNotice.finished;
    AppSounds.playWithHaptic(SoundEffect.rake);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(seconds: finished ? 10 : 6),
        backgroundColor:
            finished ? AppColors.danger : AppColors.warning,
        content: Row(
          children: [
            Icon(finished ? Icons.timer_off_outlined : Icons.timer_outlined,
                color: Colors.black, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                finished ? tr('session_finished') : tr('ten_min_remaining'),
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleUndo(BuildContext context, SessionProvider provider, PokerSession session) {
    final voided = provider.undo();
    if (voided == null || !context.mounted) return;
    final fmt = CurrencyFormatter(session.currency);
    final playerName = voided.playerId == null
        ? 'the table'
        : provider.players
            .firstWhere((p) => p.id == voided.playerId, orElse: () => provider.players.first)
            .name;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Undone: ${voided.type.label} of ${fmt.format(voided.amount)} for $playerName'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final showAddPlayerAction = _index == _tableIndex || _index == _playersIndex;

    // Tournament sessions get the tournament console in the first tab
    // instead of the cash-game dashboard. The two never render together,
    // so neither mode can drive the other's logic.
    final tabs = [
      if (session.isTournament)
        TournamentTab(onViewPlayers: () => _goTo(_playersIndex))
      else
        DashboardTab(
          onViewHistory: () => _goTo(_timelineIndex),
          onViewPlayers: () => _goTo(_playersIndex),
          onViewTable: () => _goTo(_tableIndex),
        ),
      const TableViewTab(),
      const PlayersTab(),
      const TransactionsTab(),
      const HistoryTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const PokerChipLogo(size: 26),
            const SizedBox(width: 10),
            Expanded(child: Text(session.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          // Privacy Mode lives in the AppBar, not buried in Settings: it
          // is needed the instant someone leans over the table, and a
          // banker will not navigate two screens deep to hide numbers.
          Builder(builder: (ctx) {
            final settings = ctx.watch<SettingsProvider>();
            return IconButton(
              tooltip: settings.privacyMode
                  ? 'Show amounts'
                  : 'Hide amounts (privacy mode)',
              onPressed: () => ctx.read<SettingsProvider>().togglePrivacyMode(),
              icon: Icon(
                settings.privacyMode
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: settings.privacyMode ? AppColors.gold : null,
              ),
            );
          }),
          if (showAddPlayerAction)
            IconButton(
              tooltip: tr('add_player'),
              onPressed: () => PlayersTab.showAddPlayerSheet(context),
              icon: const Icon(Icons.person_add_outlined),
            ),
          PopupMenuButton<String>(
            tooltip: tr('more'),
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'undo':
                  _handleUndo(context, provider, session);
                  break;
                case 'redo':
                  provider.redo();
                  break;
                case 'tables':
                  showTableManagerSheet(context);
                  break;
                case 'house_rules':
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const HouseRulesScreen()));
                  break;
                case 'reports':
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => ReportsScreen(sessionId: session.id)));
                  break;
                case 'settings':
                  Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
                  break;
              }
            },
            itemBuilder: (ctx) => [
              // Undo/Redo live here deliberately small and out of the way
              // — a banker reaches for them rarely, and they shouldn't
              // compete for attention with the buttons used constantly.
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
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: [
          NavigationDestination(
            icon: Icon(session.isTournament
                ? Icons.emoji_events_outlined
                : Icons.dashboard_outlined),
            label: session.isTournament ? tr('tournament') : tr('dashboard'),
          ),
          NavigationDestination(
              icon: const Icon(Icons.table_restaurant_outlined),
              label: tr('table')),
          NavigationDestination(
              icon: const Icon(Icons.people_outline), label: tr('players')),
          NavigationDestination(
              icon: const Icon(Icons.bolt_outlined), label: tr('actions')),
          NavigationDestination(
              icon: const Icon(Icons.receipt_long_outlined),
              label: tr('timeline')),
        ],
      ),
    );
  }
}
