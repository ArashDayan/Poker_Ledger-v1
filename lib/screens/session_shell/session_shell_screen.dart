import 'dart:async';
import '../../core/localization/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/chip_bank_provider.dart';
import '../../providers/session_provider.dart';
import '../../services/hive_service.dart';
import '../../services/sound_service.dart';

import '../../widgets/poker_chip_logo.dart';
import '../../widgets/session_chrome.dart';
import '../dashboard/dashboard_tab.dart';
import '../history/transaction_history_screen.dart';
import '../players/players_tab.dart';
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
      final provider = context.read<SessionProvider>();
      provider.loadSession(session);
      provider.retryFailedWatchers();
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
      // Per-table countdowns. Each table is evaluated independently, so
      // one finishing never affects another's clock.
      final tableNotice = provider.consumeTableTimerNotice();
      if (tableNotice != null) _showTableTimerNotice(tableNotice);
      // Low chip inventory. Polled on the same tick rather than pushed
      // from the chip provider so a chip write can never trigger a
      // rebuild of the money ledger — the two stay fully decoupled.
      final chipAlert = context.read<ChipBankProvider>().consumeAlert();
      if (chipAlert != null) _showChipBankAlert(chipAlert);
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
  /// A specific table's countdown has run out.
  ///
  /// Names the table explicitly — with several tables running, a bare
  /// "timer finished" would leave the banker guessing. Uses the dedicated
  /// alarm chime rather than a chip sound so it is unmistakable in a
  /// noisy room, and stays a snackbar rather than a dialog so it can
  /// never land on top of a transaction being recorded.
  void _showTableTimerNotice(TableTimerNotice notice) {
    if (!mounted) return;
    AppSounds.playTimerAlarmWithHaptic();
    final messenger = ScaffoldMessenger.of(context);
    // Two tables finishing seconds apart should queue as two distinct
    // alerts, not overwrite one another.
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        backgroundColor: AppColors.danger,
        content: Row(
          children: [
            const Icon(Icons.alarm_on, color: Colors.black, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${notice.tableName} — '
                '${notice.plannedMinutes} ${tr('minute_timer_finished')}',
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: tr('view_table'),
          textColor: Colors.black,
          onPressed: () => _goTo(_tableIndex),
        ),
      ),
    );
  }

  /// Low chip inventory in the Bank.
  ///
  /// NOT SPAMMED, AND CORRECTLY RE-ARMED
  /// [ChipBankProvider.consumeAlert] returns each threshold crossing at
  /// most once and persists the fired flag, so the banker is told once
  /// per crossing even across an app restart. If inventory recovers back
  /// above the threshold the flag resets, so a later crossing alerts
  /// again. All of that logic lives in the provider; this method only
  /// renders whatever it is handed.
  ///
  /// Deliberately a snackbar, never a dialog: a chip warning must not
  /// land on top of a buy-in the banker is mid-way through recording.
  void _showChipBankAlert(ChipBankAlert alert) {
    if (!mounted) return;
    final critical = alert == ChipBankAlert.critical;
    AppSounds.playWithHaptic(SoundEffect.rake);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(seconds: critical ? 10 : 6),
        backgroundColor: critical ? AppColors.danger : AppColors.warning,
        content: Row(
          children: [
            Icon(
              critical
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline,
              color: Colors.black,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                critical
                    ? tr('chip_bank_critical_alert')
                    : tr('chip_bank_low_alert'),
                style: const TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: tr('view'),
          textColor: Colors.black,
          onPressed: () => openSessionReconciliation(context),
        ),
      ),
    );
  }

  // Player-to-player chip transfer REMOVED (E7): a pot being pushed is
  // physical play, not a financial operation. The ledger captures net
  // movement through physical counts; chips that change hands at the
  // table are never recorded player→player.

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

  // Undo/redo/session overflow actions live in widgets/session_chrome.dart
  // (shared with Floor). This console intentionally has no own copy.

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
          // Shared with Floor (session_chrome.dart) so privacy/session
          // actions can never drift between the two live-session hosts.
          const PrivacyToggleButton(),
          if (showAddPlayerAction)
            IconButton(
              tooltip: tr('add_player'),
              onPressed: () => PlayersTab.showAddPlayerSheet(context),
              icon: const Icon(Icons.person_add_outlined),
            ),
          const SessionOverflowMenu(),
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
