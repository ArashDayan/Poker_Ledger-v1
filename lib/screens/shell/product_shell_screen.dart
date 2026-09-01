import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/chip_bank_provider.dart';
import '../../providers/product_nav_controller.dart';
import '../../providers/session_provider.dart';
import '../../services/sound_service.dart';
import '../../widgets/session_chrome.dart';
import '../player_history/players_directory_screen.dart';
import 'floor_screen.dart';
import 'house_hub_screen.dart';

/// Product root of Poker Ledger (ICR-02): **Floor | Players | House**.
///
/// This is the PRODUCT launching a game module, not a session with
/// tabs. Floor runs the live night (the existing poker table), Players
/// is the global Player Master directory, and House holds the
/// house-level tools (chip bank, reports, house rules, configuration).
/// The old five-tab session console ([SessionShellScreen]) survives as
/// a pushed, secondary tool host — it is no longer the product.
///
/// ADAPTIVE LAYOUT
/// Phones get the Material bottom [NavigationBar]. At tablet/desktop
/// widths (≥ 840 logical px) the same destinations move to a
/// [NavigationRail] on the side with the content maximised — the rail
/// is the future sidebar's anchor: an inspector panel to its right is
/// a pure layout addition (a third child in the [Row]), not a
/// restructure. Both presentations share one destination list, so
/// phone and tablet can never offer different products.
///
/// LIVE ALERTS
/// The per-second ticker that delivers timer/blind/table-timer/chip
/// alerts used to live in the session shell; it lives here now because
/// Floor is where live play happens. Notices are only consumed while
/// the shell is the visible route: when a full-screen console or dialog
/// covers it, that screen decides instead of a snackbar vanishing
/// behind the modal barrier.
class ProductShellScreen extends StatefulWidget {
  const ProductShellScreen({super.key});

  /// Width at which bottom navigation becomes a side rail.
  static const double railBreakpoint = 840;

  /// Width at which the rail carries labels beside its icons.
  static const double extendedRailBreakpoint = 1240;

  @override
  State<ProductShellScreen> createState() => _ProductShellScreenState();
}

class _ProductShellScreenState extends State<ProductShellScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Drives live notices (session timer, blind levels, per-table
    // countdowns, low chip inventory) without every destination needing
    // its own ticker. Consumption is gated on visibility so an alert
    // can never be swallowed while this shell is covered by another
    // full-screen route.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      final provider = context.read<SessionProvider>();
      // Nothing live → nothing to re-render and no notices to deliver.
      // (Timers, blind levels and chip alerts all belong to a session;
      // this also keeps the directory/house tabs from rebuilding once
      // per second while the box is idle.)
      if (provider.current == null) return;
      setState(() {});
      final notice = provider.consumeTimerNotice();
      if (notice != null) _showTimerNotice(notice);
      final blind = provider.consumeBlindNotice();
      if (blind != null) _showBlindNotice(blind);
      final tableNotice = provider.consumeTableTimerNotice();
      if (tableNotice != null) _showTableTimerNotice(tableNotice);
      final chipAlert = context.read<ChipBankProvider>().consumeAlert();
      if (chipAlert != null) _showChipBankAlert(chipAlert);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Live notices (renderers unchanged from the pre-ICR-02 session shell:
  // snackbar + haptic, never a dialog over a half-recorded transaction).
  // ---------------------------------------------------------------------

  void _showTimerNotice(SessionTimerNotice notice) {
    if (!mounted) return;
    final finished = notice == SessionTimerNotice.finished;
    AppSounds.playWithHaptic(SoundEffect.rake);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(seconds: finished ? 10 : 6),
        backgroundColor: finished ? AppColors.danger : AppColors.warning,
        content: Row(
          children: [
            Icon(
                finished ? Icons.timer_off_outlined : Icons.timer_outlined,
                color: Colors.black,
                size: 20),
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

  void _showTableTimerNotice(TableTimerNotice notice) {
    if (!mounted) return;
    AppSounds.playTimerAlarmWithHaptic();
    final messenger = ScaffoldMessenger.of(context);
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
          onPressed: () => context.read<ProductNavController>().goToFloor(),
        ),
      ),
    );
  }

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

  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<ProductNavController>();
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= ProductShellScreen.railBreakpoint;

    // One list of destinations, two presentations — phone and tablet
    // can never offer different products by accident.
    const destinations = [
      _Destination(Icons.table_restaurant_outlined, 'nav_floor'),
      _Destination(Icons.people_outline, 'nav_players'),
      _Destination(Icons.home_work_outlined, 'nav_house'),
    ];

    if (useRail) {
      final extended = width >= ProductShellScreen.extendedRailBreakpoint;
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: extended,
              minExtendedWidth: 168,
              labelType: extended
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              selectedIndex: nav.index,
              onDestinationSelected: nav.goTo,
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    label: Text(tr(d.labelKey)),
                  ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            // Content uses the rest. A future inspector panel is a
            // third child here — not a restructure of this shell.
            Expanded(child: _ProductBody(index: nav.index)),
          ],
        ),
      );
    }

    return Scaffold(
      body: _ProductBody(index: nav.index),
      bottomNavigationBar: NavigationBar(
        selectedIndex: nav.index,
        onDestinationSelected: nav.goTo,
        destinations: [
          for (final d in destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              tooltip: tr(d.labelKey),
              label: tr(d.labelKey),
            ),
        ],
      ),
    );
  }
}

class _Destination {
  final IconData icon;
  final String labelKey;
  const _Destination(this.icon, this.labelKey);
}

/// The three product destinations, kept alive while off-screen so a
/// mid-flow Floor state (seat sheet open state aside) survives a quick
/// hop to House and back.
class _ProductBody extends StatelessWidget {
  final int index;
  const _ProductBody({required this.index});

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: index,
      children: const [
        FloorScreen(),
        PlayersDirectoryScreen(),
        HouseHubScreen(),
      ],
    );
  }
}
