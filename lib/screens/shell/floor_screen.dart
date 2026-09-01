import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/enums.dart';
import '../../models/session.dart';
import '../../providers/session_provider.dart';
import '../../services/hive_service.dart';
import '../../widgets/poker_chip_logo.dart';
import '../../widgets/session_chrome.dart';
import '../home/session_list_screen.dart';
import '../new_session/new_session_screen.dart';
import '../table_view/table_view_tab.dart';

/// Floor — the live-game destination of the product shell (ICR-02).
///
/// When a session is live this IS the night: the existing
/// [TableViewTab] runs embedded, untouched — same poker table, same
/// geometry, same accounting paths, same seat sheets. The AppBar keeps
/// the two live-workflow actions the old session console carried
/// (privacy toggle, overflow with undo/redo/tables/chip tools) via the
/// shared [SessionOverflowMenu], so no capability was lost when the
/// five-tab console stopped being the product root.
///
/// When nothing is live the Floor is a launcher: start a new session
/// or open the session list to resume a night. Re-entering the tab
/// auto-loads the most recent non-ended session once, so the usual
/// case ("same night continues") never needs a tap.
class FloorScreen extends StatefulWidget {
  const FloorScreen({super.key});

  @override
  State<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends State<FloorScreen> {
  bool _autoloadAttempted = false;

  @override
  void initState() {
    super.initState();
    // Post-frame: loadSession notifies listeners, which must not happen
    // during the first build of the shell.
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoloadLive());
  }

  void _autoloadLive() {
    if (_autoloadAttempted || !mounted) return;
    _autoloadAttempted = true;
    final provider = context.read<SessionProvider>();
    if (provider.current != null) return;

    PokerSession? latest;
    try {
      for (final s in HiveService.sessions.values) {
        if (s.status == SessionStatus.ended) continue;
        if (latest == null || s.dateTime.isAfter(latest!.dateTime)) {
          latest = s;
        }
      }
    } catch (_) {
      return; // sessions box unreadable — the picker below stays up.
    }
    if (latest != null) {
      provider.loadSession(latest!);
      provider.retryFailedWatchers();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current;
    final live = session != null && session.status != SessionStatus.ended;

    if (!live) return const _NightPicker();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const PokerChipLogo(size: 26),
            const SizedBox(width: 10),
            Expanded(
                child: Text(session.name, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: const [
          PrivacyToggleButton(),
          SessionOverflowMenu(includeSwitchNight: true),
        ],
      ),
      body: const TableViewTab(),
    );
  }
}

/// Shown when no night is live. Two honest doors: start one, or open
/// the session list (which also holds ended nights for review).
class _NightPicker extends StatelessWidget {
  const _NightPicker();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const PokerChipLogo(size: 26),
            const SizedBox(width: 10),
            Text(tr('nav_floor')),
          ],
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.table_restaurant_outlined,
                  size: 56, color: AppColors.textSecondary),
              const SizedBox(height: 16),
              Text(
                tr('floor_no_live'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                tr('floor_no_live_hint'),
                style: const TextStyle(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: Text(tr('new_session')),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const NewSessionScreen())),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.history),
                label: Text(tr('sessions')),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SessionListScreen())),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
